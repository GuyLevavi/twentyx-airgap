#!/usr/bin/env bash
# Run OUTSIDE. Checks release/update.sh's chaining against a fake registry,
# with nix-store, sudo and /run/current-system mocked. No Nix, no root.
#
#   ./scripts/test-update.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
T="$(mktemp -d)"; export T
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/store" "$T/home"

cat > "$T/bin/readlink" <<'M'
#!/usr/bin/env bash
if [ "${!#}" = /run/current-system ]; then cat "$T/current"; else exec /usr/bin/env -S readlink "$@"; fi
M
cat > "$T/bin/nix-store" <<'M'
#!/usr/bin/env bash
case "$1" in
  --check-validity) shift; [ "$1" = --print-invalid ] && shift
                    for p; do grep -qxF "$p" "$T/valid" || echo "$p"; done ;;
  -qR) cat "$T/valid" ;;
esac
M
# "sudo bash <dir>/apply.sh": import the release's paths and switch.
cat > "$T/bin/sudo" <<'M'
#!/usr/bin/env bash
dir="$(dirname "$2")"; rel="$(basename "$dir")"
ls "$dir"/wsl-*.nar.tar.gz > /dev/null
cat "$T/store/$rel/adds" >> "$T/valid"
sed -n 's/^WSL_SYSTEM=//p' "$dir/MANIFEST.txt" > "$T/current"
echo "$rel" >> "$T/log"
M
chmod +x "$T"/bin/*
# readlink mock must not find itself.
sed -i "s|/usr/bin/env -S readlink|$(command -v readlink)|" "$T/bin/readlink"

# mk RELEASE SYSTEM BASE KIND "needs" "paths its apply adds"
mk() {
    local d="$T/store/$1"; mkdir -p "$d"
    { echo "RELEASE=$1"; echo "KIND=$4"; echo "BASE_RELEASE=$3"; [ -z "$2" ] || echo "WSL_SYSTEM=$2"; } > "$d/MANIFEST.txt"
    printf '%s\n' $5 | sed '/^$/d' > "$d/wsl-needs.txt"
    printf '%s\n' $6 | sed '/^$/d' > "$d/adds"
    : > "$d/wsl-$4.nar.tar.gz"; : > "$d/apply.sh"
}
mk R1 ""  R0 delta ""  ""          # an import-only November release
mk R2 S2  R1 delta "a" "S2 b"
mk R3 S3  R2 delta "b" "S3 c"
mk R4 S4  R3 delta "c" "S4 d"
mk R5 S5  R4 delta "a" "S5"        # cut against several bases
mk F  S4  "" full  ""  "S4 a b c d"

fail=0
# check NAME CURRENT "valid paths" TARGET "expected applies" EXPECTED-EXIT
check() {
    rm -rf "$T/home/.cache"; : > "$T/log"
    echo "$2" > "$T/current"; printf '%s\n' $3 > "$T/valid"
    local rc=0
    HOME="$T/home" PATH="$T/bin:$PATH" TWENTYX_STORE_URL="file://$T/store" \
        bash release/update.sh "$4" > "$T/out" 2>&1 || rc=$?
    local got; got="$(tr '\n' ' ' < "$T/log" | sed 's/ $//')"
    if [ "$got" = "$5" ] && [ "$rc" = "$6" ]; then
        echo "ok   $1"
    else
        echo "FAIL $1: applied '$got' exit $rc, wanted '$5' exit $6"; cat "$T/out"; fail=1
    fi
}
check "two behind"                S2 "S2 a b"     R4 "R3 R4"    0
check "on 20261013, three behind" S0 "a"          R4 "R2 R3 R4" 0
check "one behind"                S3 "S3 a b c"   R4 "R4"       0
check "up to date"                S4 "S4 a b c d" R4 ""         0
check "multi-base delta"          S0 "a"          R5 "R5"       0
check "full reset"                S0 ""           F  "F"        0
check "no release fits"           S0 ""           R4 ""         1
check "unknown release"           S2 "S2"         R9 ""         1
exit "$fail"

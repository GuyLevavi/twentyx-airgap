#!/usr/bin/env bash
# Run OUTSIDE the airgap. Produces one tarball to carry across.
#
#   ./scripts/fetch-vendor.sh                    fetch tier 1+2+3, verify, pack
#   ./scripts/fetch-vendor.sh --tier 1           first transfer only (small)
#   ./scripts/fetch-vendor.sh --update-hashes    fill in sha256 = "SKIP" entries
#
# Output: dist/airgap-vendor-<version>.tar.gz  (+ .sha256)
#
# This is the only script permitted to touch the public internet.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
MANIFEST="vendor/manifest.toml"
WORK="vendor/.work"
OUT="dist"
TIER=""
UPDATE_HASHES=0

while [ $# -gt 0 ]; do
    case "$1" in
        --tier)           TIER="$2"; shift 2 ;;
        --update-hashes)  UPDATE_HASHES=1; shift ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

command -v curl >/dev/null || { echo "need curl" >&2; exit 1; }
mkdir -p "$WORK" "$OUT" vendor/bin vendor/lsp

VERSION="$(sed -nE 's/^version[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$MANIFEST" | head -1)"

# --- parse [[artifact]] blocks ---------------------------------------------
# Emits TSV: name url sha256 dest extract
parse() {
    awk '
        /^\[\[artifact\]\]/ { if (name) print name"\t"url"\t"sha"\t"dest"\t"ext
                              name=url=sha=dest=ext=""; next }
        /^[[:space:]]*name[[:space:]]*=/    { match($0,/"[^"]*"/);    name=substr($0,RSTART+1,RLENGTH-2) }
        /^[[:space:]]*url[[:space:]]*=/     { match($0,/"[^"]*"/);    url =substr($0,RSTART+1,RLENGTH-2) }
        /^[[:space:]]*sha256[[:space:]]*=/  { match($0,/"[^"]*"/);    sha =substr($0,RSTART+1,RLENGTH-2) }
        /^[[:space:]]*dest[[:space:]]*=/    { match($0,/"[^"]*"/);    dest=substr($0,RSTART+1,RLENGTH-2) }
        /^[[:space:]]*extract[[:space:]]*=/ { match($0,/"[^"]*"/);    ext =substr($0,RSTART+1,RLENGTH-2) }
        END { if (name) print name"\t"url"\t"sha"\t"dest"\t"ext }
    ' "$MANIFEST"
}

# --- fetch + extract one artifact ------------------------------------------
fetch_one() {
    local name="$1" url="$2" sha="$3" dest="$4" ext="$5"
    local cache="$WORK/$(basename "$url")"
    local target="vendor/$dest"

    if [ ! -f "$cache" ]; then
        echo "  fetch  $name"
        curl -fSL --retry 3 --connect-timeout 20 -o "$cache.part" "$url"
        mv "$cache.part" "$cache"
    else
        echo "  cached $name"
    fi

    local got; got="$(sha256sum "$cache" | cut -d' ' -f1)"
    if [ "$UPDATE_HASHES" = 1 ]; then
        # Rewrite only the sha256 line inside this artifact's block.
        awk -v n="$name" -v h="$got" '
            $0 ~ /^\[\[artifact\]\]/ { inblk=0 }
            $0 ~ "name[[:space:]]*=[[:space:]]*\"" n "\"" { inblk=1 }
            inblk && /^[[:space:]]*sha256[[:space:]]*=/ { sub(/"[^"]*"/, "\"" h "\""); inblk=0 }
            { print }
        ' "$MANIFEST" > "$MANIFEST.tmp" && mv "$MANIFEST.tmp" "$MANIFEST"
    elif [ "$sha" != "SKIP" ] && [ "$got" != "$sha" ]; then
        echo "    MISMATCH $name: want $sha got $got" >&2
        return 1
    fi

    mkdir -p "$(dirname "$target")"
    case "$cache" in
        *.tar.gz|*.tgz|*.tar.xz)
            if [ -n "$ext" ]; then
                # Pull a single member out of the archive, flattening the path.
                tar -xf "$cache" -C "$WORK" --wildcards "$ext" 2>/dev/null || \
                    tar -xf "$cache" -C "$WORK"
                found="$(find "$WORK" -type f -name "$(basename "$ext")" | head -1)"
                [ -n "$found" ] || { echo "    extract failed: $ext" >&2; return 1; }
                mv "$found" "$target"
            else
                mkdir -p "$target" && tar -xf "$cache" -C "$target" --strip-components=1
            fi
            ;;
        *) cp "$cache" "$target" ;;
    esac
    case "$dest" in bin/*) chmod +x "$target" ;; esac
}

echo "==> vendoring (manifest version $VERSION)"
n=0
while IFS=$'\t' read -r name url sha dest ext; do
    [ -n "$name" ] || continue
    fetch_one "$name" "$url" "$sha" "$dest" "$ext" || exit 1
    n=$((n+1))
done < <(parse)

[ "$UPDATE_HASHES" = 1 ] && { echo "==> manifest hashes updated; re-run without --update-hashes"; exit 0; }

# --- checksum the EXTRACTED files -------------------------------------------
# manifest.toml hashes upstream archives; this hashes what actually ships, so
# the build inside the airgap can detect a corrupted physical transfer.
echo "==> generating CHECKSUMS.sha256"
( cd vendor && find . -type f \
    ! -name CHECKSUMS.sha256 ! -path './.work/*' \
    -print0 | sort -z | xargs -0 sha256sum > CHECKSUMS.sha256 )
echo "    $(grep -c . vendor/CHECKSUMS.sha256) files"

# --- pack -------------------------------------------------------------------
TARBALL="$OUT/airgap-vendor-$VERSION.tar.gz"
echo "==> packing $n artifacts"
tar -czf "$TARBALL" vendor/manifest.toml vendor/CHECKSUMS.sha256 vendor/bin vendor/lsp \
    $(ls vendor/*.tar.xz 2>/dev/null || true) \
    $(ls -d vendor/nvim-pack vendor/vsix 2>/dev/null || true)
sha256sum "$TARBALL" > "$TARBALL.sha256"

cat <<EOF

  $TARBALL  ($(du -h "$TARBALL" | cut -f1))
  $(cat "$TARBALL.sha256")

  Next: carry it in, then
    ./scripts/push-artifactory.sh $TARBALL
EOF

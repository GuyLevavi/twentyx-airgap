#!/usr/bin/env bash
# Publish the transfer artifacts to the project's GitLab generic package
# registry. Artifactory stays as the CI fallback (see .gitlab-ci.yml).
#
#   ./scripts/push-gitlab-packages.sh [file-or-dir ...]     default: dist
#
# Every regular file among the arguments goes to
#
#   <api>/projects/<project>/packages/generic/twentyx-airgap/<version>/<filename>
#
# A directory argument means the files directly inside it -- the dist/ layout
# is flat. Version resolution matches push-artifactory.sh: PACKAGE_VERSION, or
# the repo's VERSION file.
#
# Auth, in this order:
#   1. CI  -- CI_API_V4_URL + CI_PROJECT_ID + CI_JOB_TOKEN (JOB-TOKEN header)
#   2. local, GITLAB_TOKEN -- GITLAB_PROJECT (id or group/project) names the
#      project, GITLAB_URL (default https://gitlab.com) or GITLAB_API_URL the
#      instance (PRIVATE-TOKEN header)
#   3. local, no token -- `glab packages upload` when this glab has it,
#      otherwise a token lifted from `glab auth status --show-token` used
#      against the API path of (2)
#
# Download side (for a later consumer, e.g. another project's CI):
#
#   curl -fSL --header "JOB-TOKEN: $CI_JOB_TOKEN" \
#     "$CI_API_V4_URL/projects/$CI_PROJECT_ID/packages/generic/twentyx-airgap/<version>/nix-layer.tar.gz" \
#     -o dist/nix-layer.tar.gz
#
# FIRST TRANSFER: check the GitLab instance's max package size for the
# generic registry before pushing a multi-GB layer. GitLab.com defaults to
# 5 GB per file; self-managed instances may differ (Admin > Settings >
# Preferences, max_package_size). If a layer does not fit, keep
# push-artifactory.sh as the publisher -- the assemble stage in
# .gitlab-ci.yml still falls back to Artifactory.
set -euo pipefail

say() { printf '\033[36m==>\033[0m %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

VERSION="${PACKAGE_VERSION:-$(cat "$(dirname "${BASH_SOURCE[0]}")/../VERSION")}"
PACKAGE=twentyx-airgap

# -- collect the files ------------------------------------------------------
[ $# -gt 0 ] || set -- dist
FILES=()
for arg in "$@"; do
    if [ -d "$arg" ]; then
        for f in "$arg"/*; do
            [ -f "$f" ] && FILES+=("$f")
        done
    elif [ -f "$arg" ]; then
        FILES+=("$arg")
    else
        say "skipping $arg (not a file)"
    fi
done
[ "${#FILES[@]}" -gt 0 ] || die "nothing to upload"

# -- resolve endpoint + auth ------------------------------------------------
API=""
PROJECT=""
AUTH=()

if [ -n "${CI_API_V4_URL:-}" ] && [ -n "${CI_PROJECT_ID:-}" ] && [ -n "${CI_JOB_TOKEN:-}" ]; then
    API="$CI_API_V4_URL"
    PROJECT="$CI_PROJECT_ID"
    AUTH=(-H "JOB-TOKEN: $CI_JOB_TOKEN")
    say "endpoint: $API (CI job token)"
elif [ -n "${GITLAB_TOKEN:-}" ]; then
    GITLAB_URL="${GITLAB_URL:-https://gitlab.com}"
    API="${GITLAB_API_URL:-$GITLAB_URL/api/v4}"
    PROJECT="${CI_PROJECT_ID:-${GITLAB_PROJECT:-}}"
    [ -n "$PROJECT" ] || die "set GITLAB_PROJECT=<id|group/project> alongside GITLAB_TOKEN"
    # group/project -> group%2Fproject; a numeric id passes through
    PROJECT="${PROJECT//\//%2F}"
    AUTH=(-H "PRIVATE-TOKEN: $GITLAB_TOKEN")
    say "endpoint: $API (private token)"
fi

upload_api() {
    local f name url
    say "package: $API/projects/$PROJECT/packages/generic/$PACKAGE/$VERSION/"
    for f in "${FILES[@]}"; do
        name="$(basename "$f")"
        url="$API/projects/$PROJECT/packages/generic/$PACKAGE/$VERSION/$name"
        say "uploading $name ($(du -h "$f" | cut -f1))"
        curl -fSL "${AUTH[@]}" --upload-file "$f" "$url"
        say "uploaded $name"
    done
}

if [ -n "$API" ]; then
    upload_api
    say "done"
    exit 0
fi

# -- 3. glab ----------------------------------------------------------------
# Probed, not assumed: older glab builds have no `packages` group at all, in
# which case the stored token is reused on the API path instead.
if command -v glab >/dev/null 2>&1; then
    if glab packages --help >/dev/null 2>&1 &&
        GLAB_HELP="$(glab packages upload --help 2>&1)"; then
        # Flag names differ across glab releases (--package-name vs --name):
        # read them off this binary's own help and adapt.
        NAME_FLAG=""
        case "$GLAB_HELP" in
            *--package-name*) NAME_FLAG="--package-name" ;;
            *--name*) NAME_FLAG="--name" ;;
        esac
        VERSION_FLAG=""
        case "$GLAB_HELP" in
            *--version*) VERSION_FLAG="--version" ;;
        esac
        if [ -n "$NAME_FLAG" ] && [ -n "$VERSION_FLAG" ]; then
            say "endpoint: glab packages upload ($NAME_FLAG, $VERSION_FLAG)"
            for f in "${FILES[@]}"; do
                say "uploading $(basename "$f") ($(du -h "$f" | cut -f1))"
                glab packages upload "$f" "$NAME_FLAG" "$PACKAGE" "$VERSION_FLAG" "$VERSION"
                say "uploaded $(basename "$f")"
            done
            say "done"
            exit 0
        fi
    fi

    TOKEN="$(glab auth status --show-token 2>/dev/null | sed -n 's/.*Token: //p' | head -1 || true)"
    if [ -n "$TOKEN" ]; then
        GITLAB_URL="${GITLAB_URL:-https://gitlab.com}"
        API="${GITLAB_API_URL:-$GITLAB_URL/api/v4}"
        PROJECT="${CI_PROJECT_ID:-${GITLAB_PROJECT:-}}"
        [ -n "$PROJECT" ] || die "glab token found, but set GITLAB_PROJECT=<id|group/project> so the API path is known"
        PROJECT="${PROJECT//\//%2F}"
        AUTH=(-H "PRIVATE-TOKEN: $TOKEN")
        say "endpoint: $API (glab stored token)"
        upload_api
        say "done"
        exit 0
    fi
fi

die "no GitLab endpoint/token. Set CI_API_V4_URL+CI_PROJECT_ID+CI_JOB_TOKEN (CI), or GITLAB_TOKEN+GITLAB_PROJECT [GITLAB_URL|GITLAB_API_URL] (local), or log in with glab"

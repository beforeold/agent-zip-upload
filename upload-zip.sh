#!/usr/bin/env bash
# upload-zip.sh — upload a .zip to a GitHub Release and print its public download link.
#
# Usage:
#   upload-zip.sh --repo OWNER/NAME [--tag TAG] [--name ASSET.zip] [--create] [--clobber] FILE.zip
#
# Auth (first one found wins): $GITHUB_TOKEN, $GH_TOKEN, `gh auth token`.
# The token needs `repo` (classic) or "Contents: read & write" (fine-grained) on the target repo;
# --create additionally needs permission to create repositories.
#
# Output: one JSON object on stdout, e.g.
#   {"url":"https://github.com/o/r/releases/download/TAG/file.zip", "release_url":..., "sha256":..., ...}
# All progress/errors go to stderr. Exit code 0 only on verified success.
set -euo pipefail

API="${GITHUB_API_URL:-https://api.github.com}"
UPLOADS="${GITHUB_UPLOADS_URL:-https://uploads.github.com}"

die() { echo "upload-zip: error: $*" >&2; exit 1; }
log() { echo "upload-zip: $*" >&2; }

REPO="${ZIP_UPLOAD_REPO:-}"; TAG=""; NAME=""; CREATE=0; CLOBBER=0; FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="${2:-}"; shift 2;;
    --tag) TAG="${2:-}"; shift 2;;
    --name) NAME="${2:-}"; shift 2;;
    --create) CREATE=1; shift;;
    --clobber) CLOBBER=1; shift;;
    -h|--help) sed -n '2,15p' "$0"; exit 0;;
    -*) die "unknown option: $1";;
    *) [ -z "$FILE" ] || die "only one file allowed"; FILE="$1"; shift;;
  esac
done

for bin in curl jq; do command -v "$bin" >/dev/null || die "missing dependency: $bin"; done
[ -n "$FILE" ] || die "no file given (see --help)"
[ -f "$FILE" ] || die "file not found: $FILE"
[ -n "$REPO" ] || die "--repo OWNER/NAME is required (or set ZIP_UPLOAD_REPO)"
[[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "bad --repo: $REPO"

# Must really be a zip: local-file header PK\x03\x04 (or PK\x05\x06 for an empty archive).
MAGIC="$(head -c 4 "$FILE" | od -An -tx1 | tr -d ' \n')"
case "$MAGIC" in 504b0304|504b0506) ;; *) die "not a zip file (magic=$MAGIC): $FILE";; esac

SIZE=$(wc -c < "$FILE" | tr -d ' ')
[ "$SIZE" -lt 2147483648 ] || die "file is ${SIZE} bytes; GitHub release assets must be < 2 GiB"
if command -v shasum >/dev/null; then SHA=$(shasum -a 256 "$FILE" | cut -d' ' -f1)
else SHA=$(sha256sum "$FILE" | cut -d' ' -f1); fi

[ -n "$NAME" ] || NAME="$(basename "$FILE")"
case "$NAME" in *.zip) ;; *) NAME="$NAME.zip";; esac
NAME="$(printf '%s' "$NAME" | tr -c 'A-Za-z0-9._-' '_')"   # GitHub renames odd chars anyway; be explicit
[ -n "$TAG" ] || TAG="zip-$(date -u +%Y%m%d-%H%M%S)-${SHA:0:8}"

TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
if [ -z "$TOKEN" ] && command -v gh >/dev/null; then TOKEN="$(gh auth token 2>/dev/null || true)"; fi
[ -n "$TOKEN" ] || die "no GitHub token: set GITHUB_TOKEN / GH_TOKEN or run 'gh auth login'"

# gh_api METHOD URL [curl args...] -> sets $HTTP (status) and $BODY (response) in the current shell
RESP="$(mktemp)"; trap 'rm -f "$RESP"' EXIT
gh_api() {
  local method="$1" url="$2"; shift 2
  HTTP=$(curl -sS -o "$RESP" -w '%{http_code}' -X "$method" \
    -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" -H "User-Agent: agent-zip-upload" "$@" "$url") \
    || die "network error calling $url"
  BODY="$(cat "$RESP")"
}

# 1. Repo must exist (or be created with --create).
gh_api GET "$API/repos/$REPO"
if [ "$HTTP" = 404 ]; then
  [ "$CREATE" = 1 ] || die "repo $REPO not found (or token cannot see it); pass --create to create it"
  OWNER="${REPO%%/*}"; RNAME="${REPO#*/}"
  gh_api GET "$API/user"; ME=$(echo "$BODY" | jq -r .login)
  PAYLOAD=$(jq -n --arg n "$RNAME" '{name:$n, private:false, auto_init:true, description:"Zip uploads via agent-zip-upload"}')
  if [ "$OWNER" = "$ME" ]; then gh_api POST "$API/user/repos" -d "$PAYLOAD"
  else gh_api POST "$API/orgs/$OWNER/repos" -d "$PAYLOAD"; fi
  [ "$HTTP" = 201 ] || die "create repo failed ($HTTP): $(echo "$BODY" | jq -r '.message? // .')"
  log "created public repo $REPO"
  sleep 2
elif [ "$HTTP" != 200 ]; then
  die "cannot read repo $REPO ($HTTP): $(echo "$BODY" | jq -r '.message? // .')"
fi
PRIVATE=$(echo "$BODY" | jq -r '.private')
DEFAULT_BRANCH=$(echo "$BODY" | jq -r '.default_branch // "main"')

# 2. Releases need a commit to tag. Seed an empty repo with a README.
gh_api GET "$API/repos/$REPO/commits?per_page=1"
if [ "$HTTP" = 409 ]; then
  CONTENT=$(printf '# %s\n\nZip files uploaded as GitHub Release assets.\n' "${REPO#*/}" | base64 | tr -d '\n')
  gh_api PUT "$API/repos/$REPO/contents/README.md" \
    -d "$(jq -n --arg c "$CONTENT" '{message:"Initialize repository", content:$c}')" >/dev/null
  [ "$HTTP" = 201 ] || die "repo is empty and seeding README failed ($HTTP)"
  log "seeded empty repo with README.md"
fi

# 3. Find or create the release for TAG.
gh_api GET "$API/repos/$REPO/releases/tags/$TAG"
if [ "$HTTP" = 404 ]; then
  gh_api POST "$API/repos/$REPO/releases" -d "$(jq -n --arg t "$TAG" --arg b "$DEFAULT_BRANCH" --arg n "$NAME" --arg s "$SHA" \
    '{tag_name:$t, target_commitish:$b, name:$t, body:("Uploaded by agent-zip-upload\n\n- file: `"+$n+"`\n- sha256: `"+$s+"`"), draft:false, prerelease:false}')"
  [ "$HTTP" = 201 ] || die "create release failed ($HTTP): $(echo "$BODY" | jq -c '.errors? // .message? // .')"
  log "created release $TAG"
elif [ "$HTTP" != 200 ]; then
  die "cannot read release $TAG ($HTTP)"
fi
RELEASE_ID=$(echo "$BODY" | jq -r .id)
RELEASE_URL=$(echo "$BODY" | jq -r .html_url)

# 4. Same-name asset already there?
EXISTING=$(echo "$BODY" | jq -r --arg n "$NAME" '.assets[]? | select(.name==$n) | .id')
if [ -n "$EXISTING" ]; then
  [ "$CLOBBER" = 1 ] || die "asset $NAME already exists in release $TAG; pass --clobber to replace it or --name to rename"
  gh_api DELETE "$API/repos/$REPO/releases/assets/$EXISTING"
  [ "$HTTP" = 204 ] || die "delete old asset failed ($HTTP)"
  log "deleted existing asset $NAME"
fi

# 5. Upload.
log "uploading $NAME ($SIZE bytes) to $REPO@$TAG ..."
gh_api POST "$UPLOADS/repos/$REPO/releases/$RELEASE_ID/assets?name=$NAME" \
  -H "Content-Type: application/zip" --data-binary "@$FILE"
[ "$HTTP" = 201 ] || die "upload failed ($HTTP): $(echo "$BODY" | jq -c '.errors? // .message? // .')"
[ "$(echo "$BODY" | jq -r .state)" = uploaded ] || die "asset state is not 'uploaded'"
[ "$(echo "$BODY" | jq -r .size)" = "$SIZE" ] || die "uploaded size mismatch"

jq -n --argjson a "$BODY" --arg repo "$REPO" --arg tag "$TAG" --arg rel "$RELEASE_URL" --arg sha "$SHA" --argjson priv "$PRIVATE" '{
  url: $a.browser_download_url,
  release_url: $rel,
  repo: $repo, tag: $tag, name: $a.name, size: $a.size, sha256: $sha,
  api_asset_url: $a.url,
  public: ($priv | not),
  note: (if $priv then "Repo is private: the url needs GitHub auth to download." else "Anyone can download the url." end)
}'

---
name: github-zip-upload
description: Upload a local .zip file to GitHub as a Release asset and return a stable public download link. Use when an agent needs to publish, share, hand off, or host a zip (build output, dataset, bundle, report) and get back a URL. Works with a GitHub token or the gh CLI; no server needed.
version: 1.0.0
homepage: https://github.com/beforeold/agent-zip-upload
---

# GitHub Zip Upload

Turn a local `.zip` into a link like
`https://github.com/OWNER/REPO/releases/download/TAG/file.zip`
by uploading it as an asset of a GitHub Release.

- Links from **public** repos download for anyone, no login. Links from private repos need GitHub auth.
- One asset must be **< 2 GiB**. A release may hold up to 1000 assets.
- The link is stable as long as the repo, tag and asset name stay the same.

## What you need

1. A GitHub credential with write access to the target repo, found in this order:
   `$GITHUB_TOKEN`, `$GH_TOKEN`, or a logged-in `gh` CLI (`gh auth token`).
   Classic token scope `repo` (or `public_repo` for public repos); fine-grained token: *Contents: Read and write*.
   **Never print, log, or echo the token. Never put it in a URL.**
2. A target repo `OWNER/REPO`. If the user did not name one, ask, or use
   `<your-login>/zip-uploads` with `--create` (creates a **public** repo; tell the user).
3. `bash`, `curl`, `jq` (Path A) — or just `gh` (Path B).

If no credential is available, stop and tell the user to run `gh auth login` or export `GITHUB_TOKEN`.
Do not ask the user to paste a token into chat.

## Path A — bundled script (recommended)

```bash
curl -fsSL https://beforeold.github.io/agent-zip-upload/upload-zip.sh -o upload-zip.sh
chmod +x upload-zip.sh
./upload-zip.sh --repo OWNER/REPO path/to/file.zip
```

Options: `--tag TAG` (default `zip-<UTC time>-<sha256[:8]>`, i.e. one release per upload),
`--name NAME.zip` (asset name), `--create` (create the repo if missing),
`--clobber` (replace a same-name asset in an existing release).

It checks the file is a real zip, seeds an empty repo with a README (releases need a commit),
creates/reuses the release, uploads, verifies size and state, and prints JSON on stdout:

```json
{
  "url": "https://github.com/OWNER/REPO/releases/download/zip-20261110-101500-1a2b3c4d/file.zip",
  "release_url": "https://github.com/OWNER/REPO/releases/tag/zip-20261110-101500-1a2b3c4d",
  "repo": "OWNER/REPO", "tag": "zip-20261110-101500-1a2b3c4d",
  "name": "file.zip", "size": 12345, "sha256": "…",
  "public": true, "note": "Anyone can download the url."
}
```

Return `url` to the user (plus `sha256` if integrity matters). Exit code ≠ 0 means it failed; the reason is on stderr.

## Path B — gh CLI only

```bash
TAG="zip-$(date -u +%Y%m%d-%H%M%S)"
gh release create "$TAG" path/to/file.zip --repo OWNER/REPO --title "$TAG" --notes "Uploaded by agent"
gh release view "$TAG" --repo OWNER/REPO --json assets --jq '.assets[] | select(.name=="file.zip") | .url'
```

(`gh release create` fails on a repo with no commits — add a README first.
To add to an existing release: `gh release upload TAG file.zip --repo OWNER/REPO [--clobber]`.)

## Path C — raw REST (no script, no gh)

```bash
H=(-H "Authorization: Bearer $GITHUB_TOKEN" -H "Accept: application/vnd.github+json")
# 1) create release
REL=$(curl -fsS "${H[@]}" -X POST https://api.github.com/repos/OWNER/REPO/releases \
      -d '{"tag_name":"zip-001","name":"zip-001"}')
ID=$(echo "$REL" | jq -r .id)
# 2) upload asset (note: uploads.github.com, raw bytes, Content-Type application/zip)
curl -fsS "${H[@]}" -H "Content-Type: application/zip" --data-binary @file.zip \
  "https://uploads.github.com/repos/OWNER/REPO/releases/$ID/assets?name=file.zip" | jq -r .browser_download_url
```

## Verify (recommended)

```bash
curl -fsSL "$URL" -o /tmp/check.zip && shasum -a 256 /tmp/check.zip   # must equal the reported sha256
```

## Errors

| Symptom | Cause / fix |
|---|---|
| `401` / `Bad credentials` | Token missing, expired, or wrong. |
| `403` / `404` on the repo | Token lacks access, or repo does not exist (use `--create`). |
| `409` on commits | Repo is empty; the script seeds a README, gh/REST users must add one. |
| `422 already_exists` on upload | Same asset name in that release: use `--clobber`, another `--name`, or a new tag. |
| Link returns 404 to others | Repo is private, or release is still a draft. |

## Do not

- Upload secrets, credentials, or personal data: public release assets are world-readable and get cached/mirrored.
- Use this for files ≥ 2 GiB (split them, or use another host).
- Delete or retag releases you did not create.

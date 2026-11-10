# agent-zip-upload

A public skill any AI agent can read to learn how to **upload a `.zip` to GitHub and get back a download link**.
GitHub itself is the service: files are stored as GitHub Release assets; no server, no shared credentials.

**Skill link (give this to an agent):**

```
https://beforeold.github.io/agent-zip-upload/SKILL.md
```

Mirror: `https://raw.githubusercontent.com/beforeold/agent-zip-upload/main/SKILL.md`

## Example prompt

> Read https://beforeold.github.io/agent-zip-upload/SKILL.md and upload `dist/build.zip` to `my-org/artifacts`. Give me the link.

## Files

- [`SKILL.md`](SKILL.md) — the skill (agent-readable instructions, Agent Skills format).
- [`upload-zip.sh`](upload-zip.sh) — the uploader: `./upload-zip.sh --repo OWNER/REPO file.zip` → JSON with `url`, `sha256`.
- [`index.html`](index.html) — landing page for humans.

## Install as a local skill (Claude Code etc.)

```bash
mkdir -p ~/.claude/skills/github-zip-upload
curl -fsSL https://beforeold.github.io/agent-zip-upload/SKILL.md -o ~/.claude/skills/github-zip-upload/SKILL.md
```

## Security model

The agent uploads with **its own** GitHub credential (`GITHUB_TOKEN`, `GH_TOKEN`, or `gh auth`).
This repo holds no tokens and runs no endpoint, so nobody can upload into your account through it.
Assets in public repos are world-readable — don't upload secrets.

## License

MIT

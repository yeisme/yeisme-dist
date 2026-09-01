# Agent Guidelines

This repository is the **public distribution mirror** for Yeisme binaries. It
mirrors upstream release artifacts; it is not a product source tree.

## Non-negotiables

- Do not check out, rebuild, or vendor private product source code here.
- Do not hand-edit `catalog.json` or anything under `receipts/` (append-only,
  written by `scripts/sync.sh` and CI).
- Do not introduce credentials into workflows; CI gates run anonymous
  (`scripts/check.sh`, `install.sh gitea-mcp`).

## Commands

Start from `MAINTAIN.md` — it is the authoritative entrypoint for layout,
`scripts/sync.sh`, verify policies, and receipts. When asked to operate here,
prefer the maintainer notes over guessing.

## Skill routing

- Active skills are declared in root `.skills/profiles/targets/cli/yeisme-dist.txt`
  and generated with `scripts/skills.sh sync-target cli/yeisme-dist` from the
  monorepo root.
- Use `private-release` for distribution channels, verify policies, and
  token-authenticated install flows.
- Use `ai-native-cli-output-contract` mindset for `install.sh` and catalog
  output changes: stable, machine-parseable, no secrets.

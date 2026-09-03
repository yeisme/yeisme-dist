## 1. Mirror contract

- [x] 1.1 Extend sync fixture parsing for optional declared Skills asset sets without changing catalog schema.
- [x] 1.2 Verify upstream checksums and mirrored SHA-256 for tarball, bundle manifest, install manifest and catalog.
- [x] 1.3 Fail closed on incomplete/mismatched sets and retain previous stable release.

## 2. Verification and docs

- [x] 2.1 Add Eikona/Scaena fixtures and anonymous download checks without private source checkout.
- [x] 2.2 Update `MAINTAIN.md` with exact-byte-only ownership and rollback.
- [x] 2.3 Run `scripts/check.sh` and `openspec validate product-agent-skills-assets-v1 --strict --no-interactive`.

## Verification record

- 2026-09-03: offline Eikona/Scaena Skills asset fixtures passed (14/14 total sync tests).
- 2026-09-03: `scripts/check.sh` passed without credentials or private source checkout.
- 2026-09-03: strict OpenSpec validation passed.
- 2026-09-03 review follow-up: `scripts/check.sh`, all 14 offline sync
  scenarios, package-manifest regeneration checks, and strict OpenSpec
  validation passed again.
- 2026-09-03 review follow-up: ShellCheck passed for the modified scripts with
  the repository-known `SC2012`, `SC2034`, and `SC2329` exclusions.

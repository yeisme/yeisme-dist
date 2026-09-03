# product-agent-skills-assets Specification

## Purpose
TBD - created by archiving change product-agent-skills-assets-v1. Update Purpose after archive.
## Requirements
### Requirement: Dist SHALL mirror declared product Skills assets byte-for-byte

When a product install manifest declares Skills assets, dist SHALL copy the exact upstream
bytes and verify each SHA-256 against the manifest and checksums before catalog promotion.
Dist SHALL NOT unpack, rebuild, curate or semantically index the bundle.

#### Scenario: All declared assets match

- **WHEN** tarball, bundle manifest, install manifest and catalog are present with matching digests
- **THEN** dist SHALL mirror them under the same product tag
- **AND** SHALL record their exact digests in the append-only sync receipt

#### Scenario: One Skills asset is missing

- **WHEN** the install manifest declares an asset that is absent upstream or after mirror
- **THEN** dist SHALL fail the product release sync
- **AND** SHALL keep the previous stable catalog entry unchanged

### Requirement: Legacy releases without Skills declarations SHALL remain compatible

An older install manifest that does not declare product Skills SHALL continue through the
existing binary mirror rules. Optional Skills support SHALL NOT change catalog schema or
retroactively require missing assets.

#### Scenario: An older Eikona release is mirrored

- **WHEN** its existing manifest omits the new shared product Skills fields
- **THEN** dist SHALL apply the existing release validation path
- **AND** SHALL NOT synthesize a Skills bundle or manifest


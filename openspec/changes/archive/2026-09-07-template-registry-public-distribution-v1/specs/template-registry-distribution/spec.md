## ADDED Requirements

### Requirement: Verified public Registry artifacts
Dist SHALL mirror only the declared Registry binaries, checksums, SBOM and Skill assets from a verified private product release.

#### Scenario: Source archive appears
- **WHEN** an upstream release contains an undeclared source archive
- **THEN** verification fails and the release is not promoted

### Requirement: Anonymous installation
Users SHALL install Registry without private repository credentials.

#### Scenario: Clean installation
- **WHEN** a user downloads the public installer without a token
- **THEN** the verified Registry archive installs and can report its version and prompt command surface

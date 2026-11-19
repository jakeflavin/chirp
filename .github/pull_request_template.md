## What this changes

<!-- One or two sentences. Link the issue if there is one. -->

## How I checked it

- [ ] `cd Packages/ChirpCore && swift test` passes
- [ ] The app builds (`Scripts/bootstrap.sh`, then the build command in Docs/DEVELOPMENT.md)
- [ ] I tried the change in a test copy of the app
- [ ] `Scripts/e2e.sh` for the area I touched (`ONLY=…`), if it has a check

## Rules

- [ ] Follows [Docs/CODING-STANDARDS.md](../Docs/CODING-STANDARDS.md) and [Docs/DESIGN.md](../Docs/DESIGN.md)
- [ ] Any new network call is listed in [Docs/PRIVACY.md](../Docs/PRIVACY.md)
- [ ] Docs updated if behaviour or architecture changed
- [ ] No personal data, keys or machine paths in code, tests or fixtures

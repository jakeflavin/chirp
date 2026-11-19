# Releasing

How a new version of Chirp gets from `main` to people's Macs. Only maintainers release.

## Channels

| Channel | Tag | GitHub release | Build | Who gets it |
|---|---|---|---|---|
| Stable | `v0.3.0` | Normal release | `CHIRP_CHANNEL` empty: no beta icon or markers | Everyone |
| Beta | `v0.3.0-beta.1` | Pre-release | `CHIRP_CHANNEL=Beta`: beta icon and markers | People with Settings › Updates › **Get beta versions** on |

Both channels share one app, one bundle id and one library. A beta item in the update feed carries `<sparkle:channel>beta</sparkle:channel>`. Chirp only accepts those when the beta switch is on.

Turning the beta switch off never downgrades. The app stays on its beta until a newer stable version comes out.

## Version numbers

- `MARKETING_VERSION` is the version people see (`0.3.0`). It comes from the tag.
- `CURRENT_PROJECT_VERSION` is the build number. It is the CI run number, so it always goes up. Sparkle compares build numbers.

## Cutting a release

1. Make sure `main` is green in CI.
2. Move the `[Unreleased]` notes in `CHANGELOG.md` under the new version and commit.
3. Tag and push:

   ```bash
   git tag v0.3.0-beta.1
   git push origin v0.3.0-beta.1
   ```

4. The `release` workflow (`.github/workflows/release.yml`) then:
   1. builds Release with the channel taken from the tag;
   2. signs with the Developer ID certificate in a temporary keychain;
   3. sends it to Apple's notary service and staples the ticket;
   4. makes `Chirp.dmg`;
   5. signs the update with Sparkle's `sign_update`;
   6. creates the GitHub release (a pre-release for betas) with `Chirp.dmg` and `sparkle.json` (its version, build,
      channel and update signature) attached;
   7. redeploys the site (`.github/workflows/site.yml`), which writes `appcast.xml` fresh from all the releases
      with `Scripts/appcast.py`. Nothing is committed to `main`.
5. Check the release page, download the DMG on a clean account, and open it. There should be no Gatekeeper warning.

## Secrets the workflow needs

Set these once in the repository's Settings › Secrets and variables › Actions.

| Secret | What it is |
|---|---|
| `APPLE_TEAM_ID` | The team the Developer ID certificate belongs to |
| `MACOS_CERT_P12` | Developer ID Application certificate and key, exported as .p12, base64 |
| `MACOS_CERT_PASSWORD` | Password of that .p12 |
| `NOTARY_KEY` | App Store Connect API key (.p8), base64 |
| `NOTARY_KEY_ID` | That key's id |
| `NOTARY_ISSUER` | The issuer id from App Store Connect › Users and Access › Integrations |
| `SPARKLE_PRIVATE_KEY` | Sparkle EdDSA private key (from `generate_keys -x`) |

The matching public key is `SPARKLE_PUBLIC_KEY` in `Config/Base.xcconfig`, which becomes `SUPublicEDKey` in `Info.plist`. A build with no public key never checks for updates. If the private key is ever lost, people can't update until they download a new build by hand. Keep a copy in a password manager.

## Releasing by hand

If CI is down, run the same script on a Mac with the Developer ID certificate in its keychain and the Sparkle key in its keychain (`generate_keys --account chirp` puts it there):

```bash
xcrun notarytool store-credentials chirp-notary   # once
APPLE_TEAM_ID=… NOTARY_PROFILE=chirp-notary Scripts/release.sh v0.3.0
```

Then create the release by hand with `build/release/Chirp.dmg` and `build/release/sparkle.json` attached (`gh release create`), and run the Site workflow from the Actions tab.

## Before the Developer ID certificate exists

`SIGN_IDENTITY="Apple Development" Scripts/release.sh <tag>` makes a build signed with a development certificate and
not notarized. macOS blocks its first open: people click **Open Anyway** in System Settings › Privacy & Security once.
Permissions survive updates because the signing team stays the same. Updates still check the Sparkle signature.
Once the Developer ID exists, the next release is notarized and reaches everyone through the updater.

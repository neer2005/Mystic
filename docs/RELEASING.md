# Releasing

Pushing a tag such as `v0.2.0` runs `.github/workflows/release.yml`: it runs the engine, C interface and app tests, builds a
release app with the tag's version, packs `Mystic-<version>.dmg` with a checksum, and publishes a GitHub release with generated
notes. A tag with a suffix, such as `v0.2.0-beta.1`, becomes a pre-release, which the app's update check doesn't offer.

```sh
git tag v0.2.0
git push origin v0.2.0
```

## Signing secrets

Under the repository's Settings → Secrets and variables → Actions:

| Secret | What it is |
| --- | --- |
| `DEVELOPER_ID_CERTIFICATE_P12` | A Developer ID Application certificate and key, exported as `.p12`, then `base64 -i certificate.p12` |
| `DEVELOPER_ID_CERTIFICATE_PASSWORD` | The password chosen when exporting it |
| `NOTARY_APPLE_ID` | The Apple ID that notarizes |
| `NOTARY_APP_PASSWORD` | An app-specific password for that Apple ID |
| `NOTARY_TEAM_ID` | The Apple Developer team ID |

These need a paid Apple Developer Program membership. Without all five, the workflow still tests and builds, signs ad-hoc and
leaves the release as a draft, for testing only: macOS blocks such an app on other Macs, and the AWDL helper can't be approved.

## Trying it locally

```sh
MYSTIC_SIGNING_IDENTITY=- MYSTIC_VERSION=0.2.0 bash scripts/build-macos-app.sh release
bash scripts/package-release.sh 0.2.0
```

The runner image is GitHub's Xcode 27 public preview; move to a stable label once one exists.

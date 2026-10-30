# Persistent local signing

`bash scripts/build-macos-app.sh` signs Mystic with a persistent certificate so
Keychain can recognize the app across code changes. No credentials or private keys
are copied into the repository.

The certificate is selected in this order:

1. `MYSTIC_SIGNING_IDENTITY` environment override (certificate SHA-1 or exact name).
2. This checkout's `git config mystic.signingIdentity`.
3. The sole valid `Apple Development` identity in the user's Keychain.

Without a configured identity or exactly one valid Apple Development identity,
the build stops with setup instructions. Signing failures also stop the build;
there is no automatic fallback to ad-hoc signing. The completed app's signature
is verified with `codesign --verify --deep --strict`.

## Setup

List available identities:

```sh
security find-identity -v -p codesigning
```

Select the SHA-1 of your Apple Development certificate locally:

```sh
git config --local mystic.signingIdentity <certificate-SHA-1>
bash scripts/build-macos-app.sh
```

If none exists, use Xcode → Settings → Accounts → your Apple account → Manage
Certificates to create an Apple Development certificate. Keep its private key in
Keychain. If macOS requests permission for `codesign` to use that key, approve the
system prompt yourself. Certificate creation/renewal may require an Apple account.

Launch `.build/Mystic.app` for pairing and streaming. The standalone SwiftPM
executable and test runners have separate code identities; they do not inherit
the app bundle's Keychain approval. Tests use fake credential storage.

On the first run after changing from ad-hoc signing, Keychain may ask once for
each existing Mystic item (client identity and host certificate pins). Choose
**Always Allow** for the signed Mystic app if you want persistent access. Existing
pairings are retained. Future rebuilds using the same certificate and bundle
identifier should retain that approval; a locked Keychain, changed permissions,
certificate renewal or a different signing identity may require approval again.
This does not disable Keychain protection or broaden item access to other apps.

For an intentionally temporary build on a machine without a certificate:

```sh
MYSTIC_SIGNING_IDENTITY=- bash scripts/build-macos-app.sh
```

That explicit override restores ad-hoc signing and its rebuild-related prompts.
It should not be used for routine local gaming builds. This workflow is local
development signing, not Developer ID distribution signing or notarization.

References: [Apple code signing requirements](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements),
[managing signing certificates](https://help.apple.com/xcode/mac/current/en.lproj/dev154b28f09.html),
and [Keychain access prompts](https://support.apple.com/en-ae/guide/keychain-access/kyca1243/mac).

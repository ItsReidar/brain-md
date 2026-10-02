# Releasing Brain.md

Brain.md is released as a DMG on [GitHub Releases](https://github.com/ItsReidar/brain-md/releases) and as a Homebrew cask in the personal tap [`ItsReidar/homebrew-tap`](https://github.com/ItsReidar/homebrew-tap). Everything runs locally on your Mac with two scripts; no paid Apple Developer account or CI minutes are needed.

| Script | What it does | Network |
|---|---|---|
| `scripts/release/package.sh` | Archives a universal (arm64 + x86_64) Release build, signs it, verifies the signature, builds `dist/brain-md-<version>.dmg` + `.sha256`, and renders the cask `dist/brain-md.rb`. | None |
| `scripts/release/publish.sh` | Creates the GitHub release `v<version>` and uploads the DMG, checks that the published download matches the checksum, then commits and pushes the cask to the tap. Asks before every public step. | GitHub |

---

## What "signed without a developer account" means

| | This setup | Paid Developer ID + notarization |
|---|---|---|
| Signature | Ad hoc (or your self-signed certificate) with the hardened runtime | Developer ID Application certificate |
| First launch of a downloaded copy | Blocked once; the user clicks **Open Anyway** | Opens normally |
| Official `homebrew/cask` | Not accepted (casks must pass Gatekeeper since 2026-09-01) | Accepted |
| Personal tap | Works | Works |

- Apple Silicon only runs signed code, so the app is always signed. Without notarization, Gatekeeper rejects quarantined copies (anything downloaded by a browser or by Homebrew) until the user approves them.
- On macOS 15 and later, right-click → **Open** no longer bypasses this. The user must try to open the app once, then go to **System Settings > Privacy & Security** and click **Open Anyway**. The button appears for about an hour after the blocked launch.
- Your free **Apple Development** certificate is not a substitute. It is meant for development, expires yearly, embeds your Apple ID email in every shipped binary, and Gatekeeper still rejects it on other Macs.

## Optional: a stable signing identity (recommended)

Ad-hoc signatures change with every build, so macOS treats each update as a different app. Users would be asked again for Documents access (the default vault lives in `~/Documents`), microphone access, and the firewall prompt for the MCP server port. A self-signed certificate keeps the same identity across updates. It does **not** remove the Gatekeeper prompt.

1. Open **Keychain Access** → **Keychain Access** menu → **Certificate Assistant** → **Create a Certificate…**
2. Name: `Brain.md Self-Signed`, Identity Type: **Self-Signed Root**, Certificate Type: **Code Signing**, then **Create**.
3. Confirm that it is listed: `security find-identity -p codesigning`.
4. Package with it: `SIGN_IDENTITY="Brain.md Self-Signed" scripts/release/package.sh`.
   If `codesign` reports that the certificate is not trusted, open it in Keychain Access and set **Trust > Code Signing** to **Always Trust**.

Back up the certificate and its private key (File → Export Items… as `.p12`, password in your password manager). If you sign with a different certificate later, users have to re-grant permissions once.

## One-time setup

1. Create a **public** GitHub repository named `homebrew-tap` under `ItsReidar`. An empty repo with a README is enough; `publish.sh` creates `Casks/brain-md.rb`.
2. Tap it locally. `publish.sh` uses this clone by default (or pass `--tap-dir PATH`):

   ```bash
   brew tap itsreidar/tap
   ```

3. Install and authenticate the GitHub CLI:

   ```bash
   brew install gh && gh auth login
   ```

## Cutting a release

1. Set the version: update **MARKETING_VERSION** in the Xcode project (General → Identity → Version), or pass `--version` to both scripts. The build number defaults to the commit count.
2. Commit and push. `publish.sh` refuses to publish a dirty tree or a commit GitHub doesn't have, so the tag always matches what was built.
3. Package:

   ```bash
   scripts/release/package.sh
   ```

4. Smoke-test `dist/brain-md-<version>.dmg`: open it, drag Brain.md to Applications, and launch it.
5. Publish:

   ```bash
   scripts/release/publish.sh
   ```

### Updating only the cask

`publish.sh` renders the cask from `packaging/homebrew/brain-md.rb.template` every time. To ship a cask-only change (caveats, `zap` paths, description) for the current version, commit and push the template change, then run:

```bash
scripts/release/publish.sh --skip-release
```

This reuses the DMG already published for the version, checks it against `dist/brain-md-<version>.dmg.sha256`, and pushes only the updated cask to the tap. Don't re-run `package.sh` first: DMG builds aren't byte-for-byte reproducible, so a rebuild would no longer match the published checksum.

## Installing (for users)

```bash
brew install --cask itsreidar/tap/brain-md
```

Or download the DMG from the [latest release](https://github.com/ItsReidar/brain-md/releases/latest) and drag Brain.md into Applications. Both routes require macOS 26 (Tahoe) or later and the one-time **Open Anyway** approval described above. `brew upgrade --cask brain-md` picks up new versions, and `brew uninstall --zap --cask brain-md` also removes app preferences and caches. It never removes your notes vault.

## GitHub Actions (disabled)

`.github/disabled-workflows/release.yml` runs the same two scripts on a `macos-26` runner when a `v*` tag is pushed or when started manually. GitHub only runs workflows from `.github/workflows/`, so it stays inactive until you move it:

```bash
git mv .github/disabled-workflows/release.yml .github/workflows/release.yml
```

Standard GitHub-hosted runners are free for public repositories. Updating the tap from CI needs a fine-grained token with **Contents: read and write** on `ItsReidar/homebrew-tap`, stored as the secret `TAP_GITHUB_TOKEN`. CI signs ad hoc; using a self-signed certificate there would require importing it into a temporary keychain.

## Troubleshooting

- **"brain-md is damaged and can't be opened"**: the signature is broken, usually because files in the bundle changed after signing. Rebuild, then check with `codesign --verify --deep --strict --verbose=2 /Applications/brain-md.app`.
- **Build fails**: `package.sh` prints the last 30 lines; the full log is `build/release/xcodebuild.log`.
- **Checking the cask**: Homebrew only lints casks inside a tap. Run `brew style --cask itsreidar/tap/brain-md` and `brew audit --cask --strict itsreidar/tap/brain-md` after the tap is updated.

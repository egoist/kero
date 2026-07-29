# Releasing kero

kero auto-updates with [Sparkle](https://sparkle-project.org). Releases live in a
**Cloudflare R2** bucket served at **`https://releases.kero.sh`**. New users
download a notarized **`.dmg`**; existing users get smaller in-app delta updates
via Sparkle, which reads the appcast at `https://releases.kero.sh/appcast.xml`,
verifies each build's EdDSA signature, and installs it. One release command
produces both.

Once set up, cutting a release is one command:

```sh
bun scripts/release.ts        # or: bun run release
```

- Updater code: [`kero/Updater.swift`](kero/Updater.swift) — **Check for Updates…**
  (app menu) and the **Updates** section in Settings.
- Feed URL + public key: [`kero/Info.plist`](kero/Info.plist)
  (`SUFeedURL`, `SUPublicEDKey`).
- Release automation (Bun + TypeScript): [`scripts/release.ts`](scripts/release.ts),
  [`scripts/generate-appcast.ts`](scripts/generate-appcast.ts),
  [`scripts/ExportOptions.plist`](scripts/ExportOptions.plist).

---

## One-time setup

The release script runs on [Bun](https://bun.sh) (`brew install bun`) and builds
the disk image with [`create-dmg`](https://github.com/create-dmg/create-dmg)
(`brew install create-dmg`). Optionally run `bun install` once for editor
type-checking of the scripts — it isn't needed to run them.

### 1. Sparkle signing keys

Every update is signed with an ed25519 key. The **private** key stays in your
login keychain; the **public** key ships in the app.

Download the Sparkle tools (`Sparkle-<version>.tar.xz` from the
[releases page](https://github.com/sparkle-project/Sparkle/releases)), unpack,
then:

```sh
./bin/generate_keys
```

Copy the printed public key into [`kero/Info.plist`](kero/Info.plist), replacing
the placeholder `SUPublicEDKey` (it decodes to `REPLACE-ME-WITH-REAL-SPARKLE-KEY`,
so it's obvious if you forget). Back the private key up somewhere safe:

```sh
./bin/generate_keys -x sparkle_private_key.txt   # export → password manager
./bin/generate_keys -f sparkle_private_key.txt   # import on another machine / CI
```

> ⚠️ Lose the private key and you can't ship updates to existing users. Keep it.

Put the Sparkle `bin/` on your `PATH`, or point the release at it with
`SPARKLE_BIN=/path/to/Sparkle/bin`.

### 2. Developer ID signing + notarization

Sparkle needs the app signed with your **Developer ID** and **notarized**
(Gatekeeper blocks un-notarized apps; Hardened Runtime is already enabled in the
project).

- Install your **Developer ID Application** certificate in the login keychain.
  The script signs the `.dmg` with it too; if you have more than one such cert,
  set `SIGN_IDENTITY` to the exact name or SHA-1.
- Set `teamID` in [`scripts/ExportOptions.plist`](scripts/ExportOptions.plist)
  (find it with `xcrun security find-identity -v -p codesigning`).
- Store notarization credentials once as a keychain profile named `NOTARY`:
  ```sh
  xcrun notarytool store-credentials NOTARY \
    --apple-id you@example.com --team-id XXXXXXXXXX
  # (paste an app-specific password, or use --key for an App Store Connect API key)
  ```

### 3. Cloudflare R2 bucket + domain

1. Create an R2 bucket (default name the script expects: `kero-releases` — or set
   `R2_BUCKET`).
2. Attach the custom domain **`releases.kero.sh`** to the bucket
   (R2 → your bucket → Settings → Custom Domains). This serves objects publicly
   at `https://releases.kero.sh/<file>`.
3. Create an **R2 API token** (R2 → Manage API Tokens → Object Read & Write).
   It only needs access to this one bucket — the script passes
   `--s3-no-check-bucket`, so no bucket-creation permission is required.

### 4. rclone remote for R2

The script uses [rclone](https://rclone.org) to sync the bucket
(`brew install rclone`). Add an R2 remote named `r2` — either run
`rclone config` (type **S3**, provider **Cloudflare**), or drop this into
`~/.config/rclone/rclone.conf`:

```ini
[r2]
type = s3
provider = Cloudflare
access_key_id = <R2 access key id>
secret_access_key = <R2 secret access key>
endpoint = https://<ACCOUNT_ID>.r2.cloudflarestorage.com
region = auto
no_check_bucket = true
```

`no_check_bucket = true` stops rclone from trying to create the (already
existing) bucket — needed for bucket-scoped tokens. The script also passes
`--s3-no-check-bucket`, so this line is belt-and-suspenders.

Verify with `rclone lsf r2:kero-releases --s3-no-check-bucket`.

---

## Cutting a release

1. **Bump the version** in the `kero` target's build settings:
   - `MARKETING_VERSION` — user-visible, e.g. `1.1` (`CFBundleShortVersionString`).
   - `CURRENT_PROJECT_VERSION` — build number, e.g. `2` (`CFBundleVersion`).
     **Must increase every release** — Sparkle compares it to decide what's newer.
2. **Write the release notes** — add a `## [1.1]` section at the top of
   [`CHANGELOG.md`](CHANGELOG.md) (the heading must match `MARKETING_VERSION`).
3. **Run it:**
   ```sh
   bun scripts/release.ts        # or: bun run release
   ```

That's it. The script archives → exports a Developer ID app → builds a
notarized, stapled **`.dmg`** → staples the app and zips it for Sparkle →
attaches the matching `CHANGELOG.md` section as release notes → pulls the 15
most recent archives from R2 by default (so Sparkle can build deltas) →
regenerates `appcast.xml` → uploads the DMG and the update archives to R2. When
it finishes:

- **Download link** (for the website): `https://releases.kero.sh/kero-<version>.dmg`
- **In-app updates**: served from the same origin via the appcast.

Notarizing the DMG also notarizes the app's code, so the script staples both from
a single submission — the DMG for direct downloads, the app for the Sparkle zip.

Finally it bumps the **Homebrew cask** (see below).

Test by running an **older** build and choosing **Check for Updates…**.

### Options

| Env | Default | Purpose |
| --- | --- | --- |
| `R2_BUCKET` | `kero-releases` | R2 bucket name |
| `R2_REMOTE` | `r2` | rclone remote name |
| `NOTARY_PROFILE` | `NOTARY` | `notarytool` keychain profile |
| `SIGN_IDENTITY` | `Developer ID Application` | codesigning identity for the DMG |
| `EXPORT_OPTIONS` | `scripts/ExportOptions.plist` | export config |
| `DOWNLOAD_URL_PREFIX` | `https://releases.kero.sh/` | base URL in the appcast |
| `HISTORY_COUNT` | `15` | number of recent archives to pull for delta generation |
| `TAP_REPO` | `egoist/homebrew-tap` | tap holding the Homebrew cask |
| `TAP_CASK` | `Casks/kero.rb` | cask path within the tap |
| `TAP_DIR` | `build/homebrew-tap` | local checkout of the tap |
| `FORCE=1` | — | re-release a version that already exists |
| `NO_TAP=1` | — | skip bumping the Homebrew cask |
| `NO_HISTORY=1` | — | skip pulling old archives (full updates, no deltas) |

---

## The Homebrew cask

kero is also installable with `brew install egoist/tap/kero`, from the
cask at [`egoist/homebrew-tap`](https://github.com/egoist/homebrew-tap)
(`Casks/kero.rb`). The cask downloads the same `.dmg` from R2, so it needs the
new version and its `sha256` after every release.

`scripts/release.ts` does that for you as its last step
([`scripts/bump-cask.ts`](scripts/bump-cask.ts)): it hashes the DMG it just
built, clones/refreshes the tap under `build/homebrew-tap`, rewrites the
`version` and `sha256` stanzas, and pushes a `kero <version>` commit. It needs
**push access to the tap over SSH** — nothing else.

The bump runs *after* the upload, so the hash always covers a DMG that's already
fetchable, and a failure there is a warning rather than a failed release — the
release is live either way. Retry it on its own:

```sh
bun scripts/bump-cask.ts 1.1     # downloads the published DMG if it's not in build/
```

Re-running when the cask already names that version is a no-op. Set `NO_TAP=1`
to skip the bump entirely.

The cask's `depends_on macos:` mirrors the app's `LSMinimumSystemVersion`, which
the bump doesn't touch — it only warns when the two drift apart. If you raise the
deployment target, edit that stanza in the tap by hand.

---

## Notes

- **Two artifacts per release:** a notarized `.dmg` (what people download) and a
  `.zip` (what Sparkle installs, with binary deltas). Only the `.zip` goes in the
  appcast; point your website's download button at
  `https://releases.kero.sh/kero-<version>.dmg`. Want a stable URL? Add a
  Cloudflare redirect from e.g. `/download` to the newest `.dmg`.
- **Automatic checks:** by default Sparkle asks the user once whether to allow
  automatic update checks. To opt in by default (no prompt), add to
  [`kero/Info.plist`](kero/Info.plist):
  ```xml
  <key>SUEnableAutomaticChecks</key>
  <true/>
  ```
  The **Updates** settings toggle lets users change it either way.
- **Release notes** live in [`CHANGELOG.md`](CHANGELOG.md). The release script
  publishes the matching version section as `kero-<version>.md` next to the
  archive, and `generate_appcast` links it as the update's release notes
  (Sparkle 2.9+ renders Markdown). No matching section → the release just ships
  without notes. Notes for older versions stay in R2, so they keep showing.
- Until the real `SUPublicEDKey` is in place, the app runs and checks the feed
  fine, but installing an update fails signature verification by design.
- kero isn't sandboxed, so no Sparkle XPC services need bundling.
- Old archives stay in R2 so users far behind can still download them. Only the
  recent archives needed for new deltas are staged under `build/`, which is
  git-ignored.

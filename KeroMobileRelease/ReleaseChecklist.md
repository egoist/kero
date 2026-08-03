# Kero for iOS 0.0.1 Release Checklist

The source project is intended to be release-candidate ready without adding
file transfer. The remaining unchecked items require the App Store account,
legal owner, a public web host, physical devices, or a review server.

## Product and legal

- [ ] Confirm the final App Store name, seller name, copyright, pricing, and
      availability.
- [ ] Decide the iOS distribution license. The repository is GPLv3, while App
      Store distribution terms and DRM can create compatibility concerns.
      Obtain appropriate advice and dual-license the iOS app if needed before
      uploading it. Do not silently change the repository license.
- [ ] Confirm trademark rights for the Kero name and icon.
- [x] Keep the 1.0 scope focused on interactive SSH; no SFTP/file-transfer
      subsystem is included.

## Account and signing

- [ ] Create the App Store Connect record for bundle ID `sh.kero.mobile`.
- [ ] Set the Xcode development team and confirm the bundle ID belongs to that
      account.
- [ ] Create or refresh distribution signing assets through Xcode.
- [ ] Set the legal copyright value in App Store Connect.
- [ ] Increment `CURRENT_PROJECT_VERSION` for every uploaded build.

## Privacy and compliance

- [x] Include an app privacy manifest with the required UserDefaults reason.
- [x] Provide an in-app privacy policy and an Erase All Data control.
- [ ] Publish `PrivacyPolicy.md` at https://kero.sh/privacy and a support page
      with a working contact path at https://kero.sh/support; verify both are
      reachable without authentication.
- [ ] Complete App Store privacy answers against the exact release binary.
      The current implementation supports **Data Not Collected**.
- [ ] Complete Apple's encryption export-compliance questionnaire. Kero
      implements industry-standard SSH cryptography through SwiftNIO SSH and
      Swift Crypto rather than relying exclusively on encryption built into
      the operating system.
- [ ] If Apple supplies or requires export documentation or a compliance code,
      upload the documentation and add the resulting
      `ITSEncryptionExportComplianceCode` value to the target. Do not guess
      `ITSAppUsesNonExemptEncryption`.
- [x] Bundle the complete MIT and Apache 2.0 license texts plus applicable
      third-party notices, and expose them in Settings.

## Store listing

- [ ] Copy and review `AppStoreMetadata.md`.
- [ ] Verify support and marketing URLs.
- [ ] Complete age-rating and content-rights questionnaires.
- [ ] Capture required current iPhone and iPad screenshot sizes from a release
      build using only synthetic server data.
- [ ] Add accessible screenshot captions and review the listing on phone and
      desktop App Store previews.
- [ ] Provide an isolated, non-privileged, time-limited SSH review account and
      its verified SHA-256 host-key fingerprint in Review Notes.
- [ ] Keep the review server reachable until the version is approved.

## Stable toolchain and archive

- [ ] Install the current stable Xcode accepted by App Store Connect. Do not
      upload an archive produced by a beta Xcode.
- [ ] Run `bun scripts/release-ios-testflight.ts --dry-run` to verify the
      stable Xcode, signing team, export options, version, and next build
      number. Run the same command without `--dry-run` to execute the offline
      test pass, reserve that build number, archive, upload, and verify Apple's
      upload receipt. Use `--build N --skip-tests` only to retry the same
      release candidate after an upload failure.
- [x] Resolve packages from the committed `Package.resolved` file.
- [x] Run unit, loopback SSH integration, UI, and static analyzer checks.
- [x] Build Debug and Release for a generic iOS device with no warnings.
- [ ] Archive with distribution signing, then run **Validate App** in Xcode
      Organizer.
- [x] Inspect the unsigned local archive: no source README, test bundles,
      secrets, review
      credentials, or unexpected files; privacy and license resources present.
- [ ] Upload to App Store Connect and confirm processing completes without
      privacy-manifest, icon, signing, or export-compliance warnings.

The checked local validation items were completed with the installed Xcode 27
beta. Repeat them with Apple's accepted stable Xcode before signing or upload.

## Physical-device release pass

- [ ] Test the release candidate on the oldest supported iOS 18 device and the
      latest iOS version.
- [ ] Test a current iPhone and iPad in portrait and landscape, light and dark
      appearances, large Dynamic Type, VoiceOver, and Reduce Motion.
- [ ] Test software and hardware keyboards, Unicode input, selection, links,
      all touch keys, terminal resize, and rotation during an active session.
- [ ] Test password authentication with and without Face ID/passcode
      protection.
- [ ] Generate an Ed25519 key, install its public half on a test server,
      authenticate with it, copy/share it, and delete it.
- [ ] Test IPv4, IPv6, DNS names, non-default ports, local-network permission,
      bad credentials, unreachable servers, first-use trust, rejected keys,
      and changed-host-key warnings.
- [ ] Background and foreground the app, confirm the privacy shield protects
      the app-switcher snapshot, then reconnect and resume a tmux session.
- [ ] Erase All Data and confirm host metadata, passwords, keys, trusted host
      identities, and settings are gone after relaunch.
- [ ] Run a TestFlight pass with at least one tester who did not build the app.

## Submission

- [ ] Select the processed build, complete compliance fields, and submit for
      review.
- [ ] Monitor the support URL and App Store Connect messages during review.
- [ ] After approval, verify the public product page and perform a clean
      App Store install before phased or manual release.

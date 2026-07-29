#!/usr/bin/env bun
//
// Automated kero release:
//   archive → Developer ID export → notarize → staple → package →
//   sign & (re)generate the Sparkle appcast → upload to Cloudflare R2.
//
// Download origin: https://releases.kero.sh  (R2 bucket + custom domain).
//
// One-time setup (see RELEASING.md):
//   • Sparkle EdDSA keys in your keychain   — `generate_keys`
//   • Developer ID cert + notary profile    — `xcrun notarytool store-credentials`
//   • rclone remote for R2                   — `rclone config`  (S3-compatible)
//   • Fill in scripts/ExportOptions.plist (teamID)
//   • Push access to the Homebrew tap over SSH (for the cask bump)
//
// Usage:
//   bun scripts/release.ts            # release the version currently in the project
//   bun scripts/release.ts --local     # build signed artifacts without publishing
//   FORCE=1 bun scripts/release.ts    # re-release even if that version exists
//   NO_TAP=1 bun scripts/release.ts   # skip bumping the Homebrew cask
//   NO_HISTORY=1 bun scripts/release.ts   # skip pulling old archives (no deltas)
//   HISTORY_COUNT=3 bun scripts/release.ts   # use fewer prior archives for deltas
//
// Bump MARKETING_VERSION (CFBundleShortVersionString) and CURRENT_PROJECT_VERSION
// (CFBundleVersion) in the project before running — Sparkle compares the build
// number to decide what's newer.
import { $ } from "bun";
import { existsSync, mkdirSync, rmSync } from "node:fs";
import { join } from "node:path";
import { die, need, say } from "./lib";
import { generateAppcast } from "./generate-appcast";
import { extractReleaseNotes } from "./changelog";
import { bumpCask, checkMinimumSystemVersion } from "./bump-cask";

// Run from the repo root regardless of where we were invoked.
process.chdir(join(import.meta.dir, ".."));

const args = process.argv.slice(2).filter((arg) => arg !== "--");
const unknownArg = args.find((arg) => arg !== "--local");
if (unknownArg) die(`unknown option: ${unknownArg}`);
const localBuild = args.includes("--local");

// ---- config (override via env) -------------------------------------------
const PROJECT = "kero.xcodeproj";
const SCHEME = "kero";
const CONFIGURATION = process.env.CONFIGURATION ?? "Release";
const BUILD_DIR = process.env.BUILD_DIR ?? "build";
const UPDATES_DIR = join(BUILD_DIR, "updates");
const ARCHIVE_PATH = join(BUILD_DIR, "kero.xcarchive");
const EXPORT_DIR = join(BUILD_DIR, "export");
const EXPORT_OPTIONS = process.env.EXPORT_OPTIONS ?? "scripts/ExportOptions.plist";
const NOTARY_PROFILE = process.env.NOTARY_PROFILE ?? "NOTARY";
// Codesigning identity for the .dmg itself. A partial name matches when there's
// a single Developer ID Application cert; override with the full name/SHA-1.
const SIGN_IDENTITY = process.env.SIGN_IDENTITY ?? "Developer ID Application";
const DOWNLOAD_URL_PREFIX = process.env.DOWNLOAD_URL_PREFIX ?? "https://releases.kero.sh/";
const R2_REMOTE = process.env.R2_REMOTE ?? "r2";
const R2_BUCKET = process.env.R2_BUCKET ?? "kero-releases";
const R2_DEST = `${R2_REMOTE}:${R2_BUCKET}`;
// Keep a broader recent window available for delta generation. Override to
// trade delta coverage for less download/storage.
const HISTORY_COUNT = Number(process.env.HISTORY_COUNT ?? "15");
if (!Number.isSafeInteger(HISTORY_COUNT) || HISTORY_COUNT < 0) {
  die("HISTORY_COUNT must be a non-negative integer.");
}

// A bucket-scoped R2 API token (Object Read & Write) can't create buckets, and
// rclone otherwise tries to check/create the bucket before uploading. The
// bucket already exists, so skip that on every call.
const RCLONE_FLAGS = ["--s3-no-check-bucket"];

process.env.DEVELOPER_DIR ??= "/Applications/Xcode-beta.app/Contents/Developer";

need("xcodebuild");
need("ditto");
if (!localBuild) need("xcrun");
need("plutil");
if (!localBuild) need("rclone");
// Checked up front: the cask bump runs after publishing, too late to be useful
// as a prerequisite failure.
if (!localBuild && process.env.NO_TAP !== "1") need("git");
need("create-dmg"); // brew install create-dmg
if (!existsSync(EXPORT_OPTIONS)) {
  die(`export options not found: ${EXPORT_OPTIONS} (see RELEASING.md)`);
}

// ---- 1. archive ----------------------------------------------------------
say(`Archiving (${CONFIGURATION})…`);
rmSync(ARCHIVE_PATH, { recursive: true, force: true });
rmSync(EXPORT_DIR, { recursive: true, force: true });
await $`xcodebuild -project ${PROJECT} -scheme ${SCHEME} -configuration ${CONFIGURATION} -archivePath ${ARCHIVE_PATH} archive`;

// ---- 2. export a Developer ID-signed app ---------------------------------
say("Exporting Developer ID app…");
await $`xcodebuild -exportArchive -archivePath ${ARCHIVE_PATH} -exportOptionsPlist ${EXPORT_OPTIONS} -exportPath ${EXPORT_DIR}`;

const app = join(EXPORT_DIR, "Kero.app");
if (!existsSync(app)) die(`exported app not found at ${app}`);
const appPlist = join(app, "Contents/Info.plist");

// ---- 3. read the version from the built app ------------------------------
const version = (await $`plutil -extract CFBundleShortVersionString raw ${appPlist}`.text()).trim();
const build = (await $`plutil -extract CFBundleVersion raw ${appPlist}`.text()).trim();
if (!version) die("could not read CFBundleShortVersionString");
const zipName = `kero-${version}.zip`; // Sparkle in-app update (deltas)
const dmgName = `kero-${version}.dmg`; // notarized download
say(`Releasing kero ${version} (build ${build})`);

// Don't clobber an already-published version unless forced.
if (!localBuild && process.env.FORCE !== "1") {
  let existing = "";
  try {
    existing = await $`rclone lsf ${R2_DEST} ${RCLONE_FLAGS}`.text();
  } catch {
    existing = ""; // empty/unreachable bucket — let later steps surface it
  }
  if (existing.split("\n").includes(zipName)) {
    die(`${zipName} already exists in R2 — bump the version, or set FORCE=1.`);
  }
}

// ---- 4. build the DMG ----------------------------------------------------
// A staged folder holds only the app, so the disk image window is just the app
// + the Applications drop target.
say(`Building ${dmgName}…`);
const dmgPath = join(BUILD_DIR, dmgName);
const dmgStaging = join(BUILD_DIR, "dmg");
rmSync(dmgStaging, { recursive: true, force: true });
rmSync(dmgPath, { force: true });
mkdirSync(dmgStaging, { recursive: true });
await $`ditto ${app} ${join(dmgStaging, "Kero.app")}`;
// create-dmg can return non-zero from cosmetic Finder-scripting hiccups even
// when the image is fine, so check for the file instead of the exit code.
await $`create-dmg \
  --volname ${`Kero ${version}`} \
  --window-size 540 380 \
  --icon-size 128 \
  --icon ${"Kero.app"} 150 195 \
  --app-drop-link 390 195 \
  --hide-extension ${"Kero.app"} \
  --no-internet-enable \
  ${dmgPath} ${dmgStaging}`.nothrow();
if (!existsSync(dmgPath)) die("create-dmg did not produce a disk image");
await $`codesign --force --sign ${SIGN_IDENTITY} ${dmgPath}`;
if (localBuild) {
  say(`Done. Built and signed kero ${version} locally; nothing was notarized or published:`);
  console.log(`     app      : ${app}`);
  console.log(`     download : ${dmgPath}`);
  process.exit(0);
}

// ---- 5. notarize + staple ------------------------------------------------
// Notarizing the DMG also notarizes the app's code hash, so we can staple both
// the DMG (for downloads) and the app (for the Sparkle zip) from one submission.
say(`Notarizing (profile: ${NOTARY_PROFILE})…`);
await $`xcrun notarytool submit ${dmgPath} --keychain-profile ${NOTARY_PROFILE} --wait`;
say("Stapling tickets…");
await $`xcrun stapler staple ${dmgPath}`;
await $`xcrun stapler staple ${app}`;

// ---- 6. package the Sparkle update (pull history first for deltas) --------
// The DMG is the download; Sparkle updates from this zip so it can build small
// binary deltas. UPDATES_DIR is a clean staging directory containing only the
// current archive and the recent history needed for those deltas.
rmSync(UPDATES_DIR, { recursive: true, force: true });
mkdirSync(UPDATES_DIR, { recursive: true });
if (process.env.NO_HISTORY !== "1") {
  say(`Selecting the ${HISTORY_COUNT} most recent archives from R2 (for deltas)…`);
  type RemoteFile = { Name: string; IsDir: boolean };
  const remoteFiles = JSON.parse(
    await $`rclone lsjson ${R2_DEST} ${RCLONE_FLAGS} --files-only --include ${"*.zip"} --include ${"appcast.xml"}`.text(),
  ) as RemoteFile[];
  const archiveVersion = (name: string) =>
    name.slice("kero-".length, -".zip".length);
  const versionOrder = new Intl.Collator("en", { numeric: true });
  const recentArchives = remoteFiles
    .filter(
      ({ Name, IsDir }) =>
        !IsDir && /^kero-.+\.zip$/.test(Name) && Name !== zipName,
    )
    .sort((a, b) =>
      versionOrder.compare(archiveVersion(b.Name), archiveVersion(a.Name)),
    )
    .slice(0, HISTORY_COUNT)
    .map(({ Name }) => Name);
  const historyFiles = [
    ...(remoteFiles.some(({ Name }) => Name === "appcast.xml")
      ? ["appcast.xml"]
      : []),
    ...recentArchives,
  ];

  if (historyFiles.length > 0) {
    const includeFlags = historyFiles.flatMap((name) => [
      "--include",
      `/${name}`,
    ]);
    await $`rclone copy ${R2_DEST} ${UPDATES_DIR} ${RCLONE_FLAGS} ${includeFlags}`;
  }
  say(
    recentArchives.length > 0
      ? `Pulled ${recentArchives.join(", ")}`
      : "No prior archives found",
  );
}
say(`Packaging ${zipName}…`);
await $`ditto -c -k --keepParent ${app} ${join(UPDATES_DIR, zipName)}`;

// Release notes: slice this version's section out of CHANGELOG.md next to the
// archive (as kero-<version>.md). generate_appcast then attaches it as the
// update's <sparkle:releaseNotesLink>, which Sparkle renders in the prompt.
const changelog = "CHANGELOG.md";
if (existsSync(changelog)) {
  const notes = extractReleaseNotes(await Bun.file(changelog).text(), version);
  if (notes) {
    await Bun.write(join(UPDATES_DIR, `kero-${version}.md`), `${notes}\n`);
    say(`Attached release notes for ${version}`);
  } else {
    say(`No "${version}" section in ${changelog} — releasing without notes`);
  }
} else {
  say(`No ${changelog} — releasing without notes`);
}

// ---- 7. sign + (re)generate the appcast ----------------------------------
say("Generating appcast…");
await generateAppcast(UPDATES_DIR, DOWNLOAD_URL_PREFIX);

// ---- 8. upload to R2 -----------------------------------------------------
// Archives and the DMG are immutable → cache forever. appcast.xml changes every
// release → keep it fresh so update checks aren't served stale.
say(`Uploading the DMG to ${R2_DEST}…`);
await $`rclone copyto ${dmgPath} ${`${R2_DEST}/${dmgName}`} ${RCLONE_FLAGS} --header-upload ${"Cache-Control: public, max-age=31536000, immutable"} --progress`;
say(`Uploading update archives to ${R2_DEST}…`);
await $`rclone copy ${UPDATES_DIR} ${R2_DEST} ${RCLONE_FLAGS} --exclude ${"appcast.xml"} --exclude ${"old_updates/**"} --header-upload ${"Cache-Control: public, max-age=31536000, immutable"} --progress`;
say("Uploading appcast.xml…");
await $`rclone copyto ${join(UPDATES_DIR, "appcast.xml")} ${`${R2_DEST}/appcast.xml`} ${RCLONE_FLAGS} --header-upload ${"Cache-Control: public, max-age=300, must-revalidate"}`;

// ---- 9. bump the Homebrew cask -------------------------------------------
// Last, because the cask's sha256 covers a DMG that must already be fetchable.
// The release is live at this point, so a failure here is a warning with a
// retry command, not a failed release.
if (process.env.NO_TAP !== "1") {
  say("Bumping the Homebrew cask…");
  try {
    await bumpCask(version, dmgPath);
    await checkMinimumSystemVersion(appPlist);
  } catch (error) {
    console.warn(
      `\x1b[1;33mwarning:\x1b[0m could not bump the cask: ${error instanceof Error ? error.message : error}\n` +
        `         retry with: bun scripts/bump-cask.ts ${version}`,
    );
  }
}

say(`Done. kero ${version} is live:`);
console.log(`     download : ${DOWNLOAD_URL_PREFIX}${dmgName}`);
console.log(`     update   : ${DOWNLOAD_URL_PREFIX}${zipName}`);
console.log(`     feed     : ${DOWNLOAD_URL_PREFIX}appcast.xml`);

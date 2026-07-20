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
//
// Usage:
//   bun scripts/release.ts            # release the version currently in the project
//   FORCE=1 bun scripts/release.ts    # re-release even if that version exists
//   NO_HISTORY=1 bun scripts/release.ts   # skip pulling old archives (no deltas)
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

// Run from the repo root regardless of where we were invoked.
process.chdir(join(import.meta.dir, ".."));

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
const DOWNLOAD_URL_PREFIX = process.env.DOWNLOAD_URL_PREFIX ?? "https://releases.kero.sh/";
const R2_REMOTE = process.env.R2_REMOTE ?? "r2";
const R2_BUCKET = process.env.R2_BUCKET ?? "kero-releases";
const R2_DEST = `${R2_REMOTE}:${R2_BUCKET}`;

// A bucket-scoped R2 API token (Object Read & Write) can't create buckets, and
// rclone otherwise tries to check/create the bucket before uploading. The
// bucket already exists, so skip that on every call.
const RCLONE_FLAGS = ["--s3-no-check-bucket"];

process.env.DEVELOPER_DIR ??= "/Applications/Xcode-beta.app/Contents/Developer";

need("xcodebuild");
need("ditto");
need("xcrun");
need("plutil");
need("rclone");
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

const app = join(EXPORT_DIR, "kero.app");
if (!existsSync(app)) die(`exported app not found at ${app}`);
const appPlist = join(app, "Contents/Info.plist");

// ---- 3. read the version from the built app ------------------------------
const version = (await $`plutil -extract CFBundleShortVersionString raw ${appPlist}`.text()).trim();
const build = (await $`plutil -extract CFBundleVersion raw ${appPlist}`.text()).trim();
if (!version) die("could not read CFBundleShortVersionString");
const zipName = `kero-${version}.zip`;
say(`Releasing kero ${version} (build ${build}) → ${zipName}`);

// Don't clobber an already-published version unless forced.
if (process.env.FORCE !== "1") {
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

// ---- 4. notarize + staple ------------------------------------------------
say(`Notarizing (profile: ${NOTARY_PROFILE})…`);
const notarizeZip = join(BUILD_DIR, "kero-notarize.zip");
await $`ditto -c -k --keepParent ${app} ${notarizeZip}`;
await $`xcrun notarytool submit ${notarizeZip} --keychain-profile ${NOTARY_PROFILE} --wait`;
say("Stapling ticket…");
await $`xcrun stapler staple ${app}`;

// ---- 5. package (pull history first so generate_appcast can build deltas) -
mkdirSync(UPDATES_DIR, { recursive: true });
if (process.env.NO_HISTORY !== "1") {
  say("Pulling existing archives from R2 (for deltas)…");
  // copy is additive — it never deletes local or remote files. Pull the old
  // appcast too so generate_appcast preserves any hand-added release notes.
  await $`rclone copy ${R2_DEST} ${UPDATES_DIR} ${RCLONE_FLAGS} --include ${"*.zip"} --include ${"*.delta"} --include ${"*.md"} --include ${"*.html"} --include ${"appcast.xml"}`;
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

// ---- 6. sign + (re)generate the appcast ----------------------------------
say("Generating appcast…");
await generateAppcast(UPDATES_DIR, DOWNLOAD_URL_PREFIX);

// ---- 7. upload to R2 -----------------------------------------------------
// Archives are immutable → cache forever. appcast.xml changes every release →
// keep it fresh so update checks aren't served stale.
say(`Uploading archives to ${R2_DEST}…`);
await $`rclone copy ${UPDATES_DIR} ${R2_DEST} ${RCLONE_FLAGS} --exclude ${"appcast.xml"} --header-upload ${"Cache-Control: public, max-age=31536000, immutable"} --progress`;
say("Uploading appcast.xml…");
await $`rclone copyto ${join(UPDATES_DIR, "appcast.xml")} ${`${R2_DEST}/appcast.xml`} ${RCLONE_FLAGS} --header-upload ${"Cache-Control: public, max-age=300, must-revalidate"}`;

say(`Done. kero ${version} is live:`);
console.log(`     app  : ${DOWNLOAD_URL_PREFIX}${zipName}`);
console.log(`     feed : ${DOWNLOAD_URL_PREFIX}appcast.xml`);

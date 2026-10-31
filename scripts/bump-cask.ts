#!/usr/bin/env bun
//
// Bump the Homebrew cask in the tap to a released version.
//
// The cask (https://github.com/egoist/homebrew-tap, Casks/kero.rb) points at the
// DMG in R2, so it needs the new version + its sha256 after every release.
// `scripts/release.ts` calls this at the end; it's also runnable on its own to
// retry a failed push or to backfill a version released before this existed:
//
//   bun scripts/bump-cask.ts            # version from build/export/Kero.app
//   bun scripts/bump-cask.ts 0.1.25     # explicit version (downloads the DMG
//                                       # from R2 if it isn't in build/)
//
// Env (NO_TAP=1 skips the bump, but that's release.ts's flag — running this
// script directly is already an explicit request to bump):
//   TAP_REPO     default egoist/homebrew-tap
//   TAP_CASK     path of the cask within the tap, default Casks/kero.rb
//   TAP_DIR      local checkout, default build/homebrew-tap
import { $ } from "bun";
import { existsSync } from "node:fs";
import { join } from "node:path";
import { die, say } from "./lib";

const TAP_REPO = process.env.TAP_REPO ?? "egoist/homebrew-tap";
const TAP_CASK = process.env.TAP_CASK ?? "Casks/kero.rb";
const TAP_DIR = process.env.TAP_DIR ?? join(process.env.BUILD_DIR ?? "build", "homebrew-tap");
const DOWNLOAD_URL_PREFIX = process.env.DOWNLOAD_URL_PREFIX ?? "https://releases.kero.sh/";

/** macOS versions Homebrew knows by name, for the `depends_on macos:` check. */
const MACOS_NAMES: Record<string, string> = {
  "13": "ventura",
  "14": "sonoma",
  "15": "sequoia",
  "26": "tahoe",
};

const sha256 = (bytes: ArrayBuffer): string =>
  new Bun.CryptoHasher("sha256").update(bytes).digest("hex");

/**
 * Point the tap's cask at `version` and push. Returns false when the cask was
 * already at that version and sha (a no-op re-run), true when it pushed.
 *
 * Throws rather than exiting: by the time `release.ts` calls this the release
 * is already published, so it wants to catch the failure and still report the
 * release as live.
 */
export async function bumpCask(version: string, dmgPath?: string): Promise<boolean> {
  if (!Bun.which("git")) throw new Error("missing required tool: git");

  // Hash the DMG we just built when we have it, otherwise the published one —
  // either way it's the exact bytes `brew install` will download.
  let dmg: ArrayBuffer;
  if (dmgPath && existsSync(dmgPath)) {
    dmg = await Bun.file(dmgPath).arrayBuffer();
  } else {
    const url = `${DOWNLOAD_URL_PREFIX}kero-${version}.dmg`;
    say(`Downloading ${url} to hash it…`);
    const res = await fetch(url);
    if (!res.ok) throw new Error(`could not download ${url} (HTTP ${res.status})`);
    dmg = await res.arrayBuffer();
  }
  const digest = sha256(dmg);

  // Fresh checkout, or reset an existing one to origin so a half-finished
  // earlier run can't leave stray commits behind.
  if (existsSync(join(TAP_DIR, ".git"))) {
    await $`git -C ${TAP_DIR} fetch --quiet origin main`;
    await $`git -C ${TAP_DIR} reset --quiet --hard origin/main`;
  } else {
    say(`Cloning ${TAP_REPO}…`);
    await $`git clone --quiet git@github.com:${TAP_REPO}.git ${TAP_DIR}`;
  }

  const caskPath = join(TAP_DIR, TAP_CASK);
  if (!existsSync(caskPath)) throw new Error(`cask not found in ${TAP_REPO}: ${TAP_CASK}`);
  const before = await Bun.file(caskPath).text();

  const after = before
    .replace(/^(\s*version\s+)"[^"]*"/m, `$1"${version}"`)
    .replace(/^(\s*sha256\s+)"[^"]*"/m, `$1"${digest}"`);
  if (!after.includes(`"${version}"`) || !after.includes(`"${digest}"`)) {
    throw new Error(`could not find version/sha256 stanzas in ${TAP_CASK} — bump it by hand`);
  }
  if (after === before) {
    say(`${TAP_REPO} is already at ${version} — nothing to bump`);
    return false;
  }

  await Bun.write(caskPath, after);
  await $`git -C ${TAP_DIR} add ${TAP_CASK}`;
  await $`git -C ${TAP_DIR} commit --quiet -m ${`kero ${version}`}`;
  await $`git -C ${TAP_DIR} push --quiet origin main`;
  say(`Bumped ${TAP_REPO} to ${version}`);
  return true;
}

/**
 * The cask's `depends_on macos:` mirrors the app's LSMinimumSystemVersion; if
 * the deployment target moves and the cask doesn't, Homebrew happily installs a
 * build that won't launch. Warn rather than fail — the release is already out,
 * and an unrecognised macOS version shouldn't block the bump.
 */
export async function checkMinimumSystemVersion(appPlist: string): Promise<void> {
  if (!existsSync(appPlist)) return;
  const min = (await $`plutil -extract LSMinimumSystemVersion raw ${appPlist}`.nothrow().text()).trim();
  const name = MACOS_NAMES[min.split(".")[0] ?? ""];
  if (!name) return;
  const caskPath = join(TAP_DIR, TAP_CASK);
  if (!existsSync(caskPath)) return;
  const cask = await Bun.file(caskPath).text();
  if (!new RegExp(`depends_on\\s+macos:\\s+:${name}\\b`).test(cask)) {
    console.warn(
      `\x1b[1;33mwarning:\x1b[0m the app needs macOS ${min} (:${name}) but ${TAP_CASK} ` +
        `says otherwise — update its depends_on stanza.`,
    );
  }
}

// ---- standalone ----------------------------------------------------------
if (import.meta.main) {
  process.chdir(join(import.meta.dir, ".."));

  let version = process.argv[2];
  if (!version) {
    const plist = join(process.env.BUILD_DIR ?? "build", "export/Kero.app/Contents/Info.plist");
    if (!existsSync(plist)) {
      die("no version given and no built app to read one from — pass it, e.g. `bun scripts/bump-cask.ts 0.1.25`");
    }
    version = (await $`plutil -extract CFBundleShortVersionString raw ${plist}`.text()).trim();
  }

  const buildDir = process.env.BUILD_DIR ?? "build";
  try {
    await bumpCask(version, join(buildDir, `kero-${version}.dmg`));
  } catch (error) {
    die(error instanceof Error ? error.message : String(error));
  }
  await checkMinimumSystemVersion(join(buildDir, "export/Kero.app/Contents/Info.plist"));
}

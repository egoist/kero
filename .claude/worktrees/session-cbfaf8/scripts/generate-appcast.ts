#!/usr/bin/env bun
//
// Generate/refresh the Sparkle appcast for a directory of update archives.
//
// Usage:
//   bun scripts/generate-appcast.ts <updates-dir>
//
// <updates-dir> holds the packaged archives (e.g. kero-1.1.zip) plus any older
// archives so Sparkle can build deltas. appcast.xml is written into that dir.
//
// The private signing key is read from your login keychain (see RELEASING.md).
// Env overrides:
//   SPARKLE_BIN          dir containing the Sparkle tools (generate_appcast)
//   DOWNLOAD_URL_PREFIX  base URL for <enclosure> links (default releases.kero.sh)
import { $ } from "bun";
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { die } from "./lib";

/** Locate Sparkle's `generate_appcast`: SPARKLE_BIN, then PATH, then the copy
 *  Swift Package Manager caches under DerivedData. */
export async function findGenerateAppcast(): Promise<string | null> {
  const fromEnv = process.env.SPARKLE_BIN;
  if (fromEnv && existsSync(join(fromEnv, "generate_appcast"))) {
    return join(fromEnv, "generate_appcast");
  }

  const onPath = Bun.which("generate_appcast");
  if (onPath) return onPath;

  const derived = join(homedir(), "Library/Developer/Xcode/DerivedData");
  if (existsSync(derived)) {
    const pattern = "*/artifacts/*/Sparkle/bin/generate_appcast";
    try {
      const out = await $`find ${derived} -path ${pattern} -type f`.text();
      const hit = out.split("\n").filter(Boolean)[0];
      if (hit) return hit;
    } catch {
      // no match / not searchable — fall through
    }
  }
  return null;
}

/** Sign the archives in `updatesDir` and (re)write appcast.xml. */
export async function generateAppcast(
  updatesDir: string,
  downloadUrlPrefix: string,
): Promise<void> {
  const gen = await findGenerateAppcast();
  if (!gen) {
    die(
      "generate_appcast not found. Set SPARKLE_BIN to the Sparkle tools 'bin' " +
        "dir, or download it from https://github.com/sparkle-project/Sparkle/releases",
    );
  }
  console.log(`Using: ${gen}`);
  // Same prefix for both: archives and the kero-<version>.md release notes are
  // served from the same origin. The notes prefix makes generate_appcast emit
  // <sparkle:releaseNotesLink> for any notes file matching an archive name.
  await $`${gen} --download-url-prefix ${downloadUrlPrefix} --release-notes-url-prefix ${downloadUrlPrefix} ${updatesDir}`;
  console.log(`Wrote ${join(updatesDir, "appcast.xml")}`);
}

if (import.meta.main) {
  const updatesDir = process.argv[2];
  if (!updatesDir) die("usage: bun scripts/generate-appcast.ts <updates-dir>");
  const prefix = process.env.DOWNLOAD_URL_PREFIX ?? "https://releases.kero.sh/";
  await generateAppcast(updatesDir, prefix);
}

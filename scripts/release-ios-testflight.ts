#!/usr/bin/env bun
//
// Automated Kero for iOS TestFlight release:
//   offline tests → build-number bump → archive → App Store Connect upload
//
// Usage:
//   bun scripts/release-ios-testflight.ts
//   bun scripts/release-ios-testflight.ts --build 10
//   bun scripts/release-ios-testflight.ts --skip-tests
//   bun scripts/release-ios-testflight.ts --dry-run
//
// Environment overrides:
//   DEVELOPER_DIR      Stable Xcode developer directory
//   DEVELOPMENT_TEAM   Apple Developer team (defaults to ExportOptions)
//   EXPORT_OPTIONS     TestFlight export-options plist
//   IOS_RELEASE_DIR    Archive/output directory
//   IOS_SIMULATOR_ID   Simulator used for offline tests
import { $ } from "bun";
import {
  existsSync,
  lstatSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { join } from "node:path";
import { die, need, say } from "./lib";

process.chdir(join(import.meta.dir, ".."));

const PROJECT = "KeroMobile.xcodeproj";
const PROJECT_FILE = join(PROJECT, "project.pbxproj");
const SCHEME = "KeroMobile";
const CONFIGURATION = "Release";
const BUNDLE_ID = "sh.kero.mobile";
const EXPORT_OPTIONS =
  process.env.EXPORT_OPTIONS ??
  "KeroMobileRelease/ExportOptions-TestFlight.plist";
const OUTPUT_ROOT = process.env.IOS_RELEASE_DIR ?? "build/ios-testflight";
const APP_STORE_CONNECT_URL =
  "https://appstoreconnect.apple.com/apps/6795790509/testflight/ios";

type Options = {
  build?: number;
  dryRun: boolean;
  skipTests: boolean;
};

type ProjectMetadata = {
  build: number;
  configurationCount: number;
  version: string;
};

type Simulator = {
  isAvailable?: boolean;
  name: string;
  state: string;
  udid: string;
};

type SimctlDevices = {
  devices: Record<string, Simulator[]>;
};

type ArchiveInfo = {
  ApplicationProperties?: {
    CFBundleIdentifier?: string;
    CFBundleShortVersionString?: string;
    CFBundleVersion?: string;
    Team?: string;
  };
  Distributions?: Array<{
    uploadedBuildNumber?: number | string;
    uploadEvent?: {
      errors?: unknown[];
      state?: string;
      title?: string;
      warnings?: unknown[];
    };
  }>;
};

const usage = (): void => {
  console.log(`Usage: bun scripts/release-ios-testflight.ts [options]

Options:
  --build N      Use N instead of incrementing CURRENT_PROJECT_VERSION
  --skip-tests   Skip the offline unit and UI test pass
  --dry-run      Validate configuration and print the planned release
  --help         Show this help

The script uploads to TestFlight only. It does not submit for App Review,
answer export-compliance questions, or change tester groups.`);
};

const parseOptions = (): Options => {
  const args = process.argv.slice(2).filter((arg) => arg !== "--");
  const options: Options = {
    dryRun: false,
    skipTests: false,
  };

  for (let index = 0; index < args.length; index += 1) {
    const argument = args[index];
    switch (argument) {
      case "--build": {
        const value = args[index + 1];
        if (!value || !/^[1-9]\d*$/.test(value)) {
          die("--build requires a positive integer");
        }
        options.build = Number(value);
        if (!Number.isSafeInteger(options.build)) {
          die("--build is too large");
        }
        index += 1;
        break;
      }
      case "--dry-run":
        options.dryRun = true;
        break;
      case "--help":
      case "-h":
        usage();
        process.exit(0);
      case "--skip-tests":
        options.skipTests = true;
        break;
      default:
        die(`unknown option: ${argument}`);
    }
  }

  return options;
};

const appBuildConfigurationPattern = new RegExp(
  "(\\t\\t[^\\n]+\\/\\* (?:Debug|Release) \\*\\/ = \\{\\n" +
    "\\t\\t\\tisa = XCBuildConfiguration;[\\s\\S]*?\\n\\t\\t\\};)",
  "g",
);
const appBundleIdentifierPattern =
  /PRODUCT_BUNDLE_IDENTIFIER = "?sh\.kero\.mobile"?;/;

const readProjectMetadata = (source: string): ProjectMetadata => {
  const builds = new Set<number>();
  const versions = new Set<string>();
  let configurationCount = 0;

  for (const match of source.matchAll(appBuildConfigurationPattern)) {
    const block = match[1];
    if (!appBundleIdentifierPattern.test(block)) continue;

    const buildMatch = block.match(/CURRENT_PROJECT_VERSION = (\d+);/);
    const versionMatch = block.match(/MARKETING_VERSION = ([^;]+);/);
    if (!buildMatch || !versionMatch) {
      die("the KeroMobile build settings are missing version values");
    }

    configurationCount += 1;
    builds.add(Number(buildMatch[1]));
    versions.add(versionMatch[1].replaceAll('"', "").trim());
  }

  if (configurationCount !== 2) {
    die(
      `expected two KeroMobile build configurations, found ${configurationCount}`,
    );
  }
  if (builds.size !== 1 || versions.size !== 1) {
    die("KeroMobile Debug and Release versions do not match");
  }

  return {
    build: [...builds][0],
    configurationCount,
    version: [...versions][0],
  };
};

const setProjectBuild = (
  source: string,
  currentBuild: number,
  nextBuild: number,
): string => {
  let updatedCount = 0;
  const updated = source.replace(
    appBuildConfigurationPattern,
    (block: string) => {
      if (!appBundleIdentifierPattern.test(block)) return block;

      const expected = `CURRENT_PROJECT_VERSION = ${currentBuild};`;
      if (!block.includes(expected)) {
        die("KeroMobile build settings changed while preparing the release");
      }
      updatedCount += 1;
      return block.replace(
        expected,
        `CURRENT_PROJECT_VERSION = ${nextBuild};`,
      );
    },
  );

  if (updatedCount !== 2) {
    die(
      `expected to update two KeroMobile build settings, updated ${updatedCount}`,
    );
  }
  return updated;
};

const readPlist = async <T>(path: string): Promise<T> => {
  const json = await $`plutil -convert json -o - ${path}`.text();
  return JSON.parse(json) as T;
};

const ensureNoTestBundles = (root: string): void => {
  const visit = (directory: string): void => {
    for (const entry of readdirSync(directory)) {
      const path = join(directory, entry);
      if (entry.endsWith(".xctest")) {
        die(`archive unexpectedly contains a test bundle: ${path}`);
      }
      if (lstatSync(path).isDirectory()) visit(path);
    }
  };
  visit(root);
};

const runtimeVersion = (runtime: string): number[] => {
  const match = runtime.match(/iOS-(\d+)-(\d+)(?:-(\d+))?$/);
  return match
    ? [Number(match[1]), Number(match[2]), Number(match[3] ?? 0)]
    : [0, 0, 0];
};

const compareVersionsDescending = (left: number[], right: number[]): number => {
  for (let index = 0; index < 3; index += 1) {
    if (left[index] !== right[index]) return right[index] - left[index];
  }
  return 0;
};

const chooseSimulator = async (): Promise<Simulator> => {
  const configured = process.env.IOS_SIMULATOR_ID;
  const listing = JSON.parse(
    await $`xcrun simctl list devices available --json`.text(),
  ) as SimctlDevices;

  const candidates = Object.entries(listing.devices)
    .filter(([runtime]) => runtime.includes("SimRuntime.iOS-"))
    .flatMap(([runtime, devices]) =>
      devices
        .filter(
          (device) =>
            device.isAvailable !== false && device.name.startsWith("iPhone"),
        )
        .map((device) => ({
          device,
          version: runtimeVersion(runtime),
        })),
    );

  if (configured) {
    const match = candidates.find(({ device }) => device.udid === configured);
    if (!match) {
      die(`IOS_SIMULATOR_ID is not an available iPhone Simulator: ${configured}`);
    }
    return match.device;
  }

  candidates.sort((left, right) => {
    const stateOrder =
      Number(right.device.state === "Booted") -
      Number(left.device.state === "Booted");
    return (
      stateOrder ||
      compareVersionsDescending(left.version, right.version) ||
      left.device.name.localeCompare(right.device.name)
    );
  });

  const selected = candidates[0]?.device;
  if (!selected) {
    die(
      "no iPhone Simulator is available; install one or pass IOS_SIMULATOR_ID",
    );
  }
  return selected;
};

const main = async (): Promise<void> => {
  const options = parseOptions();

  process.env.DEVELOPER_DIR ??=
    "/Applications/Xcode.app/Contents/Developer";

  for (const tool of ["bun", "git", "plutil", "xcodebuild", "xcrun"]) {
    need(tool);
  }
  if (!existsSync(PROJECT_FILE)) die(`project not found: ${PROJECT_FILE}`);
  if (!existsSync(EXPORT_OPTIONS)) {
    die(`export options not found: ${EXPORT_OPTIONS}`);
  }

  const xcodeVersion = (
    await $`xcodebuild -version`.quiet().text()
  ).trim();
  if (
    process.env.DEVELOPER_DIR.toLowerCase().includes("beta") ||
    xcodeVersion.toLowerCase().includes("beta")
  ) {
    die(
      `TestFlight releases require stable Xcode, found ${process.env.DEVELOPER_DIR}`,
    );
  }

  const exportOptions = await readPlist<Record<string, unknown>>(
    EXPORT_OPTIONS,
  );
  if (
    exportOptions.destination !== "upload" ||
    exportOptions.method !== "app-store-connect"
  ) {
    die("export options must use destination=upload and method=app-store-connect");
  }
  if (exportOptions.manageAppVersionAndBuildNumber !== false) {
    die("export options must preserve the script-selected build number");
  }

  const team =
    process.env.DEVELOPMENT_TEAM ??
    (typeof exportOptions.teamID === "string" ? exportOptions.teamID : "");
  if (!team) {
    die("set DEVELOPMENT_TEAM or teamID in the TestFlight export options");
  }

  const projectSource = readFileSync(PROJECT_FILE, "utf8");
  const current = readProjectMetadata(projectSource);
  if (!/^\d+(?:\.\d+){1,2}$/.test(current.version)) {
    die(`unsupported MARKETING_VERSION: ${current.version}`);
  }
  const build = options.build ?? current.build + 1;
  if (build < current.build) {
    die(
      `build ${build} is older than project build ${current.build}; ` +
        `use ${current.build} or newer`,
    );
  }
  const releaseProject =
    build === current.build
      ? projectSource
      : setProjectBuild(projectSource, current.build, build);
  const releaseMetadata = readProjectMetadata(releaseProject);
  if (
    releaseMetadata.build !== build ||
    releaseMetadata.version !== current.version
  ) {
    die("could not prepare the requested project version");
  }
  const simulator = options.skipTests ? undefined : await chooseSimulator();

  say(`Kero for iOS ${current.version} (${build})`);
  console.log(`    Xcode : ${xcodeVersion.replace("\n", ", ")}`);
  console.log(`    Team  : ${team}`);
  console.log(`    Output: ${OUTPUT_ROOT}`);
  if (simulator) {
    console.log(`    Tests : ${simulator.name} (${simulator.udid})`);
  } else {
    console.log("    Tests : skipped");
  }
  if (build === current.build) {
    console.log("    Build : retrying the current build number");
  } else {
    console.log(`    Build : incrementing ${current.build} → ${build}`);
  }

  if (options.dryRun) {
    say("Dry run complete; no files changed and nothing was uploaded.");
    return;
  }

  await $`git diff --check`;
  const status = (await $`git status --short`.quiet().text()).trim();
  if (status) {
    console.log("\nReleasing the current worktree:");
    console.log(status);
  }

  if (simulator) {
    say(`Running offline tests on ${simulator.name}…`);
    await $`xcodebuild test \
      -project ${PROJECT} \
      -scheme ${SCHEME} \
      -destination ${`platform=iOS Simulator,id=${simulator.udid}`} \
      -skip-testing:KeroMobileUITests/testLiveSSHConnectionOutcome \
      -skip-testing:KeroMobileUITests/testLiveSSHReconnectAfterBackgrounding \
      -skip-testing:KeroMobileUITests/testExistingSimulatorSSHFilesPanel`;
  } else {
    say("Skipping tests by request.");
  }

  if (build !== current.build) {
    writeFileSync(PROJECT_FILE, releaseProject);
    await $`git diff --check -- ${PROJECT_FILE}`;
  }

  const releaseRoot = join(
    OUTPUT_ROOT,
    `${current.version}-${build}`,
  );
  const archivePath = join(
    releaseRoot,
    `KeroMobile ${current.version} (${build}).xcarchive`,
  );
  const exportPath = join(releaseRoot, "upload");
  rmSync(releaseRoot, { force: true, recursive: true });
  mkdirSync(releaseRoot, { recursive: true });

  say(`Archiving Kero ${current.version} (${build})…`);
  try {
    await $`xcodebuild archive \
      -project ${PROJECT} \
      -scheme ${SCHEME} \
      -configuration ${CONFIGURATION} \
      -destination ${"generic/platform=iOS"} \
      -archivePath ${archivePath} \
      DEVELOPMENT_TEAM=${team} \
      -allowProvisioningUpdates`;
  } catch (error) {
    console.error(
      `\nThe archive failed. Build ${build} remains reserved in ${PROJECT_FILE}.`,
    );
    throw error;
  }

  const archiveInfoPath = join(archivePath, "Info.plist");
  const archiveInfo = await readPlist<ArchiveInfo>(archiveInfoPath);
  const app = archiveInfo.ApplicationProperties;
  if (
    app?.CFBundleShortVersionString !== current.version ||
    String(app?.CFBundleVersion) !== String(build) ||
    app?.CFBundleIdentifier !== BUNDLE_ID ||
    app?.Team !== team
  ) {
    die("archive metadata does not match the intended TestFlight release");
  }

  const archivedApp = join(
    archivePath,
    "Products",
    "Applications",
    "Kero.app",
  );
  if (!existsSync(archivedApp)) die(`archived app not found: ${archivedApp}`);
  ensureNoTestBundles(archivedApp);

  say("Uploading to App Store Connect…");
  try {
    await $`xcodebuild -exportArchive \
      -archivePath ${archivePath} \
      -exportOptionsPlist ${EXPORT_OPTIONS} \
      -exportPath ${exportPath} \
      -allowProvisioningUpdates`;
  } catch (error) {
    console.error(
      `\nThe upload failed. Retry build ${build} with:`,
    );
    console.error(
      `  bun scripts/release-ios-testflight.ts --build ${build} --skip-tests`,
    );
    throw error;
  }

  const uploadedArchiveInfo = await readPlist<ArchiveInfo>(archiveInfoPath);
  const upload = [...(uploadedArchiveInfo.Distributions ?? [])]
    .reverse()
    .find(
      (distribution) =>
        String(distribution.uploadedBuildNumber) === String(build),
    );
  if (
    upload?.uploadEvent?.state !== "success" ||
    (upload.uploadEvent.errors?.length ?? 0) > 0
  ) {
    die("Xcode finished without a successful Apple upload receipt");
  }

  say(`Uploaded Kero ${current.version} (${build}) to TestFlight.`);
  console.log("Apple accepted the build and has started processing it.");
  console.log(`TestFlight: ${APP_STORE_CONNECT_URL}`);
  if ((upload.uploadEvent.warnings?.length ?? 0) > 0) {
    console.log(
      `Apple returned ${upload.uploadEvent.warnings?.length} upload ` +
        "warning(s); inspect the archive in Xcode Organizer.",
    );
  }
};

await main();

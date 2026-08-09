import {
  copyFileSync,
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  unlinkSync,
  writeFileSync,
} from 'node:fs';
import { basename, join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

// Usage: bun scripts/generate-material-file-icons.ts /path/to/vscode-material-icon-theme
//
// The input checkout must be the pinned version below. Kero vendors the SVGs
// and generated lookup table, so building Kero never downloads or generates
// icon resources.
const upstreamVersion = '5.37.0';
const upstreamCommit = '850c06c7fb7ea73d873a0ce2f966bbd20850946d';
const upstreamRoot = resolve(process.argv[2] ?? '');
const packagePath = join(upstreamRoot, 'package.json');
const iconSourceDirectory = join(upstreamRoot, 'icons');
const outputDirectory = resolve('kero/MaterialFileIcons');
const swiftOutputPath = resolve('kero/MaterialFileIcon.swift');
const resourcePrefix = 'material-file-icon-';

if (!existsSync(packagePath)) {
  throw new Error('Pass a vscode-material-icon-theme checkout as the first argument.');
}
const upstreamPackage = JSON.parse(readFileSync(packagePath, 'utf8'));
if (upstreamPackage.version !== upstreamVersion) {
  throw new Error(
    `Expected vscode-material-icon-theme ${upstreamVersion}, got ${upstreamPackage.version}.`,
  );
}

const { fileIcons } = await import(
  pathToFileURL(join(upstreamRoot, 'src/core/icons/fileIcons.ts')).href
);

// Upstream orders broadly useful file types first. Start from that core, then
// trade niche or obsolete entries for common modern languages, build tools,
// frameworks, infrastructure formats, and agent instruction files found later
// in the catalog. The fallback file glyph counts as one of the 300 icons.
const excludedFromUpstreamCore = new Set([
  'adobe-swc',
  'angular-component',
  'angular-directive',
  'angular-guard',
  'angular-interceptor',
  'angular-pipe',
  'angular-resolver',
  'angular-service',
  'apiblueprint',
  'appveyor',
  'aurelia',
  'auto',
  'autohotkey',
  'autoit',
  'bbx',
  'bibliography',
  'bibtex-style',
  'bithound',
  'blink',
  'bower',
  'bucklescript',
  'cake',
  'cbx',
  'chromatic',
  'cloudfoundry',
  'coffee',
  'conduct',
  'context',
  'crystal',
  'cuda',
  'cucumber',
  'doctex-installer',
  'dotjs',
  'drone',
  'dtx',
  'ejs',
  'flash',
  'flow',
  'fusebox',
  'graphcool',
  'grunt',
  'happo',
  'harmonix',
  'hip',
  'hjson',
  'ionic',
  'karma',
  'keystatic',
  'kivy',
  'kl',
  'kusto',
  'latexmk',
  'lbx',
  'liara',
  'lyric',
  'lynx',
  'livescript',
  'mathematica',
  'merlin',
  'mist',
  'mjml',
  'mxml',
  'ngrx-actions',
  'ngrx-effects',
  'ngrx-entity',
  'ngrx-reducer',
  'ngrx-selectors',
  'ngrx-state',
  'onnx',
  'otne',
  'palette',
  'payload',
  'processing',
  'protractor',
  'qsharp',
  'raml',
  'rc',
  'redux-action',
  'redux-reducer',
  'redux-selector',
  'redux-store',
  'restql',
  'riot',
  'rocket',
  'robot',
  'routing',
  'rspec',
  'rstack',
  'sbt',
  'scons',
  'simulink',
  'sonarcloud',
  'sty',
  'sublime',
  'smarty',
  'svgo',
  'swc',
  'toon',
  'travis',
  'tune',
  'twine',
  'unlicense',
  'vala',
  'varnish',
  'vfl',
  'virtual',
  'verdaccio',
  'vedic',
  'wakatime',
  'webhint',
  'vuex-store',
  'yang',
  'actionscript',
  'hex',
  'javaclass',
]);

const addedCuratedIcons = new Set([
  'ada',
  'amplify',
  'appwrite',
  'asciidoc',
  'azure',
  'azure-pipelines',
  'bazel',
  'bicep',
  'biome',
  'bruno',
  'buildkite',
  'bun',
  'capacitor',
  'claude',
  'cline',
  'cobol',
  'codeowners',
  'command',
  'commitizen',
  'commitlint',
  'cue',
  'copilot',
  'cursor',
  'cypress',
  'deno',
  'dependabot',
  'django',
  'drawio',
  'drizzle',
  'epub',
  'esbuild',
  'expo',
  'fastlane',
  'fortran',
  'freemarker',
  'gcp',
  'godot',
  'godot-assets',
  'hcl',
  'helm',
  'hosts',
  'hurl',
  'husky',
  'i18n',
  'jsconfig',
  'jsr',
  'kcl',
  'jupyter',
  'kubernetes',
  'lean',
  'lighthouse',
  'liquid',
  'makefile',
  'markdownlint',
  'maven',
  'mdx',
  'mermaid',
  'meson',
  'moon',
  'nest',
  'netlify',
  'nginx',
  'nuget',
  'nx',
  'openapi',
  'oxc',
  'parcel',
  'pascal',
  'pdm',
  'php',
  'phpunit',
  'pipeline',
  'pkl',
  'pnpm',
  'poetry',
  'pre-commit',
  'prisma',
  'puppeteer',
  'qwik',
  'robots',
  'scala',
  'serverless',
  'shader',
  'shellcheck',
  'skill',
  'sketch',
  'stencil',
  'storybook',
  'supabase',
  'svelte',
  'svg',
  'swagger',
  'tailwindcss',
  'tauri',
  'taskfile',
  'tcl',
  'template',
  'textlint',
  'tldraw',
  'tsconfig',
  'typst',
  'uml',
  'unity',
  'unocss',
  'vagrant',
  'vanilla-extract',
  'vim',
  'vite',
  'vitest',
  'webassembly',
  'wrangler',
  'wxt',
  'gemini-ai',
  'lefthook',
]);

const upstreamCoreNames = new Set(
  fileIcons.icons.slice(0, 300).map((icon: { name: string }) => icon.name),
);
const selectedIcons = fileIcons.icons.filter((icon: { name: string }) =>
  (upstreamCoreNames.has(icon.name) && !excludedFromUpstreamCore.has(icon.name))
  || addedCuratedIcons.has(icon.name),
);
const curatedIconCount = selectedIcons.length + 1;
if (curatedIconCount !== 300) {
  throw new Error(
    `Curated catalog must contain 300 logical icons, got ${curatedIconCount} `
      + `(${selectedIcons.length} specific plus fallback).`,
  );
}

for (const icon of selectedIcons) {
  if (icon.clone) {
    throw new Error(`Curated icon ${icon.name} is a generated clone, not a vendorable SVG.`);
  }
  const source = join(iconSourceDirectory, `${icon.name}.svg`);
  if (!existsSync(source)) {
    throw new Error(`Missing upstream SVG for curated icon ${icon.name}.`);
  }
}

mkdirSync(outputDirectory, { recursive: true });
for (const existing of readdirSync(outputDirectory)) {
  if (existing.startsWith(resourcePrefix) && existing.endsWith('.svg')) {
    unlinkSync(join(outputDirectory, existing));
  }
}

// The fallback glyph is generated by upstream from this exact path and its
// default Material blue-gray file color.
const fallbackPath = 'm8.668 6h3.6641l-3.6641-3.668v3.668m-4.668-4.668h5.332l4 4v8c0 0.73828-0.59375 1.3359-1.332 1.3359h-8c-0.73828 0-1.332-0.59766-1.332-1.3359v-10.664c0-0.74219 0.59375-1.3359 1.332-1.3359m3.332 1.3359h-3.332v10.664h8v-6h-4.668z';
writeFileSync(
  join(outputDirectory, `${resourcePrefix}file.svg`),
  `<svg viewBox="0 0 16 16" xmlns="http://www.w3.org/2000/svg"><path d="${fallbackPath}" fill="#90a4ae" /></svg>\n`,
);

const lightIconNames: string[] = [];
for (const icon of selectedIcons) {
  copyFileSync(
    join(iconSourceDirectory, `${icon.name}.svg`),
    join(outputDirectory, `${resourcePrefix}${icon.name}.svg`),
  );
  const lightSource = join(iconSourceDirectory, `${icon.name}_light.svg`);
  if (icon.light && existsSync(lightSource)) {
    copyFileSync(
      lightSource,
      join(outputDirectory, `${resourcePrefix}${icon.name}_light.svg`),
    );
    lightIconNames.push(icon.name);
  }
}

copyFileSync(
  join(upstreamRoot, 'LICENSE'),
  join(outputDirectory, 'LICENSE-material-icon-theme.txt'),
);
writeFileSync(
  join(outputDirectory, 'NOTICE-material-icon-theme.txt'),
  `Material Icon Theme ${upstreamVersion}\n`
    + `Source: https://github.com/PKief/vscode-material-icon-theme\n`
    + `Pinned commit: ${upstreamCommit}\n`
    + 'Kero includes a curated catalog of 300 logical file icons.\n',
);

// Reproduce the default Angular-pack mappings, using later upstream entries to
// resolve conflicts exactly as the extension generator does.
const fileNames = new Map<string, string>();
const fileExtensions = new Map<string, string>();
for (const icon of selectedIcons) {
  if (icon.disabled) continue;
  if (icon.enabledFor && !icon.enabledFor.includes('angular')) continue;
  for (const name of icon.fileNames ?? []) {
    fileNames.set(name.toLowerCase(), icon.name);
  }
  for (const extension of icon.fileExtensions ?? []) {
    fileExtensions.set(extension.toLowerCase(), icon.name);
  }
}

const swiftString = (value: string) => JSON.stringify(value);
const swiftDictionary = (values: Map<string, string>) =>
  [...values.entries()]
    .sort(([left], [right]) => left.localeCompare(right))
    .map(([key, value]) => `        ${swiftString(key)}: ${swiftString(value)},`)
    .join('\n');
const swiftSet = (values: string[]) =>
  [...values]
    .sort((left, right) => left.localeCompare(right))
    .map((value) => `        ${swiftString(value)},`)
    .join('\n');

const generatedSwift = `// Generated by scripts/${basename(import.meta.path)} from Material Icon Theme ${upstreamVersion}.
// Source commit: ${upstreamCommit}

import AppKit
import SwiftUI

@MainActor
enum MaterialFileIcon {
    static let curatedIconCount = ${curatedIconCount}

    private static let resourcePrefix = "${resourcePrefix}"
    private static let cache = NSCache<NSString, NSImage>()
    private static let lightIconNames: Set<String> = [
${swiftSet(lightIconNames)}
    ]
    private static let fileNames: [String: String] = [
${swiftDictionary(new Map([...fileNames].filter(([name]) => !name.includes('/'))))}
    ]
    private static let pathFileNames: [String: String] = [
${swiftDictionary(new Map([...fileNames].filter(([name]) => name.includes('/'))))}
    ]
    private static let fileExtensions: [String: String] = [
${swiftDictionary(fileExtensions)}
    ]

    static func image(forPath path: String, appearance: NSAppearance? = nil) -> NSImage {
        let iconName = iconName(forPath: path)
        let resolvedAppearance = appearance ?? NSApp.effectiveAppearance
        let isLight = resolvedAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua
        let variant = isLight && lightIconNames.contains(iconName)
            ? iconName + "_light"
            : iconName
        let cacheKey = variant as NSString
        if let cached = cache.object(forKey: cacheKey) { return cached }

        guard let url = Bundle.main.url(
            forResource: resourcePrefix + variant,
            withExtension: "svg"
        ), let image = NSImage(contentsOf: url) else {
            return NSImage(
                systemSymbolName: "doc.text",
                accessibilityDescription: nil
            ) ?? NSImage()
        }
        image.isTemplate = false
        cache.setObject(image, forKey: cacheKey)
        return image
    }

    static func iconName(forPath path: String) -> String {
        let normalizedPath = path
            .replacingOccurrences(of: "\\\\", with: "/")
            .lowercased()
        let fileName = (normalizedPath as NSString).lastPathComponent

        let pathParts = normalizedPath.split(separator: "/", omittingEmptySubsequences: true)
        if pathParts.count > 1 {
            for index in 0..<(pathParts.count - 1) {
                let suffix = pathParts[index...].joined(separator: "/")
                if let exact = pathFileNames[suffix] { return exact }
            }
        }
        if let exact = fileNames[fileName] { return exact }

        let parts = fileName.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count > 1 {
            for index in 1..<parts.count {
                let suffix = parts[index...].joined(separator: ".")
                if let iconName = fileExtensions[suffix] { return iconName }
            }
        }
        return "file"
    }
}

struct MaterialFileIconView: View {
    let path: String
    var size: CGFloat = 14
    var opacity: Double = 1

    @Environment(\\.colorScheme) private var colorScheme

    var body: some View {
        Image(nsImage: MaterialFileIcon.image(
            forPath: path,
            appearance: colorScheme == .dark
                ? NSAppearance(named: .darkAqua)
                : NSAppearance(named: .aqua)
        ))
        .renderingMode(.original)
        .resizable()
        .interpolation(.high)
        .scaledToFit()
        .frame(width: size, height: size)
        .opacity(opacity)
        .accessibilityHidden(true)
    }
}
`;
writeFileSync(swiftOutputPath, generatedSwift);

console.log(
  `Generated ${curatedIconCount} logical icons, ${fileNames.size} file-name mappings, `
    + `${fileExtensions.size} extension mappings, and ${lightIconNames.length} light variants.`,
);

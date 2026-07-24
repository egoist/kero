# Ghostty Patches

This directory is the single place for local upstream Ghostty patches used by
the `libghostty-spm` build pipeline.

## Rules

- Keep patches numbered so they apply in a stable order.
- Prefer standard unified diff files (`.patch`) when the upstream context is
  stable.
- Use executable patch scripts (`.sh`) only when upstream context is too
  unstable for a reliable diff.
- Keep version-specific variants beside the original patch and select them in
  `Script/apply-patches.sh` using an upstream API marker.
- Preserve newer Ghostty's renamed internal-library outputs when extending its
  Darwin static-library build path.
- Every patch in this directory must be safe to re-run.
- Patches here are applied automatically by `Script/build-ghostty.sh`, so they
  affect macOS, iOS, and Mac Catalyst builds equally.

## Current goal

This patch workflow exists so we can carry host-managed IO work required for
sandboxed iOS, macOS, and Mac Catalyst integration without hiding upstream
modifications inside ad-hoc build script edits.

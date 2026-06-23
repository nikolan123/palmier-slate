# PalmierPro

AI-native macOS video editor. Swift 6.2, SwiftUI + AppKit, AVFoundation. macOS 26 only, arm64 only. Non-sandboxed Developer ID app.

## Build

```bash
swift build
swift run
```

## Fork policy

This fork is local-first. Preserve that policy during normal development and upstream merges.

- No telemetry. Do not add Sentry, analytics, event reporting, identify calls, breadcrumbs, or telemetry-shaped log metadata.
- No accounts, subscriptions, credits, top-ups, sign-in flows, Clerk, Convex, or backend account state.
- No hosted Palmier generation backend. Keep hosted generation tools unavailable in this build unless the user explicitly changes the fork policy.
- Keep MCP/local workflows. MCP support is allowed, but should be off by default on first launch.
- Keep Claude/Anthropic integration optional. Claude UI and agent chat should be hidden/disabled when the Claude integration toggle is off. The toggle should be off by default on first launch.
- Keep local smart features such as transcription, smart search, Apple/Hugging Face model usage, and local model downloads. Model downloads must remain explicit and user-confirmed when initiated.
- Allowed network paths are currently limited to user-enabled Anthropic calls and explicit local model downloads, such as Hugging Face model downloads. Do not introduce other background network calls without documenting and confirming the policy change.
- `import_media` for MCP/agent use is local-only: local paths, local directories, or inline bytes. Do not reintroduce URL download imports.
- Do not reintroduce localized README files unless the user asks for them.

## Upstream merge policy

When merging upstream, keep useful editor improvements but filter them through this fork’s local-first policy.

- Prefer upstream fixes for editor stability, rendering, timeline behavior, media import, project I/O, export, tests, and local features.
- Reject or remove upstream changes that reintroduce telemetry, account/subscription UI, Clerk/Convex/Sentry/Sparkle dependencies, hosted generation services, updater/changelog resources tied to hosted distribution, or localized README files.
- If upstream adds package dependencies, inspect `Package.swift` and `Package.resolved`; keep only dependencies still needed by the local-first build.
- If conflicts touch project I/O or layout persistence, preserve prior local behavior unless upstream has a clear stability fix. Combine deliberately, then run source-level checks.
- After resolving a merge, scan for rejected-policy symbols such as `Telemetry`, `Sentry`, `Clerk`, `Convex`, `AccountService`, `BackendConfig`, `GenerationService`, `PalmierClient`, and `telemetry:`.
- Report what was merged, what was rejected, and how conflicts were resolved.

## Policy documentation

- When adding a new repository policy, fork-specific behavior rule, or major architectural decision, update this `AGENTS.md` in the same change.
- When merging major upstream changes, document any new accepted or rejected upstream policy here if it affects future agent behavior.
- Do not rely on chat history for durable repository rules.

## Code style

- Keep comments minimal. Only write one when the *why* is non-obvious. Don't restate what the code does, don't narrate the current change, don't leave `// removed X` breadcrumbs. One short line max — no multi-line comment blocks or paragraph docstrings.

## Design System

All UI styling MUST use `AppTheme` constants from `Sources/PalmierPro/UI/AppTheme.swift`. Never use hardcoded numeric values for:

- **Spacing/padding** → `AppTheme.Spacing.*` (xxs through xxl)
- **Font sizes** → `AppTheme.FontSize.*` (xxs through display)
- **Font weights** → `AppTheme.FontWeight.*` (regular, medium, semibold, bold)
- **Corner radii** → `AppTheme.Radius.*` (xs through xl)
- **Border widths** → `AppTheme.BorderWidth.*` (hairline, thin, medium, thick)
- **Opacity** → `AppTheme.Opacity.*` (subtle, faint, muted, medium, strong, prominent)
- **Icon frame sizes** → `AppTheme.IconSize.*` (xs through xl)
- **Shadows** → `AppTheme.Shadow.*` (sm, md, lg) via `.shadow(AppTheme.Shadow.md)`
- **Colors** → `AppTheme.Text.*`, `AppTheme.Border.*`, `AppTheme.Background.*`
- **Animation durations** → `AppTheme.Anim.*`

If a needed value doesn't exist in AppTheme, add it there first — don't hardcode it.

## Drag and drop

SwiftUI `.onDrop` on a parent view shadows every drop target inside its layout area on macOS 26 — even AppKit `NSDraggingDestination` children registered directly with the window. Inner `.onDrop` modifiers silently never fire while a parent `.onDrop` is active.

Rule: **any drop target that spans an area containing other drop targets must use native AppKit** (see `MediaPanelDropArea` in `Sources/PalmierPro/MediaPanel/`). Inner / leaf drops can stay SwiftUI `.onDrop`. Do not stack SwiftUI `.onDrop` modifiers in parent/child layouts.

## Voice

Palmier Pro speaks like a quietly capable native Mac app for filmmakers: direct, technical, calm, and 
confident. Prefer Apple HIG-style terseness over warmth. Never chatty or cute. Never marketing. When the
product needs to ask for action, lead with the action verb; when it reports state, name the thing.

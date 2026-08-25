# 007 — Ghostty Embedding Integration: Plan

| | |
| --- | --- |
| **Status** | Implemented (retrospective) |
| **Anchor date** | 2026-03-21 |
| **Documented** | 2026-07-12 (backfilled) |
| **Primary PRs** | #26, #27, #29, #31, #32, #33 (initial wave); #237, #242, #352 (theme); #286, #348, #374 (text/key safety) |
| **Sources** | PR descriptions; upstream review ledger entry 2026-05-09 "Ghostty fork patch" (see `docs-ai/017-upstream-sync-process/upstream-ledger.md`); [ghostty-fork-sync.md](ghostty-fork-sync.md) (living runbook in this folder) |
| **Related** | [012-keybinding-system](../012-keybinding-system/000-plan.md) (key routing), [030-agent-status-detection](../030-agent-status-detection/000-plan.md) (`ghostty_surface_pid` fork patch), [031-command-palette-architecture](../031-command-palette-architecture/000-plan.md) |

## Background

Prowl embeds GhosttyKit as a C library: one `ghostty_app_t` (owned by `GhosttyRuntime`)
hosting many independent `ghostty_surface_t` sessions (each wrapped by a
`GhosttySurfaceBridge` + `GhosttySurfaceView`). Ghostty does not perform window/tab/UI
operations itself — it emits *runtime actions* (`ghostty_action_s`) through an app-level
callback and expects the embedder to implement them. A stock Ghostty macOS app implements
the full action set; early Prowl implemented only a handful (new tab, close tab, goto tab,
title updates), so many user keybindings and Ghostty command-palette entries were silent
no-ops, while others (e.g. `check_for_updates`) duplicated native Prowl features.

Fork issues #21–#24 scoped the gap. For each Ghostty action the decision is one of:

1. **Implement natively** at the right level (app-wide vs per-surface).
2. **Route into Prowl's feature layer** (TCA) when the action has app semantics that
   Ghostty cannot know about (quit confirmation, native Sparkle updater).
3. **Filter out** actions that make no sense in Prowl's single-window architecture, so the
   Ghostty command palette does not advertise dead entries.

Two later waves belong to the same integration frame and are kept as amendments: making
Ghostty's theme follow Prowl's appearance mode, and hardening the C-ABI text/key-event
boundary (a real memory leak plus two classes of undefined text decoding).

## Goals

- Honor user Ghostty keybindings and command-palette commands wherever the action has a
  sensible meaning inside Prowl (title prompts, open config, fullscreen, maximize,
  background opacity, quit, close window).
- Route actions with app-level semantics through Prowl's own flow rather than bypassing it
  (quit must hit confirm-before-quit; updates must use Sparkle).
- Hide unsupported/duplicate Ghostty actions from the in-terminal command palette.
- (Amendment 002) Terminal colors follow the app's Light/Dark appearance without ever
  mutating the user's Ghostty config file.
- (Amendment 003) No memory leaks or malformed strings across the `ghostty_text_s` /
  `NSEvent` boundary.

**Non-goals**: multi-window Ghostty semantics (`new_window`, `goto_window`,
`close_all_windows`), window-decoration toggling (Prowl draws its own chrome), Ghostty's
inspector/GTK debug tooling, and key *binding* resolution itself (that is
[012-keybinding-system](../012-keybinding-system/000-plan.md)).

## Design / Approach

Action routing is layered, mirroring Ghostty's own target model:

- **App level** — `GhosttyRuntime` intercepts actions before any surface bridge:
  `GHOSTTY_ACTION_OPEN_CONFIG` (for `GHOSTTY_TARGET_APP`) resolves the config path via
  `ghostty_config_open_path()` and opens it; `GHOSTTY_ACTION_QUIT` is forwarded to the app
  store; `GHOSTTY_ACTION_CLOSE_WINDOW` closes the window owning the originating surface.
- **Surface level** — `GhosttySurfaceBridge.handleAppAction` implements
  `toggle_fullscreen` (native `NSWindow.toggleFullScreen`, regardless of Ghostty's
  native/non-native mode parameter), `toggle_maximize` (`NSWindow.zoom`), and
  `toggle_background_opacity` (only effective when the user configured
  `background-opacity < 1`; skipped in fullscreen, matching Ghostty).
- **Callback pattern** — surface actions that need UI (title prompts) follow the existing
  bridge-callback style (`onTitleChange`, `onCloseRequest`, …): the bridge exposes
  `onPromptTitle`, and `WorktreeTerminalState` presents the `NSAlert` sheet and applies
  the result through `TerminalTabManager` title override/lock methods.
- **Palette filtering** — a single `Set<String>` of Ghostty action keys
  (`filteredGhosttyActionKeys`) is consulted when building Ghostty-backed command-palette
  items, hiding native duplicates and architecturally unsupported actions.

## Alternatives & decisions

- **Quit through TCA, not `NSApp.terminate` directly**: #31 first landed the direct
  AppKit call, then (still inside #31) rerouted `GHOSTTY_ACTION_QUIT` through
  `AppFeature.requestQuit` so Ghostty-initiated quit gets the same confirm-before-quit
  behavior as the menu path.
- **Filter instead of implement** for `new_window` / `goto_window` / `close_all_windows` /
  `toggle_tab_overview` / `toggle_window_decorations` / `inspector` /
  `show_gtk_inspector` / `show_on_screen_keyboard`: Prowl is a single-window app with its
  own chrome and tab bar; implementing these would fight the architecture. Explicitly
  recorded in #27/#32/#33.
- **`check_for_updates` filtered, not bridged**: Prowl's Sparkle updater is the native
  implementation ([021-sparkle-update-ux](../021-sparkle-update-ux/000-plan.md) territory);
  the Ghostty palette entry would have been a no-op duplicate (#29).
- **Always native fullscreen**: Ghostty's fullscreen-mode parameter (native vs
  non-native) is accepted but ignored; Prowl always uses macOS native fullscreen (#27).
- **Runtime-only theme override, never config mutation** (amendment 002): the fallback is
  applied by loading a generated override file on top of the user's config in-process;
  the user's Ghostty config file is never written.
- **Carry fork patches on `release/v<tag>-patched`** (amendment 003): the text-free ABI
  fix was backported onto `onevcat/ghostty` `release/v1.3.1-patched` instead of waiting
  for an upstream tag; the branch model, patch list, and upgrade procedure are maintained
  in [ghostty-fork-sync.md](ghostty-fork-sync.md).

## Amendments

- Updated 2026-05-26: theme/appearance sync — single-theme runtime fallback (#237),
  initial color-scheme sync (#242), explicit dual themes + no-theme default (#352) — see
  [002-theme-appearance-sync.md](002-theme-appearance-sync.md)
- Updated 2026-05-30: text & key-event safety — text-free ABI fork backport (#286),
  explicit-length text decoding (#348), no text reads from modifier key events (#374) —
  see [003-text-and-key-event-safety.md](003-text-and-key-event-safety.md)
- Updated 2026-08-25: runtime-shared mouse press ownership prevents focus-transfer clicks
  and cross-pane releases from corrupting terminal selection — see
  [004-mouse-selection-ownership.md](004-mouse-selection-ownership.md)

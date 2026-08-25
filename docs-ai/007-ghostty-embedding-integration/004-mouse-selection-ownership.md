# 007.004 — Mouse Selection Ownership

## Context

PR #722 fixed stale terminal selection anchors after long scrollback by hit-testing from
the window content view, using the actual first responder for focus, consuming focus-transfer
clicks in an active window, and forwarding a left-button release only after a corresponding
press.

The initial ownership state was stored per `GhosttySurfaceView`. Each surface also installs
its own local event monitor. When an earlier-created pane consumed a focus-transfer click,
AppKit stopped dispatching that event to later monitors. A later-created pane could therefore
retain stale ownership and forward the subsequent release even though the new press belonged
to no Ghostty surface.

## Change

- Added the runtime-scoped, `@MainActor` `GhosttySurfaceMouseCoordinator` in
  `supacode/Infrastructure/Ghostty/GhosttySurfaceMouseCoordinator.swift`.
- The coordinator records one left-button press owner by pane UUID for the entire
  `GhosttyRuntime`. Every local left-button mouse-down clears that owner before window,
  hit-test, or focus guards can return.
- `GhosttySurfaceView+Mouse.swift` keeps the existing per-surface monitors for key-up and
  modifier forwarding, while delegating left-button focus and ownership decisions to the
  shared coordinator.
- Only a pane that successfully forwarded a press can own it. A release is forwarded only
  when its pane UUID matches the owner; every release clears ownership and resets Force Touch
  pressure, including non-matching and duplicate releases.
- `supacodeTests/GhosttySurfaceViewTests.swift` covers the monitor-order regression: pane A
  is created first, pane B holds stale ownership, pane A consumes a focus-transfer click,
  and pane B's later release is not forwarded.

## Refs

- PR #722.

## Current state

The ownership boundary is one Ghostty runtime, matching Prowl's single runtime that hosts all
terminal panes. Window activation clicks still pass through after assigning first responder;
focus-transfer clicks inside an already active key window are consumed so they cannot become
terminal presses.

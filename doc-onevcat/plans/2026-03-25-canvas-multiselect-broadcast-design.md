# Canvas Multi-Select and Broadcast Input Design

## Goal

Let Canvas select multiple cards and send the same user input to all selected cards, with a strong emphasis on:

- natural multi-card selection on macOS (`Cmd+Click`)
- direct typing into Canvas without a separate batch-input textbox
- correct non-English input behavior
- preserving current single-card interaction when multi-select is not active

This design targets the two main user scenarios discussed:

1. Open multiple cards backed by different agents and send the same prompt to compare results.
2. Operate multiple remote SSH sessions and apply the same command/configuration to all of them.

---

## Non-Goals

This design does **not** try to make multiple terminals behave like a perfectly synchronized remote desktop.

Out of scope for v1:

- broadcasting mouse interactions to multiple cards
- broadcasting search UI, text selection, or context menus
- mirroring IME candidate windows/preedit UI to follower cards
- guaranteeing perfect behavior for all full-screen TUIs (`vim`, `fzf`, `less`, `top`, etc.)
- changing sidebar multi-selection or worktree detail selection behavior outside Canvas

---

## Current Architecture Summary

Canvas today is fundamentally a **single-focus** experience:

- `CanvasView` stores a single `focusedTabID`.
- `CanvasCardView` only allows terminal hit testing when the card is focused.
- Canvas exit behavior uses the focused canvas card to decide which worktree/tab to return to.
- Terminal command routing is mostly **worktree-scoped**, while Canvas cards are effectively **tab-scoped**.

Relevant current implementation points:

- `supacode/Features/Canvas/Views/CanvasView.swift`
- `supacode/Features/Canvas/Views/CanvasCardView.swift`
- `supacode/Features/Terminal/Models/WorktreeTerminalState.swift`
- `supacode/Features/Terminal/BusinessLogic/WorktreeTerminalManager.swift`
- `supacode/Infrastructure/Ghostty/GhosttySurfaceView.swift`
- `supacode/App/CommandKeyObserver.swift`

Important constraints from current code:

1. A card maps to a **tab**, not only a worktree.
2. Input routing for active terminals depends on the focused `GhosttySurfaceView`.
3. `GhosttySurfaceView` already supports AppKit IME (`NSTextInputClient`) and distinguishes:
   - marked/preedit text (`setMarkedText` / `syncPreedit`)
   - committed text (`insertText`)
4. `CommandKeyObserver` already exists app-wide and can be reused to drive `Cmd`-based selection affordances.

---

## User Experience Design

## High-Level Model

Canvas will support:

- **primary focus**: the card that owns the real first responder and drives local input/IME
- **multi-selection**: zero, one, or many selected cards
- **selection mode**: a temporary click-interpretation mode entered by `Cmd+Click`

The key distinction is:

- **focus** decides where real AppKit/Ghostty input originates
- **selection** decides which cards receive mirrored input

These are related but not identical.

---

## Selection Rules

### Entering selection mode

- `Cmd+Click` on any unselected card region enters selection mode.
- The clicked card is added to selection.
- The clicked card becomes the **primary selected card**.

"Any card region" includes the terminal content area, not only the title bar.

### While selection mode is active

- `Cmd+Click` on an unselected card adds it to selection.
- `Cmd+Click` on a selected card removes it from selection.
- If removal leaves one selected card, Canvas may stay visually selected but effectively returns to single-card behavior.
- Clicking empty canvas clears selection and exits selection mode.

### Leaving selection mode

The mode should be intentionally short-lived and should end on the first normal interaction.

- Any **non-Command click** on a card:
  - exits selection mode
  - clears prior multi-selection
  - focuses that clicked card as the sole active card
- Any **non-Command keyboard input** when multiple cards are selected:
  - exits the pure selection state
  - immediately becomes a broadcast-input interaction
- Clicking empty canvas:
  - clears all selected cards
  - clears primary focus in Canvas (0-selection is allowed)

This keeps selection lightweight and avoids sticky modifier-heavy behavior.

---

## Focus and Primary Card Semantics

When multiple cards are selected, exactly one selected card is still the **primary** card.

The primary card is responsible for:

- owning the real first responder
- owning the visible IME composition/preedit state
- serving as the source of mirrored input
- deciding the worktree/tab used when exiting Canvas back to the normal terminal view

Selection without a primary card is invalid.

If the primary card is removed from selection:

- pick the most recently added remaining selected card as the new primary, or
- if that history is unavailable, pick a deterministic fallback (e.g. the last card toggled on)

---

## Visual Design

### Selected card styling

Cards need two visual states:

- **primary focused/selected** card
- **follower selected** cards

Suggested styling:

- primary card: current accent-colored focus ring
- follower cards: subtler selected ring/background tint, distinct from focus

### Broadcast hint

When more than one card is selected, show a lightweight hint in Canvas chrome, for example:

- `Broadcasting to 3 cards`
- `Esc to clear`

This should be informational only, not a dedicated text entry field.

A separate textbox is intentionally rejected because it makes the interaction feel unlike a terminal.

---

## Input Behavior Design

## Core Principle

When multiple cards are selected, the user still types **once** into the primary card.
Canvas mirrors that input to follower cards.

This should feel like:

- one real terminal under the cursor
- N-1 follower terminals receiving mirrored input

---

## IME / Non-English Input Behavior

This is the most important rule:

> Followers must receive committed characters/words, not the phonetic keystrokes used to compose them.

Examples:

- Chinese Pinyin input should mirror `你好`, not `nihao`
- Japanese input should mirror committed kana/kanji text, not unfinished romaji sequences

### IME behavior in v1

#### Primary card

The primary card handles the full native IME lifecycle as it does today:

- marked text / preedit
- candidate window
- commit
- cancel

#### Follower cards

Follower cards do **not** render IME preedit/candidate UI.
They receive only the final committed text.

That means:

- while the user is composing, followers may show no change yet
- once composition commits, followers receive the committed string immediately

This is the intended design, not a degradation.
It is the safest way to guarantee that non-English input remains semantically correct.

---

## Broadcast Categories

Input fan-out should be split into two classes.

### 1. Committed text broadcast

Used for:

- English text input that arrives as text
- committed IME text
- pasted text

Behavior:

- take the committed string from the primary card
- insert the same committed string into each follower card

### 2. Normalized special-key broadcast

Used for:

- `Enter`
- `Backspace` / `Delete`
- arrow keys
- `Tab`
- `Escape`
- common shell control keys (for example `Ctrl-C`, `Ctrl-D`, `Ctrl-L`)

Behavior:

- normalize the originating primary-card key event into a small mirror-safe model
- replay that normalized input on followers

### Explicitly excluded from broadcast

Do not broadcast:

- `Cmd` shortcuts
- menu shortcuts
- window/app commands
- mouse events
- IME marked/preedit updates

This keeps the feature aligned with terminal input rather than app control.

---

## Implementation Design

## 1. Canvas Selection State

Add explicit selection state to `CanvasView`.

Suggested state:

```swift
@State private var primaryFocusedTabID: TerminalTabID?
@State private var selectedTabIDs: Set<TerminalTabID> = []
@State private var selectionMode: CanvasSelectionMode = .idle
@State private var selectionOrder: [TerminalTabID] = []
```

Where:

```swift
enum CanvasSelectionMode {
  case idle
  case selecting
}
```

Notes:

- `focusedTabID` should evolve into `primaryFocusedTabID`
- `selectedTabIDs` may be empty
- `selectionOrder` is useful for deterministic replacement when the primary card is deselected

### Why keep this in `CanvasView` for v1

The behavior is Canvas-local and highly UI-driven.
There is no strong need to move it into TCA reducer state yet.

To keep the logic testable, extract the transition rules into a small pure helper type, for example:

- `CanvasSelectionStateMachine`
- `CanvasSelectionModel`

Then `CanvasView` can host the state while tests target the pure transition logic.

---

## 2. Cmd+Click Anywhere on a Card

### Problem

Today the focused terminal content receives hit testing, which means the terminal area would normally steal clicks.
A title-bar-only approach is not acceptable.

### Proposed solution: selection shield overlay

When either of the following is true:

- `CommandKeyObserver.isPressed == true`, or
- `selectionMode == .selecting`

Canvas should place a transparent hit-testing layer over every visible card.

This layer:

- captures clicks before Ghostty terminal content
- interprets `Cmd+Click` as selection toggling
- interprets non-Command clicks as exit-from-selection behavior

In normal single-focus mode, the shield is disabled and cards behave as they do today.

### Why this fits the current code

- `CommandKeyObserver` is already injected into the environment from `supacodeApp.swift`
- `CanvasCardView` already wraps the full card surface
- we only need temporary precedence over the terminal surface during selection interactions

This avoids invasive Ghostty mouse interception for v1.

---

## 3. Make Broadcast Tab-Scoped, Not Worktree-Scoped

Current terminal commands are mostly scoped by `Worktree`.
Canvas cards are scoped by `TerminalTabID`.

The broadcast feature must therefore introduce **tab-scoped** terminal helpers.

### Add tab-targeted helpers on `WorktreeTerminalState`

Suggested APIs:

```swift
func surfaceView(for tabId: TerminalTabID) -> GhosttySurfaceView?
func insertCommittedText(_ text: String, in tabId: TerminalTabID) -> Bool
func submitLine(in tabId: TerminalTabID) -> Bool
func applyMirroredKey(_ key: MirroredTerminalKey, in tabId: TerminalTabID) -> Bool
```

### Add lookup helpers on `WorktreeTerminalManager`

Suggested APIs:

```swift
func ownerState(for tabId: TerminalTabID) -> WorktreeTerminalState?
func ownerWorktreeID(for tabId: TerminalTabID) -> Worktree.ID?
func broadcast(_ input: CanvasBroadcastInput, from primary: TerminalTabID, to tabs: Set<TerminalTabID>)
```

This keeps Canvas from manually searching every state each time input is mirrored.

---

## 4. Add Explicit Broadcast Hooks to `GhosttySurfaceView`

Current callbacks are insufficient for correct fan-out.

Today there is:

- `onKeyInput: (() -> Void)?`

That only signals that input happened; it does not tell us **what** was committed or which key should be mirrored.

### Proposed new callbacks

Add narrow, mirror-oriented hooks:

```swift
var onCommittedText: ((String) -> Void)?
var onMirroredKey: ((MirroredTerminalKey) -> Void)?
var onPasteText: ((String) -> Void)?
```

Where `MirroredTerminalKey` is a normalized model, for example:

```swift
struct MirroredTerminalKey: Equatable, Sendable {
  var keyCode: UInt16
  var characters: String?
  var charactersIgnoringModifiers: String?
  var modifiers: NSEvent.ModifierFlags
  var kind: Kind
  var isRepeat: Bool

  enum Kind: Equatable, Sendable {
    case enter
    case backspace
    case delete
    case arrowUp
    case arrowDown
    case arrowLeft
    case arrowRight
    case tab
    case escape
    case controlCharacter
    case other
  }
}
```

### Important filtering rule

Do **not** emit mirrored-key callbacks for `Cmd` shortcuts.
Those remain app-level behavior.

---

## 5. Add Safe Follower Insertion APIs

### Problem

`GhosttySurfaceView.insertText(_:, replacementRange:)` currently guards on `NSApp.currentEvent != nil`.
That is appropriate for responder-driven text input, but follower fan-out should not depend on responder-chain assumptions.

### Proposed solution

Add explicit non-responder insertion APIs for mirrored use:

```swift
func insertCommittedTextForBroadcast(_ text: String)
func applyMirroredKeyForBroadcast(_ key: MirroredTerminalKey) -> Bool
```

Behavior:

- `insertCommittedTextForBroadcast(_:)` should write committed UTF-8 text directly to the surface
- `applyMirroredKeyForBroadcast(_:)` should replay a normalized key on the target surface without making it the app first responder

This avoids coupling broadcast behavior to `NSApp.currentEvent` or menu routing.

### Focus behavior for followers

Follower cards should **not** steal first responder during broadcast.
The primary card remains the real focused AppKit responder.

This is essential for stable IME behavior.

---

## 6. Event Flow

### A. Multi-select click flow

1. User holds `Cmd`.
2. Canvas enables selection shield overlays.
3. User clicks any card region.
4. Canvas toggles that `tabID` in `selectedTabIDs`.
5. Canvas updates `primaryFocusedTabID` if needed.
6. Ghostty does not consume that click.

### B. Normal single-card click while in selection mode

1. User clicks a card without `Cmd`.
2. Canvas clears prior multi-selection.
3. Canvas sets clicked card as sole selected/focused card.
4. Canvas exits selection mode.
5. Normal single-card terminal behavior resumes.

### C. IME composition on primary card

1. User types with IME on the primary card.
2. Primary card receives `setMarkedText(...)` and updates preedit locally.
3. No follower update happens yet.
4. User commits a candidate.
5. Primary card receives `insertText(...)` with committed text.
6. Canvas/manager broadcasts that committed string to followers.

### D. Enter key broadcast

1. Primary card receives Enter.
2. Primary card submits normally.
3. Broadcast layer emits `.enter` mirrored key.
4. Followers receive `.enter` via broadcast helper.

---

## 7. Interaction With Existing Canvas Exit Behavior

Current Canvas exit uses the focused canvas card to decide which worktree/tab to restore.
That should continue to use the **primary selected card**.

Rules:

- if multiple cards are selected, exiting Canvas returns to the primary card's owning worktree/tab
- if selection was cleared and no primary remains, Canvas exits to the prior normal fallback behavior
- clicking empty canvas may leave Canvas with 0 selection and 0 focused card; this is acceptable

---

## Alternatives Considered

## Rejected: title-bar-only multi-select

Rejected because users must be able to select from the terminal area too.
In Canvas, the card is the object, not only its title bar.

## Rejected: dedicated batch-input textbox

Rejected because it makes terminal broadcast feel indirect and unlike the rest of Prowl.
Direct typing is the intended interaction.

## Rejected: full raw-event mirroring for IME

Rejected because it would risk propagating phonetic composition keys (`nihao`, romaji, etc.) instead of committed text.
Correct multilingual output is more important than perfect preedit mirroring.

---

## Suggested File-Level Changes

### Primary feature files

- `supacode/Features/Canvas/Views/CanvasView.swift`
  - add selection state
  - add selection-mode transitions
  - add broadcast status UI
  - integrate selection shield

- `supacode/Features/Canvas/Views/CanvasCardView.swift`
  - add selected/follower styling
  - expose overlay entry points for selection interception
  - preserve normal terminal hit testing outside selection mode

### Terminal model / manager

- `supacode/Features/Terminal/Models/WorktreeTerminalState.swift`
  - add tab-scoped mirrored input helpers

- `supacode/Features/Terminal/BusinessLogic/WorktreeTerminalManager.swift`
  - add owner lookup + broadcast helper methods

### Ghostty bridge

- `supacode/Infrastructure/Ghostty/GhosttySurfaceView.swift`
  - add committed-text callback(s)
  - add normalized mirrored-key callback(s)
  - add follower-safe insertion/replay methods
  - keep IME preedit primary-only

### Optional small helper extraction

- `supacode/Features/Canvas/Models/CanvasSelectionStateMachine.swift`
  - pure logic for selection transitions

- `supacode/Infrastructure/Ghostty/MirroredTerminalKey.swift`
  - normalized key model used between primary and followers

---

## Verification Strategy

## Automated

### Pure selection-state tests

Test the extracted selection state machine for:

- `Cmd+Click` enter selection mode
- toggle on/off selected cards
- click blank canvas clears all
- non-Command click exits selection mode
- primary replacement when current primary is deselected

### Terminal mirror helper tests

If `MirroredTerminalKey` normalization is extracted, test:

- Enter maps correctly
- arrows map correctly
- `Cmd` shortcuts are filtered out
- IME committed text is handled as text, not special-key broadcast

## Manual

### Shell / SSH

- select 2+ SSH cards
- type a command like `pwd`
- verify all cards receive the same text
- press Enter
- verify all cards execute once
- test `Ctrl-C`

### Agent prompt comparison

- select 2+ agent cards
- type the same prompt
- verify all cards receive the same committed prompt text

### IME

- use Chinese Pinyin
- compose text in primary card
- verify followers do not show phonetic intermediate text
- commit the candidate
- verify followers receive committed Chinese text

- repeat with Japanese input

### Selection UX

- `Cmd+Click` terminal area of focused and unfocused cards
- ordinary click exits selection mode correctly
- blank-canvas click clears selection
- exit Canvas returns to the primary card's worktree/tab

---

## Risks

1. **Ghostty/AppKit event ordering**
   - follower replay must not interfere with the primary first responder

2. **IME edge cases**
   - candidate confirmation behavior may differ by input method
   - design intentionally limits follower behavior to committed text

3. **Complex TUIs**
   - some full-screen or mouse-driven apps may not behave intuitively under broadcast
   - acceptable for v1

4. **Click/drag interaction overlap**
   - card drag gestures and selection clicks must be thresholded cleanly

---

## Recommended Delivery Shape

Implement this in slices:

### Slice 1
- selection state model
- Cmd+Click anywhere using selection shield
- follower selected styling
- clear/exit behavior

### Slice 2
- tab-scoped terminal helpers
- primary/follower broadcast plumbing
- committed text broadcast
- Enter/backspace/arrows/basic control keys

### Slice 3
- IME hardening
- paste behavior
- edge-case polish and manual verification

This keeps UX validation separate from lower-level Ghostty input fan-out.

---

## Final Recommendation

Proceed with a design that treats Canvas multi-select as:

- **card-level selection anywhere on the card**, not title-bar-only
- **primary-card-driven live broadcast**, not a separate textbox
- **IME commit-text mirroring**, not phonetic keystroke mirroring

That combination best matches the requested UX while staying implementable in the current Prowl/Ghostty architecture.

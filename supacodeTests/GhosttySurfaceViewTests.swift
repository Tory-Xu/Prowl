import AppKit
import Foundation
import GhosttyKit
import Testing

@testable import supacode

@MainActor
struct GhosttySurfaceViewTests {
  @Test func mainMenuExactMatchRejectsShiftVariantOfCommandComma() throws {
    let menu = NSMenu()
    let item = NSMenuItem(title: "Settings", action: nil, keyEquivalent: ",")
    item.keyEquivalentModifierMask = [.command]
    menu.addItem(item)

    let event = try makeKeyEvent(
      characters: "<",
      charactersIgnoringModifiers: ",",
      modifiers: [.command, .shift],
      keyCode: 43
    )

    #expect(!GhosttySurfaceView.mainMenuHasMatchingItem(for: event, in: menu))
  }

  @Test func mainMenuExactMatchAcceptsExactCommandComma() throws {
    let menu = NSMenu()
    let item = NSMenuItem(title: "Settings", action: nil, keyEquivalent: ",")
    item.keyEquivalentModifierMask = [.command]
    menu.addItem(item)

    let event = try makeKeyEvent(
      characters: ",",
      charactersIgnoringModifiers: ",",
      modifiers: [.command],
      keyCode: 43
    )

    #expect(GhosttySurfaceView.mainMenuHasMatchingItem(for: event, in: menu))
  }

  @Test func mainMenuExactMatchAcceptsShiftedSymbolKeyEquivalent() throws {
    let menu = NSMenu()
    let item = NSMenuItem(title: "Help", action: nil, keyEquivalent: "?")
    item.keyEquivalentModifierMask = [.command]
    menu.addItem(item)

    let event = try makeKeyEvent(
      characters: "?",
      charactersIgnoringModifiers: "/",
      modifiers: [.command, .shift],
      keyCode: 44
    )

    #expect(GhosttySurfaceView.mainMenuHasMatchingItem(for: event, in: menu))
  }

  @Test func mainMenuExactMatchRejectsUnshiftedVariantOfShiftedSymbolKeyEquivalent() throws {
    let menu = NSMenu()
    let item = NSMenuItem(title: "Help", action: nil, keyEquivalent: "?")
    item.keyEquivalentModifierMask = [.command]
    menu.addItem(item)

    let event = try makeKeyEvent(
      characters: "/",
      charactersIgnoringModifiers: "/",
      modifiers: [.command],
      keyCode: 44
    )

    #expect(!GhosttySurfaceView.mainMenuHasMatchingItem(for: event, in: menu))
  }

  @Test func mainMenuExactMatchFindsSubmenuItems() throws {
    let menu = NSMenu()
    let parent = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
    let submenu = NSMenu()
    let item = NSMenuItem(title: "Show Diff", action: nil, keyEquivalent: "y")
    item.keyEquivalentModifierMask = [.command, .shift]
    submenu.addItem(item)
    parent.submenu = submenu
    menu.addItem(parent)

    let event = try makeKeyEvent(
      characters: "Y",
      charactersIgnoringModifiers: "y",
      modifiers: [.command, .shift],
      keyCode: 16
    )

    #expect(GhosttySurfaceView.mainMenuHasMatchingItem(for: event, in: menu))
  }

  @Test func keyEquivalentFocusOwnershipRequiresActualFirstResponder() {
    #expect(GhosttySurfaceView.hasKeyEquivalentFocusOwnership(cachedFocused: true, isActualFirstResponder: true))
    #expect(!GhosttySurfaceView.hasKeyEquivalentFocusOwnership(cachedFocused: true, isActualFirstResponder: false))
    #expect(!GhosttySurfaceView.hasKeyEquivalentFocusOwnership(cachedFocused: false, isActualFirstResponder: true))
  }

  @Test func leftMouseReleaseRequiresSharedOwnedPress() throws {
    let runtime = GhosttyRuntime()
    let surfaceView = GhosttySurfaceView(
      runtime: runtime,
      workingDirectory: nil,
      context: GHOSTTY_SURFACE_CONTEXT_TAB,
      skipsSurfaceCreationForTesting: true
    )
    let mouseDown = try makeMouseEvent(type: .leftMouseDown)
    let mouseUp = try makeMouseEvent(type: .leftMouseUp)
    var pressCount = 0
    var releaseCount = 0
    var pressureResetCount = 0
    surfaceView.mouseButtonHandlerForTesting = { state, button in
      #expect(button == GHOSTTY_MOUSE_LEFT)
      if state == GHOSTTY_MOUSE_PRESS {
        pressCount += 1
      } else if state == GHOSTTY_MOUSE_RELEASE {
        releaseCount += 1
      }
      return true
    }
    surfaceView.onMousePressureResetForTesting = { pressureResetCount += 1 }

    surfaceView.prevPressureStage = 2
    surfaceView.mouseUp(with: mouseUp)
    #expect(releaseCount == 0)
    #expect(surfaceView.prevPressureStage == 0)

    surfaceView.mouseDown(with: mouseDown)
    surfaceView.prevPressureStage = 2
    surfaceView.mouseUp(with: mouseUp)
    surfaceView.mouseUp(with: mouseUp)

    #expect(pressCount == 1)
    #expect(releaseCount == 1)
    #expect(pressureResetCount == 3)
    #expect(surfaceView.prevPressureStage == 0)
  }

  @Test func crossPaneMouseReleaseClearsSharedOwnershipAndResetsPressure() throws {
    let runtime = GhosttyRuntime()
    let paneA = GhosttySurfaceView(
      runtime: runtime,
      workingDirectory: nil,
      context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
      skipsSurfaceCreationForTesting: true
    )
    let paneB = GhosttySurfaceView(
      runtime: runtime,
      workingDirectory: nil,
      context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
      skipsSurfaceCreationForTesting: true
    )
    let mouseDown = try makeMouseEvent(type: .leftMouseDown)
    let mouseUp = try makeMouseEvent(type: .leftMouseUp)
    var paneAReleaseCount = 0
    var paneBReleaseCount = 0
    var paneAPressureResetCount = 0
    var paneBPressureResetCount = 0
    paneA.mouseButtonHandlerForTesting = { state, _ in
      if state == GHOSTTY_MOUSE_RELEASE {
        paneAReleaseCount += 1
      }
      return true
    }
    paneB.mouseButtonHandlerForTesting = { state, _ in
      if state == GHOSTTY_MOUSE_RELEASE {
        paneBReleaseCount += 1
      }
      return true
    }
    paneA.onMousePressureResetForTesting = { paneAPressureResetCount += 1 }
    paneB.onMousePressureResetForTesting = { paneBPressureResetCount += 1 }

    paneB.mouseDown(with: mouseDown)
    paneA.prevPressureStage = 2
    paneA.mouseUp(with: mouseUp)
    paneB.prevPressureStage = 2
    paneB.mouseUp(with: mouseUp)

    #expect(paneAReleaseCount == 0)
    #expect(paneBReleaseCount == 0)
    #expect(paneAPressureResetCount == 1)
    #expect(paneBPressureResetCount == 1)
    #expect(paneA.prevPressureStage == 0)
    #expect(paneB.prevPressureStage == 0)
  }

  @Test func focusTransferClickClearsLaterPaneMouseOwnershipBeforeRelease() throws {
    let mouseCoordinator = GhosttySurfaceMouseCoordinator(isActiveKeyWindow: { _ in true })
    let runtime = GhosttyRuntime(mouseCoordinator: mouseCoordinator)
    let paneA = GhosttySurfaceView(
      runtime: runtime,
      workingDirectory: nil,
      context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
      skipsSurfaceCreationForTesting: true
    )
    let paneB = GhosttySurfaceView(
      runtime: runtime,
      workingDirectory: nil,
      context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
      skipsSurfaceCreationForTesting: true
    )
    let windowSize = CGSize(width: 400, height: 200)
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: windowSize),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    defer { window.orderOut(nil) }

    let contentView = NSView(frame: NSRect(origin: .zero, size: windowSize))
    paneA.frame = NSRect(x: 0, y: 0, width: 200, height: 200)
    paneB.frame = NSRect(x: 200, y: 0, width: 200, height: 200)
    contentView.addSubview(paneA)
    contentView.addSubview(paneB)
    window.contentView = contentView
    window.orderFront(nil)
    #expect(window.makeFirstResponder(paneB))

    var paneBReleaseCount = 0
    var paneBPressureResetCount = 0
    paneB.mouseButtonHandlerForTesting = { state, _ in
      if state == GHOSTTY_MOUSE_RELEASE {
        paneBReleaseCount += 1
      }
      return true
    }
    paneB.onMousePressureResetForTesting = { paneBPressureResetCount += 1 }

    let stalePress = try makeMouseEvent(
      type: .leftMouseDown,
      window: window,
      location: NSPoint(x: 300, y: 100)
    )
    paneB.mouseDown(with: stalePress)

    let focusClick = try makeMouseEvent(
      type: .leftMouseDown,
      window: window,
      location: NSPoint(x: 100, y: 100)
    )
    // Pane A installed its monitor before pane B. Consuming here models AppKit stopping
    // monitor dispatch before pane B's monitor can observe the new mouse-down.
    let result = paneA.localEventLeftMouseDown(focusClick)
    #expect(result == nil)
    #expect(window.firstResponder === paneA)

    paneB.prevPressureStage = 2
    paneB.mouseUp(
      with: try makeMouseEvent(
        type: .leftMouseUp,
        window: window,
        location: NSPoint(x: 100, y: 100)
      )
    )

    #expect(paneBReleaseCount == 0)
    #expect(paneBPressureResetCount == 1)
    #expect(paneB.prevPressureStage == 0)
  }

  @Test func contentViewHitTestFindsScrolledSurface() throws {
    let runtime = GhosttyRuntime()
    let surfaceView = GhosttySurfaceView(
      runtime: runtime,
      workingDirectory: nil,
      context: GHOSTTY_SURFACE_CONTEXT_TAB,
      skipsSurfaceCreationForTesting: true
    )
    let windowSize = CGSize(width: 400, height: 300)
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: windowSize),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    defer { window.orderOut(nil) }

    let contentView = NSView(frame: NSRect(origin: .zero, size: windowSize))
    let scrollView = NSScrollView(frame: contentView.bounds)
    scrollView.hasVerticalScroller = false
    scrollView.contentView.clipsToBounds = false
    let documentView = NSView(frame: NSRect(x: 0, y: 0, width: windowSize.width, height: 3_000))
    surfaceView.frame = NSRect(x: 0, y: 2_000, width: windowSize.width, height: windowSize.height)
    documentView.addSubview(surfaceView)
    scrollView.documentView = documentView
    contentView.addSubview(scrollView)
    window.contentView = contentView
    window.orderFront(nil)

    scrollView.contentView.scroll(to: NSPoint(x: 0, y: 2_000))
    scrollView.reflectScrolledClipView(scrollView.contentView)

    let locationInWindow = NSPoint(x: 100, y: 100)
    let event = try #require(
      NSEvent.mouseEvent(
        with: .leftMouseDown,
        location: locationInWindow,
        modifierFlags: [],
        timestamp: 1,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 1,
        clickCount: 1,
        pressure: 1
      )
    )

    let surfaceLocalPoint = surfaceView.convert(locationInWindow, from: nil)
    #expect(surfaceView.hitTest(surfaceLocalPoint) !== surfaceView)
    #expect(contentView.hitTest(locationInWindow) === surfaceView)
    _ = surfaceView.localEventLeftMouseDown(event)
    #expect(window.firstResponder === surfaceView)
  }

  @Test func occlusionStateResendsDesiredValueAfterAttachmentChange() {
    var state = GhosttySurfaceView.OcclusionState()

    let firstApply = state.prepareToApply(true)
    let secondApply = state.prepareToApply(true)

    #expect(firstApply)
    #expect(!secondApply)
    let desired = state.invalidateForAttachmentChange()
    let reapply = state.prepareToApply(true)

    #expect(desired == true)
    #expect(reapply)
  }

  @Test func occlusionStateDoesNotResendBeforeAnyDesiredValueExists() {
    var state = GhosttySurfaceView.OcclusionState()

    let desired = state.invalidateForAttachmentChange()
    let firstApply = state.prepareToApply(false)
    let secondApply = state.prepareToApply(false)

    #expect(desired == nil)
    #expect(firstApply)
    #expect(!secondApply)
  }

  @Test func occlusionStateStoresDesiredValueWithoutMarkingItApplied() {
    var state = GhosttySurfaceView.OcclusionState()

    state.setDesired(true)
    let firstApply = state.prepareToApply(true)
    let secondApply = state.prepareToApply(true)

    #expect(firstApply)
    #expect(!secondApply)
  }

  @Test func occlusionStateUsesLatestDeferredDesiredValue() {
    var state = GhosttySurfaceView.OcclusionState()

    state.setDesired(true)
    state.setDesired(false)
    let applyDeferredValue = state.prepareToApply(false)
    let secondApply = state.prepareToApply(false)

    #expect(applyDeferredValue)
    #expect(!secondApply)
  }

  @Test func occlusionStateAppliesLatestValueAfterAttachmentInvalidation() {
    var state = GhosttySurfaceView.OcclusionState()

    let firstApply = state.prepareToApply(true)
    let desiredAfterAttachmentChange = state.invalidateForAttachmentChange()
    #expect(firstApply)
    #expect(desiredAfterAttachmentChange == true)

    state.setDesired(false)
    let applyLatestValue = state.prepareToApply(false)
    let duplicateApply = state.prepareToApply(false)

    #expect(applyLatestValue)
    #expect(!duplicateApply)
  }

  @Test func occlusionStateRetainsLatestDesiredValueAcrossMultipleAttachmentChanges() {
    var state = GhosttySurfaceView.OcclusionState()

    state.setDesired(true)
    let desiredAfterFirstAttachmentChange = state.invalidateForAttachmentChange()
    #expect(desiredAfterFirstAttachmentChange == true)
    state.setDesired(false)
    let desiredAfterSecondAttachmentChange = state.invalidateForAttachmentChange()
    #expect(desiredAfterSecondAttachmentChange == false)

    let applyLatestValue = state.prepareToApply(false)
    let duplicateApply = state.prepareToApply(false)

    #expect(applyLatestValue)
    #expect(!duplicateApply)
  }

  @Test func launchEnvironmentCarriesThePaneIdentity() {
    let runtime = GhosttyRuntime()
    let surfaceView = GhosttySurfaceView(
      runtime: runtime,
      workingDirectory: nil,
      context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
      environment: ["PROWL_WORKTREE_PATH": "/repo/wt", "PROWL_PANE_ID": "forged"],
      skipsSurfaceCreationForTesting: true
    )
    let sibling = GhosttySurfaceView(
      runtime: runtime,
      workingDirectory: nil,
      context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
      skipsSurfaceCreationForTesting: true
    )

    #expect(surfaceView.launchEnvironment["PROWL_PANE_ID"] == surfaceView.id.uuidString)
    #expect(surfaceView.launchEnvironment["PROWL_WORKTREE_PATH"] == "/repo/wt")
    #expect(sibling.launchEnvironment["PROWL_PANE_ID"] == sibling.id.uuidString)
    #expect(sibling.id != surfaceView.id)
  }

  @Test func occlusionDoesNotApplyUntilViewHasSuperviewAndWindow() async {
    let runtime = GhosttyRuntime()
    let surfaceView = GhosttySurfaceView(
      runtime: runtime,
      workingDirectory: nil,
      context: GHOSTTY_SURFACE_CONTEXT_TAB,
      skipsSurfaceCreationForTesting: true
    )
    var appliedValues: [Bool] = []
    surfaceView.onOcclusionAppliedForTesting = { appliedValues.append($0) }
    var attachmentState = (hasSuperview: false, hasWindow: false)
    surfaceView.attachmentStateForTesting = { attachmentState }

    surfaceView.setOcclusion(true)
    await drainMainQueue()
    #expect(appliedValues.isEmpty)

    attachmentState = (hasSuperview: true, hasWindow: false)
    surfaceView.handleAttachmentChangeForTesting()
    await drainMainQueue()
    #expect(appliedValues.isEmpty)

    attachmentState = (hasSuperview: true, hasWindow: true)
    surfaceView.handleAttachmentChangeForTesting()
    await drainMainQueue()
    #expect(appliedValues == [true])
  }

  @Test func occlusionAppliesLatestDeferredValueAfterWindowReattachment() async {
    let runtime = GhosttyRuntime()
    let surfaceView = GhosttySurfaceView(
      runtime: runtime,
      workingDirectory: nil,
      context: GHOSTTY_SURFACE_CONTEXT_TAB,
      skipsSurfaceCreationForTesting: true
    )
    var appliedValues: [Bool] = []
    surfaceView.onOcclusionAppliedForTesting = { appliedValues.append($0) }
    var attachmentState = (hasSuperview: true, hasWindow: true)
    surfaceView.attachmentStateForTesting = { attachmentState }

    surfaceView.handleAttachmentChangeForTesting()
    await drainMainQueue()
    #expect(appliedValues.isEmpty)

    surfaceView.setOcclusion(true)
    await drainMainQueue()
    #expect(appliedValues == [true])

    attachmentState = (hasSuperview: false, hasWindow: false)
    surfaceView.handleAttachmentChangeForTesting()
    await drainMainQueue()

    // Occluding (false) applies immediately even while detached to stop
    // the render loop.  Un-occluding (true) is deferred until reattached.
    surfaceView.setOcclusion(false)
    surfaceView.setOcclusion(true)
    surfaceView.setOcclusion(false)
    await drainMainQueue()
    #expect(appliedValues == [true, false])

    attachmentState = (hasSuperview: true, hasWindow: true)
    surfaceView.handleAttachmentChangeForTesting()
    await drainMainQueue()
    // Reattachment re-applies the desired value (false) even though it
    // was already applied, because invalidateForAttachmentChange clears
    // the applied cache.
    #expect(appliedValues == [true, false, false])
  }

  @Test func occlusionFalseAppliesImmediatelyWithoutViewAttachment() async {
    let runtime = GhosttyRuntime()
    let surfaceView = GhosttySurfaceView(
      runtime: runtime,
      workingDirectory: nil,
      context: GHOSTTY_SURFACE_CONTEXT_TAB,
      skipsSurfaceCreationForTesting: true
    )
    var appliedValues: [Bool] = []
    surfaceView.onOcclusionAppliedForTesting = { appliedValues.append($0) }
    var attachmentState = (hasSuperview: false, hasWindow: false)
    surfaceView.attachmentStateForTesting = { attachmentState }

    // Occluding without a view hierarchy applies immediately (stops the
    // Metal render loop for restored surfaces that are never displayed).
    surfaceView.setOcclusion(false)
    await drainMainQueue()
    #expect(appliedValues == [false])

    // Un-occluding without a view hierarchy is deferred.
    surfaceView.setOcclusion(true)
    await drainMainQueue()
    #expect(appliedValues == [false])

    // Once attached, the deferred un-occlude is applied.
    attachmentState = (hasSuperview: true, hasWindow: true)
    surfaceView.handleAttachmentChangeForTesting()
    await drainMainQueue()
    #expect(appliedValues == [false, true])
  }

  @Test func occlusionCanRecoverWhenAttachmentCallbackIsMissedAfterReattachment() async {
    let runtime = GhosttyRuntime()
    let surfaceView = GhosttySurfaceView(
      runtime: runtime,
      workingDirectory: nil,
      context: GHOSTTY_SURFACE_CONTEXT_TAB,
      skipsSurfaceCreationForTesting: true
    )
    var appliedValues: [Bool] = []
    surfaceView.onOcclusionAppliedForTesting = { appliedValues.append($0) }
    var attachmentState = (hasSuperview: true, hasWindow: true)
    surfaceView.attachmentStateForTesting = { attachmentState }

    surfaceView.setOcclusion(true)
    await drainMainQueue()
    #expect(appliedValues == [true])

    attachmentState = (hasSuperview: false, hasWindow: false)
    surfaceView.handleAttachmentChangeForTesting()
    await drainMainQueue()

    attachmentState = (hasSuperview: true, hasWindow: true)
    surfaceView.resumeDeferredOcclusionIfNeededForTesting()
    await drainMainQueue()
    #expect(appliedValues == [true, true])
  }

  @Test func terminalHostReattachesSurfaceOnlyAfterItLeavesTheViewTree() {
    let runtime = GhosttyRuntime()
    let surfaceView = GhosttySurfaceView(
      runtime: runtime,
      workingDirectory: nil,
      context: GHOSTTY_SURFACE_CONTEXT_TAB,
      skipsSurfaceCreationForTesting: true
    )
    let terminalHost = GhosttySurfaceScrollView(surfaceView: surfaceView, hostKind: .terminal)
    let foreignHost = NSView()

    #expect(terminalHost.isSurfaceAttachedToDocumentView)

    foreignHost.addSubview(surfaceView)
    #expect(!terminalHost.isSurfaceAttachedToDocumentView)

    terminalHost.ensureSurfaceAttached(requiresLiveHost: false)

    #expect(!terminalHost.isSurfaceAttachedToDocumentView)
    #expect(surfaceView.superview === foreignHost)

    surfaceView.removeFromSuperview()
    #expect(surfaceView.superview == nil)

    terminalHost.ensureSurfaceAttached(requiresLiveHost: false)

    #expect(terminalHost.isSurfaceAttachedToDocumentView)
    #expect(surfaceView.scrollWrapper === terminalHost)
  }

  @Test func terminalHostDoesNotStealSurfaceFromCanvasHost() {
    let runtime = GhosttyRuntime()
    let surfaceView = GhosttySurfaceView(
      runtime: runtime,
      workingDirectory: nil,
      context: GHOSTTY_SURFACE_CONTEXT_TAB,
      skipsSurfaceCreationForTesting: true
    )
    let terminalHost = GhosttySurfaceScrollView(surfaceView: surfaceView, hostKind: .terminal)
    let canvasHost = GhosttySurfaceScrollView(surfaceView: surfaceView, hostKind: .canvas)

    #expect(!terminalHost.isSurfaceAttachedToDocumentView)
    #expect(canvasHost.isSurfaceAttachedToDocumentView)
    #expect(surfaceView.scrollWrapper === canvasHost)

    terminalHost.ensureSurfaceAttached(requiresLiveHost: false)

    #expect(!terminalHost.isSurfaceAttachedToDocumentView)
    #expect(canvasHost.isSurfaceAttachedToDocumentView)
    #expect(surfaceView.scrollWrapper === canvasHost)
  }

  @Test func canvasHostDoesNotStealDetachedSurfaceBack() {
    let runtime = GhosttyRuntime()
    let surfaceView = GhosttySurfaceView(
      runtime: runtime,
      workingDirectory: nil,
      context: GHOSTTY_SURFACE_CONTEXT_TAB,
      skipsSurfaceCreationForTesting: true
    )
    let canvasHost = GhosttySurfaceScrollView(surfaceView: surfaceView, hostKind: .canvas)
    let foreignHost = NSView()

    #expect(canvasHost.isSurfaceAttachedToDocumentView)

    foreignHost.addSubview(surfaceView)
    #expect(!canvasHost.isSurfaceAttachedToDocumentView)

    canvasHost.ensureSurfaceAttached(requiresLiveHost: false)

    #expect(!canvasHost.isSurfaceAttachedToDocumentView)
    #expect(surfaceView.superview === foreignHost)
  }

  private func drainMainQueue() async {
    await withCheckedContinuation { continuation in
      DispatchQueue.main.async {
        continuation.resume()
      }
    }
  }

  @Test func normalizedWorkingDirectoryPathRemovesTrailingSlashForNonRootPath() {
    #expect(
      GhosttySurfaceView.normalizedWorkingDirectoryPath("/Users/onevcat/Sync/github/supacode/")
        == "/Users/onevcat/Sync/github/supacode"
    )
    #expect(
      GhosttySurfaceView.normalizedWorkingDirectoryPath("/Users/onevcat/Sync/github/supacode///")
        == "/Users/onevcat/Sync/github/supacode"
    )
  }

  @Test func normalizedWorkingDirectoryPathKeepsRootPath() {
    #expect(GhosttySurfaceView.normalizedWorkingDirectoryPath("/") == "/")
  }

  @Test func accessibilityLineCountsLineBreaksUpToIndex() {
    let content = "alpha\nbeta\ngamma"

    #expect(GhosttySurfaceView.accessibilityLine(for: 0, in: content) == 0)
    #expect(GhosttySurfaceView.accessibilityLine(for: 5, in: content) == 0)
    #expect(GhosttySurfaceView.accessibilityLine(for: 6, in: content) == 1)
    #expect(GhosttySurfaceView.accessibilityLine(for: content.count, in: content) == 2)
  }

  @Test func accessibilityStringReturnsSubstringForValidRange() {
    let content = "alpha\nbeta"

    #expect(
      GhosttySurfaceView.accessibilityString(
        for: NSRange(location: 6, length: 4),
        in: content
      ) == "beta"
    )
    #expect(
      GhosttySurfaceView.accessibilityString(
        for: NSRange(location: 99, length: 1),
        in: content
      ) == nil
    )
  }

  @Test func stringFromGhosttyTextUsesExplicitLength() {
    let bytes: [UInt8] = Array("alpha".utf8) + [0] + Array("omega".utf8)

    let decoded = bytes.withUnsafeBufferPointer { buffer in
      let pointer = UnsafeRawPointer(buffer.baseAddress!).assumingMemoryBound(to: CChar.self)
      return GhosttySurfaceView.stringFromGhosttyText(pointer: pointer, length: UInt(bytes.count))
    }

    #expect(Array(decoded.utf8) == bytes)
  }

  @Test func keyboardLayoutChangeKeyUpSuppressionSuppressesMatchingKeyUp() {
    let suppression = GhosttySurfaceView.KeyboardLayoutChangeKeyUpSuppression(
      keyCode: 49,
      timestamp: 10
    )

    #expect(suppression.suppresses(keyCode: 49, timestamp: 10.1))
    #expect(!suppression.isExpired(at: 10.1))
  }

  @Test func keyboardLayoutChangeKeyUpSuppressionIgnoresDifferentKeyUp() {
    let suppression = GhosttySurfaceView.KeyboardLayoutChangeKeyUpSuppression(
      keyCode: 49,
      timestamp: 10
    )

    #expect(!suppression.suppresses(keyCode: 50, timestamp: 10.1))
    #expect(suppression.suppresses(keyCode: 49, timestamp: 10.2))
    #expect(!suppression.isExpired(at: 10.1))
  }

  @Test func keyboardLayoutChangeKeyUpSuppressionExpires() {
    let suppression = GhosttySurfaceView.KeyboardLayoutChangeKeyUpSuppression(
      keyCode: 49,
      timestamp: 10
    )

    #expect(!suppression.suppresses(keyCode: 49, timestamp: 11.1))
    #expect(suppression.isExpired(at: 11.1))
  }

  private func makeKeyEvent(
    characters: String,
    charactersIgnoringModifiers: String,
    modifiers: NSEvent.ModifierFlags,
    keyCode: UInt16
  ) throws -> NSEvent {
    try #require(
      NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: modifiers,
        timestamp: 1,
        windowNumber: 0,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: charactersIgnoringModifiers,
        isARepeat: false,
        keyCode: keyCode
      )
    )
  }

  private func makeMouseEvent(
    type: NSEvent.EventType,
    window: NSWindow? = nil,
    location: NSPoint = .zero
  ) throws -> NSEvent {
    try #require(
      NSEvent.mouseEvent(
        with: type,
        location: location,
        modifierFlags: [],
        timestamp: 1,
        windowNumber: window?.windowNumber ?? 0,
        context: nil,
        eventNumber: 1,
        clickCount: 1,
        pressure: 1
      )
    )
  }
}

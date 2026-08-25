import AppKit

@MainActor
final class GhosttySurfaceMouseCoordinator {
  private var leftMousePressOwnerID: UUID?
  private let isActiveKeyWindow: (NSWindow) -> Bool

  init(
    isActiveKeyWindow: @escaping (NSWindow) -> Bool = { window in
      NSApp.isActive && window.isKeyWindow
    }
  ) {
    self.isActiveKeyWindow = isActiveKeyWindow
  }

  func forwardLeftMouseDown(for surfaceID: UUID, send: () -> Bool) {
    leftMousePressOwnerID = nil
    guard send() else { return }
    leftMousePressOwnerID = surfaceID
  }

  func forwardLeftMouseUp(for surfaceID: UUID, send: () -> Void) {
    let ownsPress = leftMousePressOwnerID == surfaceID
    leftMousePressOwnerID = nil
    guard ownsPress else { return }
    send()
  }

  func localEventLeftMouseDown(_ event: NSEvent, for surfaceView: GhosttySurfaceView) -> NSEvent? {
    leftMousePressOwnerID = nil
    guard let window = surfaceView.window, let eventWindow = event.window, window === eventWindow else {
      return event
    }
    guard window.contentView?.hitTest(event.locationInWindow) === surfaceView else { return event }
    guard window.firstResponder !== surfaceView else { return event }
    if isActiveKeyWindow(window) {
      guard window.makeFirstResponder(surfaceView) else { return event }
      return nil
    }
    window.makeFirstResponder(surfaceView)
    return event
  }
}

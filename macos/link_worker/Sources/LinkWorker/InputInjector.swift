import Foundation
import CoreGraphics
import ApplicationServices

public final class InputInjector {
    public static let shared = InputInjector()

    private var isLeftMouseDown: Bool = false
    private var isRightMouseDown: Bool = false

    private init() {}

    public var isAccessibilityTrusted: Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    public func moveMouse(normX: Double, normY: Double, bounds: CGRect) {
        guard isAccessibilityTrusted else { return }
        let px = bounds.origin.x + normX * bounds.width
        let py = bounds.origin.y + normY * bounds.height
        let point = CGPoint(x: px, y: py)

        let eventType: CGEventType
        let mouseButton: CGMouseButton
        if isLeftMouseDown {
            eventType = .leftMouseDragged
            mouseButton = .left
        } else if isRightMouseDown {
            eventType = .rightMouseDragged
            mouseButton = .right
        } else {
            eventType = .mouseMoved
            mouseButton = .left
        }

        guard let event = CGEvent(mouseEventSource: nil, mouseType: eventType, mouseCursorPosition: point, mouseButton: mouseButton) else { return }
        event.post(tap: .cghidEventTap)
    }

    public func mouseAction(action: String, button: Int, normX: Double, normY: Double, bounds: CGRect) {
        guard isAccessibilityTrusted else { return }
        let px = bounds.origin.x + normX * bounds.width
        let py = bounds.origin.y + normY * bounds.height
        let point = CGPoint(x: px, y: py)

        let mouseButton: CGMouseButton = switch button {
        case 1: .right
        case 2: .center
        default: .left
        }

        let (downType, upType): (CGEventType, CGEventType) = switch button {
        case 1: (.rightMouseDown, .rightMouseUp)
        case 2: (.otherMouseDown, .otherMouseUp)
        default: (.leftMouseDown, .leftMouseUp)
        }

        if action == "down" || action == "click" {
            if button == 0 { isLeftMouseDown = true }
            if button == 1 { isRightMouseDown = true }
            if let eventDown = CGEvent(mouseEventSource: nil, mouseType: downType, mouseCursorPosition: point, mouseButton: mouseButton) {
                eventDown.post(tap: .cghidEventTap)
            }
        }

        if action == "up" || action == "click" {
            if button == 0 { isLeftMouseDown = false }
            if button == 1 { isRightMouseDown = false }
            if let eventUp = CGEvent(mouseEventSource: nil, mouseType: upType, mouseCursorPosition: point, mouseButton: mouseButton) {
                eventUp.post(tap: .cghidEventTap)
            }
        }
    }

    public func mouseWheel(deltaY: Double) {
        guard isAccessibilityTrusted else { return }
        let ticks = Int32((-deltaY).rounded().clamped(to: -50...50))
        if ticks == 0 { return }
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: ticks, wheel2: 0, wheel3: 0) else { return }
        event.post(tap: .cghidEventTap)
    }

    public func keyAction(macKeyCode: UInt16, isDown: Bool) {
        guard isAccessibilityTrusted else { return }
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(macKeyCode), keyDown: isDown) else { return }
        event.post(tap: .cghidEventTap)
    }

    public func insertText(_ text: String) {
        guard isAccessibilityTrusted else { return }
        let utf16Chars = Array(text.utf16)
        guard let eventDown = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let eventUp = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { return }
        eventDown.keyboardSetUnicodeString(stringLength: utf16Chars.count, unicodeString: utf16Chars)
        eventUp.keyboardSetUnicodeString(stringLength: utf16Chars.count, unicodeString: utf16Chars)
        eventDown.post(tap: .cghidEventTap)
        eventUp.post(tap: .cghidEventTap)
    }
}

private extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }
}

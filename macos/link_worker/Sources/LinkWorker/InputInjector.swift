import Foundation
import CoreGraphics
import ApplicationServices

public final class InputInjector {
    public static let shared = InputInjector()

    private init() {}

    public var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    public func moveMouse(normX: Double, normY: Double, width: Double, height: Double) {
        guard isAccessibilityTrusted else { return }
        let px = normX * width
        let py = normY * height
        let point = CGPoint(x: px, y: py)
        guard let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) else { return }
        event.post(tap: .cghidEventTap)
    }

    public func mouseAction(action: String, button: Int, normX: Double, normY: Double, width: Double, height: Double) {
        guard isAccessibilityTrusted else { return }
        let px = normX * width
        let py = normY * height
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
            if let eventDown = CGEvent(mouseEventSource: nil, mouseType: downType, mouseCursorPosition: point, mouseButton: mouseButton) {
                eventDown.post(tap: .cghidEventTap)
            }
        }

        if action == "up" || action == "click" {
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
}

private extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }
}

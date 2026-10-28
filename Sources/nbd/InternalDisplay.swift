import Foundation
import CoreGraphics
import IOKit
import IOKit.graphics

/// Brightness control for built-in Apple displays.
///
/// Primary path: the private DisplayServices framework (works on Apple
/// Silicon, where IODisplayConnect no longer exists and CGDisplayIOServicePort
/// is broken on macOS 26+). Fallback: classic IOKit display parameters via
/// CGDisplayIOServicePort (works on Intel Macs / older macOS).
enum InternalDisplay {

    /// Sets brightness (0.0...1.0) on the built-in display.
    @discardableResult
    static func setBrightness(_ value: Float, displayID: CGDirectDisplayID) -> Bool {
        guard value >= 0, value <= 1 else { return false }

        if DisplayServicesBrightness.set(value, displayID: displayID) {
            return true
        }

        let service = CGDisplayIOServicePort(displayID)
        guard service != IO_OBJECT_NULL else { return false }
        var connect: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &connect) == KERN_SUCCESS else { return false }
        defer { IOServiceClose(connect) }
        let result = IODisplaySetFloatParameter(connect, 0, kIODisplayBrightnessKey as CFString, value)
        return result == KERN_SUCCESS
    }

    /// Reads current brightness (0.0...1.0) of the built-in display.
    static func getBrightness(displayID: CGDirectDisplayID) -> Float? {
        if let value = DisplayServicesBrightness.get(displayID: displayID) {
            return value
        }

        let service = CGDisplayIOServicePort(displayID)
        guard service != IO_OBJECT_NULL else { return nil }
        var connect: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &connect) == KERN_SUCCESS else { return nil }
        defer { IOServiceClose(connect) }

        var value: Float = 0
        let result = IODisplayGetFloatParameter(connect, 0, kIODisplayBrightnessKey as CFString, &value)
        return result == KERN_SUCCESS ? value : nil
    }
}


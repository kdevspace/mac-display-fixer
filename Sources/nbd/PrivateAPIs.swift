import Foundation
import CoreGraphics
import IOKit

// MARK: - Private / deprecated API declarations

/// Deprecated by Apple in macOS 10.9 without a public replacement, still fully functional.
/// Returns the IOKit service port of a CG display (used for EDID/name and built-in brightness).
@_silgen_name("CGDisplayIOServicePort")
func CGDisplayIOServicePort(_ display: CGDirectDisplayID) -> io_service_t

// MARK: - IOAVService (Apple Silicon DDC/CI channel)

/// The IOAVService I2C family lives in the IOKit binary but is not part of the public SDK
/// headers, so it is declared here manually. These are the exact signatures used by
/// MonitorControl and Crisp on Apple Silicon Macs.
@_silgen_name("IOAVServiceCreateWithService")
private func _IOAVServiceCreateWithService(_ allocator: CFAllocator?, _ service: io_service_t) -> Unmanaged<AnyObject>?

@_silgen_name("IOAVServiceReadI2C")
private func _IOAVServiceReadI2C(_ service: AnyObject?, _ address: UInt32, _ dataAddress: UInt32, _ data: UnsafeMutablePointer<UInt8>, _ dataLength: UInt32) -> kern_return_t

@_silgen_name("IOAVServiceWriteI2C")
private func _IOAVServiceWriteI2C(_ service: AnyObject?, _ address: UInt32, _ dataAddress: UInt32, _ data: UnsafeMutablePointer<UInt8>, _ dataLength: UInt32) -> kern_return_t

/// Creates an IOAVService for an IORegistry entry (returns a retained CF object).
func IOAVServiceCreateWithService(_ service: io_service_t) -> AnyObject? {
    _IOAVServiceCreateWithService(nil, service)?.takeRetainedValue()
}

/// Reads bytes over the display's DDC I2C bus.
func IOAVServiceReadI2C(_ service: AnyObject?, address: UInt32, dataAddress: UInt32, data: inout [UInt8]) -> kern_return_t {
    data.withUnsafeMutableBufferPointer { buffer in
        _IOAVServiceReadI2C(service, address, dataAddress, buffer.baseAddress!, UInt32(buffer.count))
    }
}

/// Writes bytes over the display's DDC I2C bus.
func IOAVServiceWriteI2C(_ service: AnyObject?, address: UInt32, dataAddress: UInt32, data: inout [UInt8]) -> kern_return_t {
    data.withUnsafeMutableBufferPointer { buffer in
        _IOAVServiceWriteI2C(service, address, dataAddress, buffer.baseAddress!, UInt32(buffer.count))
    }
}

// MARK: - CoreDisplay (private framework, binary in dyld cache)

private let _CoreDisplayHandle: UnsafeMutableRawPointer? = {
    dlopen("/System/Library/PrivateFrameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY)
}()

private let _CDCreateDisplayInfo: (@convention(c) (CGDirectDisplayID) -> UnsafeRawPointer?)? = {
    guard let h = _CoreDisplayHandle, let sym = dlsym(h, "CoreDisplay_DisplayCreateInfoDictionary") else { return nil }
    return unsafeBitCast(sym, to: (@convention(c) (CGDirectDisplayID) -> UnsafeRawPointer?).self)
}()

/// Display info dictionary for a CG display (names etc.).
/// Returns a retained CF dictionary. Works on all macOS versions where
/// CGDisplayIOServicePort is broken (returns 0, e.g. macOS 26+).
func CoreDisplay_DisplayCreateInfoDictionary(_ display: CGDirectDisplayID) -> CFDictionary? {
    guard let create = _CDCreateDisplayInfo, let raw = create(display) else { return nil }
    // CF create rule: the returned CF object is retained, hand it to ARC as retained.
    return unsafeBitCast(raw, to: CFDictionary.self)
}

// MARK: - DisplayServices (private framework, binary in dyld cache)
//
// Built-in panel brightness on Apple Silicon, where IODisplayConnect no longer
// exists and CoreDisplay_Display_SetUserBrightness is a no-op. Loaded via
// dlsym because SwiftPM cannot link private frameworks.

private let _DisplayServicesHandle: UnsafeMutableRawPointer? = {
    dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
}()

private let _DSSetBrightness: (@convention(c) (CGDirectDisplayID, Float) -> Int32)? = {
    guard let h = _DisplayServicesHandle, let sym = dlsym(h, "DisplayServicesSetBrightness") else { return nil }
    return unsafeBitCast(sym, to: (@convention(c) (CGDirectDisplayID, Float) -> Int32).self)
}()

private let _DSGetBrightness: (@convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32)? = {
    guard let h = _DisplayServicesHandle, let sym = dlsym(h, "DisplayServicesGetBrightness") else { return nil }
    return unsafeBitCast(sym, to: (@convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32).self)
}()

enum DisplayServicesBrightness {
    /// Returns the raw Set/Get function pointers (nil when unavailable).
    static var isAvailable: Bool { _DSSetBrightness != nil && _DSGetBrightness != nil }

    /// Reads brightness (0.0...1.0). Returns nil when unavailable.
    static func get(displayID: CGDirectDisplayID) -> Float? {
        guard let get = _DSGetBrightness else { return nil }
        var value: Float = 0
        guard get(displayID, &value) == 0 else { return nil }
        return value
    }

    /// Sets brightness (0.0...1.0).
    @discardableResult
    static func set(_ value: Float, displayID: CGDirectDisplayID) -> Bool {
        guard let set = _DSSetBrightness else { return false }
        return set(displayID, value) == 0
    }
}


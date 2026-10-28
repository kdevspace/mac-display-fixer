import Foundation
import CoreGraphics

/// Display rotation via Apple's (private) MonitorPanel framework.
///
/// This is the same mechanism `displayplacer` uses: the MPDisplay class is
/// loaded from /System/Library/PrivateFrameworks/MonitorPanel.framework
/// (the binary lives in the dyld shared cache on modern macOS) and its
/// setOrientation: method rotates the display.
///
/// MPDisplay does not formally conform to any Swift protocol, so the
/// selectors initWithCGSDisplayID: / setOrientation: (which take a C int)
/// are invoked through a type-matched objc_msgSend.
enum RotationService {

    private static let frameworkPath = "/System/Library/PrivateFrameworks/MonitorPanel.framework/MonitorPanel"

    /// objc_msgSend with one int argument, returning an object pointer.
    private typealias MsgSendInt = @convention(c) (UnsafeMutableRawPointer, Selector, Int32) -> UnsafeMutableRawPointer

    static var isAvailable: Bool {
        guard let handle = dlopen(frameworkPath, RTLD_LAZY),
              let msgSend = symbol(handle, "objc_msgSend"),
              NSClassFromString("MPDisplay") != nil else { return false }
        return msgSend != nil
    }

    private static func symbol(_ handle: UnsafeMutableRawPointer, _ name: String) -> MsgSendInt? {
        guard let raw = dlsym(handle, name) else { return nil }
        return unsafeBitCast(raw, to: MsgSendInt.self)
    }

    /// Synchronous variant: performs the rotation and waits on the calling
    /// thread. Used by the CLI (no main run loop there). UI code uses the
    /// async setRotation(_:for:completion:) variant below.
    static func setRotationSync(_ degrees: Int, for displayID: CGDirectDisplayID) -> Bool {
        guard let handle = dlopen(frameworkPath, RTLD_LAZY),
              let msgSend = symbol(handle, "objc_msgSend"),
              let displayClass = NSClassFromString("MPDisplay") else {
            return false
        }

        let classPtr = Unmanaged.passUnretained(displayClass as AnyObject).toOpaque()
        // alloc ignores the extra register argument, so passing 0 is safe.
        let allocated = msgSend(classPtr, sel_registerName("alloc"), 0)
        let display = msgSend(allocated, sel_registerName("initWithCGSDisplayID:"), Int32(bitPattern: displayID))
        guard display != nil else { return false }
        _ = msgSend(display, sel_registerName("setOrientation:"), Int32(degrees))

        // Wait (up to 10 s) for the rotation to take effect.
        let startedAt = Date()
        while Date().timeIntervalSince(startedAt) < 10 {
            if Int(CGDisplayRotation(displayID)) == degrees { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return Int(CGDisplayRotation(displayID)) == degrees
    }

    /// Rotates the given display to `degrees` (0, 90, 180 or 270).
    /// The completion handler is called on the main queue once the rotation
    /// has been confirmed (or timed out / failed).
    static func setRotation(_ degrees: Int, for displayID: CGDirectDisplayID, completion: @escaping @Sendable (Bool) -> Void) {
        DispatchQueue.main.async {
            guard let handle = dlopen(frameworkPath, RTLD_LAZY),
                  let msgSend = symbol(handle, "objc_msgSend"),
                  let displayClass = NSClassFromString("MPDisplay") else {
                completion(false)
                return
            }

            let classPtr = Unmanaged.passUnretained(displayClass as AnyObject).toOpaque()
            // alloc ignores the extra register argument, so passing 0 is safe.
            let allocated = msgSend(classPtr, sel_registerName("alloc"), 0)
            let display = msgSend(allocated, sel_registerName("initWithCGSDisplayID:"), Int32(bitPattern: displayID))
            guard display != nil else {
                completion(false)
                return
            }
            _ = msgSend(display, sel_registerName("setOrientation:"), Int32(degrees))

            // Wait (up to 10 s) for the rotation to take effect, polling periodically
            // without blocking the main thread.
            let startedAt = Date()
            poll(startedAt: startedAt, displayID: displayID, degrees: degrees, completion: completion)
        }
    }

    private static func poll(startedAt: Date, displayID: CGDirectDisplayID, degrees: Int, completion: @escaping @Sendable (Bool) -> Void) {
        if Int(CGDisplayRotation(displayID)) == degrees {
            completion(true)
            return
        }
        if Date().timeIntervalSince(startedAt) > 10 {
            completion(false)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            poll(startedAt: startedAt, displayID: displayID, degrees: degrees, completion: completion)
        }
    }
}

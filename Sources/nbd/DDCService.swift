import Foundation
import CoreGraphics
import IOKit

// MARK: - DDC/CI over IOAVService (Apple Silicon)
//
// Protocol verified against MonitorControl and Crisp:
//   Write (Set VCP):  payload [0x84, 0x03, vcpCode, valueHi, valueLo] + checksum
//   Read  (Get VCP):  payload [0x82, 0x01, vcpCode] + checksum, then read 12 bytes
//   Checksum:         XOR of (0x6E ^ 0x51) with every payload byte
//   Reply:            [0x6E, len, 0x02, 0x00, vcp, type, maxHi, maxLo, curHi, curLo, checksum]
//                     reply checksum = XOR of 0x50 with bytes 0...9

struct VCPValue {
    var current: UInt16
    var maximum: UInt16

    var pct: Double {
        guard maximum > 0 else { return 0 }
        return Double(current) / Double(maximum) * 100.0
    }
}

final class DDCService {
    static let shared = DDCService()
    private init() {}

    static let brightnessCode: UInt8 = 0x10
    static let contrastCode: UInt8 = 0x12

    private static let i2cAddress: UInt32 = 0x37
    private static let i2cDataAddress: UInt32 = 0x51
    private static let minimumOperationDelay: TimeInterval = 0.05

    private let queue = DispatchQueue(label: "com.nbd.ddc", qos: .userInitiated)
    private let lock = NSLock()
    private var serviceCache: [CGDirectDisplayID: AnyObject] = [:]
    private var cachePopulated = false

    // Coalesced write queue (slider drags generate many events)
    private var pendingWrites: [String: (displayID: CGDirectDisplayID, code: UInt8, value: UInt16)] = [:]
    private var draining = false

    // MARK: - Public API

    /// Synchronously looks up the DDC service for a display.
    /// Must not be called from the main thread.
    func service(for displayID: CGDirectDisplayID) -> AnyObject? {
        lock.lock()
        if cachePopulated, let cached = serviceCache[displayID] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        return queue.sync { () -> AnyObject? in
            refreshServiceCache()
            lock.lock()
            defer { lock.unlock() }
            return serviceCache[displayID]
        }
    }

    /// Reads a VCP feature value. Runs on the DDC queue, calls back on the main thread.
    func readVCP(_ code: UInt8, displayID: CGDirectDisplayID, completion: @escaping @Sendable (VCPValue?) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            let value = self.readVCPNow(code, displayID: displayID)
            DispatchQueue.main.async { completion(value) }
        }
    }

    /// Coalesced async write (Set VCP). Rapid updates collapse into the latest value.
    func writeVCP(_ code: UInt8, value: UInt16, displayID: CGDirectDisplayID) {
        lock.lock()
        pendingWrites["\(displayID)-\(code)"] = (displayID, code, value)
        let shouldDrain = !draining
        draining = true
        lock.unlock()
        guard shouldDrain else { return }
        queue.async { [weak self] in self?.drainPendingWrites() }
    }

    /// Drops all cached services and pending writes (call on display topology changes).
    func invalidate() {
        lock.lock()
        serviceCache.removeAll()
        cachePopulated = false
        pendingWrites.removeAll()
        lock.unlock()
    }
}

// MARK: - Discovery
//
// On Apple Silicon the DDC channel (DCPAVServiceProxy) and the display identity
// (DisplayAttributes -> ProductAttributes) live in sibling subtrees, so a
// depth-first registry walk that remembers the most recently seen identity is
// used to pair channels with displays, then an identity match
// (vendor/product/serial) is attempted against the CG display list.

extension DDCService {

    private struct AVChannel {
        let service: AnyObject
        let vendor: UInt32?
        let product: UInt32?
        let serial: UInt32?
    }

    func refreshServiceCache() {
        let channels = discoverAVChannels()

        var displayCount: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &displayCount)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetOnlineDisplayList(displayCount, &ids, &displayCount)
        let external = ids.prefix(Int(displayCount)).filter { CGDisplayIsBuiltin($0) == 0 }

        var cache: [CGDirectDisplayID: AnyObject] = [:]
        var remaining = channels
        for displayID in external {
            let vendor = CGDisplayVendorNumber(displayID)
            let product = CGDisplayModelNumber(displayID)
            let serial = CGDisplaySerialNumber(displayID)

            let matched = remaining.first(where: { $0.vendor == vendor && $0.product == product && $0.serial == serial })
                ?? remaining.first(where: { $0.vendor == vendor && $0.product == product })
            if let matched {
                cache[displayID] = matched.service
                remaining.removeAll { $0.service === matched.service }
            }
        }

        // Traversal-order fallback for displays that could not be identity matched
        // (e.g. two identical monitors sharing vendor/product/serial).
        let unmatched = external.filter { cache[$0] == nil }
        for (displayID, channel) in zip(unmatched, remaining) {
            cache[displayID] = channel.service
        }

        lock.lock()
        serviceCache = cache
        cachePopulated = true
        lock.unlock()
    }

    private func discoverAVChannels() -> [AVChannel] {
        var channels: [AVChannel] = []
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != IO_OBJECT_NULL else { return [] }
        defer { IOObjectRelease(root) }

        var iterator = io_iterator_t()
        guard IORegistryEntryCreateIterator(root, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var lastVendor: UInt32?
        var lastProduct: UInt32?
        var lastSerial: UInt32?

        while true {
            let entry = IOIteratorNext(iterator)
            guard entry != IO_OBJECT_NULL else { break }
            defer { IOObjectRelease(entry) }

            if let attrs = IORegistryEntryCreateCFProperty(entry, "DisplayAttributes" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any],
               let productAttrs = attrs["ProductAttributes"] as? [String: Any] {
                if let vendor = (productAttrs["LegacyManufacturerID"] as? NSNumber)?.uint32Value {
                    lastVendor = vendor
                }
                if let product = (productAttrs["ProductID"] as? NSNumber)?.uint32Value {
                    lastProduct = product
                }
                if let serial = (productAttrs["SerialNumber"] as? NSNumber)?.uint32Value {
                    lastSerial = serial
                }
            }

            var classNameBuffer = [CChar](repeating: 0, count: 128)
            guard IOObjectGetClass(entry, &classNameBuffer) == KERN_SUCCESS else { continue }
            let className = String(cString: classNameBuffer)

            if className == "DCPAVServiceProxy" {
                let location = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
                if location == nil || location == "External" {
                    if let service = IOAVServiceCreateWithService(entry) {
                        channels.append(AVChannel(service: service, vendor: lastVendor, product: lastProduct, serial: lastSerial))
                    }
                }
            }
        }
        return channels
    }
}

// MARK: - Raw DDC operations (must only be called on the DDC queue)

extension DDCService {

    func readVCPNow(_ code: UInt8, displayID: CGDirectDisplayID) -> VCPValue? {
        lock.lock()
        let service = serviceCache[displayID]
        let populated = cachePopulated
        lock.unlock()

        guard service != nil || !populated else { return nil }
        if service == nil {
            refreshServiceCache()
            lock.lock()
            let resolved = serviceCache[displayID]
            lock.unlock()
            guard let resolved else { return nil }
            return readVCPOnChannel(code, service: resolved)
        }
        return readVCPOnChannel(code, service: service!)
    }

    func writeVCPNow(_ code: UInt8, value: UInt16, displayID: CGDirectDisplayID) -> Bool {
        lock.lock()
        let service = serviceCache[displayID]
        let populated = cachePopulated
        lock.unlock()

        guard service != nil || !populated else { return false }
        if service == nil {
            refreshServiceCache()
            lock.lock()
            let resolved = serviceCache[displayID]
            lock.unlock()
            guard let resolved else { return false }
            return writeVCPOnChannel(code, value: value, service: resolved)
        }
        return writeVCPOnChannel(code, value: value, service: service!)
    }

    private func readVCPOnChannel(_ code: UInt8, service: AnyObject) -> VCPValue? {
        var checksum = UInt8(0x6E ^ 0x51)
        let payload: [UInt8] = [0x82, 0x01, code]
        for byte in payload { checksum ^= byte }

        var request = payload
        request.append(checksum)
        guard IOAVServiceWriteI2C(service, address: Self.i2cAddress, dataAddress: Self.i2cDataAddress, data: &request) == KERN_SUCCESS else {
            return nil
        }

        // Per DDC/CI spec the monitor needs ~40 ms to prepare the reply.
        Thread.sleep(forTimeInterval: 0.04)

        var reply = [UInt8](repeating: 0, count: 12)
        guard IOAVServiceReadI2C(service, address: Self.i2cAddress, dataAddress: Self.i2cDataAddress, data: &reply) == KERN_SUCCESS else {
            return nil
        }

        // Validate the reply frame: many monitors ack the read but return garbage.
        guard reply[0] == 0x6E,       // source address
              reply[2] == 0x02,       // Get VCP Feature Reply opcode
              reply[3] == 0x00,       // result code
              reply[4] == code        // VCP code echo
        else { return nil }

        var expectedChecksum = UInt8(0x50)
        for index in 0...9 { expectedChecksum ^= reply[index] }
        guard expectedChecksum == reply[10] else { return nil }

        let maximum = (UInt16(reply[6]) << 8) | UInt16(reply[7])
        let current = (UInt16(reply[8]) << 8) | UInt16(reply[9])
        guard maximum > 0 else { return nil }
        return VCPValue(current: current, maximum: maximum)
    }

    private func writeVCPOnChannel(_ code: UInt8, value: UInt16, service: AnyObject) -> Bool {
        var checksum = UInt8(0x6E ^ 0x51)
        let payload: [UInt8] = [0x84, 0x03, code, UInt8(value >> 8), UInt8(value & 0xFF)]
        for byte in payload { checksum ^= byte }

        var packet = payload
        packet.append(checksum)
        return IOAVServiceWriteI2C(service, address: Self.i2cAddress, dataAddress: Self.i2cDataAddress, data: &packet) == KERN_SUCCESS
    }

    func drainPendingWrites() {
        while true {
            lock.lock()
            let next = pendingWrites.popFirst()
            lock.unlock()
            guard let item = next?.value else { break }

            _ = writeVCPNow(item.code, value: item.value, displayID: item.displayID)
            Thread.sleep(forTimeInterval: Self.minimumOperationDelay)
        }
        lock.lock()
        draining = false
        lock.unlock()
    }
}



// MARK: - Thread-safe helpers

extension DDCService {
    /// Synchronous read. Safe from any background thread (NOT the main thread):
    /// blocks on the DDC queue until the answer arrives.
    func readVCPNowSafe(_ code: UInt8, displayID: CGDirectDisplayID) -> VCPValue? {
        queue.sync { [weak self] in
            self?.readVCPNow(code, displayID: displayID)
        }
    }

    /// Synchronous write. Safe from any background thread (NOT the main thread).
    func writeVCPNowSafe(_ code: UInt8, value: UInt16, displayID: CGDirectDisplayID) -> Bool {
        queue.sync { [weak self] in
            self?.writeVCPNow(code, value: value, displayID: displayID) ?? false
        }
    }
}

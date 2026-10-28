import Foundation
import CoreGraphics
import CGVirtualDisplayKit

// MARK: - Presets

/// Aspect ratio preset for a virtual display. The mode list is generated as a
/// ladder from 720p up to 8K in the given aspect (same scheme BetterDummy uses).
struct VirtualDisplayPreset: Identifiable, Codable, Hashable {
    let id: Int
    let aspectWidth: Int
    let aspectHeight: Int
    let step: Int
    let description: String

    var name: String { "MDF Virtual \(description)" }

    private var minMultiplier: Int {
        max((720 + (aspectWidth * step - 1)) / (aspectWidth * step),
            (720 + (aspectHeight * step - 1)) / (aspectHeight * step))
    }

    private var maxMultiplier: Int {
        min(8192 / (aspectWidth * step), 8192 / (aspectHeight * step))
    }

    var modeSizes: [(width: Int, height: Int)] {
        guard maxMultiplier >= minMultiplier else { return [] }
        return (minMultiplier...maxMultiplier).map { multiplier in
            (aspectWidth * multiplier * step, aspectHeight * multiplier * step)
        }
    }

    var maxPixelsWide: UInt32 { UInt32(aspectWidth * maxMultiplier * step) }
    var maxPixelsHigh: UInt32 { UInt32(aspectHeight * maxMultiplier * step) }
}

enum VirtualDisplayPresets {
    /// Vendor ID used to mark our virtual displays (same marker BetterDummy used).
    static let vendorID: UInt32 = 0xF0F0
    /// Default refresh rate (BetterDummy's choice — always safe).
    static let defaultRefreshRate: Double = 60
    /// Refresh rates offered when creating a virtual display.
    static let availableRefreshRates: [Double] = [60, 75, 100, 120, 144, 165, 240]

    static let all: [VirtualDisplayPreset] = [
        VirtualDisplayPreset(id: 10, aspectWidth: 16, aspectHeight: 9, step: 2, description: "16:9"),
        VirtualDisplayPreset(id: 20, aspectWidth: 16, aspectHeight: 10, step: 2, description: "16:10"),
        VirtualDisplayPreset(id: 30, aspectWidth: 16, aspectHeight: 12, step: 2, description: "4:3"),
        VirtualDisplayPreset(id: 50, aspectWidth: 64, aspectHeight: 27, step: 2, description: "21:9"),
        VirtualDisplayPreset(id: 60, aspectWidth: 43, aspectHeight: 18, step: 2, description: "21.5:9"),
        VirtualDisplayPreset(id: 90, aspectWidth: 32, aspectHeight: 9, step: 2, description: "32:9"),
        VirtualDisplayPreset(id: 100, aspectWidth: 20, aspectHeight: 20, step: 2, description: "1:1"),
        VirtualDisplayPreset(id: 110, aspectWidth: 9, aspectHeight: 16, step: 2, description: "9:16 (портрет)"),
        VirtualDisplayPreset(id: 120, aspectWidth: 10, aspectHeight: 16, step: 2, description: "10:16 (портрет)"),
        VirtualDisplayPreset(id: 210, aspectWidth: 15, aspectHeight: 10, step: 2, description: "3:2"),
    ]

    static func preset(id: Int) -> VirtualDisplayPreset? {
        all.first { $0.id == id }
    }
}

// MARK: - Manager

/// Owns the CGVirtualDisplay instances. The virtual display stays online only
/// while the CGVirtualDisplay object is retained, so the manager keeps strong
/// references and persists the list in UserDefaults to survive relaunches.
final class VirtualDisplayManager {

    static let shared = VirtualDisplayManager()
    private init() {}

    struct Instance {
        let preset: VirtualDisplayPreset
        let serial: UInt32
        let refreshRate: Double
        fileprivate var handle: CGVirtualDisplay?

        var displayID: CGDirectDisplayID { handle?.displayID ?? 0 }
        var isConnected: Bool { handle != nil && displayID != 0 }
    }

    private(set) var instances: [Instance] = []
    private static let storageKey = "nbd.virtualDisplays"
    /// Debug flag: prints CGVirtualDisplay retain counts around removal.
    var debugRetainCounts = false

    // MARK: - Creation / removal

    /// Creates and connects a virtual display for the given preset.
    @discardableResult
    func create(preset: VirtualDisplayPreset,
                serial: UInt32 = UInt32.random(in: 1...UInt32.max),
                refreshRate: Double = VirtualDisplayPresets.defaultRefreshRate) -> Bool {
        guard let handle = Self.buildDisplay(preset: preset, serial: serial, refreshRate: refreshRate) else { return false }
        instances.append(Instance(preset: preset, serial: serial, refreshRate: refreshRate, handle: handle))
        persist()
        return true
    }

    /// Changes the refresh rate of a virtual display by recreating it with the
    /// SAME serial number. Because the identity (vendor/product/serial) is
    /// preserved, macOS automatically re-attaches any mirrors onto the new
    /// instance.
    @discardableResult
    func setRefreshRate(displayID: CGDirectDisplayID, rate: Double) -> Bool {
        guard let instance = instances.first(where: { $0.displayID == displayID }) else { return false }
        guard abs(instance.refreshRate - rate) > 0.01 else { return true }
        let preset = instance.preset
        let serial = instance.serial
        remove(displayID: displayID)
        return create(preset: preset, serial: serial, refreshRate: rate)
    }

    /// Disconnects the virtual display with the given CG display ID.
    /// Unmirrors anything mirroring it, force-disables it (the system keeps
    /// internal retains on CGVirtualDisplay after mirroring, so releasing
    /// the object alone is not always enough) and releases the handle.
    func remove(displayID: CGDirectDisplayID) {
        guard let index = instances.firstIndex(where: { $0.displayID == displayID }) else { return }

        // Unmirror any displays that mirror this virtual display.
        for display in DisplayManager.activeDisplays() where !display.isVirtual {
            if CGDisplayMirrorsDisplay(display.id) == displayID {
                _ = DisplayManager.unsetMirror(display: display.id)
            }
        }

        let handle = instances[index].handle
        if debugRetainCounts, let handle {
            print("[ddc-debug] retain count before release: \(CFGetRetainCount(handle))")
        }

        // Force-disable the display if it is still online.
        if handle != nil && displayID != 0 && CGDisplayIsOnline(displayID) == 1 {
            _ = DisplayManager.setDisplayEnabled(false, display: displayID)
        }

        instances[index].handle = nil
        if debugRetainCounts, let handle {
            print("[ddc-debug] retain count after release: \(CFGetRetainCount(handle))")
        }
        instances.remove(at: index)
        persist()
    }

    /// Disconnects everything.
    func removeAll() {
        for index in instances.indices {
            instances[index].handle = nil
        }
        instances.removeAll()
        persist()
    }

    func instance(displayID: CGDirectDisplayID) -> Instance? {
        instances.first { $0.displayID == displayID }
    }

    func isConnected(displayID: CGDirectDisplayID) -> Bool {
        instance(displayID: displayID)?.isConnected ?? false
    }

    // MARK: - CGVirtualDisplay construction

    private static func buildDisplay(preset: VirtualDisplayPreset, serial: UInt32, refreshRate: Double) -> CGVirtualDisplay? {
        guard let descriptor = CGVirtualDisplayDescriptor() else { return nil }

        descriptor.queue = DispatchQueue.global(qos: .userInteractive)
        descriptor.name = preset.name
        descriptor.maxPixelsWide = preset.maxPixelsWide
        descriptor.maxPixelsHigh = preset.maxPixelsHigh
        // Fixed at a 24" diagonal like BetterDummy did.
        let diagonal: Double = 24 * 25.4
        let ratio = diagonal / sqrt(Double(preset.aspectWidth * preset.aspectWidth + preset.aspectHeight * preset.aspectHeight))
        descriptor.sizeInMillimeters = CGSize(
            width: Double(preset.aspectWidth) * ratio,
            height: Double(preset.aspectHeight) * ratio
        )
        descriptor.serialNum = serial
        descriptor.productID = UInt32(min(preset.aspectWidth - 1, 255) * 256 + min(preset.aspectHeight - 1, 255))
        descriptor.vendorID = VirtualDisplayPresets.vendorID

        guard let display = CGVirtualDisplay(descriptor: descriptor) else { return nil }

        let modes: [CGVirtualDisplayMode] = preset.modeSizes.compactMap { size in
            CGVirtualDisplayMode(width: UInt(size.width), height: UInt(size.height), refreshRate: refreshRate)
        }
        guard !modes.isEmpty, let settings = CGVirtualDisplaySettings() else { return nil }
        settings.hiDPI = 1
        settings.modes = modes

        guard display.apply(settings) else { return nil }
        return display
    }

    // MARK: - Persistence

    private struct StoredEntry: Codable {
        let presetId: Int
        let serial: UInt32
        var refreshRate: Double?

        init(presetId: Int, serial: UInt32, refreshRate: Double) {
            self.presetId = presetId
            self.serial = serial
            self.refreshRate = refreshRate
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            presetId = try container.decode(Int.self, forKey: .presetId)
            serial = try container.decode(UInt32.self, forKey: .serial)
            // Backwards compatibility with entries saved before refresh rates existed.
            refreshRate = try container.decodeIfPresent(Double.self, forKey: .refreshRate)
        }
    }

    private func persist() {
        let entries = instances.map { StoredEntry(presetId: $0.preset.id, serial: $0.serial, refreshRate: $0.refreshRate) }
        UserDefaults.standard.set(try? JSONEncoder().encode(entries), forKey: Self.storageKey)
    }

    /// Recreates persisted virtual displays (called on app launch).
    func restorePersisted() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let entries = try? JSONDecoder().decode([StoredEntry].self, from: data) else {
            return
        }
        instances.removeAll()
        for entry in entries {
            guard let preset = VirtualDisplayPresets.preset(id: entry.presetId),
                  let handle = Self.buildDisplay(preset: preset, serial: entry.serial, refreshRate: entry.refreshRate ?? VirtualDisplayPresets.defaultRefreshRate) else { continue }
            instances.append(Instance(preset: preset, serial: entry.serial, refreshRate: entry.refreshRate ?? VirtualDisplayPresets.defaultRefreshRate, handle: handle))
        }
    }
}

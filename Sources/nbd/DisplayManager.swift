import Foundation
import CoreGraphics
import IOKit
import IOKit.graphics

// MARK: - Models

struct ModeInfo: Identifiable, Hashable {
    let width: Int
    let height: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let refreshRate: Double
    let isHiDPI: Bool
    /// IOKit mode ID — present for modes that can only be applied through the
    /// private CGS path (hidden framebuffer modes).
    var ioModeID: Int32? = nil
    /// True for modes that exist only in the private CGS framebuffer list and
    /// are invisible to the public CG API (they need the CGS apply path).
    var isCGSOnly: Bool = false

    init(width: Int, height: Int, pixelWidth: Int, pixelHeight: Int, refreshRate: Double, isHiDPI: Bool, ioModeID: Int32? = nil, isCGSOnly: Bool = false) {
        self.width = width
        self.height = height
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.refreshRate = refreshRate
        self.isHiDPI = isHiDPI
        self.ioModeID = ioModeID
        self.isCGSOnly = isCGSOnly
    }

    init(mode: CGDisplayMode) {
        self.init(
            width: mode.width,
            height: mode.height,
            pixelWidth: mode.pixelWidth,
            pixelHeight: mode.pixelHeight,
            refreshRate: mode.refreshRate,
            isHiDPI: mode.pixelWidth > mode.width,
            ioModeID: mode.ioDisplayModeID
        )
    }

    /// Hidden (CGS-only) mode: logical size + density flag + IOKit mode ID.
    init(hiddenWidth: Int, hiddenHeight: Int, refreshRate: Double, isHiDPI: Bool, ioModeID: Int32) {
        let pixelWidth = isHiDPI ? hiddenWidth * 2 : hiddenWidth
        let pixelHeight = isHiDPI ? hiddenHeight * 2 : hiddenHeight
        self.init(
            width: hiddenWidth,
            height: hiddenHeight,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            refreshRate: refreshRate,
            isHiDPI: isHiDPI,
            ioModeID: ioModeID,
            isCGSOnly: true
        )
    }

    /// True when this mode is not visible to the public CG API and needs
    /// the CGS path to be applied.
    var isHiddenCGS: Bool { isCGSOnly }

    var id: String { "\(width)x\(height)@\(Int(refreshRate.rounded()))\(isHiDPI ? "+hidpi" : "")" }

    var label: String {
        let hidpi = isHiDPI ? LF("mode.hidpi.render", " (HiDPI → рендер %d×%d)", pixelWidth, pixelHeight) : ""
        let hz = refreshRate > 0 ? LF("mode.hz", "%ld Гц", Int(refreshRate.rounded())) : L("mode.hz.none", "—")
        let hidden = isHiddenCGS ? " · " + L("mode.hidden", "скрытый") : ""
        return "\(width)×\(height)\(hidpi) · \(hz)\(hidden)"
    }
}

struct DisplayInfo: Identifiable {
    let id: CGDirectDisplayID
    var name: String
    var isBuiltIn: Bool
    var isMain: Bool
    var isMirrored: Bool
    var isVirtual: Bool
    var rotationDegrees: Int
    var origin: CGPoint
    var currentMode: ModeInfo?
    var modes: [ModeInfo]

    var summary: String {
        let mode = currentMode?.label ?? "—"
        return "\(mode) · " + LF("mode.summary.rotation", "поворот %d°", rotationDegrees)
    }
}

// MARK: - CGS (private CoreGraphics) declarations

/// Private CoreGraphics symbol (exported by CoreGraphics.tbd, used by
/// displayplacer for `enabled:false`). Disables/enables a display within a
/// reconfiguration transaction.
@_silgen_name("CGSConfigureDisplayEnabled")
private func CGSConfigureDisplayEnabled(_ config: CGDisplayConfigRef?, _ display: CGDirectDisplayID, _ enabled: Bool) -> CGError

/// Private CoreGraphics symbol (displayplacer uses it the same way).
/// Applies a display mode by its IOKit mode ID inside a
/// CGBegin/CGCompleteDisplayConfiguration transaction. Reaches GPU-scaled
/// HiDPI variants that the public CGConfigureDisplayWithDisplayMode cannot
/// see (e.g. 1920x1080 HiDPI @144Hz on external displays).
@_silgen_name("CGSConfigureDisplayMode")
func CGSConfigureDisplayMode(_ config: CGDisplayConfigRef?, _ display: CGDirectDisplayID, _ modeNum: Int32) -> CGError

/// Private CoreGraphics symbols used to enumerate ALL framebuffer modes of a
/// display (including ones hidden from CGDisplayCopyAllDisplayModes).
@_silgen_name("CGSGetNumberOfDisplayModes")
private func CGSGetNumberOfDisplayModes(_ display: CGDirectDisplayID, _ nModes: UnsafeMutablePointer<Int32>) -> CGError

/// The D4 layout (0xD4 bytes) of the private CGS display mode description:
///   mode@0x00 (uint32, IOKit mode ID)   flags@0x04   width@0x08   height@0x0C
///   depth@0x10   freq@0xBE (uint16)     density@0xD0 (float, 2.0 = HiDPI)
@_silgen_name("CGSGetDisplayModeDescriptionOfLength")
private func CGSGetDisplayModeDescriptionOfLength(_ display: CGDirectDisplayID, _ idx: Int32, _ mode: UnsafeMutableRawPointer, _ length: Int32) -> CGError

/// CGDisplayCreateUUIDFromDisplayID is public C API but not exposed to Swift
/// on newer SDKs — declare it manually.
@_silgen_name("CGDisplayCreateUUIDFromDisplayID")
private func _CGDisplayCreateUUIDFromDisplayID(_ display: CGDirectDisplayID) -> CFUUID?

// MARK: - DisplayManager

enum DisplayManager {

    /// Refresh rates match within 1 Hz (macOS reports 59.97 for 60, etc.).
    static func refreshMatches(_ a: Double, _ b: Double) -> Bool {
        if a == 0 || b == 0 { return true }
        return abs(a - b) < 1.0
    }

    /// Returns all currently online displays (includes mirror slaves that
    /// are excluded from CGGetActiveDisplayList).
    static func activeDisplays() -> [DisplayInfo] {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        guard count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        let err = CGGetOnlineDisplayList(count, &ids, &count)
        guard err == .success else { return [] }
        return ids.prefix(Int(count)).map(info(for:))
    }

    static func info(for id: CGDirectDisplayID) -> DisplayInfo {
        let bounds = CGDisplayBounds(id)
        let currentMode = CGDisplayCopyDisplayMode(id).map(ModeInfo.init(mode:))
        return DisplayInfo(
            id: id,
            name: displayName(for: id),
            isBuiltIn: CGDisplayIsBuiltin(id) == 1,
            isMain: CGDisplayIsMain(id) == 1,
            isMirrored: CGDisplayMirrorsDisplay(id) != 0,
            isVirtual: CGDisplayVendorNumber(id) == VirtualDisplayPresets.vendorID,
            rotationDegrees: Int(CGDisplayRotation(id)),
            origin: bounds.origin,
            currentMode: currentMode,
            modes: modes(for: id)
        )
    }

    /// Human readable display name. Primary source is the private CoreDisplay
    /// framework (works everywhere, incl. macOS 26+ where CGDisplayIOServicePort
    /// is broken), with the IOKit dictionary as a fallback.
    static func displayName(for id: CGDirectDisplayID) -> String {
        if let dict = CoreDisplay_DisplayCreateInfoDictionary(id) as? [String: Any] {
            if let names = dict["DisplayProductName"] as? [String: String],
               let name = names["en_US"] ?? names.first?.value,
               !name.isEmpty {
                return name
            }
        }
        let service = CGDisplayIOServicePort(id)
        if service != IO_OBJECT_NULL,
           let unmanaged = IODisplayCreateInfoDictionary(service, 0),
           let dict = unmanaged.takeRetainedValue() as? [String: Any] {
            if let names = dict["DisplayProductName"] as? [String: String],
               let name = names["en_US"] ?? names.first?.value,
               !name.isEmpty {
                return name
            }
        }
        return CGDisplayIsBuiltin(id) == 1 ? L("display.builtin.fallback", "Встроенный дисплей") : LF("display.fallback", "Дисплей %ld", Int(id))
    }

    /// All usable display modes: the public CG list (including HiDPI variants
    /// hidden by default) plus the CGS-only framebuffer modes (marked
    /// "скрытый") that need the private CGS path to be applied.
    static func modes(for id: CGDirectDisplayID) -> [ModeInfo] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let list = CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode] else { return [] }
        var seen = Set<String>()
        var result: [ModeInfo] = []
        for mode in list {
            guard mode.isUsableForDesktopGUI() else { continue }
            let info = ModeInfo(mode: mode)
            if seen.insert(info.id).inserted {
                result.append(info)
            }
        }
        // Append CGS-only modes that the CG list doesn't already cover.
        for hidden in cgsOnlyModes(for: id, excluding: Set(result.map(\.id))) {
            if seen.insert(hidden.id).inserted {
                result.append(hidden)
            }
        }
        result.sort { a, b in
            if a.width != b.width { return a.width > b.width }
            if a.height != b.height { return a.height > b.height }
            if a.isHiDPI != b.isHiDPI { return a.isHiDPI }
            return a.refreshRate > b.refreshRate
        }
        return result
    }

    /// Raw CGS mode description (diagnostics).
    struct CGSRawMode {
        let ioModeID: Int32
        let flags: UInt32
        let width: Int
        let height: Int
        let depth: Int
        let freqAtBC: Int
        let freqAtBC0: Int
        let freqAtBCu: Int
        let freqAtBE: Int
        let density: Double
    }

    /// Raw count for the CGS framebuffer mode list (diagnostics).
    static func cgsRawModeCount(_ displayID: CGDirectDisplayID, _ nModes: inout Int32) -> CGError {
        CGSGetNumberOfDisplayModes(displayID, &nModes)
    }

    /// Reads a raw CGS mode description at several candidate offsets (diagnostics).
    static func cgsRawMode(_ displayID: CGDirectDisplayID, index: Int32) -> CGSRawMode? {
        let description = UnsafeMutableRawPointer.allocate(byteCount: 0xD4, alignment: MemoryLayout<UInt32>.alignment)
        defer { description.deallocate() }
        memset(description, 0, 0xD4)
        guard CGSGetDisplayModeDescriptionOfLength(displayID, index, description, 0xD4) == .success else { return nil }
        return CGSRawMode(
            ioModeID: Int32(bitPattern: description.load(fromByteOffset: 0x00, as: UInt32.self)),
            flags: description.load(fromByteOffset: 0x04, as: UInt32.self),
            width: Int(description.load(fromByteOffset: 0x08, as: UInt32.self)),
            height: Int(description.load(fromByteOffset: 0x0C, as: UInt32.self)),
            depth: Int(description.load(fromByteOffset: 0x10, as: UInt32.self)),
            freqAtBC: Int(description.load(fromByteOffset: 0xBC, as: UInt16.self)),
            freqAtBC0: Int(description.load(fromByteOffset: 0xB8, as: UInt16.self)),
            freqAtBCu: Int(description.load(fromByteOffset: 0xBC, as: UInt32.self)),
            freqAtBE: Int(description.load(fromByteOffset: 0xBE, as: UInt16.self)),
            density: Double(description.load(fromByteOffset: 0xD0, as: Float.self))
        )
    }

    /// Enumerates the full framebuffer mode list through the private CGS API
    /// and returns only the entries that have no public CG counterpart.
    static func cgsOnlyModes(for id: CGDirectDisplayID, excluding publicIDs: Set<String>) -> [ModeInfo] {
        var nModes: Int32 = 0
        guard CGSGetNumberOfDisplayModes(id, &nModes) == .success, nModes > 0 else { return [] }

        // modes_D4 description is 0xD4 bytes (see displayplacer's Header.h).
        let description = UnsafeMutableRawPointer.allocate(byteCount: 0xD4, alignment: MemoryLayout<UInt32>.alignment)
        defer { description.deallocate() }

        var result: [ModeInfo] = []
        for index in 0..<nModes {
            memset(description, 0, 0xD4)
            guard CGSGetDisplayModeDescriptionOfLength(id, index, description, 0xD4) == .success else { continue }

            let ioModeID = Int32(bitPattern: description.load(fromByteOffset: 0x00, as: UInt32.self))
            let width = Int(description.load(fromByteOffset: 0x08, as: UInt32.self))
            let height = Int(description.load(fromByteOffset: 0x0C, as: UInt32.self))
            let depth = Int(description.load(fromByteOffset: 0x10, as: UInt32.self))
            // freq (uint16) sits right after the 42-byte padding area; displayplacer
            // reads it as derived.freq.
            let freq = Double(description.load(fromByteOffset: 0xBE, as: UInt16.self))
            let density = Double(description.load(fromByteOffset: 0xD0, as: Float.self))

            // Note: the D4 "depth" field is not bits-per-pixel (it reads 8 for
            // regular 32bpp modes), so no depth filtering is applied here.
            guard width > 0, height > 0, freq > 0, ioModeID != 0 else { continue }
            let isHiDPI = abs(density - 2.0) < 0.01

            let info = ModeInfo(hiddenWidth: width, hiddenHeight: height, refreshRate: freq, isHiDPI: isHiDPI, ioModeID: ioModeID)
            // Skip entries the public list already offers.
            let publicKey = "\(width)x\(height)@\(Int(freq.rounded()))\(isHiDPI ? "+hidpi" : "")"
            guard !publicIDs.contains(publicKey) else { continue }
            result.append(info)
        }
        return result
    }

    /// Applies a mode matching the given attributes. CG-visible modes go
    /// through the public CG API; CGS-only ("скрытый") modes are applied by
    /// their IOKit mode ID via the private CGSConfigureDisplayMode path.
    /// Mirrors of other displays can't take mode changes directly, so the
    /// change is routed to the mirror master when necessary.
    @discardableResult
    static func apply(_ mode: ModeInfo, to displayID: CGDirectDisplayID, save: Bool = true) -> Bool {
        var targetID = displayID
        let mirrorMaster = CGDisplayMirrorsDisplay(displayID)
        if mirrorMaster != 0 && mirrorMaster != displayID {
            targetID = mirrorMaster
        }

        let ok: Bool
        if mode.isCGSOnly, let ioModeID = mode.ioModeID {
            ok = applyByIOModeID(ioModeID, to: targetID)
        } else {
            ok = applyPublic(mode, to: targetID)
        }
        if ok && save {
            saveAppliedMode(mode, for: displayID)
        }
        return ok
    }

    /// Public CG API path: match attributes against the current mode list.
    private static func applyPublic(_ mode: ModeInfo, to targetID: CGDirectDisplayID) -> Bool {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let list = CGDisplayCopyAllDisplayModes(targetID, options) as? [CGDisplayMode] else { return false }

        let candidates = list.filter {
            $0.width == mode.width && $0.height == mode.height && $0.isUsableForDesktopGUI()
        }
        let chosen = candidates.first(where: {
            ($0.pixelWidth > $0.width) == mode.isHiDPI && refreshMatches($0.refreshRate, mode.refreshRate)
        }) ?? candidates.first(where: {
            ($0.pixelWidth > $0.width) == mode.isHiDPI
        }) ?? candidates.first

        guard let chosen else { return false }

        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let cfg = config else { return false }
        let result = CGConfigureDisplayWithDisplayMode(cfg, targetID, chosen, nil)
        guard result == .success else {
            CGCancelDisplayConfiguration(cfg)
            return false
        }
        return CGCompleteDisplayConfiguration(cfg, .permanently) == .success
    }

    /// Private CGS path: apply a framebuffer mode by its IOKit mode ID.
    /// Must run inside a real CGBegin/CGComplete transaction (the first
    /// argument is the config token, not a connection id).
    @discardableResult
    static func applyByIOModeID(_ ioModeID: Int32, to displayID: CGDirectDisplayID) -> Bool {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let cfg = config else { return false }
        let result = CGSConfigureDisplayMode(cfg, displayID, ioModeID)
        guard result == .success else {
            CGCancelDisplayConfiguration(cfg)
            return false
        }
        return CGCompleteDisplayConfiguration(cfg, .permanently) == .success
    }

    /// Makes `display` show the content of `master` (mirror).
    /// Used to mirror a real monitor onto a virtual display so the virtual
    /// display's mode list wins — this is the classic BetterDummy trick
    /// for correct HiDPI/scaling on non-Apple displays.
    @discardableResult
    static func setMirror(display: CGDirectDisplayID, master: CGDirectDisplayID) -> Bool {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let cfg = config else { return false }
        guard CGConfigureDisplayMirrorOfDisplay(cfg, display, master) == .success else {
            CGCancelDisplayConfiguration(cfg)
            return false
        }
        return CGCompleteDisplayConfiguration(cfg, .permanently) == .success
    }

    /// Removes `display` from a mirror set.
    @discardableResult
    static func unsetMirror(display: CGDirectDisplayID) -> Bool {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let cfg = config else { return false }
        guard CGConfigureDisplayMirrorOfDisplay(cfg, display, kCGNullDirectDisplay) == .success else {
            CGCancelDisplayConfiguration(cfg)
            return false
        }
        return CGCompleteDisplayConfiguration(cfg, .permanently) == .success
    }

    /// Force-disables (black-screens and deactivates) a display. Used to remove
    /// virtual displays: after mirroring the system holds internal retains on
    /// the CGVirtualDisplay object, so releasing it alone doesn't disconnect
    /// the display. This is the same mechanism displayplacer uses for
    /// `enabled:false`.
    @discardableResult
    static func setDisplayEnabled(_ enabled: Bool, display: CGDirectDisplayID) -> Bool {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let cfg = config else { return false }
        let result = CGSConfigureDisplayEnabled(cfg, display, enabled)
        guard result == .success else {
            CGCancelDisplayConfiguration(cfg)
            return false
        }
        return CGCompleteDisplayConfiguration(cfg, .permanently) == .success
    }

    // MARK: - Saved mode persistence (per display UUID, by ATTRIBUTES)
    //
    // macOS reassigns raw IOKit mode IDs whenever the mode list is rebuilt
    // (reconnect, sleep/wake, HiDPI override changes), so the saved mode is
    // stored as attributes and matched against the *current* mode list when
    // restoring. Same strategy as Crisp's ResolutionService.

    struct SavedMode: Codable {
        let width: Int
        let height: Int
        let refresh: Double
        let hidpi: Bool
    }

    private static let savedModesKey = "nbd.savedModes"

    /// Stable per-display key (survives reconnects and display ID changes).
    static func displayUUIDKey(_ displayID: CGDirectDisplayID) -> String {
        guard let uuid = _CGDisplayCreateUUIDFromDisplayID(displayID),
              let string = CFUUIDCreateString(kCFAllocatorDefault, uuid) as String? else {
            return "id-\(displayID)"
        }
        return string
    }

    /// Remembers the last user-selected mode for the display.
    static func saveAppliedMode(_ mode: ModeInfo, for displayID: CGDirectDisplayID) {
        let key = displayUUIDKey(displayID)
        var saved = savedModes
        saved[key] = SavedMode(width: mode.width, height: mode.height, refresh: mode.refreshRate, hidpi: mode.isHiDPI)
        if let data = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(data, forKey: savedModesKey)
        }
    }

    private static var savedModes: [String: SavedMode] {
        guard let data = UserDefaults.standard.data(forKey: savedModesKey),
              let decoded = try? JSONDecoder().decode([String: SavedMode].self, from: data) else {
            return [:]
        }
        return decoded
    }

    /// Re-applies the remembered mode for the display if the currently active
    /// mode drifted from it (e.g. macOS reset it on sleep/wake or reconnect).
    /// Only applies when an exact match exists in the current valid mode list.
    @discardableResult
    static func restoreSavedModeIfNeeded(for displayID: CGDirectDisplayID) -> Bool {
        guard let saved = savedModes[displayUUIDKey(displayID)] else { return false }
        if let current = CGDisplayCopyDisplayMode(displayID),
           current.width == saved.width, current.height == saved.height,
           (current.pixelWidth > current.width) == saved.hidpi,
           refreshMatches(current.refreshRate, saved.refresh) {
            return false // already at the saved mode
        }
        guard let match = modes(for: displayID).first(where: {
            $0.width == saved.width && $0.height == saved.height &&
            $0.isHiDPI == saved.hidpi && refreshMatches($0.refreshRate, saved.refresh)
        }) else { return false }
        return apply(match, to: displayID)
    }
}

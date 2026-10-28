import Foundation
import CoreGraphics
import AppKit

/// UI-facing control state for a single display.
struct DisplayControls {
    var brightnessAvailable: Bool = false
    var brightnessPct: Double = 0
    var contrastAvailable: Bool = false
    var contrastPct: Double = 0
    /// DDC maximum (VCP scale), used to convert percent to a raw value.
    var brightnessMax: UInt16 = 100
    var contrastMax: UInt16 = 100
}

@MainActor
final class DisplayStore: ObservableObject {

    static let shared = DisplayStore()

    @Published private(set) var displays: [DisplayInfo] = []
    @Published private(set) var controls: [CGDirectDisplayID: DisplayControls] = [:]
    @Published private(set) var rotating: Set<CGDirectDisplayID> = []
    @Published var lastMessage: String?

    private var refreshGeneration = 0
    private static var callbackRegistered = false
    private let callbackLock = NSLock()
    private var scheduledRefresh: DispatchWorkItem?

    private init() {
        VirtualDisplayManager.shared.restorePersisted()
        refresh()
        registerReconfigurationCallback()
        registerWakeNotification()
    }

    // MARK: - Refresh

    func refresh() {
        refreshGeneration += 1
        let generation = refreshGeneration

        let newDisplays = DisplayManager.activeDisplays()
        let oldIDs = Set(displays.map(\.id))
        let newIDs = Set(newDisplays.map(\.id))
        displays = newDisplays

        if oldIDs != newIDs {
            DDCService.shared.invalidate()
            controls.removeAll()
        }

        // Re-apply remembered modes if macOS reset them (sleep/wake, reconnect).
        for display in newDisplays {
            _ = DisplayManager.restoreSavedModeIfNeeded(for: display.id)
        }

        for display in newDisplays {
            probeControls(for: display, generation: generation)
        }
    }

    private func probeControls(for display: DisplayInfo, generation: Int) {
        if display.isVirtual { return } // no DDC/brightness on virtual displays
        if display.isBuiltIn {
            guard controls[display.id] == nil else { return }
            var state = DisplayControls()
            if let value = InternalDisplay.getBrightness(displayID: display.id) {
                state.brightnessAvailable = true
                state.brightnessPct = Double(value) * 100
            }
            controls[display.id] = state
            return
        }

        let displayID = display.id
        Task.detached(priority: .utility) { [weak self] in
            guard DDCService.shared.service(for: displayID) != nil else {
                await self?.finishProbe(displayID, brightness: nil, contrast: nil, generation: generation)
                return
            }
            let brightness = DDCService.shared.readVCPNowSafe(DDCService.brightnessCode, displayID: displayID)
            let contrast = DDCService.shared.readVCPNowSafe(DDCService.contrastCode, displayID: displayID)
            await self?.finishProbe(displayID, brightness: brightness, contrast: contrast, generation: generation)
        }
    }

    private func finishProbe(
        _ displayID: CGDirectDisplayID,
        brightness: VCPValue?,
        contrast: VCPValue?,
        generation: Int
    ) {
        guard generation == refreshGeneration else { return }
        var state = controls[displayID] ?? DisplayControls()
        if brightness != nil || contrast != nil {
            state.brightnessAvailable = true
        }
        if let brightness {
            state.brightnessPct = brightness.pct
            state.brightnessMax = max(brightness.maximum, 1)
        }
        if let contrast {
            state.contrastAvailable = true
            state.contrastPct = contrast.pct
            state.contrastMax = max(contrast.maximum, 1)
        }
        controls[displayID] = state
    }
}


extension DisplayStore {

    // MARK: - User actions

    func setBrightness(pct: Double, for display: DisplayInfo) {
        let clamped = min(max(pct, 0), 100)
        if var state = controls[display.id] {
            state.brightnessPct = clamped
            controls[display.id] = state
        }
        if display.isBuiltIn {
            InternalDisplay.setBrightness(Float(clamped / 100.0), displayID: display.id)
        } else {
            let raw = UInt16((clamped / 100.0 * Double((controls[display.id]?.brightnessMax ?? 100))).rounded())
            DDCService.shared.writeVCP(DDCService.brightnessCode, value: raw, displayID: display.id)
        }
    }

    func setContrast(pct: Double, for display: DisplayInfo) {
        guard !display.isBuiltIn else { return }
        let clamped = min(max(pct, 0), 100)
        if var state = controls[display.id] {
            state.contrastPct = clamped
            controls[display.id] = state
        }
        let raw = UInt16((clamped / 100.0 * Double((controls[display.id]?.contrastMax ?? 100))).rounded())
        DDCService.shared.writeVCP(DDCService.contrastCode, value: raw, displayID: display.id)
    }

    func applyMode(_ mode: ModeInfo, to display: DisplayInfo) {
        let ok = DisplayManager.apply(mode, to: display.id)
        if !ok { lastMessage = LF("store.mode.failed", "Не удалось применить режим %@", mode.label) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.refresh()
        }
    }

    func rotate(to degrees: Int, display: DisplayInfo) {
        guard !rotating.contains(display.id) else { return }
        guard Int(CGDisplayRotation(display.id)) != degrees else { return }
        rotating.insert(display.id)
        let displayID = display.id
        let displayName = display.name
        RotationService.setRotation(degrees, for: displayID) { [weak self] success in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.rotating.remove(displayID)
                if !success { self.lastMessage = LF("store.rotate.failed", "Не удалось повернуть «%@»", displayName) }
                self.refresh()
            }
        }
    }

    // MARK: - Virtual displays

    var virtualDisplays: [DisplayInfo] {
        displays.filter(\.isVirtual)
    }

    var realDisplays: [DisplayInfo] {
        displays.filter { !$0.isVirtual }
    }

    func createVirtualDisplay(preset: VirtualDisplayPreset, refreshRate: Double = VirtualDisplayPresets.defaultRefreshRate) {
        guard VirtualDisplayManager.shared.create(preset: preset, refreshRate: refreshRate) else {
            lastMessage = LF("store.virtual.createfailed", "Не удалось создать виртуальный дисплей «%@»", preset.label)
            return
        }
        scheduleRefresh()
    }

    /// Recreates a virtual display at a different refresh rate (same serial,
    /// so mirrors re-attach automatically).
    func setVirtualRefreshRate(displayID: CGDirectDisplayID, rate: Double) {
        guard VirtualDisplayManager.shared.setRefreshRate(displayID: displayID, rate: rate) else {
            lastMessage = L("store.virtual.ratefailed", "Не удалось сменить частоту виртуального дисплея")
            return
        }
        scheduleRefresh()
    }

    /// The stored refresh rate of a virtual display instance (for the UI picker).
    func virtualRefreshRate(displayID: CGDirectDisplayID) -> Double {
        VirtualDisplayManager.shared.instance(displayID: displayID)?.refreshRate
            ?? VirtualDisplayPresets.defaultRefreshRate
    }

    func removeVirtualDisplay(displayID: CGDirectDisplayID) {
        VirtualDisplayManager.shared.remove(displayID: displayID)
        scheduleRefresh()
    }

    /// Sets or removes mirroring of a real display onto a virtual display.
    func setMirror(of display: DisplayInfo, toVirtual masterID: CGDirectDisplayID?) {
        let ok: Bool
        if let masterID {
            ok = DisplayManager.setMirror(display: display.id, master: masterID)
        } else {
            ok = DisplayManager.unsetMirror(display: display.id)
        }
        if !ok {
            lastMessage = LF("store.mirror.failed", "Не удалось изменить зеркалирование «%@»", display.name)
        }
        scheduleRefresh()
    }

    /// The virtual display this real display is currently mirroring (if any).
    func mirroredVirtualMaster(of displayID: CGDirectDisplayID) -> CGDirectDisplayID? {
        let master = CGDisplayMirrorsDisplay(displayID)
        guard master != 0, displays.first(where: { $0.id == master })?.isVirtual == true else { return nil }
        return master
    }

    // MARK: - Display reconfiguration notifications

    private func registerReconfigurationCallback() {
        callbackLock.lock()
        let alreadyRegistered = DisplayStore.callbackRegistered
        DisplayStore.callbackRegistered = true
        callbackLock.unlock()
        guard !alreadyRegistered else { return }

        CGDisplayRegisterReconfigurationCallback({ _, flags, _ in
            guard flags.contains(.addFlag)
                || flags.contains(.removeFlag)
                || flags.contains(.enabledFlag)
                || flags.contains(.disabledFlag)
                || flags.contains(.setModeFlag)
            else { return }
            DispatchQueue.main.async {
                DisplayStore.shared.scheduleRefresh()
            }
        }, nil)
    }

    /// Debounced refresh — the reconfiguration callback fires many times per change.
    func scheduleRefresh() {
        scheduledRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        scheduledRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    // MARK: - Sleep / wake

    private func registerWakeNotification() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // macOS often resets non-standard modes on wake; re-apply saved ones.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self?.refresh()
            }
        }
    }
}

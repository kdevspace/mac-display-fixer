import Foundation
import CoreGraphics

/// Command line interface (also used for smoke tests):
///   nbd --list
///   nbd --probe
///   nbd --brightness <displayID> <0-100>
///   nbd --contrast  <displayID> <0-100>
///   nbd --mode <displayID> <width> <height> [hz] [hidpi|nohidpi]
///   nbd --rotate <displayID> <0|90|180|270>
enum CLI {

    static func run(args: [String]) {
        guard args.count > 1 else {
            usage()
            exit(0)
        }
        switch args[1] {
        case "--list":
            list()
        case "--probe":
            probe()
        case "--brightness", "--contrast":
            setVCP(args)
        case "--mode":
            setMode(args)
        case "--rotate":
            rotate(args)
        case "--restore":
            // Restores the saved mode for a display (test of persistence).
            guard args.count > 2, let displayID = CGDirectDisplayID(args[2]) else {
                usage()
                exit(1)
            }
            let applied = DisplayManager.restoreSavedModeIfNeeded(for: displayID)
            print(applied ? "Сохранённый режим восстановлен" : "Восстановление не потребовалось/не удалось")
            exit(applied ? 0 : 1)
        case "--mirror":
            // nbd --mirror <displayID> <masterID>
            guard args.count > 4,
                  let displayID = CGDirectDisplayID(args[2]),
                  let masterID = CGDirectDisplayID(args[3]) else {
                usage()
                exit(1)
            }
            let ok = DisplayManager.setMirror(display: displayID, master: masterID)
            print(ok ? "OK: \(displayID) зеркалирует \(masterID)" : "Ошибка")
            exit(ok ? 0 : 1)
        case "--unmirror":
            guard args.count > 2, let displayID = CGDirectDisplayID(args[2]) else {
                usage()
                exit(1)
            }
            let ok = DisplayManager.unsetMirror(display: displayID)
            print(ok ? "OK: \(displayID) исключён из зеркала" : "Ошибка")
            exit(ok ? 0 : 1)
        case "--vtest":
            virtualTest()
        case "--vtest4":
            virtualTestRefreshRate()
        case "--cgs":
            // Diagnostic: raw dump of the private CGS framebuffer mode list.
            cgsDump(args)
        case "--vtest2":
            virtualTestMinimal(mirror: false)
        case "--vtest3":
            virtualTestMinimal(mirror: true)
        case "--vpersist-create":
            // Creates a virtual display, persists it to UserDefaults (domain of
            // the app bundle) and exits. The display itself dies with the
            // process; the app recreates it from prefs on next launch.
            // Used to verify the restore-on-launch path.
            guard args.count > 2, let presetId = Int(args[2]),
                  let preset = VirtualDisplayPresets.preset(id: presetId) else {
                usage()
                exit(1)
            }
            guard VirtualDisplayManager.shared.create(preset: preset) else {
                print("Не удалось создать виртуальный дисплей")
                exit(1)
            }
            print("Создан и сохранён в UserDefaults: \(preset.name)")
            exit(0)
        default:
            usage()
        }
        exit(0)
    }

    private static func usage() {
        print("""
        Mac Display Fixer — управление дисплеями macOS (аналог BetterDisplay)

        Использование (CLI-часть приложения):
          nbd --list                              показать дисплеи и режимы
          nbd --cgs <id>                          сырой дамп CGS-списка режимов
          nbd --probe                             проверить DDC (яркость/контраст)
          nbd --brightness <id> <0-100>           установить яркость
          nbd --contrast  <id> <0-100>            установить контраст
          nbd --mode <id> <W> <H> [hz] [hidpi] [--raw]   сменить разрешение
          nbd --restore <id>                      восстановить сохранённый режим
          nbd --rotate <id> <0|90|180|270>        повернуть экран
          nbd --mirror <id> <masterID>            зеркалировать дисплей
          nbd --unmirror <id>                     снять зеркалирование
          nbd --vtest                             тест виртуальных дисплеев

        Без аргументов запускается меню-бар приложение.
        """)
    }

    private static func list() {
        for display in DisplayManager.activeDisplays() {
            print("=== \(display.name) (ID \(display.id))")
            print("    встроенный: \(display.isBuiltIn), основной: \(display.isMain), поворот: \(display.rotationDegrees)°")
            print("    текущий: \(display.currentMode?.label ?? "—")")
            print("    режимы:")
            for mode in display.modes {
                print("      \(mode.label)\(mode.id == display.currentMode?.id ? "   <-- активный" : "")")
            }
        }
    }

    private static func probe() {
        for display in DisplayManager.activeDisplays() {
            print("=== \(display.name) (ID \(display.id)) — встроенный: \(display.isBuiltIn)")
            if display.isBuiltIn {
                if let b = InternalDisplay.getBrightness(displayID: display.id) {
                    print("    яркость (DisplayServices): \(Int(b * 100))%")
                } else {
                    print("    яркость: недоступна")
                }
                continue
            }
            if DDCService.shared.service(for: display.id) == nil {
                print("    DDC: канал не найден")
                continue
            }
            let brightness = DDCService.shared.readVCPNowSafe(DDCService.brightnessCode, displayID: display.id)
            let contrast = DDCService.shared.readVCPNowSafe(DDCService.contrastCode, displayID: display.id)
            if let b = brightness {
                print("    DDC яркость: \(b.current)/\(b.maximum)")
            } else {
                print("    DDC яркость: нет ответа (запись может работать)")
            }
            if let c = contrast {
                print("    DDC контраст: \(c.current)/\(c.maximum)")
            } else {
                print("    DDC контраст: нет ответа")
            }
        }
    }
}

extension CLI {

    /// End-to-end test of virtual displays: create, verify in the CG display
    /// list, check modes, briefly mirror+unmirror a real display, remove.
    /// Everything is restored at the end.
    /// Matrix test: create -> (optionally mirror) -> remove.
    /// Args: virtualTestMinimal(mirror: true/false)
    private static func virtualTestMinimal(mirror: Bool = false) {
        guard let preset = VirtualDisplayPresets.preset(id: 10) else { exit(1) }
        print("create:", VirtualDisplayManager.shared.create(preset: preset))
        Thread.sleep(forTimeInterval: 1.0)
        guard let id = DisplayManager.activeDisplays().first(where: \.isVirtual)?.id else {
            print("dummy не появился")
            exit(1)
        }
        print("dummy id:", id, "main:", CGDisplayIsMain(id) == 1, "online:", CGDisplayIsOnline(id) == 1)
        VirtualDisplayManager.shared.debugRetainCounts = true
        if mirror {
            let real = DisplayManager.activeDisplays().first { !$0.isVirtual }
            print("mirroring \(real?.name ?? "?") onto dummy…")
            print("setMirror:", DisplayManager.setMirror(display: real!.id, master: id))
            Thread.sleep(forTimeInterval: 1.0)
            print("dummy main after mirror:", CGDisplayIsMain(id) == 1)
        }
        VirtualDisplayManager.shared.remove(displayID: id)
        print("instances after remove:", VirtualDisplayManager.shared.instances.count)
        for i in 1...12 {
            Thread.sleep(forTimeInterval: 0.5)
            let stillActive = DisplayManager.activeDisplays().contains { $0.isVirtual && $0.id == id }
            print("t+\(Double(i) * 0.5)s active:", stillActive)
            if !stillActive { break }
        }
        exit(0)
    }

    /// Virtual display refresh-rate test: creates a 144 Hz dummy, mirrors an
    /// external (not currently mirrored) real display onto it and checks that
    /// 144 Hz modes become available to the mirror set. Restores everything.
    private static func virtualTestRefreshRate() {
        print("1) Создание виртуального дисплея 16:9 @ 144 Гц…")
        guard let preset = VirtualDisplayPresets.preset(id: 10),
              VirtualDisplayManager.shared.create(preset: preset, refreshRate: 144) else {
            print("   ОШИБКА: не создался")
            exit(1)
        }
        var dummyID: CGDirectDisplayID = 0
        for _ in 0..<50 {
            if let found = DisplayManager.activeDisplays().first(where: \.isVirtual) { dummyID = found.id; break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard dummyID != 0 else {
            print("   ОШИБКА: не появился")
            exit(1)
        }
        let dummyModes = DisplayManager.modes(for: dummyID)
        let rates = Set(dummyModes.map { Int($0.refreshRate.rounded()) }).sorted()
        print("   Частоты в списке виртуалки: \(rates)")
        let has144 = dummyModes.contains { Int($0.refreshRate.rounded()) == 144 }
        print("   OK: displayID=\(dummyID), режимов: \(dummyModes.count), 144 Гц среди них: \(has144)")
        guard has144 else {
            // Diagnostic: dump raw CGS entries of the dummy before removing it.
            var rawCount: Int32 = 0
            if DisplayManager.cgsRawModeCount(dummyID, &rawCount) == .success {
                print("   CGS-дамп виртуалки (первые 6):")
                for index in 0..<min(rawCount, 6) {
                    if let raw = DisplayManager.cgsRawMode(dummyID, index: index) {
                        print(String(format: "      id=%d %dx%d freq@BE=%d density=%.2f", raw.ioModeID, raw.width, raw.height, raw.freqAtBE, raw.density))
                    }
                }
            }
            VirtualDisplayManager.shared.remove(displayID: dummyID)
            exit(1)
        }

        print("2) Зеркалирование свободного внешнего дисплея на виртуалку…")
        guard let real = DisplayManager.activeDisplays().first(where: { !$0.isVirtual && !$0.isBuiltIn && !$0.isMirrored }) else {
            print("   Пропущено: нет свободного внешнего дисплея")
            VirtualDisplayManager.shared.remove(displayID: dummyID)
            exit(0)
        }
        guard DisplayManager.setMirror(display: real.id, master: dummyID) else {
            print("   ОШИБКА: зеркалирование не сработало")
            VirtualDisplayManager.shared.remove(displayID: dummyID)
            exit(1)
        }
        Thread.sleep(forTimeInterval: 1.5)
        let realModes = DisplayManager.modes(for: real.id)
        let rate144 = realModes.filter { Int($0.refreshRate.rounded()) == 144 }
        print("   Дисплей «\(real.name)»: режимов 144 Гц в наборе зеркала: \(rate144.count)")
        for mode in rate144.prefix(5) { print("      \(mode.label)") }

        print("3) Отмена зеркалирования и удаление виртуалки…")
        _ = DisplayManager.unsetMirror(display: real.id)
        VirtualDisplayManager.shared.remove(displayID: dummyID)
        Thread.sleep(forTimeInterval: 1.0)
        let cleaned = DisplayManager.activeDisplays().first { $0.isVirtual && $0.id == dummyID } == nil
        print(cleaned ? "   OK: всё убрано" : "   ОШИБКА: виртуалка осталась")
        exit(rate144.isEmpty ? 1 : 0)
    }

    private static func virtualTest() {
        guard let preset = VirtualDisplayPresets.preset(id: 10) else { exit(1) }
        print("1) Создание виртуального дисплея \(preset.name)…")
        guard VirtualDisplayManager.shared.create(preset: preset) else {
            print("   ОШИБКА: CGVirtualDisplay не создался")
            exit(1)
        }
        // Wait for the display to appear in the active list.
        var dummyID: CGDirectDisplayID = 0
        for _ in 0..<50 {
            let displays = DisplayManager.activeDisplays().filter(\.isVirtual)
            if let found = displays.first {
                dummyID = found.id
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard dummyID != 0 else {
            print("   ОШИБКА: виртуальный дисплей не появился в CGGetActiveDisplayList")
            VirtualDisplayManager.shared.removeAll()
            exit(1)
        }
        let dummy = DisplayManager.info(for: dummyID)
        print("   OK: displayID=\(dummyID), имя=\"\(dummy.name)\", режимов: \(dummy.modes.count)")
        for mode in dummy.modes.prefix(12) {
            print("      \(mode.label)")
        }

        print("2) Зеркалирование основного дисплея на виртуальный…")
        let realDisplay = DisplayManager.activeDisplays().first { !$0.isVirtual && !$0.isBuiltIn }
            ?? DisplayManager.activeDisplays().first { !$0.isVirtual }
        guard let realDisplay else {
            print("   Пропущено: нет физического дисплея")
            VirtualDisplayManager.shared.remove(displayID: dummyID)
            exit(0)
        }
        guard DisplayManager.setMirror(display: realDisplay.id, master: dummyID) else {
            print("   ОШИБКА: CGConfigureDisplayMirrorOfDisplay не сработал")
            VirtualDisplayManager.shared.remove(displayID: dummyID)
            exit(1)
        }
        Thread.sleep(forTimeInterval: 1.0)
        let mirroredNow = CGDisplayIsInMirrorSet(realDisplay.id) == 1 && CGDisplayMirrorsDisplay(realDisplay.id) == dummyID
        print(mirroredNow ? "   OK: дисплей «\(realDisplay.name)» зеркалируется" : "   ОШИБКА: зеркалирование не подтвердилось")

        print("3) Отмена зеркалирования…")
        let unmirrorOK = DisplayManager.unsetMirror(display: realDisplay.id)
        Thread.sleep(forTimeInterval: 1.0)
        let stillMirrored = CGDisplayIsInMirrorSet(realDisplay.id) == 1 && CGDisplayMirrorsDisplay(realDisplay.id) == dummyID
        print(unmirrorOK && !stillMirrored ? "   OK: зеркалирование снято" : "   ОШИБКА: зеркалирование не снялось")

        print("4) Удаление виртуального дисплея…")
        // The display ID of a virtual display can change after mirroring
        // operations, so re-enumerate to find its current ID.
        let currentVirtualID = DisplayManager.activeDisplays().first(where: \.isVirtual)?.id ?? dummyID
        if currentVirtualID != dummyID {
            print("   (ID изменился: \(dummyID) -> \(currentVirtualID))")
        }
        VirtualDisplayManager.shared.remove(displayID: currentVirtualID)
        var gone = false
        for _ in 0..<20 {
            Thread.sleep(forTimeInterval: 0.25)
            gone = DisplayManager.activeDisplays().first(where: \.isVirtual ) == nil
            if gone { break }
        }
        print(gone ? "   OK: виртуальный дисплей отключён" : "   ОШИБКА: виртуальный дисплей всё ещё активен")

        let allOK = mirroredNow && unmirrorOK && !stillMirrored && gone
        print(allOK ? "ИТОГ: все проверки пройдены ✔" : "ИТОГ: есть ошибки ✘")
        exit(allOK ? 0 : 1)
    }

    /// Raw dump of the CGS framebuffer mode list (debugging offsets).
    private static func cgsDump(_ args: [String]) {
        guard args.count > 2, let displayID = CGDirectDisplayID(args[2]) else {
            usage()
            exit(1)
        }
        var nModes: Int32 = 0
        guard DisplayManager.cgsRawModeCount(displayID, &nModes) == .success, nModes > 0 else {
            print("CGSGetNumberOfDisplayModes: нет данных")
            exit(1)
        }
        print("CGS режимов: \(nModes)")
        for index in 0..<nModes {
            guard let raw = DisplayManager.cgsRawMode(displayID, index: index) else { continue }
            print(String(format: "  id=%-4d flags=0x%08x %4dx%-4d depth=%d freq0xBC=%d freq0xBC0=%d freq@BC=%d freq@BE=%d density=%.2f",
                          raw.ioModeID, raw.flags, raw.width, raw.height, raw.depth,
                          raw.freqAtBC, raw.freqAtBC0, raw.freqAtBCu, raw.freqAtBE, raw.density))
        }
        // Current mode via CG for comparison.
        if let current = CGDisplayCopyDisplayMode(displayID) {
            print("Текущий CG: \(current.width)x\(current.height) @\(current.refreshRate) hidpi=\(current.pixelWidth > current.width) ioID=\(current.ioDisplayModeID)")
        }
        exit(0)
    }

    private static func setVCP(_ args: [String]) {
        guard args.count >= 4,
              let displayID = CGDirectDisplayID(args[2]),
              let pct = Double(args[3]) else {
            usage()
            exit(1)
        }
        let clamped = min(max(pct, 0), 100)
        let code: UInt8 = args[1] == "--brightness" ? DDCService.brightnessCode : DDCService.contrastCode

        guard let display = DisplayManager.activeDisplays().first(where: { $0.id == displayID }) else {
            print("Дисплей \(displayID) не найден")
            exit(1)
        }
        if display.isBuiltIn {
            let ok = InternalDisplay.setBrightness(Float(clamped / 100), displayID: displayID)
            print(ok ? "Яркость \(display.name): \(Int(clamped))%" : "Не удалось установить яркость")
            exit(ok ? 0 : 1)
        }

        let semaphore = DispatchSemaphore(value: 0)
        var success = false
        DispatchQueue.global().async {
            defer { semaphore.signal() }
            let maximum: UInt16
            if let value = DDCService.shared.readVCPNowSafe(code, displayID: displayID) {
                maximum = max(value.maximum, 1)
            } else {
                maximum = 100
            }
            let raw = UInt16((clamped / 100.0 * Double(maximum)).rounded())
            success = DDCService.shared.writeVCPNowSafe(code, value: raw, displayID: displayID)
        }
        _ = semaphore.wait(timeout: .now() + 10)
        let what = args[1] == "--brightness" ? "яркость" : "контраст"
        print(success ? "OK: \(what) \(display.name) = \(Int(clamped))%" : "Не удалось (DDC недоступен?)")
        exit(success ? 0 : 1)
    }

    private static func setMode(_ args: [String]) {
        guard args.count >= 5,
              let displayID = CGDirectDisplayID(args[2]),
              let width = Int(args[3]),
              let height = Int(args[4]) else {
            usage()
            exit(1)
        }
        let hz: Double? = args.count > 5 ? Double(args[5]) : nil
        let hidpi: Bool? = args.count > 6 ? (args[6] == "hidpi") : nil

        guard let display = DisplayManager.activeDisplays().first(where: { $0.id == displayID }) else {
            print("Дисплей \(displayID) не найден")
            exit(1)
        }

        let candidates = display.modes.filter { $0.width == width && $0.height == height }
        guard !candidates.isEmpty else {
            print("Режим \(width)x\(height) недоступен для \(display.name)")
            exit(1)
        }
        let chosen = candidates.first(where: { m in
            !m.isCGSOnly && (hidpi == nil || m.isHiDPI == hidpi!) &&
            (hz == nil || DisplayManager.refreshMatches(m.refreshRate, hz!))
        }) ?? candidates.first(where: { m in
            hidpi == nil || m.isHiDPI == hidpi!
        }) ?? candidates[0]

        let ok = DisplayManager.apply(chosen, to: displayID, save: !args.contains("--raw"))
        print(ok ? "OK: \(display.name) -> \(chosen.label)" : "Не удалось применить режим")
        exit(ok ? 0 : 1)
    }

    private static func rotate(_ args: [String]) {
        guard args.count >= 4,
              let displayID = CGDirectDisplayID(args[2]),
              let degrees = Int(args[3]),
              [0, 90, 180, 270].contains(degrees) else {
            usage()
            exit(1)
        }
        guard let display = DisplayManager.activeDisplays().first(where: { $0.id == displayID }) else {
            print("Дисплей \(displayID) не найден")
            exit(1)
        }
        let ok = RotationService.setRotationSync(degrees, for: displayID)
        print(ok ? "OK: \(display.name) повернут на \(degrees)°" : "Не удалось повернуть")
        exit(ok ? 0 : 1)
    }
}

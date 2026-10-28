import SwiftUI
import AppKit

struct MacDisplayFixerApp: App {
    @StateObject private var store = DisplayStore.shared

    var body: some Scene {
        MenuBarExtra {
            RootView()
                .environmentObject(store)
                .frame(width: 440, height: 520)
        } label: {
            Image(systemName: "display")
        }
        .menuBarExtraStyle(.window)
    }
}

struct RootView: View {
    @EnvironmentObject var store: DisplayStore
    @State private var selectedPresetID: Int = VirtualDisplayPresets.all.first?.id ?? 10
    @State private var selectedRefreshRate: Double = VirtualDisplayPresets.defaultRefreshRate

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 12) {
                    if !store.displays.isEmpty {
                        ForEach(store.displays) { display in
                            DisplayCard(display: display)
                        }
                    } else {
                        Text("Дисплеи не найдены")
                            .foregroundStyle(.secondary)
                            .padding(.top, 40)
                    }
                    virtualDisplaySection
                    if let message = store.lastMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(12)
            }
            Divider()
            HStack {
                Button {
                    store.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Обновить")
                Spacer()
                Text("Mac Display Fixer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Завершить") {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(8)
        }
    }
    /// "Create virtual display" control.
    private var virtualDisplaySection: some View {
        VStack(spacing: 8) {
            Divider()
            HStack {
                Image(systemName: "plus.rectangle.on.rectangle")
                    .foregroundStyle(.secondary)
                Text("Виртуальный дисплей")
                    .font(.headline)
                Spacer()
            }
            HStack {
                Picker("Аспект", selection: $selectedPresetID) {
                    ForEach(VirtualDisplayPresets.all) { preset in
                        Text(preset.description).tag(preset.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                Picker("Частота", selection: $selectedRefreshRate) {
                    ForEach(VirtualDisplayPresets.availableRefreshRates, id: \.self) { rate in
                        Text("\(Int(rate)) Гц").tag(rate)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                Button("Создать") {
                    if let preset = VirtualDisplayPresets.preset(id: selectedPresetID) {
                        store.createVirtualDisplay(preset: preset, refreshRate: selectedRefreshRate)
                    }
                }
            }
            Text("Создайте виртуальный дисплей и зеркалируйте на него физический монитор — тогда его режимы (включая HiDPI) применятся к монитору. Для мониторов 144 Гц создавайте виртуалку на 144 Гц.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

struct DisplayCard: View {
    @EnvironmentObject var store: DisplayStore
    let display: DisplayInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Divider()
            if display.isVirtual {
                modePicker
                virtualFooter
            } else if display.isMirrored {
                mirrorNotice
                mirrorPicker
            } else {
                modePicker
                rotationPicker
                if !store.virtualDisplays.isEmpty {
                    mirrorPicker
                }
            }
            if let state = store.controls[display.id] {
                if state.brightnessAvailable { brightnessSlider(state) }
                if state.contrastAvailable { contrastSlider(state) }
            } else if !display.isBuiltIn && !display.isVirtual {
                ProgressView("Проверка DDC…")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.quaternary.opacity(0.3))
        )
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: display.isBuiltIn ? "laptopcomputer" : "display")
                .foregroundStyle(.secondary)
            Text(display.name).font(.headline)
            if display.isVirtual {
                badge("Виртуальный")
            }
            if display.isMain && !display.isVirtual {
                badge("Основной")
            }
            if display.isBuiltIn {
                badge("Встроенный")
            }
            if display.isMirrored {
                badge("Дублируется")
            }
            Spacer()
            Text("ID \(display.id)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(.secondary.opacity(0.25)))
    }
}

extension DisplayCard {

    /// Notice shown on a display that is a mirror slave: its mode is driven
    /// by the master display.
    private var mirrorNotice: some View {
        let masterID = CGDisplayMirrorsDisplay(display.id)
        let masterName = store.displays.first(where: { $0.id == masterID })?.name ?? "другой дисплей"
        return Text("Дублирует «\(masterName)» — режим задаётся там. Яркость/контраст доступны ниже.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    /// Mirroring picker for real displays: choose which virtual display to mirror.
    private var mirrorPicker: some View {
        HStack {
            Text("Зеркалировать").foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
            Picker("", selection: Binding(
                get: { Int(store.mirroredVirtualMaster(of: display.id) ?? 0) },
                set: { newValue in
                    if newValue == 0 {
                        store.setMirror(of: display, toVirtual: nil)
                    } else {
                        store.setMirror(of: display, toVirtual: CGDirectDisplayID(newValue))
                    }
                }
            )) {
                Text("—").tag(0)
                ForEach(store.virtualDisplays) { virtual in
                    Text(virtual.name).tag(Int(virtual.id))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: .infinity)
        }
    }

    /// Footer for virtual displays: refresh rate picker, mirror status,
    /// disconnect button.
    private var virtualFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            let mirroredBy = store.realDisplays.filter { store.mirroredVirtualMaster(of: $0.id) == display.id }
            if !mirroredBy.isEmpty {
                Text("Зеркалируется: \(mirroredBy.map(\.name).joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("Частота").foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
                Picker("", selection: Binding(
                    get: { store.virtualRefreshRate(displayID: display.id) },
                    set: { newValue in
                        store.setVirtualRefreshRate(displayID: display.id, rate: newValue)
                    }
                )) {
                    ForEach(VirtualDisplayPresets.availableRefreshRates, id: \.self) { rate in
                        Text("\(Int(rate)) Гц").tag(rate)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: .infinity)
            }
            Button(role: .destructive) {
                store.removeVirtualDisplay(displayID: display.id)
            } label: {
                Label("Отключить", systemImage: "minus.circle")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var modePicker: some View {
        HStack {
            Text("Режим").foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
            Picker("", selection: Binding(
                get: { display.currentMode?.id ?? "" },
                set: { newID in
                    if let mode = display.modes.first(where: { $0.id == newID }) {
                        store.applyMode(mode, to: display)
                    }
                }
            )) {
                ForEach(display.modes) { mode in
                    Text(mode.label).tag(mode.id)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: .infinity)
        }
    }

    private var rotationPicker: some View {
        HStack {
            Text("Поворот").foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
            Picker("", selection: Binding(
                get: { store.rotating.contains(display.id) ? -1 : display.rotationDegrees },
                set: { newValue in
                    if [0, 90, 180, 270].contains(newValue) {
                        store.rotate(to: newValue, display: display)
                    }
                }
            )) {
                Text("0°").tag(0)
                Text("90°").tag(90)
                Text("180°").tag(180)
                Text("270°").tag(270)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(store.rotating.contains(display.id))
            if store.rotating.contains(display.id) {
                ProgressView().controlSize(.small)
            }
        }
    }

    private func brightnessSlider(_ state: DisplayControls) -> some View {
        HStack {
            Image(systemName: "sun.max")
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            Slider(
                value: Binding(
                    get: { state.brightnessPct },
                    set: { store.setBrightness(pct: $0, for: display) }
                ),
                in: 0...100
            )
            Text("\(Int(state.brightnessPct.rounded()))")
                .font(.caption.monospacedDigit())
                .frame(width: 26, alignment: .trailing)
        }
    }

    private func contrastSlider(_ state: DisplayControls) -> some View {
        HStack {
            Image(systemName: "circle.lefthalf.filled")
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            Slider(
                value: Binding(
                    get: { state.contrastPct },
                    set: { store.setContrast(pct: $0, for: display) }
                ),
                in: 0...100
            )
            Text("\(Int(state.contrastPct.rounded()))")
                .font(.caption.monospacedDigit())
                .frame(width: 26, alignment: .trailing)
        }
    }
}

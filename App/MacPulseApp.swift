import AppKit
import ServiceManagement
import SwiftUI

@main
struct MacPulseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var sampler = Sampler.shared
    @AppStorage(Pref.barTemp) private var barTemp = true
    @AppStorage(Pref.barCPU) private var barCPU = true
    @AppStorage(Pref.barMem) private var barMem = false
    @AppStorage(Pref.barFan) private var barFan = false

    private var menuBarShown: Binding<Bool> {
        Binding(get: { barTemp || barCPU || barMem || barFan }, set: { _ in })
    }

    var body: some Scene {
        MenuBarExtra(isInserted: menuBarShown) {
            DashboardView(compact: true)
        } label: {
            Image(nsImage: MenuBarRenderer.image(snapshot: sampler.snapshot,
                                                 temp: barTemp, cpu: barCPU, mem: barMem, fan: barFan))
        }
        .menuBarExtraStyle(.window)
    }
}

enum Pref {
    static let barTemp = "menuBarTemp"
    static let barCPU = "menuBarCPU"
    static let barMem = "menuBarMem"
    static let barFan = "menuBarFan"
}

// MARK: - Menu bar item

/// Renders the menu bar item as one template image ("🌡62°  ▢38%") so the layout is exact
/// and it adapts to light/dark menu bars like system items.
@MainActor
enum MenuBarRenderer {
    static func image(snapshot s: Snapshot, temp: Bool, cpu: Bool, mem: Bool, fan: Bool) -> NSImage {
        var items: [(symbol: String, value: String, minWidth: CGFloat)] = []
        if temp { items.append(("thermometer.medium", s.isStale || s.cpuTemp == nil ? "—" : "\(Int(s.cpuTemp!.rounded()))°", 22)) }
        if cpu { items.append(("cpu", s.isStale ? "—" : "\(Int((s.cpuUsage * 100).rounded()))%", 28)) }
        if mem { items.append(("memorychip", s.isStale ? "—" : "\(Int(Snapshot.gb(s.memUsed).rounded()))G", 26)) }
        if fan, s.fanRPM != nil { items.append(("fan", s.fanText, 34)) }

        let content = HStack(spacing: 9) {
            ForEach(items.indices, id: \.self) { i in
                HStack(spacing: 3) {
                    Image(systemName: items[i].symbol)
                        .font(.system(size: 12, weight: .medium))
                    Text(items[i].value)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .fixedSize()
                        .frame(minWidth: items[i].minWidth, alignment: .leading)
                }
            }
        }
        .foregroundStyle(.black)
        .frame(height: 18)

        let renderer = ImageRenderer(content: content)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage ?? NSImage(systemSymbolName: "gauge.with.dots.needle.33percent", accessibilityDescription: nil)!
        image.isTemplate = true
        return image
    }
}

// MARK: - App delegate (dashboard window)

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { Sampler.shared.start() }
        NotificationCenter.default.addObserver(forName: .macPulseOpenDashboard, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.showDashboard() }
        }
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "didOnboard") {
            defaults.set(true, forKey: "didOnboard")
            MainActor.assumeIsolated { showDashboard() }
        }
    }

    /// Opening the app again (Finder, Spotlight) shows the dashboard,
    /// so it is reachable even when the menu bar item is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { showDashboard() }
        return true
    }

    @MainActor
    func showDashboard() {
        if window == nil {
            let host = NSHostingView(rootView: DashboardView(compact: false))
            let blur = NSVisualEffectView()
            blur.material = .hudWindow
            blur.blendingMode = .behindWindow
            blur.state = .active
            host.translatesAutoresizingMaskIntoConstraints = false
            blur.addSubview(host)
            NSLayoutConstraint.activate([
                host.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
                host.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
                host.topAnchor.constraint(equalTo: blur.topAnchor),
                host.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
            ])
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                             styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.contentView = blur
            w.title = "MacPulse"
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            window = w
        }
        // Show a Dock icon while the window is open, like a regular app window.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // The helper also restores automatic control when MacPulse disconnects.
        MainActor.assumeIsolated { FanController.shared.setAutomatic() }
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

// MARK: - Dashboard (Control Center–style glass modules)

struct DashboardView: View {
    let compact: Bool
    @ObservedObject private var sampler = Sampler.shared
    @AppStorage(Pref.barTemp) private var barTemp = true
    @AppStorage(Pref.barCPU) private var barCPU = true
    @AppStorage(Pref.barMem) private var barMem = false
    @AppStorage(Pref.barFan) private var barFan = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    private var s: Snapshot { sampler.snapshot }

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            VStack(spacing: 10) {
                header
                HStack(spacing: 10) {
                    MetricModule(symbol: "thermometer.medium", title: "CPU 溫度", value: s.tempText,
                                 detail: s.cpuTempMax.map { "最高 \(Int($0.rounded()))°" } ?? " ",
                                 fraction: tempFraction, color: tempColor)
                    MetricModule(symbol: "cpu", title: "CPU 使用率", value: s.usageText,
                                 detail: "\(ProcessInfo.processInfo.activeProcessorCount) 核心",
                                 fraction: s.cpuUsage, color: .blue)
                }
                if s.fanRPM != nil {
                    HStack(spacing: 10) {
                        MetricModule(symbol: "memorychip", title: "記憶體",
                                     value: s.isStale ? "—" : String(format: "%.1f GB", Snapshot.gb(s.memUsed)),
                                     detail: "共 \(Int(Snapshot.gb(s.memTotal).rounded())) GB",
                                     fraction: s.memFraction, color: .purple)
                        MetricModule(symbol: "fan", title: "風扇 RPM", value: s.fanText,
                                     detail: s.fanMax.map { "最高 \(Int($0.rounded()))" } ?? " ",
                                     fraction: s.fanFraction, color: .teal)
                    }
                } else {
                    memoryModule
                }
                if s.fanRPM != nil { FanControlModule(snapshot: s) }
                menuBarModule
                buttonRow
                if !compact { controlCenterHint }
            }
            .padding(compact ? 12 : 16)
            .padding(.top, compact ? 0 : 18)
        }
        .frame(width: 320)
        .animation(.easeOut(duration: 0.35), value: s)
    }

    // Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text("MacPulse").font(.system(size: 15, weight: .semibold, design: .rounded))
                Text(Self.machine).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 5) {
                Circle().fill(s.isStale ? Color.secondary : Color.green).frame(width: 6, height: 6)
                Text(s.isStale ? "未更新" : "即時").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 4)
    }

    static let machine: String = {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0)
        let chip = String(cString: buf)
        let gb = Int(Snapshot.gb(ProcessInfo.processInfo.physicalMemory).rounded())
        return "\(chip.isEmpty ? "Mac" : chip) · \(gb) GB"
    }()

    // Modules

    private var memoryModule: some View {
        HStack(spacing: 10) {
            IconBadge(symbol: "memorychip", color: .purple)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text("記憶體").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    Spacer()
                    Text(s.memText).font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
                }
                LevelBar(fraction: s.memFraction, color: .purple)
            }
        }
        .module()
    }

    private var menuBarModule: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("選單列顯示").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ChipToggle(symbol: "thermometer.medium", title: "溫度", isOn: $barTemp)
                ChipToggle(symbol: "cpu", title: "CPU", isOn: $barCPU)
                ChipToggle(symbol: "memorychip", title: "記憶體", isOn: $barMem)
                if s.fanRPM != nil {
                    ChipToggle(symbol: "fan", title: "風扇", isOn: $barFan)
                }
            }
        }
        .module()
    }

    private var buttonRow: some View {
        HStack(alignment: .top, spacing: 0) {
            RoundButton(title: "更新頻率", isOn: false, action: cycleInterval) {
                Text(intervalLabel).font(.system(size: 13, weight: .semibold, design: .rounded))
            }
            RoundButton(title: "開機啟動", isOn: launchAtLogin, action: toggleLaunchAtLogin) {
                Image(systemName: "power").font(.system(size: 15, weight: .semibold))
            }
            RoundButton(title: "活動監視器", isOn: false, action: openActivityMonitor) {
                Image(systemName: "waveform.path.ecg").font(.system(size: 15, weight: .semibold))
            }
            RoundButton(title: "結束", isOn: false, action: { NSApp.terminate(nil) }) {
                Image(systemName: "xmark").font(.system(size: 14, weight: .semibold))
            }
        }
        .overlay(alignment: .bottom) {
            if let loginError {
                Text(loginError).font(.caption2).foregroundStyle(.red).offset(y: 14)
            }
        }
    }

    private var controlCenterHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("加到控制中心", systemImage: "switch.2")
                .font(.system(size: 12, weight: .semibold))
            Text("打開控制中心 → 最下方「編輯控制項目」→ 搜尋 MacPulse，把「CPU 溫度」「CPU 使用率」「記憶體」「風扇轉速」拖進控制中心或選單列。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .module()
    }

    // Helpers

    private var tempFraction: Double { min(max(((s.cpuTemp ?? 30) - 30) / 70, 0), 1) }
    private var tempColor: Color {
        switch s.tempLevel {
        case .normal: return .green
        case .warm: return .orange
        case .hot: return .red
        }
    }

    private static let intervals: [TimeInterval] = [1, 2, 5, 10]
    private var intervalLabel: String { "\(Int(sampler.interval))s" }
    private func cycleInterval() {
        let i = Self.intervals.firstIndex(of: sampler.interval) ?? 0
        sampler.interval = Self.intervals[(i + 1) % Self.intervals.count]
    }

    private func toggleLaunchAtLogin() {
        do {
            if launchAtLogin { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
            loginError = nil
        } catch {
            loginError = "無法設定開機啟動"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func openActivityMonitor() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
    }
}

// MARK: - Building blocks

private extension View {
    /// A Control Center–style glass platter.
    func module() -> some View {
        self.padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }
}

struct IconBadge: View {
    let symbol: String
    let color: Color
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(color.gradient, in: Circle())
    }
}

struct LevelBar: View {
    let fraction: Double
    let color: Color
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.1))
                Capsule().fill(color.gradient)
                    .frame(width: max(6, geo.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 6)
    }
}

struct MetricModule: View {
    let symbol: String
    let title: String
    let value: String
    let detail: String
    let fraction: Double
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                IconBadge(symbol: symbol, color: color)
                Spacer()
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            LevelBar(fraction: fraction, color: color)
        }
        .module()
    }
}

struct ChipToggle: View {
    let symbol: String
    let title: String
    @Binding var isOn: Bool
    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                Text(title).font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(isOn ? Color.white : Color.primary)
            .padding(.horizontal, 5)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(Capsule().fill(isOn ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(.primary.opacity(0.08))))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct RoundButton<Icon: View>: View {
    let title: String
    let isOn: Bool
    let action: () -> Void
    @ViewBuilder let icon: () -> Icon

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                icon()
                    .foregroundStyle(isOn ? Color.white : Color.primary)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(isOn ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(.clear)))
                    .glassEffect(.regular, in: .circle)
                Text(title).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Fan control

struct FanControlModule: View {
    let snapshot: Snapshot
    @ObservedObject private var fan = FanController.shared
    @State private var target: Double = 0
    /// Optimistic mode until the next sample confirms it.
    @State private var pendingManual: Bool?

    private var manual: Bool { pendingManual ?? (snapshot.fanManual == true) }
    private var maxRPM: Double { snapshot.fanMax ?? 6000 }
    private var lower: Double {
        let base = fan.floor > 0 ? fan.floor : (snapshot.fanRPM ?? 0)
        return min((base / 100).rounded(.up) * 100, maxRPM - 100)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("風扇控制").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                ModeSwitch(manual: manual, onChange: switchMode)
            }
            content
            if let error = fan.errorMessage {
                Text(error).font(.system(size: 10)).foregroundStyle(.red)
            }
        }
        .module()
        .onChange(of: snapshot.fanManual) { _, value in
            if value == pendingManual { pendingManual = nil }
        }
        .onChange(of: fan.floor) { _, floor in
            if floor > 0, target < floor { target = (floor / 100).rounded(.up) * 100 }
        }
        .task {
            // Picks up approval in System Settings while the panel is open.
            while !Task.isCancelled {
                fan.refreshState()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch fan.helperState {
        case .ready:
            if manual {
                HStack(spacing: 10) {
                    Slider(value: $target, in: lower...maxRPM, step: 100) { editing in
                        if !editing { fan.setManual(rpm: target) }
                    }
                    .tint(.teal)
                    Text("\(Int(target))")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
                Text("最低 \(Int(lower)) RPM（接手時的轉速）· CPU 達 90°C 會自動交還系統")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            } else {
                Text("目前由系統自動控制。切到「手動」就能拉動轉速。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        case .notInstalled:
            HStack {
                Text("手動控制需要安裝一個管理員權限的小幫手。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("安裝") { fan.install() }
            }
        case .needsApproval:
            HStack {
                Text("請到「系統設定 › 一般 › 登入項目與延伸功能」允許 MacPulse。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("打開") { fan.openLoginItems() }
            }
        case .unavailable(let message):
            Text(message).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func switchMode(_ wantManual: Bool) {
        switch fan.helperState {
        case .ready:
            pendingManual = wantManual
            if wantManual {
                target = max(target, lower)
                fan.setManual(rpm: target)
            } else {
                fan.setAutomatic()
            }
        case .notInstalled: fan.install()
        case .needsApproval: fan.openLoginItems()
        case .unavailable: break
        }
    }
}

struct ModeSwitch: View {
    let manual: Bool
    let onChange: (Bool) -> Void

    var body: some View {
        HStack(spacing: 2) {
            segment("自動", selected: !manual) { onChange(false) }
            segment("手動", selected: manual) { onChange(true) }
        }
        .padding(2)
        .background(Capsule().fill(.primary.opacity(0.08)))
    }

    private func segment(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(selected ? AnyShapeStyle(Color.teal.gradient) : AnyShapeStyle(.clear)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

import SwiftUI
import ServiceManagement

@MainActor
final class Monitor: ObservableObject {
    @Published var cpu = 0.0
    @Published var gpu: Double?
    @Published var mem: (used: UInt64, total: UInt64) = (0, 0)
    @Published var swap: (used: UInt64, total: UInt64) = (0, 0)
    @Published var temps = StatsReader.Temps()
    @Published var net: (down: Double, up: Double) = (0, 0)
    @Published var openAtLogin = false

    private let reader = StatsReader()
    private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        cpu = reader.cpuUsage()
        gpu = reader.gpuUsage()
        mem = reader.memory()
        swap = reader.swap()
        temps = reader.temperatures()
        net = reader.network()
        openAtLogin = LoginItem.isEnabled
    }
}

// MARK: Formatting

func bytes(_ b: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .memory)
}

func rate(_ bps: Double) -> String {
    let units = ["B/s", "KB/s", "MB/s", "GB/s"]
    var v = bps, i = 0
    while v >= 1000 && i < units.count - 1 { v /= 1000; i += 1 }
    return i == 0 ? String(format: "%.0f %@", v, units[i]) : String(format: "%.1f %@", v, units[i])
}

func temp(_ t: Double?) -> String { t.map { String(format: "%.0f°C", $0) } ?? "—" }

// MARK: Views

struct Bar: View {
    let fraction: Double
    var color: Color {
        fraction > 0.85 ? .red : fraction > 0.6 ? .orange : .accentColor
    }
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(color).frame(width: max(0, min(1, fraction)) * g.size.width)
            }
        }
        .frame(height: 6)
        .animation(.easeOut(duration: 0.4), value: fraction)
    }
}

struct MetricRow: View {
    let icon: String, title: String, value: String
    var detail: String? = nil
    var fraction: Double? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Image(systemName: icon).frame(width: 18).foregroundStyle(.secondary)
                Text(title)
                Spacer()
                if let detail { Text(detail).foregroundStyle(.secondary).font(.caption) }
                Text(value).monospacedDigit().fontWeight(.semibold)
            }
            if let fraction { Bar(fraction: fraction) }
        }
    }
}

struct PanelView: View {
    @ObservedObject var m: Monitor

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("System Monitor").font(.headline)

            MetricRow(icon: "cpu", title: "Processor", value: String(format: "%.0f%%", m.cpu),
                      fraction: m.cpu / 100)
            MetricRow(icon: "rectangle.3.group", title: "GPU",
                      value: m.gpu.map { String(format: "%.0f%%", $0) } ?? "—",
                      fraction: (m.gpu ?? 0) / 100)
            MetricRow(icon: "memorychip", title: "Memory",
                      value: bytes(m.mem.used), detail: "of \(bytes(m.mem.total))",
                      fraction: m.mem.total > 0 ? Double(m.mem.used) / Double(m.mem.total) : 0)
            MetricRow(icon: "arrow.left.arrow.right.square", title: "Swap",
                      value: bytes(m.swap.used),
                      detail: m.swap.total > 0 ? "of \(bytes(m.swap.total))" : nil,
                      fraction: m.swap.total > 0 ? Double(m.swap.used) / Double(m.swap.total) : 0)

            Divider()

            Label("Temperature", systemImage: "thermometer.medium").font(.subheadline.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow { tempCell("CPU", m.temps.cpu); tempCell("GPU", m.temps.gpu) }
                GridRow { tempCell("SSD", m.temps.ssd); tempCell("Battery", m.temps.battery) }
            }

            Divider()

            Label("Network", systemImage: "network").font(.subheadline.weight(.semibold))
            HStack {
                Label { Text(rate(m.net.down)) } icon: { Image(systemName: "arrow.down.circle.fill").foregroundStyle(.blue) }
                Spacer()
                Label { Text(rate(m.net.up)) } icon: { Image(systemName: "arrow.up.circle.fill").foregroundStyle(.green) }
            }
            .monospacedDigit()

            Divider()

            Toggle("Open at Login", isOn: Binding(
                get: { m.openAtLogin },
                set: { LoginItem.set($0); m.openAtLogin = LoginItem.isEnabled }))
                .toggleStyle(.switch).controlSize(.small).font(.caption)

            HStack {
                Button("Activity Monitor") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
        .padding(16)
        .frame(width: 300)
    }

    func tempCell(_ name: String, _ t: Double?) -> some View {
        HStack {
            Text(name).foregroundStyle(.secondary)
            Spacer()
            Text(temp(t)).monospacedDigit().fontWeight(.medium)
                .foregroundStyle((t ?? 0) > 85 ? .red : (t ?? 0) > 70 ? .orange : .primary)
        }
        .frame(width: 120)
    }
}

// MARK: App (AppKit status item + dropdown panel: opens on a single click)

/// Borderless panel that can take keyboard focus (for Esc / ⌘Q).
final class DropdownPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let monitor = Monitor()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var panel: DropdownPanel!
    private var hosting: NSHostingView<AnyView>!
    private var timer: Timer?
    private var clickMonitor: Any?
    private var keyMonitor: Any?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        if let button = statusItem.button {
            let icon = NSImage(systemSymbolName: "cpu", accessibilityDescription: "System Monitor")
            icon?.isTemplate = true
            button.image = icon
            button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            button.action = #selector(togglePanel)
            button.target = self
        }

        let content = PanelView(m: monitor)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
        hosting = NSHostingView(rootView: AnyView(content))

        panel = DropdownPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: true)
        panel.contentView = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false

        updateTitle()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateTitle() }
        }
        LoginItem.enableOnFirstLaunch()
    }

    private func updateTitle() {
        let cpu = String(format: " %.0f%%", monitor.cpu)
        let t = monitor.temps.cpu.map { String(format: " %.0f°", $0) } ?? ""
        statusItem.button?.title = cpu + t
    }

    @objc private func togglePanel() {
        panel.isVisible ? closePanel() : showPanel()
    }

    private func showPanel() {
        guard let button = statusItem.button, let buttonWindow = button.window,
              let screen = buttonWindow.screen ?? NSScreen.main else { return }
        monitor.refresh()

        // Place directly under the menu bar, centred on the icon, kept fully on screen.
        let size = hosting.fittingSize
        let visible = screen.visibleFrame          // excludes the menu bar and Dock
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let margin: CGFloat = 8
        var x = anchor.midX - size.width / 2
        x = min(max(x, visible.minX + margin), visible.maxX - size.width - margin)
        let height = min(size.height, visible.height - margin * 2)
        let y = visible.maxY - height - 4
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: height), display: true)

        panel.makeKeyAndOrderFront(nil)
        button.highlight(true)

        // Close on any click outside the app, or on Esc.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            let location = NSEvent.mouseLocation
            Task { @MainActor in
                // A click on our own icon is handled by togglePanel; closing here would make it reopen.
                guard let self, !self.iconFrame().contains(location) else { return }
                self.closePanel()
            }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.closePanel(); return nil }   // Esc
            return event
        }
    }

    private func iconFrame() -> NSRect {
        guard let button = statusItem.button, let window = button.window else { return .zero }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    private func closePanel() {
        panel.orderOut(nil)
        statusItem.button?.highlight(false)
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }
}

// MARK: Open at login

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("MacMonitor: login item change failed: \(error)")
        }
    }

    /// Turns "Open at Login" on the first time the app runs; the panel toggle controls it after that.
    static func enableOnFirstLaunch() {
        let key = "didConfigureLoginItem"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        set(true)
        UserDefaults.standard.set(true, forKey: key)
    }
}

import AppKit
import SwiftUI
import ServiceManagement

final class Settings: ObservableObject {
    @Published var textSize: Int { didSet { defaults.set(textSize, forKey: "textSize"); onChange?() } }
    @Published var showSettings = false { didSet { onChange?() } }
    @Published var customPath: String { didSet { defaults.set(customPath, forKey: "codexPath") } }
    var onChange: (() -> Void)?
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        textSize = defaults.integer(forKey: "textSize")
        customPath = defaults.string(forKey: "codexPath") ?? ""
    }
    var scale: CGFloat { textSize == 2 ? 1.3 : textSize == 1 ? 1.15 : 1 }
    func font(_ style: NSFont.TextStyle = .body) -> Font {
        let font = NSFont.preferredFont(forTextStyle: style, options: [:])
        return Font(NSFont(descriptor: font.fontDescriptor, size: font.pointSize * scale) ?? font)
    }
}

final class Usage: ObservableObject {
    @Published var snapshot: UsageSnapshot?
    @Published var message = ""
    @Published var loading = false
    @Published var settingsMessage = ""
    var onUpdate: (() -> Void)?
    let client = CodexClient()
    var gate = RefreshGate()
    var customPath: () -> String = { "" }
    func refresh(force: Bool = false) {
        guard !loading, gate.permits(force: force, now: Date()) else { return }
        gate.started(at: Date()); loading = true
        let path = customPath()
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try self.client.fetch(customPath: path) }
            DispatchQueue.main.async {
                self.loading = false
                switch result {
                case .success(let snapshot):
                    self.snapshot = snapshot
                    self.message = snapshot.primary == nil && snapshot.weekly == nil ? "账号未提供标准额度窗口，请确认使用 ChatGPT 登录。" : ""
                    self.gate.completed(success: true, at: Date())
                case .failure(let error):
                    self.message = error.localizedDescription
                    self.gate.completed(success: false, at: Date())
                }
                self.onUpdate?()
            }
        }
    }
}

struct UsageContent: View {
    @ObservedObject var usage: Usage
    @ObservedObject var settings: Settings
    var chooseExecutable: () -> Void = {}
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Codex 剩余额度").font(settings.font(.headline))
                Spacer(minLength: 4)
                Text(usage.snapshot?.plan ?? "").foregroundStyle(.secondary)
                if usage.loading { ProgressView().controlSize(.small).accessibilityLabel("正在刷新") }
            }
            TimelineView(.periodic(from: .now, by: 30)) { context in
                VStack(spacing: 9) {
                    row("5 小时", usage.snapshot?.primary, now: context.date)
                    Divider()
                    row("每周", usage.snapshot?.weekly, now: context.date)
                }
            }
            if !usage.message.isEmpty {
                Text((usage.snapshot == nil ? "" : "显示上次数据 · ") + usage.message)
                    .foregroundStyle(.orange).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                Text(usage.snapshot.map { "更新 \($0.fetchedAt.formatted(date: .omitted, time: .shortened))" } ?? "等待数据")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 2)
                Button("刷新") { usage.refresh(force: true) }.disabled(usage.loading)
                Button { settings.showSettings.toggle() } label: { Image(systemName: "gearshape") }
                    .help("设置").accessibilityLabel("设置")
                Button("退出") { NSApp.terminate(nil) }
            }.buttonStyle(.borderless)
            if settings.showSettings {
                Divider()
                HStack {
                    Text("文字")
                    Picker("文字大小", selection: $settings.textSize) {
                        Text("系统").tag(0); Text("大").tag(1); Text("更大").tag(2)
                    }.labelsHidden().pickerStyle(.segmented)
                }
                HStack {
                    Button(SMAppService.mainApp.status == .enabled ? "关闭登录启动" : "开启登录启动") { toggleLogin() }
                    Spacer(minLength: 2)
                    Button("选择 Codex…", action: chooseExecutable)
                }.buttonStyle(.borderless)
                if !settings.customPath.isEmpty {
                    HStack {
                        Text(URL(fileURLWithPath: settings.customPath).lastPathComponent).help(settings.customPath)
                        Spacer()
                        Button("自动查找") { settings.customPath = ""; usage.refresh(force: true) }
                    }.buttonStyle(.borderless)
                }
                Text("每分钟刷新 · 30 秒内打开复用数据\n按住 ⌘ 拖动菜单栏数字可调整位置")
                    .font(settings.font(.callout)).foregroundStyle(.secondary)
                if !usage.settingsMessage.isEmpty { Text(usage.settingsMessage).foregroundStyle(.orange) }
            }
        }.font(settings.font()).padding(12).frame(maxWidth: .infinity)
            .fixedSize(horizontal: false, vertical: true)
    }
    func row(_ title: String, _ limit: WindowLimit?, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title).font(settings.font(.headline))
                Spacer()
                Text(limit.map { "\($0.remaining)%" } ?? "—").font(settings.font(.headline)).monospacedDigit()
            }
            ProgressView(value: Double(limit?.remaining ?? 0), total: 100)
                .tint((limit?.remaining ?? 100) <= 10 ? .orange : .accentColor)
                .accessibilityLabel("\(title)剩余").accessibilityValue(limit.map { "\($0.remaining)%" } ?? "未提供")
            if let reset = limit?.reset {
                let minutes = max(0, Int(ceil(reset.timeIntervalSince(now) / 60)))
                let countdown = minutes == 0 ? "等待重置" : minutes >= 1440 ? "\(minutes / 1440)天\((minutes % 1440) / 60)小时后" : minutes >= 60 ? "\(minutes / 60)小时\(minutes % 60)分后" : "\(minutes)分后"
                // Wrap naturally when the system text size or display width changes.
                Text("重置 \(reset.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute())) · \(countdown)")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text(limit == nil ? "未提供此额度窗口" : "重置时间未提供").foregroundStyle(.secondary)
            }
        }
    }
    func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else if SMAppService.mainApp.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
            } else {
                try SMAppService.mainApp.register()
            }
            usage.settingsMessage = SMAppService.mainApp.status == .requiresApproval ? "请在系统登录项中允许此应用。" : ""
        } catch { usage.settingsMessage = "登录启动设置失败：\(error.localizedDescription)" }
        usage.onUpdate?()
    }
}

final class PanelLayout: ObservableObject {
    @Published var width: CGFloat = 320
    @Published var height: CGFloat = 260
}
struct UsagePanel: View {
    @ObservedObject var usage: Usage
    @ObservedObject var settings: Settings
    @ObservedObject var layout: PanelLayout
    var chooseExecutable: () -> Void
    var body: some View {
        ScrollView(.vertical) {
            UsageContent(usage: usage, settings: settings, chooseExecutable: chooseExecutable)
        }.frame(width: layout.width, height: layout.height)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let usage = Usage(), settings = Settings(), layout = PanelLayout()
    var item: NSStatusItem!
    let popover = NSPopover()
    var timer: Timer?
    var observers: [NSObjectProtocol] = []
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Reopening the app should not create a second menu-bar item.
        let peers = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "io.github.codexusage.menubar")
        if peers.contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) { NSApp.terminate(nil); return }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "CodexUsageStatus"
        item.button?.font = NSFont.menuBarFont(ofSize: 0)
        item.button?.title = "—/—"
        item.button?.target = self; item.button?.action = #selector(toggle)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: UsagePanel(usage: usage, settings: settings, layout: layout, chooseExecutable: { [weak self] in self?.chooseExecutable() }))
        usage.customPath = { [weak self] in self?.settings.customPath ?? "" }
        usage.onUpdate = { [weak self] in self?.update() }
        settings.onChange = { [weak self] in DispatchQueue.main.async { self?.resize() } }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.usage.refresh() }
        timer?.tolerance = 10
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.usage.refresh() })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.resize() })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.resize() })
        resize(); usage.refresh()
    }
    func applicationWillTerminate(_ notification: Notification) { timer?.invalidate(); usage.client.cancel() }
    func update() {
        let a = usage.snapshot?.primary.map { "\($0.remaining)%" } ?? "—"
        let b = usage.snapshot?.weekly.map { "\($0.remaining)%" } ?? "—"
        item.button?.title = "\(a)/\(b)" + (usage.message.isEmpty ? "" : "!")
        item.button?.toolTip = "Codex 剩余：5 小时 \(a)，每周 \(b)" + (usage.message.isEmpty ? "" : "（上次数据／读取失败）")
        item.button?.setAccessibilityLabel(item.button?.toolTip)
        resize()
    }
    func resize() {
        let screen = item?.button?.window?.screen ?? NSScreen.main
        let available = screen?.visibleFrame.size ?? NSSize(width: 1024, height: 700)
        let width = min(320 * settings.scale, max(180, available.width - 24))
        let measurement = NSHostingView(rootView: UsageContent(usage: usage, settings: settings).frame(width: width))
        let desired = ceil(measurement.fittingSize.height)
        let height = min(max(180, desired), max(100, available.height - 40))
        layout.width = width; layout.height = height
        popover.contentSize = NSSize(width: width, height: height)
    }
    @objc func toggle() {
        if popover.isShown { popover.performClose(nil) }
        else if let button = item.button {
            resize()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
            usage.refresh()
        }
    }
    func chooseExecutable() {
        popover.performClose(nil)
        let panel = NSOpenPanel()
        panel.title = "选择 Codex 可执行文件"; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")
        if panel.runModal() == .OK, let url = panel.url {
            guard FileManager.default.isExecutableFile(atPath: url.path) else { usage.settingsMessage = "所选文件不能执行。"; return }
            settings.customPath = url.path; usage.settingsMessage = ""; usage.refresh(force: true)
        }
    }
}

if CommandLine.arguments.contains("--check") {
    do {
        let snapshot = try CodexClient().fetch(customPath: UserDefaults.standard.string(forKey: "codexPath"))
        print("5 小时剩余：\(snapshot.primary.map { String($0.remaining) } ?? "未提供")%；每周剩余：\(snapshot.weekly.map { String($0.remaining) } ?? "未提供")%；套餐：\(snapshot.plan)")
        exit(0)
    } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
}
let app = NSApplication.shared
if let index = CommandLine.arguments.firstIndex(of: "--render-previews"), CommandLine.arguments.count > index + 1 {
    let folder = URL(fileURLWithPath: CommandLine.arguments[index + 1])
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for (name, width, textSize, dark, error, expanded) in [
        ("system", CGFloat(320), 0, false, false, false),
        ("large", CGFloat(416), 2, false, false, false),
        ("narrow-dark", CGFloat(240), 0, true, false, false),
        ("error-settings", CGFloat(320), 0, false, true, true)
    ] {
        let usage = Usage()
        usage.snapshot = try UsageSnapshot.parse(Data("{\"rateLimits\":{\"primary\":{\"usedPercent\":35,\"windowDurationMins\":300,\"resetsAt\":\(Date().addingTimeInterval(5400).timeIntervalSince1970)},\"secondary\":{\"usedPercent\":5,\"windowDurationMins\":10080,\"resetsAt\":\(Date().addingTimeInterval(432000).timeIntervalSince1970)},\"planType\":\"plus\"}}".utf8))
        usage.message = error ? "读取超时，请检查网络后重试。" : ""
        let settings = Settings(defaults: UserDefaults(suiteName: "local.codexusage.preview.\(UUID().uuidString)")!)
        settings.textSize = textSize; settings.showSettings = expanded
        let view = NSHostingView(rootView: UsageContent(usage: usage, settings: settings).frame(width: width))
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let height = ceil(view.fittingSize.height)
        view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { fatalError("preview bitmap") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let canvas = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: bitmap.pixelsWide, pixelsHigh: bitmap.pixelsHigh, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        canvas.size = view.bounds.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: canvas)
        (dark ? NSColor(calibratedWhite: 0.12, alpha: 1) : NSColor.white).setFill()
        view.bounds.fill()
        let rendered = NSImage(size: view.bounds.size)
        rendered.addRepresentation(bitmap)
        rendered.draw(in: view.bounds, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        if let data = canvas.representation(using: .png, properties: [:]) {
            try data.write(to: folder.appendingPathComponent(name + ".png"))
        }
        print("\(name): \(Int(width)) × \(Int(height)) pt")
    }
    exit(0)
}
let delegate = AppDelegate()
app.delegate = delegate
app.run()

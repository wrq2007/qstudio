import SwiftUI
import AppKit

@main
struct LocalModelApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Q Studio", id: "main") {
            LocaleHost {
                ContentView()
            }
            .background(WindowOpenRegistrar())
            .environmentObject(ServerController.shared)
            .environmentObject(ChatStore.shared)
            .environmentObject(LanguageManager.shared)
            .frame(minWidth: 860, minHeight: 520)
        }
        .defaultSize(width: 1040, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新对话") { ChatStore.shared.newSession() }
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(!ChatStore.shared.canCreateNewSession)
            }
            CommandGroup(after: .appInfo) {
                Button("重启推理服务") { ServerController.shared.restart() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
    }
}

/// 观察语言变化并重新注入 locale —— 语言切换后所有 Text 立即重新查表。
private struct LocaleHost<Content: View>: View {
    @EnvironmentObject private var lang: LanguageManager
    let content: () -> Content
    var body: some View {
        content().environment(\.locale, lang.language.locale)
    }
}

/// SwiftUI 销毁窗口后只有 `openWindow` 能把它重建出来，而 AppKit 侧（菜单栏、Dock 图标）
/// 拿不到这个 environment。这里在窗口出现时把 openWindow 存进一个全局钩子。
final class WindowOpener {
    static let shared = WindowOpener()
    var open: (() -> Void)?
}

struct WindowOpenRegistrar: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                WindowOpener.shared.open = { openWindow(id: "main") }
            }
    }
}

/// Sheet / 独立窗口的内容不会稳定继承外层的 `\.locale`（macOS 上表现为：
/// Text("中文") 仍是中文，而走 L() 的文案已经翻译）。所以每个 sheet 根部都套一层。
struct LocalizedEnvironment: ViewModifier {
    @ObservedObject private var lang = LanguageManager.shared
    func body(content: Content) -> some View {
        content.environment(\.locale, lang.language.locale)
    }
}

extension View {
    func localized() -> some View { modifier(LocalizedEnvironment()) }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        installSignalHandlers()
        MenuBarController.shared.install()
        if MathSelfTest.enabled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { MathSelfTest.run() }
        }
        if ProcessInfo.processInfo.environment["MDMSGTEST"] == "1"
            || UserDefaults.standard.bool(forKey: "MDMSGTEST") {
            // 等推理服务就绪再跑（最多等 60 秒）
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
                ChatStore.shared.selfTestMessages(server: ServerController.shared)
            }
        }
        if ProcessInfo.processInfo.environment["MDRPTEST"] == "1"
            || UserDefaults.standard.bool(forKey: "MDRPTEST") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { ChatStore.shared.dumpRoleTestIfNeeded() }
        }
        if ProcessInfo.processInfo.environment["MDMENUBAR"] == "1"
            || UserDefaults.standard.bool(forKey: "MDMENUBAR") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { MenuBarController.shared.selfTest() }
        }
        if ProcessInfo.processInfo.environment["MDTHINKTEST"] == "1"
            || UserDefaults.standard.bool(forKey: "MDTHINKTEST") {
            // 等模型加载完再发消息，否则测的是「没就绪」
            DispatchQueue.main.asyncAfter(deadline: .now() + 18) {
                ChatStore.shared.selfTestThink(server: ServerController.shared)
            }
        }
        if ProcessInfo.processInfo.environment["MDCOMPACTTEST"] == "1"
            || UserDefaults.standard.bool(forKey: "MDCOMPACTTEST") {
            // 等推理服务就绪（自检里会等到 isCompacting 结束再落盘）
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
                ChatStore.shared.selfTestCompact(server: ServerController.shared)
            }
        }
        if ProcessInfo.processInfo.environment["MDATTACHTEST"] == "1"
            || UserDefaults.standard.bool(forKey: "MDATTACHTEST") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
                ChatStore.shared.selfTestAttach(server: ServerController.shared)
            }
        }
        if ProcessInfo.processInfo.environment["MDSCROLLTEST"] == "1"
            || UserDefaults.standard.bool(forKey: "MDSCROLLTEST") {
            ScrollSelfTest.schedule()
        }
    }

    /// 被 kill / 注销 / 终端信号打断时也要回收推理子进程，否则它会变成孤儿一直占着显存。
    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                ServerController.shared.stopSync()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        ServerController.shared.stopSync()
    }

    /// 有菜单栏图标之后，关掉主窗口只是收起界面，不该退出程序——推理服务还能继续用
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// 点 Dock 图标时把主窗口找回来（窗口已被关掉就重新打开）
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MenuBarController.shared.showWindow() }
        return true
    }
}

import SwiftUI
import AppKit

@main
struct LocalModelApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Q Studio") {
            LocaleHost {
                ContentView()
            }
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

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

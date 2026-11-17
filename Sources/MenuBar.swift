import AppKit
import Combine

/// 菜单栏图标 + 下拉菜单：最近 5 个对话、退出程序。
/// 关掉主窗口后 app 继续驻留在菜单栏（见 AppDelegate.applicationShouldTerminateAfterLastWindowClosed）。
final class MenuBarController: NSObject, NSMenuDelegate {
    static let shared = MenuBarController()

    private var statusItem: NSStatusItem?
    /// 最多列几条最近对话
    private let recentLimit = 5

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let img = Self.icon()
            img?.isTemplate = true          // 模板图：系统按菜单栏深浅色自动反色
            button.image = img
            button.toolTip = "Q Studio"
        }
        let menu = NSMenu()
        menu.delegate = self                 // 每次弹出前重建，保证对话列表和语言都是最新的
        item.menu = menu
        statusItem = item
    }

    // MARK: - 图标

    private static func icon() -> NSImage? {
        for name in ["MenuIcon", "MenuIcon@2x"] {
            if let url = Bundle.main.url(forResource: name, withExtension: "png"),
               let img = NSImage(contentsOf: url) {
                img.size = NSSize(width: 18, height: 18)
                return img
            }
        }
        // 资源缺失时退回 SF Symbol，保证菜单栏永远有个能点的图标
        return NSImage(systemSymbolName: "bubble.left.and.bubble.right", accessibilityDescription: "Q Studio")
    }

    // MARK: - 菜单内容

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        // 主窗口被关掉时，给一个回到窗口的入口；窗口正常显示时不加这一条
        if !Self.mainWindowVisible() {
            let show = NSMenuItem(title: L("打开主窗口"), action: #selector(showWindow), keyEquivalent: "")
            show.target = self
            menu.addItem(show)
            menu.addItem(.separator())
        }

        let recent = ChatStore.shared.sessions
            .filter { !$0.archived }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(recentLimit)

        if recent.isEmpty {
            let empty = NSMenuItem(title: L("还没有对话"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            let header = NSMenuItem(title: L("最近对话"), action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for session in recent {
                let title = Self.shortTitle(session.displayTitle)
                let mi = NSMenuItem(title: title, action: #selector(openSession(_:)), keyEquivalent: "")
                mi.target = self
                mi.representedObject = session.id.uuidString
                mi.state = (ChatStore.shared.currentID == session.id) ? .on : .off
                menu.addItem(mi)
            }
        }

        menu.addItem(.separator())
        let quit = NSMenuItem(title: L("退出程序"), action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    /// 菜单里放不下长标题，掐掉中间太长的情况
    private static func shortTitle(_ s: String) -> String {
        let clean = s.replacingOccurrences(of: "\n", with: " ")
        if clean.count <= 24 { return clean }
        return String(clean.prefix(22)) + "…"
    }

    // MARK: - 动作

    @objc private func openSession(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let id = UUID(uuidString: raw) else { return }
        ChatStore.shared.select(id)
        showWindow()
    }

    @objc func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let w = Self.mainWindow() {
            w.makeKeyAndOrderFront(nil)
        } else if let open = WindowOpener.shared.open {
            // 窗口已经被 SwiftUI 销毁：用 openWindow 重建（AppKit 没有等价的公开接口）
            open()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                Self.mainWindow()?.makeKeyAndOrderFront(nil)
            }
        }
    }

    @objc private func quit() {
        ChatStore.shared.flushPending()
        NSApp.terminate(nil)
    }

    // MARK: - 自检（无法模拟鼠标点击，用这个把菜单内容写文件核对）

    /// MDMENUBAR=1 时由 AppDelegate 调用：重建菜单并把每条标题写进 /tmp/qstudio_menubar.txt，
    /// 然后真的触发一次「打开最近对话」，把切换后的 currentID 一起写进去。
    func selfTest() {
        var lines: [String] = []
        let winTest = ProcessInfo.processInfo.environment["MDWINTEST"] == "1"
            || UserDefaults.standard.bool(forKey: "MDWINTEST")

        // 先测窗口：关窗 → 看是否还在 → 用「打开主窗口」找回
        if winTest {
            Self.mainWindow()?.performClose(nil)
            Thread.sleep(forTimeInterval: 1.2)
            lines.append("关窗后: window=\(Self.mainWindow() != nil) visible=\(Self.mainWindowVisible()) 窗口数=\(NSApp.windows.count)")
            showWindow()
            Thread.sleep(forTimeInterval: 1.0)
            lines.append("showWindow 后: window=\(Self.mainWindow() != nil) visible=\(Self.mainWindowVisible()) 窗口数=\(NSApp.windows.count)")
        }

        guard let item = statusItem, let menu = item.menu else { return }
        menuNeedsUpdate(menu)
        lines.append("statusItem=\(item.button?.image != nil ? "icon" : "no-icon")")
        for (i, mi) in menu.items.enumerated() {
            if mi.isSeparatorItem { lines.append("\(i): ---"); continue }
            lines.append("\(i): \(mi.title) [enabled=\(mi.isEnabled) state=\(mi.state == .on ? "on" : "off")]")
        }
        // 触发一次「打开最近对话」，确认切换逻辑真的生效
        let before = ChatStore.shared.currentID?.uuidString ?? "nil"
        if let target = menu.items.first(where: { $0.action == #selector(openSession(_:)) }) {
            openSession(target)
        }
        let after = ChatStore.shared.currentID?.uuidString ?? "nil"
        lines.append("switch: \(before) -> \(after)")

        try? lines.joined(separator: "\n").write(toFile: "/tmp/qstudio_menubar.txt", atomically: true, encoding: .utf8)
    }

    // MARK: - 窗口查找

    private static func mainWindow() -> NSWindow? {
        NSApp.windows.first { $0.contentView != nil && $0.canBecomeMain && $0.level == .normal }
    }

    private static func mainWindowVisible() -> Bool {
        guard let w = mainWindow() else { return false }
        return w.isVisible && !w.isMiniaturized
    }
}

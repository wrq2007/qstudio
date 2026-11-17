import SwiftUI
import AppKit
import WebKit

/// 内联渲染模型输出的 SVG，高度按 viewBox 宽高比自适应。
///
/// 安全策略：WKWebView 关掉 JavaScript，并用导航代理拦截一切外部请求——
/// SVG 里的 <script>、外链图片、xlink:href 外部地址都不会被加载。
/// 高度不从网页里跑脚本测量，而是本地解析 viewBox/width/height 算比例，
/// 所以 JS 全程关闭，模型输出始终当不可信内容对待。
struct SVGView: View {
    let source: String
    @State private var loaded = false

    /// 从 SVG 里解析出的高/宽比（height ÷ width）
    private var aspectRatio: CGFloat {
        Self.parseRatio(from: source)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "square.on.square")
                    .font(.system(size: 10))
                Text("SVG 绘图")
                    .font(.system(size: 10, weight: .medium))
                Spacer(minLength: 4)
                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(source, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc").font(.system(size: 9.5))
                }
                .buttonStyle(.plain)
                .help("复制 SVG 源码")

                Button {
                    saveSVG()
                } label: {
                    Image(systemName: "square.and.arrow.down").font(.system(size: 9.5))
                }
                .buttonStyle(.plain)
                .help("保存为 .svg 文件")
            }
            .foregroundStyle(Color.secondary)
            .padding(.horizontal, 10)
            .padding(.top, 7)
            .padding(.bottom, 5)

            // 按可用宽度 × 宽高比算高度：图多高容器就多高，不再固定裁切
            GeometryReader { geo in
                let w = displayWidth(container: geo.size.width)
                let h = min(max(w * aspectRatio, 90), 900)
                ZStack {
                    SVGWebView(html: Self.wrap(source), loaded: $loaded)
                        .frame(width: w, height: h)
                        .background(Color.white)
                    // 渲染完成前显示「绘图中」
                    if !loaded {
                        VStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("绘图中…")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.secondary)
                        }
                        .frame(width: w, height: h)
                        .background(Color.white)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .frame(height: min(max(displayWidth(container: Self.estimatedWidth) * aspectRatio, 90), 900))
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.black.opacity(0.09), lineWidth: 0.8))
    }

    /// 没有 GeometryReader 可用时的估计宽度（气泡最大 560 减去内边距）
    private static let estimatedWidth: CGFloat = 520

    /// SVG 声明的原始宽度（viewBox 的 w 或 width 属性）；解析不到返回 nil
    static func parseWidth(from svg: String) -> CGFloat? {
        guard let open = firstMatch("<svg[^>]*>", in: svg) else { return nil }
        if let vb = firstMatch("viewBox\\s*=\\s*[\"']([^\"']+)[\"']", in: open, group: 1) {
            let nums = vb.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Double($0) }
            if nums.count >= 3, nums[2] > 0 { return CGFloat(nums[2]) }
        }
        if let ws = firstMatch("width\\s*=\\s*[\"']\\s*([0-9.]+)", in: open, group: 1),
           let w = Double(ws), w > 0 { return CGFloat(w) }
        return nil
    }

    /// 实际显示宽度：小图用原始尺寸，大图缩到容器宽
    private func displayWidth(container: CGFloat) -> CGFloat {
        if let native = Self.parseWidth(from: source), native < container { return native }
        return container
    }

    /// 解析高/宽比：优先 viewBox 的 w h，其次 width/height 属性，最后给个通用比例
    static func parseRatio(from svg: String) -> CGFloat {
        let openTag: String
        if let tag = firstMatch("<svg[^>]*>", in: svg) {
            openTag = tag
        } else {
            return 0.6
        }

        // viewBox="minx miny w h" → 取第 3、4 个数
        if let vb = firstMatch("viewBox\\s*=\\s*[\"']([^\"']+)[\"']", in: openTag, group: 1) {
            let nums = vb.split(whereSeparator: { $0 == " " || $0 == "," })
                       .compactMap { Double($0) }
            if nums.count >= 4, nums[2] > 0 { return CGFloat(nums[3] / nums[2]) }
        }
        // width / height 两个独立属性
        if let ws = firstMatch("width\\s*=\\s*[\"']\\s*([0-9.]+)", in: openTag, group: 1),
           let hs = firstMatch("height\\s*=\\s*[\"']\\s*([0-9.]+)", in: openTag, group: 1),
           let w = Double(ws), let h = Double(hs), w > 0 {
            return CGFloat(h / w)
        }
        return 0.6
    }

    /// 正则取第一个匹配；group 为 0 返回整段，>0 返回捕获组
    private static func firstMatch(_ pattern: String, in text: String, group: Int = 0) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, options: [], range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > group else { return nil }
        return ns.substring(with: m.range(at: group))
    }

    /// 把 SVG 包成最小 HTML。剥掉脚本/事件属性/外链，SVG 按容器等比缩放。
    /// 正则剥离只是第一层：真正兜底的是内容规则列表和导航白名单（见 NetworkBlocker / Coordinator）。
    private static func wrap(_ svg: String) -> String {
        var clean = svg
        let strips = [
            "<script[\\s\\S]*?</script>",
            "<foreignObject[\\s\\S]*?</foreignObject>",
            "\\son[a-zA-Z]+\\s*=\\s*(\"[^\"]*\"|'[^']*')",
            // href / xlink:href 指向外部协议的一律删掉（data: 是内联图片，保留）
            "(xlink:)?href\\s*=\\s*(\"|')\\s*(?:https?:|javascript:|file:|blob:|ftp:|wss?:|//)[^\"']*\\2",
            // <style> 里的外部引用：@import 整条删，url(外部) 删掉（url(#渐变) 保留）
            "@import[^;]*;",
            "url\\(\\s*[\"']?\\s*(?:https?:|file:|blob:|ftp:|wss?:|//)[^)]*\\)"
        ]
        for p in strips {
            if let re = try? NSRegularExpression(pattern: p, options: .caseInsensitive) {
                clean = re.stringByReplacingMatches(in: clean, options: [],
                                                    range: NSRange(location: 0, length: clean.utf16.count),
                                                    withTemplate: "")
            }
        }
        return """
        <!doctype html><html><head><meta charset="utf-8"><style>
        html,body{margin:0;padding:0;background:#fff;overflow:hidden;width:100%;height:100%;
                  display:flex;align-items:center;justify-content:center}
        /* 小图按原始尺寸显示不放大，大图才等比缩到容器宽；保持宽高比 */
        svg{display:block;max-width:100%;max-height:100%;height:auto;width:auto}
        </style></head><body>\(clean)</body></html>
        """
    }

    /// 自检用：把脱敏后的 HTML 写文件，方便核对哪些东西被剥掉了
    static func selfTestDump(_ svg: String) {
        try? wrap(svg).write(toFile: "/tmp/qstudio_svg_wrap.html", atomically: true, encoding: .utf8)
    }

    private func saveSVG() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "drawing.svg"
        panel.allowedContentTypes = [.init(filenameExtension: "svg")!]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? source.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// 阻断一切网络加载：一条内容规则列表覆盖所有子资源（<image href>、CSS url()、@font-face…）。
/// 编译是异步的，编译结果缓存在静态属性里，第二次起同步可用。
enum NetworkBlocker {
    private static var cached: WKContentRuleList?
    private static var compiling = false
    private static var waiters: [() -> Void] = []

    /// 三条规则分别拦 http(s)/ws(s)/ftp，比 `.*` 更保守，不会误伤 about:blank 与 data:
    private static let rules = """
    [
      {"trigger":{"url-filter":"^https?://.*","url-filter-is-case-sensitive":false},"action":{"type":"block"}},
      {"trigger":{"url-filter":"^wss?://.*","url-filter-is-case-sensitive":false},"action":{"type":"block"}},
      {"trigger":{"url-filter":"^ftp://.*","url-filter-is-case-sensitive":false},"action":{"type":"block"}}
    ]
    """

    static func apply(to web: WKWebView, then done: @escaping () -> Void) {
        if let list = cached {
            web.configuration.userContentController.add(list)
            done()
            return
        }
        waiters.append(done)
        if compiling { return }
        compiling = true
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "block-network",
            encodedContentRuleList: rules
        ) { list, _ in
            DispatchQueue.main.async {
                compiling = false
                cached = list
                if let list {
                    web.configuration.userContentController.add(list)
                }
                let pending = waiters
                waiters = []
                pending.forEach { $0() }
            }
        }
    }
}

/// WKWebView 的 SwiftUI 包装。JS 关闭 + 内容规则列表断网 + 导航白名单。
private struct SVGWebView: NSViewRepresentable {
    let html: String
    @Binding var loaded: Bool

    func makeCoordinator() -> Coordinator { Coordinator(loaded: $loaded) }

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        // 两道开关都关：preferences 是旧接口，allowsContentJavaScript 是新接口
        cfg.preferences.javaScriptEnabled = false
        cfg.defaultWebpagePreferences.allowsContentJavaScript = false
        cfg.allowsAirPlayForMediaPlayback = false
        cfg.websiteDataStore = .nonPersistent()      // 不留 cookie / 缓存
        let web = WKWebView(frame: .zero, configuration: cfg)
        web.navigationDelegate = context.coordinator
        web.allowsMagnification = false
        // 规则列表装好再加载，避免第一帧抢跑发出请求
        NetworkBlocker.apply(to: web) {
            web.loadHTMLString(html, baseURL: nil)
        }
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        // html 变化时重载（同一条消息重绘时源码不变，不必重复加载）
        if web.url == nil { web.loadHTMLString(html, baseURL: nil) }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private var loaded: Binding<Bool>
        init(loaded: Binding<Bool>) { self.loaded = loaded }

        /// 页面渲染完成后通知 SwiftUI 撤掉「绘图中」
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.async { self.loaded.wrappedValue = true }
        }

        func webView(_ webView: WKWebView,
                     didFail navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async { self.loaded.wrappedValue = true }
        }

        /// 白名单：只放行 about: / data:（页面本体和 data: 内联图），其余一律取消。
        /// 白名单比黑名单安全——将来出现新的 scheme 也不会漏。
        private static func isAllowed(_ url: URL?) -> Bool {
            guard let scheme = url?.scheme?.lowercased() else { return true }   // 无 scheme = 本地 HTML
            return scheme == "about" || scheme == "data"
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(Self.isAllowed(navigationAction.request.url) ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationResponse: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            decisionHandler(Self.isAllowed(navigationResponse.response.url) ? .allow : .cancel)
        }

        /// 任何失败（包括被我们拦掉的请求）都要撤掉「绘图中」，否则界面会一直转圈
        func webView(_ webView: WKWebView,
                     didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            DispatchQueue.main.async { self.loaded.wrappedValue = true }
        }
    }
}

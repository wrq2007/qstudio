import SwiftUI
import WebKit

/// 公式渲染：一个专用的 WKWebView，只跑 KaTeX。
///
/// 和 SVG 那条链路刻意分开：
/// - SVG：JS 双关 + 断网（内容不可信，只做展示）
/// - 公式：JS 必须开（KaTeX 是 JS 渲染器），但页面内容完全由我们生成，
///   LaTeX 以 JSON 字符串注入并做 `</` 转义，KaTeX 用 trust:false 禁用 \href 之类的输出，
///   网络仍然用同一套内容规则全部阻断，文件访问只放开临时目录。
enum MathAssets {
    /// 首次使用时把 bundle 里的 KaTeX 拷到临时目录：loadFileURL 要求页面和资源同根
    static let directory: URL? = {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("qstudio-katex")
        let bundleDir = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/katex")
        do {
            try fm.createDirectory(at: base, withIntermediateDirectories: true)
            for name in ["katex.min.js", "katex.min.css"] {
                let dst = base.appendingPathComponent(name)
                if !fm.fileExists(atPath: dst.path) {
                    try fm.copyItem(at: bundleDir.appendingPathComponent(name), to: dst)
                }
            }
            let fontsSrc = bundleDir.appendingPathComponent("fonts")
            let fontsDst = base.appendingPathComponent("fonts")
            if !fm.fileExists(atPath: fontsDst.path) {
                try fm.copyItem(at: fontsSrc, to: fontsDst)
            }
            return base
        } catch {
            return nil
        }
    }()

    /// 把 LaTeX 安全地嵌进 <script>：JSON 编码 + 切断 </script> 逃逸
    static func jsString(_ s: String) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = []
        guard let data = try? enc.encode(s), let json = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return json.replacingOccurrences(of: "</", with: "<\\/")
    }

    static func html(latex: String, display: Bool, fontSize: CGFloat, color: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <link rel="stylesheet" href="katex.min.css">
        <style>
          html,body{margin:0;padding:0;background:transparent;overflow:hidden;}
          body{color:\(color);}
          #m{display:inline-block;font-size:\(Int(fontSize))px;padding:1px 2px;}
          .err{font-family:-apple-system;font-size:\(Int(fontSize))px;color:#b4462b;}
        </style>
        <script src="katex.min.js"></script>
        </head><body><div id="m"></div>
        <script>
          var host = document.getElementById('m');
          try {
            katex.render(\(jsString(latex)), host, {
              displayMode: \(display ? "true" : "false"),
              throwOnError: false,
              trust: false,
              strict: false
            });
          } catch (e) {
            host.className = 'err';
            host.textContent = String(e).slice(0, 120);
          }
          function report() {
            var r = document.body.getBoundingClientRect();
            window.webkit.messageHandlers.size.postMessage({
              w: Math.ceil(r.width), h: Math.ceil(r.height)
            });
          }
          report();
          window.addEventListener('load', report);
        </script></body></html>
        """
    }
}

/// MDMATHTEST=1：无界面自检。加载两条公式，确认 KaTeX 真的渲染出了 .katex 节点，
/// 并把结果写到 /tmp/qstudio_math.txt（屏幕锁着时也能核对）。
@MainActor
enum MathSelfTest {
    static var enabled: Bool {
        ProcessInfo.processInfo.environment["MDMATHTEST"] == "1"
            || UserDefaults.standard.bool(forKey: "MDMATHTEST")
    }

    static func run() {
        guard let dir = MathAssets.directory else {
            write("MathAssets 目录准备失败"); return
        }
        try? MathAssets.html(latex: "E = mc^2", display: false, fontSize: 13.5, color: "#1f1f21")
            .write(to: dir.appendingPathComponent("selftest.html"), atomically: true, encoding: .utf8)

        let cfg = WKWebViewConfiguration()
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        cfg.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 500, height: 200), configuration: cfg)
        // 关掉可见性也无所谓，这里只跑 JS
        NetworkBlocker.apply(to: web) {
            web.loadFileURL(dir.appendingPathComponent("selftest.html"), allowingReadAccessTo: dir)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                let js = """
                (function(){
                  var k = document.querySelector('.katex');
                  var e = document.querySelector('.err');
                  return JSON.stringify({
                    katex: !!k,
                    err: e ? e.textContent : null,
                    html: k ? k.innerHTML.length : 0,
                    text: document.body.innerText.slice(0,60)
                  });
                })()
                """
                web.evaluateJavaScript(js) { result, error in
                    if let error { write("JS 执行失败：\(error.localizedDescription)"); return }
                    write("结果：\(result ?? "nil")")
                }
            }
        }
    }

    private static func write(_ s: String) {
        try? s.write(toFile: "/tmp/qstudio_math.txt", atomically: true, encoding: .utf8)
    }
}

/// 单条公式。尺寸由网页回报，SwiftUI 据此排版。
struct MathBlock: View {
    let latex: String
    var display: Bool = true
    var fontSize: CGFloat = 13.5

    @State private var size = CGSize(width: 40, height: 24)

    var body: some View {
        MathWebView(latex: latex, display: display, fontSize: fontSize) { s in
            if abs(s.width - size.width) > 0.5 || abs(s.height - size.height) > 0.5 {
                size = s
            }
        }
        .frame(width: min(size.width, 620), height: max(size.height, 18))
        .fixedSize()
    }
}

private struct MathWebView: NSViewRepresentable {
    let latex: String
    let display: Bool
    let fontSize: CGFloat
    let onSize: (CGSize) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSize: onSize, directory: MathAssets.directory) }

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        // 这里是唯一开 JS 的地方：KaTeX 本身是 JS 渲染器
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        cfg.preferences.javaScriptEnabled = true
        cfg.websiteDataStore = .nonPersistent()
        cfg.userContentController.add(context.coordinator, name: "size")

        let web = WKWebView(frame: .zero, configuration: cfg)
        web.navigationDelegate = context.coordinator
        web.setValue(false, forKey: "drawsBackground")
        web.allowsMagnification = false

        // 网络照样全断：只允许文件与 about/data
        NetworkBlocker.apply(to: web) {
            context.coordinator.load(latex: latex, display: display,
                                     fontSize: fontSize, in: web)
        }
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        context.coordinator.load(latex: latex, display: display, fontSize: fontSize, in: web)
    }

    static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) {
        web.configuration.userContentController.removeScriptMessageHandler(forName: "size")
        web.stopLoading()
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let onSize: (CGSize) -> Void
        let directory: URL?
        private var lastKey: String = ""
        private var pending = false

        init(onSize: @escaping (CGSize) -> Void, directory: URL?) {
            self.onSize = onSize
            self.directory = directory
        }

        func load(latex: String, display: Bool, fontSize: CGFloat, in web: WKWebView) {
            let key = "\(display)|\(fontSize)|\(latex)"
            guard key != lastKey else { return }
            lastKey = key
            guard let dir = directory else { return }
            let html = MathAssets.html(latex: latex, display: display,
                                       fontSize: fontSize, color: "#1f1f21")
            let file = dir.appendingPathComponent("formula.html")
            guard (try? html.write(to: file, atomically: true, encoding: .utf8)) != nil else { return }
            web.loadFileURL(file, allowingReadAccessTo: dir)
        }

        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any],
                  let w = body["w"] as? Double, let h = body["h"] as? Double else { return }
            DispatchQueue.main.async { self.onSize(CGSize(width: w, height: h)) }
        }

        /// 只允许本地文件与 about:，其他一律取消（纵深防御）
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let scheme = navigationAction.request.url?.scheme?.lowercased() ?? "file"
            decisionHandler((scheme == "file" || scheme == "about") ? .allow : .cancel)
        }
    }
}

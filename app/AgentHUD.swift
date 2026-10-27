// Agent HUD 네이티브 셸. 화면(WKWebView)은 기존 대시보드를 그대로 쓰고, 번들에 든 server.py를 엔진으로 띄운다.
// 무거운 일(엔진 기동, 응답 대기)은 전부 메인 스레드 밖에서 하므로 창은 처음부터 끝까지 멈추지 않는다.
import Cocoa
@preconcurrency import WebKit

let env = ProcessInfo.processInfo.environment
let port = env["AGENT_HUD_PORT"] ?? "41717"
let base = URL(string: "http://127.0.0.1:\(port)")!
let korean = Locale.preferredLanguages.first?.hasPrefix("ko") ?? false
func tr(_ en: String, _ ko: String) -> String { korean ? ko : en }

// 대시보드 CSS의 --bg 와 같은 색. 페이지가 그려지기 전에도 창이 흰 번쩍임 없이 같은 색이다.
let background = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    ? NSColor(srgbRed: 0x14 / 255, green: 0x15 / 255, blue: 0x0f / 255, alpha: 1)
    : NSColor(srgbRed: 0xee / 255, green: 0xef / 255, blue: 0xe9 / 255, alpha: 1) }

// MARK: - 엔진

final class Engine {
    private(set) var process: Process?

    /// 이미 떠 있는 대시보드(다른 앱 창, 세션 훅이 띄운 것 등)가 있으면 true.
    func alive() async -> Bool {
        var req = URLRequest(url: base.appendingPathComponent("manifest.json"), timeoutInterval: 0.5)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (_, res) = try? await URLSession.shared.data(for: req) else { return false }
        return (res as? HTTPURLResponse)?.statusCode == 200
    }

    /// 번들의 server.py를 띄운다. 이 앱이 띄운 것만 종료 때 같이 끈다.
    func launch() -> Bool {
        process?.terminate()  // 다시 시도할 때 앞서 띄운 것이 포트를 붙들고 남지 않게 한다
        guard let script = Bundle.main.path(forResource: "server", ofType: "py"),
              let python = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
                .first(where: FileManager.default.isExecutableFile) else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: python)
        p.arguments = [script]
        // 데이터 위치는 brew/install.sh 설치와 같다 -- 그룹과 프로젝트 목록이 그대로 이어진다.
        p.environment = env.merging([
            "AGENT_HUD_NO_BROWSER": "1",
            "AGENT_HUD_HOME": env["AGENT_HUD_HOME"] ?? NSHomeDirectory() + "/.claude/tools/agent-hud",
        ]) { $1 }
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        process = p
        return true
    }

    func stop() { process?.terminate() }
}

// MARK: - 창

final class Controller: NSObject, NSApplicationDelegate, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate,
                        WKScriptMessageHandlerWithReply {
    let engine = Engine()
    var window: NSWindow!
    var web: WKWebView!
    let spinner = NSProgressIndicator()
    let message = NSStackView()
    let label = NSTextField(labelWithString: "")

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildMenu()
        buildWindow()
        NSApp.activate(ignoringOtherApps: true)
        boot()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ note: Notification) { engine.stop() }

    func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 820),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Agent HUD"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = background
        window.minSize = NSSize(width: 760, height: 520)
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("main")
        window.isReleasedWhenClosed = false

        let config = WKWebViewConfiguration()
        // '앱으로 설치' 버튼은 브라우저용이다. 앱 창 안에서는 필요 없다.
        config.userContentController.addUserScript(WKUserScript(
            source: "document.getElementById('installWrap').style.display='none'",
            injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        config.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "pickFolder")
        web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.underPageBackgroundColor = background
        web.alphaValue = 0  // 처음 그려질 때까지 숨겨 두고 부드럽게 나타낸다

        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isIndeterminate = true
        spinner.translatesAutoresizingMaskIntoConstraints = false

        label.textColor = .secondaryLabelColor
        let retry = NSButton(title: tr("Retry", "다시 시도"), target: self, action: #selector(retryBoot))
        message.orientation = .vertical
        message.spacing = 12
        message.addArrangedSubview(label)
        message.addArrangedSubview(retry)
        message.isHidden = true
        message.translatesAutoresizingMaskIntoConstraints = false

        let content = window.contentView!
        web.frame = content.bounds
        web.autoresizingMask = [.width, .height]
        content.addSubview(spinner)
        content.addSubview(message)
        content.addSubview(web)  // 맨 위: 페이지가 나타나면 스피너를 덮는다
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            message.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            message.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
        window.makeKeyAndOrderFront(nil)
    }

    // 창은 이미 떠 있다. 엔진 확인과 기동은 백그라운드에서 하고, 준비되면 페이지를 연다.
    func boot() {
        message.isHidden = true
        spinner.isHidden = false
        spinner.startAnimation(nil)
        Task.detached { [engine] in
            var up = await engine.alive()
            if !up {
                guard engine.launch() else { return await self.fail(tr("Python 3 was not found.", "Python 3를 찾지 못했습니다.")) }
                for _ in 0..<200 {  // 최대 10초, 50ms 간격
                    if await engine.alive() { up = true; break }
                    if engine.process?.isRunning == false { break }
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
            }
            if up { await MainActor.run { _ = self.web.load(URLRequest(url: base)) } }
            else { await self.fail(tr("The dashboard did not start. Is another program using port \(port)?",
                                      "대시보드가 시작되지 않았습니다. 포트 \(port)를 다른 프로그램이 쓰고 있지 않은지 확인해 주십시오.")) }
        }
    }

    @MainActor func fail(_ text: String) {
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        label.stringValue = text
        message.isHidden = false
    }

    @objc func retryBoot() { boot() }

    // MARK: WKNavigationDelegate

    func webView(_ w: WKWebView, didFinish nav: WKNavigation!) {
        spinner.stopAnimation(nil)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.18; w.animator().alphaValue = 1 }
    }

    func webView(_ w: WKWebView, didFailProvisionalNavigation nav: WKNavigation!, withError e: Error) {
        w.alphaValue = 0
        fail(tr("Lost connection to the dashboard.", "대시보드와 연결이 끊겼습니다."))
    }

    // 대시보드 밖 주소는 기본 브라우저로 보낸다.
    func webView(_ w: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url, url.host != "127.0.0.1", url.scheme?.hasPrefix("http") == true else {
            return decisionHandler(.allow)
        }
        NSWorkspace.shared.open(url)
        decisionHandler(.cancel)
    }

    func webView(_ w: WKWebView, createWebViewWith c: WKWebViewConfiguration, for a: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = a.request.url { NSWorkspace.shared.open(url) }  // target=_blank 링크
        return nil
    }

    // 폴더 추가: 서버가 osascript로 띄우면 몇 초 걸리므로, 앱이 네이티브 창을 바로 띄우고 경로를 돌려준다.
    // 취소하면 빈 문자열.
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = tr("Add", "추가")
        panel.beginSheetModal(for: window) { replyHandler($0 == .OK ? panel.url?.path ?? "" : "", nil) }
    }

    // MARK: WKUIDelegate — 페이지의 alert/confirm/prompt 는 이걸 구현하지 않으면 아무 일도 일어나지 않는다.

    private func sheet(_ text: String, buttons: [String], accessory: NSView? = nil,
                       done: @escaping (NSApplication.ModalResponse) -> Void) {
        let a = NSAlert()
        a.messageText = text
        buttons.forEach { a.addButton(withTitle: $0) }
        a.accessoryView = accessory
        a.beginSheetModal(for: window, completionHandler: done)
    }

    func webView(_ w: WKWebView, runJavaScriptAlertPanelWithMessage m: String, initiatedByFrame f: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        sheet(m, buttons: ["OK"]) { _ in completionHandler() }
    }

    func webView(_ w: WKWebView, runJavaScriptConfirmPanelWithMessage m: String, initiatedByFrame f: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        sheet(m, buttons: ["OK", tr("Cancel", "취소")]) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    func webView(_ w: WKWebView, runJavaScriptTextInputPanelWithPrompt p: String, defaultText: String?,
                 initiatedByFrame f: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = defaultText ?? ""
        sheet(p, buttons: ["OK", tr("Cancel", "취소")], accessory: field) {
            completionHandler($0 == .alertFirstButtonReturn ? field.stringValue : nil)
        }
    }

    // MARK: 메뉴 (⌘C/⌘V 같은 편집 단축키도 메뉴가 있어야 웹뷰에 전달된다)

    func buildMenu() {
        func item(_ title: String, _ sel: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command,
                  target: AnyObject? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.target = target
            return i
        }
        func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let m = NSMenu(title: title)
            items.forEach(m.addItem)
            let host = NSMenuItem(); host.submenu = m
            return host
        }
        let main = NSMenu()
        main.addItem(menu("Agent HUD", [
            item(tr("About Agent HUD", "Agent HUD 정보"), #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item(tr("Hide Agent HUD", "Agent HUD 가리기"), #selector(NSApplication.hide(_:)), "h"),
            item(tr("Quit Agent HUD", "Agent HUD 종료"), #selector(NSApplication.terminate(_:)), "q"),
        ]))
        main.addItem(menu(tr("Edit", "편집"), [
            item(tr("Undo", "실행 취소"), Selector(("undo:")), "z"),
            item(tr("Redo", "다시 실행"), Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item(tr("Cut", "오려두기"), #selector(NSText.cut(_:)), "x"),
            item(tr("Copy", "복사하기"), #selector(NSText.copy(_:)), "c"),
            item(tr("Paste", "붙여넣기"), #selector(NSText.paste(_:)), "v"),
            item(tr("Select All", "전체 선택"), #selector(NSText.selectAll(_:)), "a"),
        ]))
        main.addItem(menu(tr("View", "보기"), [
            item(tr("Reload", "새로 고침"), #selector(reload), "r", target: self),
            .separator(),
            item(tr("Actual Size", "실제 크기"), #selector(zoom(_:)), "0", target: self),
            item(tr("Zoom In", "확대"), #selector(zoom(_:)), "=", target: self),
            item(tr("Zoom Out", "축소"), #selector(zoom(_:)), "-", target: self),
            .separator(),
            item(tr("Enter Full Screen", "전체 화면"), #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ]))
        main.addItem(menu(tr("Window", "윈도우"), [
            item(tr("Minimize", "최소화"), #selector(NSWindow.performMiniaturize(_:)), "m"),
            item(tr("Zoom", "확대/축소"), #selector(NSWindow.performZoom(_:))),
            item(tr("Close", "닫기"), #selector(NSWindow.performClose(_:)), "w"),
        ]))
        NSApp.mainMenu = main
    }

    @objc func reload() { web.reload() }

    @objc func zoom(_ sender: NSMenuItem) {
        switch sender.keyEquivalent {
        case "0": web.pageZoom = 1
        case "=": web.pageZoom = min(web.pageZoom + 0.1, 2.5)
        default: web.pageZoom = max(web.pageZoom - 0.1, 0.5)
        }
    }
}

@main
struct AgentHUD {
    static func main() {
        let app = NSApplication.shared
        let controller = Controller()
        app.delegate = controller
        app.run()
        _ = controller  // delegate는 weak 참조라 run()이 끝날 때까지 붙들어 둔다
    }
}

import Cocoa
import WebKit
import UniformTypeIdentifiers

/// 호스트 앱. Quick Look 확장을 담아 시스템에 등록시키는 역할이 주 목적이며,
/// 확장 없이도 렌더링 결과를 바로 확인할 수 있는 뷰어를 함께 제공한다.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var previewWindows: [NSWindow] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildMenu()

        // 실행 인자로 받은 EPUB은 바로 연다. (예: EPUBQuickLook book.epub)
        for argument in CommandLine.arguments.dropFirst() where argument.hasSuffix(".epub") {
            openPreview(URL(fileURLWithPath: argument))
        }

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 380),
                          styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "EPUB Quick Look"
        window.center()
        window.contentView = makeContentView()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach(openPreview)
    }

    private func makeContentView() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 32, left: 32, bottom: 32, right: 32)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "EPUB Quick Look")
        title.font = .systemFont(ofSize: 22, weight: .semibold)

        let body = NSTextField(wrappingLabelWithString: """
        Finder에서 .epub 파일을 선택하고 스페이스바를 누르면 본문 미리보기가, \
        아이콘에는 책 표지가 표시됩니다.

        미리보기가 보이지 않으면 이 앱을 응용 프로그램 폴더로 옮긴 뒤 한 번 실행하고, \
        시스템 설정 › 일반 › 로그인 항목 및 확장 프로그램 › Quick Look에서 활성화되어 있는지 확인하세요.
        """)
        body.alignment = .center
        body.textColor = .secondaryLabelColor
        body.preferredMaxLayoutWidth = 420

        let openButton = NSButton(title: "EPUB 열어서 미리보기 확인…", target: self,
                                  action: #selector(chooseFile))
        openButton.bezelStyle = .rounded
        openButton.keyEquivalent = "\r"

        stack.addArrangedSubview(title)
        stack.addArrangedSubview(body)
        stack.addArrangedSubview(openButton)

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        return container
    }

    private func buildMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "EPUB 열기…", action: #selector(chooseFile), keyEquivalent: "o")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "EPUB Quick Look 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "편집")
        editMenu.addItem(withTitle: "복사", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "전체 선택", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    @objc private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if let type = UTType(filenameExtension: "epub") {
            panel.allowedContentTypes = [type]
        }
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.openPreview(url)
        }
    }

    private func openPreview(_ url: URL) {
        do {
            let document = try EPUBDocument(url: url)
            let output = try PreviewHTMLBuilder(document: document).build()

            let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 760, height: 900))
            webView.navigationDelegate = self
            webView.loadFileURL(output.htmlURL, allowingReadAccessTo: output.rootURL)

            let previewWindow = NSWindow(contentRect: webView.frame,
                                         styleMask: [.titled, .closable, .resizable, .miniaturizable],
                                         backing: .buffered, defer: false)
            previewWindow.title = document.displayTitle
            previewWindow.contentView = webView
            previewWindow.center()
            previewWindow.isReleasedWhenClosed = false
            previewWindow.makeKeyAndOrderFront(nil)
            previewWindows.append(previewWindow)
        } catch {
            let alert = NSAlert()
            alert.messageText = "EPUB을 열 수 없습니다."
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}

extension AppDelegate: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        NSLog("[EPUBQuickLook] 미리보기 로드 완료: %@", webView.url?.absoluteString ?? "nil")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        NSLog("[EPUBQuickLook] 미리보기 로드 실패: %@", error.localizedDescription)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        NSLog("[EPUBQuickLook] 미리보기 로드 실패(초기): %@", error.localizedDescription)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

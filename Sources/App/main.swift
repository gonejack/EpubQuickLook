import Cocoa
import WebKit
import UniformTypeIdentifiers

/// Hosts and registers the Quick Look extensions with the system.
/// Includes a viewer for checking rendered previews without using the extensions.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var previewWindows: [NSWindow] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildMenu()

        // Open EPUB files passed as command-line arguments (for example, EPUBQuickLook book.epub).
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
        Select an .epub file in Finder and press the space bar to preview its contents. \
        The file icon displays the book cover.

        If previews do not appear, move this app to the Applications folder and launch it once. \
        Then check that its extensions are enabled in System Settings › General › Login Items & Extensions › Quick Look.
        """)
        body.alignment = .center
        body.textColor = .secondaryLabelColor
        body.preferredMaxLayoutWidth = 420

        let openButton = NSButton(title: "Open EPUB to Preview…", target: self,
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
        appMenu.addItem(withTitle: "Open EPUB…", action: #selector(chooseFile), keyEquivalent: "o")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit EPUB Quick Look", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
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
            alert.messageText = "Unable to open the EPUB file."
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}

extension AppDelegate: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        NSLog("[EPUBQuickLook] Preview loaded: %@", webView.url?.absoluteString ?? "nil")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        NSLog("[EPUBQuickLook] Preview loading failed: %@", error.localizedDescription)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        NSLog("[EPUBQuickLook] Initial preview loading failed: %@", error.localizedDescription)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

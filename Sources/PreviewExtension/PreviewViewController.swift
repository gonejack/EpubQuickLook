import Cocoa
import QuickLookUI
import WebKit

/// Converts EPUB files to HTML and displays them in a WKWebView for Quick Look previews.
@objc(PreviewViewController)
final class PreviewViewController: NSViewController, QLPreviewingController {

    private var webView: WKWebView?
    private var messageLabel: NSTextField!
    private var temporaryDirectory: URL?
    private var previewHTMLURL: URL?
    private var previewGeneration = UUID()
    private var isPreviewHidden = false

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 900))
        container.wantsLayer = true

        messageLabel = NSTextField(labelWithString: "")
        messageLabel.alignment = .center
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.font = .systemFont(ofSize: 13)
        messageLabel.isHidden = true
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(messageLabel)
        NSLayoutConstraint.activate([
            messageLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            messageLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            messageLabel.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -40)
        ])

        self.view = container
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        isPreviewHidden = false
        displayPreviewIfNeeded()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        isPreviewHidden = true
        releaseWebView()
    }

    // MARK: - QLPreviewingController

    func preparePreviewOfFile(at url: URL) async throws {
        _ = view
        releaseWebView()
        removeTemporaryDirectory()
        previewHTMLURL = nil
        messageLabel.isHidden = true
        let generation = UUID()
        previewGeneration = generation

        // Parse and extract the archive in the background.
        let result: Result<PreviewHTMLBuilder.Output, Error> = await Task.detached(priority: .userInitiated) {
            do {
                let document = try EPUBDocument(url: url)
                let builder = PreviewHTMLBuilder(document: document)
                return .success(try builder.build())
            } catch {
                return .failure(error)
            }
        }.value

        // Discard an older request if the host has already selected another file.
        guard generation == previewGeneration, !Task.isCancelled else {
            if case .success(let output) = result {
                try? FileManager.default.removeItem(at: output.rootURL)
            }
            throw CancellationError()
        }

        switch result {
        case .success(let output):
            temporaryDirectory = output.rootURL
            previewHTMLURL = output.htmlURL
            displayPreviewIfNeeded()
        case .failure(let error):
            showMessage("Unable to open the EPUB file.\n\(error.localizedDescription)")
            throw error
        }
    }

    private func displayPreviewIfNeeded() {
        guard !isPreviewHidden, webView == nil,
              let previewHTMLURL, let temporaryDirectory else { return }

        let configuration = WKWebViewConfiguration()
        configuration.suppressesIncrementalRendering = false
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.isElementFullscreenEnabled = false
        configuration.websiteDataStore = .nonPersistent()

        let webView = WKWebView(frame: view.bounds, configuration: configuration)
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        view.addSubview(webView, positioned: .below, relativeTo: messageLabel)
        self.webView = webView
        webView.loadFileURL(previewHTMLURL, allowingReadAccessTo: temporaryDirectory)
    }

    private func releaseWebView() {
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.removeFromSuperview()
        webView = nil
    }

    private func removeTemporaryDirectory() {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
    }

    private func showMessage(_ text: String) {
        messageLabel.stringValue = text
        messageLabel.isHidden = false
        releaseWebView()
    }

    deinit {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }
}

// MARK: - Navigation Restrictions

extension PreviewViewController: WKNavigationDelegate {
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Allow only the initial load and anchor navigation within the same document.
        switch navigationAction.navigationType {
        case .linkActivated:
            let isSameDocumentAnchor = navigationAction.request.url?.fragment != nil
                && navigationAction.request.url?.path == webView.url?.path
            decisionHandler(isSameDocumentAnchor ? .allow : .cancel)
        case .other, .reload:
            decisionHandler(.allow)
        default:
            decisionHandler(.cancel)
        }
    }
}

import Cocoa
import QuickLookUI
import WebKit

/// Converts EPUB files to HTML and displays them in a WKWebView for Quick Look previews.
@objc(PreviewViewController)
final class PreviewViewController: NSViewController, QLPreviewingController {

    private var webView: WKWebView!
    private var messageLabel: NSTextField!
    private var temporaryDirectory: URL?

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 900))
        container.wantsLayer = true

        let configuration = WKWebViewConfiguration()
        configuration.suppressesIncrementalRendering = false
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.isElementFullscreenEnabled = false

        webView = WKWebView(frame: container.bounds, configuration: configuration)
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        container.addSubview(webView)

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

    // MARK: - QLPreviewingController

    func preparePreviewOfFile(at url: URL) async throws {
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

        switch result {
        case .success(let output):
            temporaryDirectory = output.rootURL
            webView.loadFileURL(output.htmlURL, allowingReadAccessTo: output.rootURL)
        case .failure(let error):
            showMessage("Unable to open the EPUB file.\n\(error.localizedDescription)")
            throw error
        }
    }

    private func showMessage(_ text: String) {
        messageLabel.stringValue = text
        messageLabel.isHidden = false
        webView.isHidden = true
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

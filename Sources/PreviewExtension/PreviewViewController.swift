import Cocoa
import QuickLookUI
import WebKit

/// Quick Look 미리보기 본체. EPUB을 HTML로 변환해 WKWebView로 보여준다.
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
        // 파싱과 압축 해제는 백그라운드에서 수행한다.
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
            showMessage("EPUB을 열 수 없습니다.\n\(error.localizedDescription)")
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

// MARK: - 내비게이션 제한

extension PreviewViewController: WKNavigationDelegate {
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // 미리보기에서는 최초 로드와 같은 문서 내 앵커 이동만 허용한다.
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

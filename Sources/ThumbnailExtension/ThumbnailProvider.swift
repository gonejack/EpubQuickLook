import Cocoa
import QuickLookThumbnailing

/// Draws the book cover as the Finder icon or thumbnail, falling back to a cover generated from the title.
@objc(ThumbnailProvider)
final class ThumbnailProvider: QLThumbnailProvider {

    override func provideThumbnail(for request: QLFileThumbnailRequest,
                                   _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        let maxSize = request.maximumSize

        guard let document = try? EPUBDocument(url: request.fileURL) else {
            handler(nil, CocoaError(.fileReadCorruptFile))
            return
        }

        let coverImage: NSImage? = document.coverImageData.flatMap { NSImage(data: $0) }
        let aspect: CGFloat = {
            if let size = coverImage?.size, size.width > 0, size.height > 0 {
                return size.width / size.height
            }
            return 0.66   // Typical book cover aspect ratio
        }()

        // Fit the drawing context within the maximum size while preserving the aspect ratio.
        var width = maxSize.height * aspect
        var height = maxSize.height
        if width > maxSize.width {
            width = maxSize.width
            height = maxSize.width / aspect
        }
        let contextSize = CGSize(width: max(width.rounded(), 1), height: max(height.rounded(), 1))

        let title = document.displayTitle
        let author = document.authorText

        let reply = QLThumbnailReply(contextSize: contextSize) { context -> Bool in
            let rect = CGRect(origin: .zero, size: contextSize)

            if let coverImage, let cgImage = coverImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                context.interpolationQuality = .high
                context.draw(cgImage, in: rect)
            } else {
                ThumbnailProvider.drawFallbackCover(in: context, rect: rect, title: title, author: author)
            }
            return true
        }

        handler(reply, nil)
    }

    /// Draws a solid-color cover with the title and author when no cover image is available.
    private static func drawFallbackCover(in context: CGContext, rect: CGRect,
                                          title: String, author: String) {
        context.setFillColor(CGColor(red: 0.20, green: 0.27, blue: 0.38, alpha: 1))
        context.fill(rect)

        // Add a vertical strip to suggest the book spine.
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.18))
        context.fill(CGRect(x: 0, y: 0, width: rect.width * 0.08, height: rect.height))

        let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext

        let inset = rect.width * 0.14
        let titleSize = max(rect.width * 0.11, 7)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail

        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: titleSize, weight: .semibold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph
        ]
        let titleRect = CGRect(x: inset, y: rect.height * 0.30,
                               width: rect.width - inset * 2, height: rect.height * 0.45)
        (title as NSString).draw(with: titleRect, options: [.usesLineFragmentOrigin],
                                 attributes: titleAttributes)

        if !author.isEmpty, rect.height > 60 {
            let authorAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: max(titleSize * 0.7, 6)),
                .foregroundColor: NSColor.white.withAlphaComponent(0.75),
                .paragraphStyle: paragraph
            ]
            let authorRect = CGRect(x: inset, y: rect.height * 0.14,
                                    width: rect.width - inset * 2, height: rect.height * 0.14)
            (author as NSString).draw(with: authorRect, options: [.usesLineFragmentOrigin],
                                      attributes: authorAttributes)
        }

        NSGraphicsContext.restoreGraphicsState()
    }
}

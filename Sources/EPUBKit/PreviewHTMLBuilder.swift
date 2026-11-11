import Foundation

/// Extracts an EPUB to a temporary directory and combines its spine into a single HTML preview document.
public struct PreviewHTMLBuilder {
    public struct Output {
        /// The HTML file to load in WKWebView.
        public let htmlURL: URL
        /// The root directory, including resources, for which read access must be granted.
        public let rootURL: URL
        public let chapterCount: Int
        public let truncated: Bool
    }

    public struct Limits {
        public var maxChapters: Int = 100
        public var maxBodyCharacters: Int = 3_000_000
        public var maxExtractedBytes: Int = 300 * 1024 * 1024
        public init() {}
    }

    public let document: EPUBDocument
    public let limits: Limits

    public init(document: EPUBDocument, limits: Limits = Limits()) {
        self.document = document
        self.limits = limits
    }

    // MARK: - Building

    public func build() throws -> Output {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("epub-ql-\(UUID().uuidString)", isDirectory: true)
        return try build(in: root)
    }

    public func build(in requestedRoot: URL) throws -> Output {
        try document.archive.extractAll(to: requestedRoot, maxTotalBytes: limits.maxExtractedBytes)

        // WKWebView checks real paths to ensure the loaded file is under allowingReadAccessTo.
        // NSTemporaryDirectory() returns /var/folders/... through a symbolic link, and Foundation's
        // resolvingSymlinksInPath() removes the /private prefix again, so use realpath(3).
        let root = Self.realPath(requestedRoot)

        var styleLinks: [String] = []
        var seenStyles = Set<String>()
        var truncated = false

        // First pass: collect chapter bodies to identify included documents before rewriting links as anchors.
        var rawChapters: [(href: String, baseDir: String, body: String)] = []
        var totalChars = 0

        for (index, item) in document.spine.enumerated() {
            if index >= limits.maxChapters || totalChars >= limits.maxBodyCharacters {
                truncated = true
                break
            }
            guard let raw = document.text(at: item.href) else { continue }
            let baseDir = (item.href as NSString).deletingLastPathComponent

            for link in Self.stylesheetHrefs(in: raw) {
                let resolved = EPUBDocument.resolve(base: baseDir, relative: link)
                guard document.archive.contains(resolved), !seenStyles.contains(resolved) else { continue }
                seenStyles.insert(resolved)
                styleLinks.append("<link rel=\"stylesheet\" href=\"\(Self.fileURLString(root: root, path: resolved))\">")
            }

            var body = Self.blockRemoteResources(Self.stripDangerousTags(Self.extractBody(from: raw)))

            // Remove leading cover images that duplicate the header cover.
            // Skip the entire page if nothing remains afterward.
            if rawChapters.isEmpty {
                body = Self.removeCoverImage(from: body, baseDir: baseDir,
                                             coverPath: document.coverImagePath)
                if Self.isEmptyPage(body) { continue }
            }

            totalChars += body.count
            rawChapters.append((item.href, baseDir, body))
        }

        // Map ZIP paths to chapter indexes in the combined document.
        var chapterAnchors: [String: Int] = [:]
        for (index, chapter) in rawChapters.enumerated() {
            chapterAnchors[chapter.href] = index
        }

        // Second pass: rewrite resource paths and internal links.
        let chapters: [String] = rawChapters.enumerated().map { index, chapter in
            let body = Self.rewriteURLs(in: chapter.body, baseDir: chapter.baseDir, root: root,
                                        archive: document.archive, chapterAnchors: chapterAnchors)
            return """
            <section class="ql-chapter" id="ql-ch-\(index)">
            \(body)
            </section>
            """
        }

        if document.spine.count > chapters.count { truncated = true }

        let html = renderDocument(root: root,
                                  styleLinks: styleLinks,
                                  chapters: chapters,
                                  chapterAnchors: chapterAnchors,
                                  truncated: truncated)

        let htmlURL = root.appendingPathComponent("__quicklook_preview.html")
        try html.write(to: htmlURL, atomically: true, encoding: .utf8)

        return Output(htmlURL: htmlURL, rootURL: root,
                      chapterCount: chapters.count, truncated: truncated)
    }

    // MARK: - Document Assembly

    private func renderDocument(root: URL,
                                styleLinks: [String],
                                chapters: [String],
                                chapterAnchors: [String: Int],
                                truncated: Bool) -> String {
        let coverTag: String = {
            guard let cover = document.coverImagePath, document.archive.contains(cover) else { return "" }
            return "<img class=\"ql-cover\" src=\"\(Self.fileURLString(root: root, path: cover))\" alt=\"\">"
        }()

        var metaRows: [String] = []
        func row(_ label: String, _ value: String, _ key: String) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            metaRows.append("""
            <div class="ql-meta-row ql-meta-\(key)"><span>\(label)</span><b>\(Self.escape(trimmed))</b></div>
            """)
        }
        // Keys let CSS select which fields remain visible at narrow widths.
        row("Author", document.authorText, "author")
        row("Publisher", document.publisher, "publisher")
        row("Published", document.date, "date")
        row("Language", document.language, "language")
        row("Length", "\(document.spine.count) documents", "count")

        // Include only table of contents entries present in the rendered spine.
        var tocItems: [String] = []
        var usedIndexes = Set<Int>()
        for entry in document.toc {
            guard let index = chapterAnchors[entry.href], !usedIndexes.contains(index) else { continue }
            usedIndexes.insert(index)
            tocItems.append("<li><a href=\"#ql-ch-\(index)\">\(Self.escape(entry.title))</a></li>")
        }
        let tocBlock = tocItems.isEmpty ? "" : """
        <nav class="ql-toc">
          <h2>Contents</h2>
          <ol>\(tocItems.joined())</ol>
        </nav>
        """

        let descBlock = document.bookDescription.isEmpty ? "" :
            "<p class=\"ql-desc\">\(Self.escape(EPUBDocument.stripTags(document.bookDescription)))</p>"

        let truncatedNote = truncated ? """
        <p class="ql-note">This preview shows only the first \(chapters.count) documents.</p>
        """ : ""

        let emptyNote = chapters.isEmpty ? """
        <p class="ql-note">Unable to read the contents. The file may be damaged or protected by DRM.</p>
        """ : ""

        return """
        <!DOCTYPE html>
        <html lang="\(document.language.isEmpty ? "en" : Self.escape(document.language))">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(Self.escape(document.displayTitle))</title>
        \(styleLinks.joined(separator: "\n"))
        <style>\(Self.previewCSS)</style>
        </head>
        <body>
        <div class="ql-wrap">
          <header class="ql-header">
            \(coverTag)
            <div class="ql-headmeta">
              <h1>\(Self.escape(document.displayTitle))</h1>
              \(metaRows.joined())
              \(descBlock)
            </div>
          </header>
          \(tocBlock)
          \(emptyNote)
          <main class="ql-body">
        \(chapters.joined(separator: "\n<hr class=\"ql-sep\">\n"))
          </main>
          \(truncatedNote)
        </div>
        </body>
        </html>
        """
    }

    // MARK: - HTML Processing Utilities

    static func extractBody(from html: String) -> String {
        guard let openRange = html.range(of: "<body[^>]*>", options: [.regularExpression, .caseInsensitive])
        else {
            // If there is no body tag, use the entire document with the head removed.
            return html.replacingOccurrences(of: "<head[\\s\\S]*?</head>", with: "",
                                             options: [.regularExpression, .caseInsensitive])
        }
        let afterOpen = html[openRange.upperBound...]
        guard let closeRange = afterOpen.range(of: "</body>", options: [.caseInsensitive, .backwards]) else {
            return String(afterOpen)
        }
        return String(afterOpen[..<closeRange.lowerBound])
    }

    static func stylesheetHrefs(in html: String) -> [String] {
        var result: [String] = []
        let pattern = "<link[^>]*rel\\s*=\\s*[\"'][^\"']*stylesheet[^\"']*[\"'][^>]*>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = html as NSString
        regex.enumerateMatches(in: html, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m else { return }
            let tag = ns.substring(with: m.range)
            if let href = tag.range(of: "href\\s*=\\s*[\"']([^\"']+)[\"']", options: [.regularExpression, .caseInsensitive]) {
                let sub = String(tag[href])
                if let value = sub.range(of: "[\"']([^\"']+)[\"']", options: .regularExpression) {
                    result.append(String(sub[value]).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")))
                }
            }
        }
        return result
    }

    /// Removes tags such as scripts that do not need to execute in a preview.
    static func stripDangerousTags(_ html: String) -> String {
        var out = html
        for pattern in ["<script[\\s\\S]*?</script>", "<iframe[\\s\\S]*?</iframe>", "<object[\\s\\S]*?</object>"] {
            out = out.replacingOccurrences(of: pattern, with: "",
                                           options: [.regularExpression, .caseInsensitive])
        }
        return out
    }

    /// Removes body images that duplicate the cover already displayed in the header.
    /// The first EPUB page is often just a cover image, which would otherwise appear twice in succession.
    static func removeCoverImage(from body: String, baseDir: String, coverPath: String?) -> String {
        guard let coverPath else { return body }

        func referencesCover(_ fragment: String) -> Bool {
            let pattern = "(?:src|xlink:href)\\s*=\\s*[\"']([^\"']+)[\"']"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                return false
            }
            let ns = fragment as NSString
            return regex.matches(in: fragment, range: NSRange(location: 0, length: ns.length))
                .contains { match in
                    let source = ns.substring(with: match.range(at: 1))
                    return EPUBDocument.resolve(base: baseDir, relative: source) == coverPath
                }
        }

        var out = body
        // Remove individual <img> tags or the entire <svg> block for SVG-wrapped covers.
        for pattern in ["<img\\b[^>]*>", "<svg\\b[\\s\\S]*?</svg>"] {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            let ns = out as NSString
            var result = ""
            var last = 0
            regex.enumerateMatches(in: out, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
                guard let match else { return }
                let tag = ns.substring(with: match.range)
                result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
                if !referencesCover(tag) { result += tag }
                last = match.range.location + match.range.length
            }
            out = result + ns.substring(from: last)
        }
        return out
    }

    /// Checks whether a page has no text or media left.
    static func isEmptyPage(_ body: String) -> Bool {
        guard EPUBDocument.stripTags(body).isEmpty else { return false }
        let hasVisual = body.range(of: "<(img|svg|image|video|audio)\\b",
                                   options: [.regularExpression, .caseInsensitive]) != nil
        return !hasVisual
    }

    /// Disables attributes that reference remote resources.
    /// Prevents external requests, such as tracking pixels, when opening a preview.
    /// Leaves links (<a href>) intact; the preview navigation policy blocks external navigation.
    static func blockRemoteResources(_ html: String) -> String {
        var out = html
        out = out.replacingOccurrences(
            of: "(src|poster|xlink:href)\\s*=\\s*[\"']https?://([^\"']*)[\"']",
            with: "data-blocked-$1=\"https://$2\"",
            options: [.regularExpression, .caseInsensitive])
        out = out.replacingOccurrences(
            of: "url\\(\\s*[\"']?https?://[^\"')]+[\"']?\\s*\\)",
            with: "none",
            options: [.regularExpression, .caseInsensitive])
        return out
    }

    private static let skipPrefixes = ["http://", "https://", "data:", "file:", "mailto:",
                                       "javascript:", "tel:", "//", "#"]

    /// Converts relative document paths to file URLs in the extracted temporary directory.
    /// Rewrites links to other included chapters as anchors within the combined document.
    static func rewriteURLs(in html: String, baseDir: String, root: URL,
                            archive: ZipArchive,
                            chapterAnchors: [String: Int] = [:]) -> String {
        var out = html

        func replaceAll(pattern: String, valueGroup: Int, wrap: (String, String) -> String) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return }
            let ns = out as NSString
            var result = ""
            var last = 0
            regex.enumerateMatches(in: out, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
                guard let m, m.numberOfRanges > valueGroup else { return }
                let whole = m.range
                let value = ns.substring(with: m.range(at: valueGroup))
                result += ns.substring(with: NSRange(location: last, length: whole.location - last))

                let lower = value.lowercased().trimmingCharacters(in: .whitespaces)
                if value.isEmpty || skipPrefixes.contains(where: { lower.hasPrefix($0) }) {
                    result += ns.substring(with: whole)
                } else {
                    let pathPart = value.components(separatedBy: "#")[0]
                    let resolved = EPUBDocument.resolve(base: baseDir, relative: pathPart)
                    if let chapter = chapterAnchors[resolved] {
                        // Rewrite links to included chapters as internal document anchors.
                        result += wrap(ns.substring(with: whole), "#ql-ch-\(chapter)")
                    } else if archive.contains(resolved) {
                        result += wrap(ns.substring(with: whole), fileURLString(root: root, path: resolved))
                    } else {
                        result += ns.substring(with: whole)
                    }
                }
                last = whole.location + whole.length
            }
            result += ns.substring(from: last)
            out = result
        }

        // Attribute values: src="...", href='...', xlink:href="...", poster="..."
        replaceAll(pattern: "(?:src|href|xlink:href|poster)\\s*=\\s*[\"']([^\"']*)[\"']",
                   valueGroup: 1) { whole, url in
            guard let eq = whole.firstIndex(of: "=") else { return whole }
            let attrName = String(whole[whole.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
            return "\(attrName)=\"\(url)\""
        }

        // Wrap inline CSS url(...) values in single quotes so they also work inside style attributes.
        replaceAll(pattern: "url\\(\\s*[\"']?([^\"')]+)[\"']?\\s*\\)",
                   valueGroup: 1) { _, url in "url('\(url)')" }

        return out
    }

    /// Resolves all symbolic links to a real path, returning the original URL on failure.
    static func realPath(_ url: URL) -> URL {
        guard let resolved = realpath(url.path, nil) else { return url }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }

    static func fileURLString(root: URL, path: String) -> String {
        let full = root.appendingPathComponent(path)
        return full.absoluteString
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: - Preview Styles

    static let previewCSS = """
    :root {
      color-scheme: light dark;
      --ql-fg: #1c1c1e;
      --ql-dim: #6b6b70;
      --ql-bg: #ffffff;
      --ql-card: #f5f5f7;
      --ql-line: rgba(0,0,0,0.12);
      --ql-accent: #0b6bcb;
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --ql-fg: #ececf1;
        --ql-dim: #a0a0a8;
        --ql-bg: #1e1e20;
        --ql-card: #2a2a2e;
        --ql-line: rgba(255,255,255,0.14);
        --ql-accent: #7cb7ff;
      }
    }
    html, body {
      margin: 0; padding: 0;
      background: var(--ql-bg) !important;
      color: var(--ql-fg) !important;
      font: 16px/1.75 -apple-system, "SF Pro Text", sans-serif;
      -webkit-text-size-adjust: 100%;
      /* Prevent horizontal overflow in narrow areas such as the Finder preview panel. */
      overflow-x: hidden;
    }
    .ql-wrap { max-width: 46rem; margin: 0 auto; padding: 2rem 1.6rem 4rem; }
    .ql-header {
      display: flex; flex-wrap: wrap; gap: 1.2rem; align-items: flex-start;
      background: var(--ql-card); border-radius: 14px;
      padding: 1.1rem 1.2rem; margin-bottom: 1.6rem;
    }
    .ql-cover {
      width: clamp(80px, 30%, 116px); height: auto; max-height: 170px; object-fit: contain;
      border-radius: 6px; box-shadow: 0 2px 10px rgba(0,0,0,0.25); flex: none;
    }
    /* Move the title below the cover when there is not enough room. */
    .ql-headmeta { flex: 1 1 11rem; min-width: 0; }
    .ql-headmeta h1 {
      font-size: 1.35rem; line-height: 1.35; margin: 0.1rem 0 0.6rem;
      color: var(--ql-fg); font-weight: 700;
      /* Preserve word boundaries, wrapping within a word only to prevent overflow. */
      word-break: keep-all; overflow-wrap: anywhere;
    }
    .ql-meta-row { font-size: 0.85rem; color: var(--ql-dim); margin: 0.15rem 0; }
    .ql-meta-row span { display: inline-block; min-width: 3.6rem; }
    .ql-meta-row b { color: var(--ql-fg); font-weight: 500; }
    .ql-desc {
      font-size: 0.85rem; color: var(--ql-dim); margin: 0.7rem 0 0;
      display: -webkit-box; -webkit-line-clamp: 4; -webkit-box-orient: vertical; overflow: hidden;
    }
    .ql-toc {
      border: 1px solid var(--ql-line); border-radius: 12px;
      padding: 0.6rem 1.1rem 0.9rem; margin-bottom: 2rem;
    }
    .ql-toc h2 { font-size: 0.8rem; letter-spacing: 0.04em; color: var(--ql-dim);
                 text-transform: uppercase; margin: 0.6rem 0 0.4rem; }
    .ql-toc ol { margin: 0; padding-left: 1.2rem; font-size: 0.9rem; }
    .ql-toc li { margin: 0.15rem 0; }
    .ql-toc a { color: var(--ql-accent); text-decoration: none; }
    .ql-toc a:hover { text-decoration: underline; }
    .ql-sep { border: none; border-top: 1px solid var(--ql-line); margin: 2.4rem 0; }
    .ql-note {
      margin-top: 2rem; padding: 0.7rem 0.9rem; font-size: 0.85rem;
      color: var(--ql-dim); background: var(--ql-card); border-radius: 10px; text-align: center;
    }
    /* Scroll long tables of contents separately so they do not push the body far down.
       Fade the bottom edge to indicate that more entries are available. */
    .ql-toc ol {
      max-height: 22rem; overflow-y: auto;
      -webkit-mask-image: linear-gradient(to bottom, #000 calc(100% - 1.6rem), transparent);
    }

    /*
     * Compact layout for narrow areas such as the Finder preview panel.
     * At roughly 250pt wide with limited height, a large cover and title would hide the body.
     * Use a smaller cover beside the title and omit repeated labels to make room for text.
     * Finder already shows the file name and size below the panel, so they need no extra emphasis.
     */
    @media (max-width: 430px) {
      .ql-wrap { padding: 0.9rem 0.8rem 2rem; }
      .ql-header {
        flex-direction: row; align-items: flex-start; flex-wrap: nowrap;
        gap: 0.75rem; padding: 0.75rem 0.8rem; margin-bottom: 1rem;
        border-radius: 10px;
      }
      .ql-cover { width: 72px; max-height: 108px; border-radius: 4px; }
      .ql-headmeta { flex: 1 1 auto; }
      .ql-headmeta h1 {
        font-size: 0.98rem; line-height: 1.4; margin: 0 0 0.3rem;
        /* Limit long titles to three lines. */
        display: -webkit-box; -webkit-line-clamp: 3; -webkit-box-orient: vertical;
        overflow: hidden;
      }
      /* Omit labels and join metadata values with middle dots. */
      .ql-meta-row { display: inline; font-size: 0.76rem; line-height: 1.45; }
      .ql-meta-row span { display: none; }
      .ql-meta-row b { font-weight: 400; color: var(--ql-dim); }
      .ql-meta-row + .ql-meta-row::before { content: " · "; color: var(--ql-dim); }
      /* Keep only the author, publication date, and document count at narrow widths. */
      .ql-meta-language, .ql-meta-publisher, .ql-desc { display: none; }

      .ql-toc { padding: 0.3rem 0.7rem 0.55rem; margin-bottom: 1.2rem; border-radius: 9px; }
      .ql-toc h2 { font-size: 0.7rem; margin: 0.45rem 0 0.3rem; }
      .ql-toc ol { font-size: 0.8rem; padding-left: 1.1rem; max-height: 7.5rem; }
      .ql-toc li { margin: 0.05rem 0; }

      .ql-body { font-size: 0.92rem; line-height: 1.65; }
      .ql-sep { margin: 1.4rem 0; }
      .ql-note { margin-top: 1.2rem; font-size: 0.78rem; }
    }
    /* Keep fixed widths and colors in the EPUB's own styles from breaking the preview. */
    .ql-body { overflow-wrap: anywhere; }
    .ql-body img, .ql-body svg, .ql-body image { max-width: 100% !important; height: auto; }
    .ql-body table { max-width: 100%; display: block; overflow-x: auto; }
    .ql-body pre { white-space: pre-wrap; word-break: break-word; }
    .ql-body div, .ql-body p, .ql-body section, .ql-body body {
      width: auto !important; max-width: 100% !important; margin-left: 0; margin-right: 0;
    }
    .ql-body a { color: var(--ql-accent); }
    @media (prefers-color-scheme: dark) {
      /* Override EPUB styles designed for light backgrounds when using dark mode. */
      .ql-body *:not(img):not(svg):not(image) {
        background-color: transparent !important;
        color: var(--ql-fg) !important;
        border-color: var(--ql-line) !important;
      }
      .ql-body a { color: var(--ql-accent) !important; }
    }
    """
}

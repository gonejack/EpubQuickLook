import Foundation

/// EPUB을 임시 디렉터리에 풀고, spine 순서대로 이어붙인 단일 HTML 미리보기 문서를 만든다.
public struct PreviewHTMLBuilder {
    public struct Output {
        /// WKWebView에 로드할 HTML 파일
        public let htmlURL: URL
        /// 읽기 권한을 부여해야 하는 루트 디렉터리(리소스 포함)
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

    // MARK: - 빌드

    public func build() throws -> Output {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("epub-ql-\(UUID().uuidString)", isDirectory: true)
        return try build(in: root)
    }

    public func build(in requestedRoot: URL) throws -> Output {
        try document.archive.extractAll(to: requestedRoot, maxTotalBytes: limits.maxExtractedBytes)

        // WKWebView는 로드할 파일이 allowingReadAccessTo 경로 아래에 있는지 실제 경로로 판단한다.
        // NSTemporaryDirectory()는 /var/folders/...(심볼릭 링크)를 돌려주고 Foundation의
        // resolvingSymlinksInPath()는 /private 접두어를 다시 떼어내므로 realpath(3)를 쓴다.
        let root = Self.realPath(requestedRoot)

        var styleLinks: [String] = []
        var seenStyles = Set<String>()
        var truncated = false

        // 1차: 본문만 모은다. 챕터 간 링크를 앵커로 바꾸려면 포함될 문서 목록이 먼저 필요하다.
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

            let body = Self.blockRemoteResources(Self.stripDangerousTags(Self.extractBody(from: raw)))
            totalChars += body.count
            rawChapters.append((item.href, baseDir, body))
        }

        // ZIP 경로 → 합쳐진 문서에서의 챕터 인덱스
        var chapterAnchors: [String: Int] = [:]
        for (index, chapter) in rawChapters.enumerated() {
            chapterAnchors[chapter.href] = index
        }

        // 2차: 리소스 경로와 내부 링크를 재작성한다.
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

    // MARK: - 문서 조립

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
        func row(_ label: String, _ value: String) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            metaRows.append("<div class=\"ql-meta-row\"><span>\(label)</span><b>\(Self.escape(trimmed))</b></div>")
        }
        row("지은이", document.authorText)
        row("출판사", document.publisher)
        row("출간일", document.date)
        row("언어", document.language)
        row("분량", "\(document.spine.count)개 문서")

        // 목차: spine에 실제로 존재하는 항목만
        var tocItems: [String] = []
        var usedIndexes = Set<Int>()
        for entry in document.toc {
            guard let index = chapterAnchors[entry.href], !usedIndexes.contains(index) else { continue }
            usedIndexes.insert(index)
            tocItems.append("<li><a href=\"#ql-ch-\(index)\">\(Self.escape(entry.title))</a></li>")
        }
        let tocBlock = tocItems.isEmpty ? "" : """
        <nav class="ql-toc">
          <h2>목차</h2>
          <ol>\(tocItems.joined())</ol>
        </nav>
        """

        let descBlock = document.bookDescription.isEmpty ? "" :
            "<p class=\"ql-desc\">\(Self.escape(EPUBDocument.stripTags(document.bookDescription)))</p>"

        let truncatedNote = truncated ? """
        <p class="ql-note">미리보기는 앞부분 \(chapters.count)개 문서만 표시합니다.</p>
        """ : ""

        let emptyNote = chapters.isEmpty ? """
        <p class="ql-note">본문을 읽을 수 없습니다. 파일이 손상되었거나 DRM으로 보호되어 있을 수 있습니다.</p>
        """ : ""

        return """
        <!DOCTYPE html>
        <html lang="\(document.language.isEmpty ? "ko" : Self.escape(document.language))">
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

    // MARK: - HTML 가공 유틸

    static func extractBody(from html: String) -> String {
        guard let openRange = html.range(of: "<body[^>]*>", options: [.regularExpression, .caseInsensitive])
        else {
            // body 태그가 없으면 head를 제거한 전체를 사용
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

    /// 스크립트 등 미리보기에서 실행될 필요가 없는 태그를 제거한다.
    static func stripDangerousTags(_ html: String) -> String {
        var out = html
        for pattern in ["<script[\\s\\S]*?</script>", "<iframe[\\s\\S]*?</iframe>", "<object[\\s\\S]*?</object>"] {
            out = out.replacingOccurrences(of: pattern, with: "",
                                           options: [.regularExpression, .caseInsensitive])
        }
        return out
    }

    /// 원격 리소스를 참조하는 속성을 무력화한다.
    /// 미리보기를 여는 것만으로 외부 서버에 요청이 나가는 일(추적 픽셀 등)을 막는다.
    /// 링크(`<a href>`)는 그대로 두되, 미리보기에서는 어차피 열리지 않는다.
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

    /// 문서 내 상대 경로를 추출된 임시 디렉터리의 file URL로 바꾼다.
    /// 미리보기에 포함된 다른 챕터를 가리키는 링크는 합쳐진 문서 내부의 앵커로 바꾼다.
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
                        // 미리보기에 이미 포함된 챕터 → 문서 내부 앵커로
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

        // 속성값: src="...", href='...', xlink:href="...", poster="..."
        replaceAll(pattern: "(?:src|href|xlink:href|poster)\\s*=\\s*[\"']([^\"']*)[\"']",
                   valueGroup: 1) { whole, url in
            guard let eq = whole.firstIndex(of: "=") else { return whole }
            let attrName = String(whole[whole.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
            return "\(attrName)=\"\(url)\""
        }

        // 인라인 CSS의 url(...) — style 속성 안에서도 깨지지 않도록 홑따옴표로 감싼다.
        replaceAll(pattern: "url\\(\\s*[\"']?([^\"')]+)[\"']?\\s*\\)",
                   valueGroup: 1) { _, url in "url('\(url)')" }

        return out
    }

    /// 심볼릭 링크를 모두 푼 실제 경로. 실패하면 원래 URL을 그대로 돌려준다.
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

    // MARK: - 미리보기 전용 스타일

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
      font: 16px/1.75 -apple-system, "SF Pro Text", "Apple SD Gothic Neo", sans-serif;
      -webkit-text-size-adjust: 100%;
    }
    .ql-wrap { max-width: 46rem; margin: 0 auto; padding: 2rem 1.6rem 4rem; }
    .ql-header {
      display: flex; gap: 1.2rem; align-items: flex-start;
      background: var(--ql-card); border-radius: 14px;
      padding: 1.1rem 1.2rem; margin-bottom: 1.6rem;
    }
    .ql-cover {
      width: 116px; height: auto; max-height: 170px; object-fit: contain;
      border-radius: 6px; box-shadow: 0 2px 10px rgba(0,0,0,0.25); flex: none;
    }
    .ql-headmeta { min-width: 0; }
    .ql-headmeta h1 {
      font-size: 1.35rem; line-height: 1.35; margin: 0.1rem 0 0.6rem;
      color: var(--ql-fg); font-weight: 700;
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
    /* EPUB 자체 스타일이 고정 폭/색을 지정해도 미리보기가 깨지지 않도록 보정 */
    .ql-body img, .ql-body svg, .ql-body image { max-width: 100% !important; height: auto; }
    .ql-body table { max-width: 100%; display: block; overflow-x: auto; }
    .ql-body pre { white-space: pre-wrap; word-break: break-word; }
    .ql-body div, .ql-body p, .ql-body section, .ql-body body {
      width: auto !important; max-width: 100% !important; margin-left: 0; margin-right: 0;
    }
    .ql-body a { color: var(--ql-accent); }
    @media (prefers-color-scheme: dark) {
      /* 밝은 배경을 전제로 작성된 EPUB CSS를 다크모드에서 중화한다 */
      .ql-body *:not(img):not(svg):not(image) {
        background-color: transparent !important;
        color: var(--ql-fg) !important;
        border-color: var(--ql-line) !important;
      }
      .ql-body a { color: var(--ql-accent) !important; }
    }
    """
}

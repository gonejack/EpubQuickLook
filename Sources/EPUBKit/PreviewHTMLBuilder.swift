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

            var body = Self.blockRemoteResources(Self.stripDangerousTags(Self.extractBody(from: raw)))

            // 앞쪽 표지 페이지는 헤더의 표지와 겹치므로 그림을 걷어내고,
            // 그래서 아무것도 남지 않으면 그 페이지 자체를 건너뛴다.
            if rawChapters.isEmpty {
                body = Self.removeCoverImage(from: body, baseDir: baseDir,
                                             coverPath: document.coverImagePath)
                if Self.isEmptyPage(body) { continue }
            }

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
        func row(_ label: String, _ value: String, _ key: String) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            metaRows.append("""
            <div class="ql-meta-row ql-meta-\(key)"><span>\(label)</span><b>\(Self.escape(trimmed))</b></div>
            """)
        }
        // key는 좁은 폭에서 어떤 항목을 남길지 CSS로 고르기 위한 것이다.
        row("지은이", document.authorText, "author")
        row("출판사", document.publisher, "publisher")
        row("출간일", document.date, "date")
        row("언어", document.language, "language")
        row("분량", "\(document.spine.count)개 문서", "count")

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

    /// 헤더에 이미 띄운 표지와 같은 그림을 본문에서 걷어낸다.
    /// EPUB 첫 페이지는 대개 표지 이미지 한 장이라, 그대로 두면 같은 그림이 연달아 두 번 나온다.
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
        // <img>는 태그만, SVG로 감싼 표지는 <svg> 블록째로 지운다.
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

    /// 그림도 글도 남지 않은 껍데기 페이지인지 확인한다.
    static func isEmptyPage(_ body: String) -> Bool {
        guard EPUBDocument.stripTags(body).isEmpty else { return false }
        let hasVisual = body.range(of: "<(img|svg|image|video|audio)\\b",
                                   options: [.regularExpression, .caseInsensitive]) != nil
        return !hasVisual
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
      /* Finder 미리보기 패널처럼 좁은 곳에서 내용이 옆으로 삐져나가지 않게 한다 */
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
    /* 제목이 들어갈 자리가 부족하면 표지 아래로 내려간다 */
    .ql-headmeta { flex: 1 1 11rem; min-width: 0; }
    .ql-headmeta h1 {
      font-size: 1.35rem; line-height: 1.35; margin: 0.1rem 0 0.6rem;
      color: var(--ql-fg); font-weight: 700;
      /* 한국어는 어절 단위로 끊되, 그래도 넘치면 강제로 줄바꿈한다 */
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
    /* 목차가 수십 개인 책에서 본문이 한참 아래로 밀리지 않도록 자체 스크롤.
       아래쪽을 흐리게 처리해 더 많은 항목이 있다는 것을 알린다. */
    .ql-toc ol {
      max-height: 22rem; overflow-y: auto;
      -webkit-mask-image: linear-gradient(to bottom, #000 calc(100% - 1.6rem), transparent);
    }

    /*
     * Finder 미리보기 패널처럼 폭이 좁을 때의 컴팩트 레이아웃.
     * 이런 패널은 폭이 250pt 남짓이고 높이도 짧아서, 표지와 제목이 화면을 다 먹으면
     * 정작 본문이 보이지 않는다. 표지를 작게 줄여 한 줄로 붙이고, 반복되는 라벨을
     * 없앤 뒤, 남는 공간을 본문에 넘긴다. 파일명·용량은 Finder가 패널 아래에
     * 따로 보여주므로 여기서 다시 강조할 이유가 없다.
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
        /* 긴 제목은 세 줄까지만 */
        display: -webkit-box; -webkit-line-clamp: 3; -webkit-box-orient: vertical;
        overflow: hidden;
      }
      /* 라벨을 떼고 가운뎃점으로 이어 붙여 한 덩어리로 만든다 */
      .ql-meta-row { display: inline; font-size: 0.76rem; line-height: 1.45; }
      .ql-meta-row span { display: none; }
      .ql-meta-row b { font-weight: 400; color: var(--ql-dim); }
      .ql-meta-row + .ql-meta-row::before { content: " · "; color: var(--ql-dim); }
      /* 좁은 곳에서는 지은이 · 출간일 · 분량만 남긴다 */
      .ql-meta-language, .ql-meta-publisher, .ql-desc { display: none; }

      .ql-toc { padding: 0.3rem 0.7rem 0.55rem; margin-bottom: 1.2rem; border-radius: 9px; }
      .ql-toc h2 { font-size: 0.7rem; margin: 0.45rem 0 0.3rem; }
      .ql-toc ol { font-size: 0.8rem; padding-left: 1.1rem; max-height: 7.5rem; }
      .ql-toc li { margin: 0.05rem 0; }

      .ql-body { font-size: 0.92rem; line-height: 1.65; }
      .ql-sep { margin: 1.4rem 0; }
      .ql-note { margin-top: 1.2rem; font-size: 0.78rem; }
    }
    /* EPUB 자체 스타일이 고정 폭/색을 지정해도 미리보기가 깨지지 않도록 보정 */
    .ql-body { overflow-wrap: anywhere; }
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

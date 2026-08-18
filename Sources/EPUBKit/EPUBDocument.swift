import Foundation

/// EPUB 패키지 문서(OPF)를 읽어 메타데이터, 읽기 순서(spine), 표지, 목차를 제공한다.
public struct EPUBDocument {
    public struct ManifestItem {
        public let id: String
        public let href: String        // ZIP 내부 절대 경로
        public let mediaType: String
        public let properties: String
    }

    public struct TOCEntry {
        public let title: String
        public let href: String        // ZIP 내부 절대 경로 (fragment 제외)
        public let depth: Int
    }

    public let archive: ZipArchive
    public let opfPath: String

    public private(set) var title: String = ""
    public private(set) var authors: [String] = []
    public private(set) var language: String = ""
    public private(set) var publisher: String = ""
    public private(set) var date: String = ""
    public private(set) var bookDescription: String = ""
    public private(set) var identifier: String = ""

    public private(set) var manifest: [String: ManifestItem] = [:]
    public private(set) var spine: [ManifestItem] = []
    public private(set) var coverImagePath: String?
    public private(set) var toc: [TOCEntry] = []

    public var displayTitle: String {
        title.isEmpty ? "제목 없음" : title
    }

    public var authorText: String {
        authors.joined(separator: ", ")
    }

    // MARK: - 로드

    public init(url: URL) throws {
        try self.init(archive: ZipArchive(url: url))
    }

    public init(archive: ZipArchive) throws {
        self.archive = archive
        self.opfPath = try EPUBDocument.locateOPF(in: archive)

        let opfData = try archive.data(for: opfPath)
        let parser = OPFParser()
        let package = parser.parse(opfData)

        let opfDir = (opfPath as NSString).deletingLastPathComponent

        for raw in package.manifest {
            let resolved = EPUBDocument.resolve(base: opfDir, relative: raw.href)
            let item = ManifestItem(id: raw.id, href: resolved,
                                    mediaType: raw.mediaType, properties: raw.properties)
            manifest[raw.id] = item
        }

        title = package.title
        authors = package.authors
        language = package.language
        publisher = package.publisher
        date = String(package.date.prefix(10))
        bookDescription = package.description
        identifier = package.identifier

        spine = package.spineIDRefs.compactMap { manifest[$0] }
        if spine.isEmpty {
            // spine이 비었으면 manifest의 XHTML을 순서대로 사용 (손상된 EPUB 대비)
            spine = manifest.values
                .filter { $0.mediaType.contains("xhtml") || $0.mediaType.contains("html") }
                .sorted { $0.href < $1.href }
        }

        coverImagePath = EPUBDocument.findCover(package: package, manifest: manifest, archive: archive)
        toc = EPUBDocument.parseTOC(package: package, manifest: manifest,
                                    archive: archive, opfDir: opfDir)
    }

    // MARK: - 리소스 접근

    public func data(at path: String) -> Data? {
        try? archive.data(for: path)
    }

    public var coverImageData: Data? {
        guard let coverImagePath else { return nil }
        return data(at: coverImagePath)
    }

    /// XHTML 문서를 문자열로 읽는다. 인코딩 선언을 참고해 디코딩한다.
    public func text(at path: String) -> String? {
        guard let raw = data(at: path) else { return nil }
        if let s = String(data: raw, encoding: .utf8) { return s }
        for encoding: String.Encoding in [.utf16, .isoLatin1, .windowsCP1252] {
            if let s = String(data: raw, encoding: encoding) { return s }
        }
        return String(decoding: raw, as: UTF8.self)
    }

    // MARK: - 내부 헬퍼

    private static func locateOPF(in archive: ZipArchive) throws -> String {
        if let containerData = try? archive.data(for: "META-INF/container.xml"),
           let xml = String(data: containerData, encoding: .utf8),
           let path = firstMatch(in: xml,
                                 pattern: "<rootfile[^>]*full-path\\s*=\\s*[\"']([^\"']+)[\"']",
                                 group: 1) {
            let decoded = path.removingPercentEncoding ?? path
            if archive.contains(decoded) { return decoded }
            if archive.contains(path) { return path }
        }
        // container.xml이 없거나 깨진 경우 .opf 파일을 직접 찾는다.
        if let fallback = archive.orderedPaths.first(where: { $0.lowercased().hasSuffix(".opf") }) {
            return fallback
        }
        throw ZipArchive.ZipError.entryNotFound("content.opf")
    }

    /// ZIP 내부 상대 경로를 정규화된 절대 경로로 변환한다.
    public static func resolve(base: String, relative: String) -> String {
        var rel = relative
        if let decoded = rel.removingPercentEncoding { rel = decoded }
        if rel.hasPrefix("/") { return String(rel.dropFirst()) }

        var components = base.isEmpty ? [] : base.split(separator: "/").map(String.init)
        for part in rel.split(separator: "/", omittingEmptySubsequences: false).map(String.init) {
            switch part {
            case "", ".": continue
            case "..": if !components.isEmpty { components.removeLast() }
            default: components.append(part)
            }
        }
        return components.joined(separator: "/")
    }

    private static func findCover(package: OPFParser.Package,
                                  manifest: [String: ManifestItem],
                                  archive: ZipArchive) -> String? {
        // 1) EPUB3: properties="cover-image"
        if let item = manifest.values.first(where: { $0.properties.contains("cover-image") }),
           archive.contains(item.href) {
            return item.href
        }
        // 2) EPUB2: <meta name="cover" content="itemID">
        if let coverID = package.metaCoverID, let item = manifest[coverID],
           item.mediaType.hasPrefix("image"), archive.contains(item.href) {
            return item.href
        }
        // 3) 파일명 휴리스틱
        let candidates = manifest.values.filter { $0.mediaType.hasPrefix("image") }
        if let item = candidates.first(where: { $0.href.lowercased().contains("cover") }),
           archive.contains(item.href) {
            return item.href
        }
        // 4) 첫 번째 이미지
        return candidates.sorted { $0.href < $1.href }.first(where: { archive.contains($0.href) })?.href
    }

    private static func parseTOC(package: OPFParser.Package,
                                 manifest: [String: ManifestItem],
                                 archive: ZipArchive,
                                 opfDir: String) -> [TOCEntry] {
        // EPUB3 nav 문서 우선
        if let nav = manifest.values.first(where: { $0.properties.contains("nav") }),
           let xml = (try? archive.data(for: nav.href)).flatMap({ String(data: $0, encoding: .utf8) }) {
            let navDir = (nav.href as NSString).deletingLastPathComponent
            let entries = parseNavXHTML(xml, baseDir: navDir)
            if !entries.isEmpty { return entries }
        }
        // EPUB2 NCX
        let ncxItem = manifest[package.spineTocID ?? ""]
            ?? manifest.values.first(where: { $0.mediaType.contains("ncx") })
        if let ncxItem,
           let xml = (try? archive.data(for: ncxItem.href)).flatMap({ String(data: $0, encoding: .utf8) }) {
            let ncxDir = (ncxItem.href as NSString).deletingLastPathComponent
            return parseNCX(xml, baseDir: ncxDir)
        }
        return []
    }

    private static func parseNavXHTML(_ xml: String, baseDir: String) -> [TOCEntry] {
        // <nav ... epub:type="toc"> 블록 안의 <a href>만 사용
        let navRange = range(of: xml, pattern: "<nav[^>]*epub:type\\s*=\\s*[\"'][^\"']*toc[^\"']*[\"'][^>]*>")
        guard let start = navRange else { return [] }
        let tail = String(xml[start.upperBound...])
        let end = tail.range(of: "</nav>", options: .caseInsensitive)
        let body = end.map { String(tail[..<$0.lowerBound]) } ?? tail

        var entries: [TOCEntry] = []
        let regex = try? NSRegularExpression(
            pattern: "<a[^>]*href\\s*=\\s*[\"']([^\"']+)[\"'][^>]*>(.*?)</a>",
            options: [.dotMatchesLineSeparators, .caseInsensitive])
        let ns = body as NSString
        regex?.enumerateMatches(in: body, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m, m.numberOfRanges >= 3 else { return }
            let href = ns.substring(with: m.range(at: 1))
            let label = stripTags(ns.substring(with: m.range(at: 2)))
            guard !label.isEmpty else { return }
            let path = resolve(base: baseDir, relative: href.components(separatedBy: "#")[0])
            entries.append(TOCEntry(title: label, href: path, depth: 0))
        }
        return entries
    }

    private static func parseNCX(_ xml: String, baseDir: String) -> [TOCEntry] {
        var entries: [TOCEntry] = []
        let regex = try? NSRegularExpression(
            pattern: "<navPoint[^>]*>.*?<text>(.*?)</text>.*?<content[^>]*src\\s*=\\s*[\"']([^\"']+)[\"']",
            options: [.dotMatchesLineSeparators, .caseInsensitive])
        let ns = xml as NSString
        regex?.enumerateMatches(in: xml, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m, m.numberOfRanges >= 3 else { return }
            let label = stripTags(ns.substring(with: m.range(at: 1)))
            let href = ns.substring(with: m.range(at: 2))
            guard !label.isEmpty else { return }
            let path = resolve(base: baseDir, relative: href.components(separatedBy: "#")[0])
            entries.append(TOCEntry(title: label, href: path, depth: 0))
        }
        return entries
    }

    static func stripTags(_ s: String) -> String {
        let noTags = s.replacingOccurrences(of: "<[^>]+>", with: "",
                                            options: .regularExpression)
        return decodeEntities(noTags).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = s
        let map = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
                   "&apos;": "'", "&#39;": "'", "&nbsp;": " ", "&mdash;": "—", "&ndash;": "–"]
        for (k, v) in map { out = out.replacingOccurrences(of: k, with: v) }
        return out
    }

    private static func firstMatch(in text: String, pattern: String, group: Int) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = text as NSString
        guard let m = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > group else { return nil }
        return ns.substring(with: m.range(at: group))
    }

    private static func range(of text: String, pattern: String) -> Range<String.Index>? {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive])
    }
}

// MARK: - OPF 파서

/// XMLParser 기반 OPF 파서. 네임스페이스 접두사(dc:, opf:)에 관대하게 동작한다.
final class OPFParser: NSObject, XMLParserDelegate {
    struct RawManifestItem {
        let id: String
        let href: String
        let mediaType: String
        let properties: String
    }

    struct Package {
        var title = ""
        var authors: [String] = []
        var language = ""
        var publisher = ""
        var date = ""
        var description = ""
        var identifier = ""
        var manifest: [RawManifestItem] = []
        var spineIDRefs: [String] = []
        var spineTocID: String?
        var metaCoverID: String?
    }

    private var package = Package()
    private var currentElement = ""
    private var buffer = ""
    private var inMetadata = false

    func parse(_ data: Data) -> Package {
        package = Package()
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = false
        parser.parse()
        return package
    }

    private func localName(_ name: String) -> String {
        name.components(separatedBy: ":").last?.lowercased() ?? name.lowercased()
    }

    private func attr(_ dict: [String: String], _ key: String) -> String? {
        if let v = dict[key] { return v }
        for (k, v) in dict where localName(k) == key.lowercased() { return v }
        return nil
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        let name = localName(elementName)
        currentElement = name
        buffer = ""

        switch name {
        case "metadata":
            inMetadata = true
        case "item":
            let id = attr(attributeDict, "id") ?? ""
            let href = attr(attributeDict, "href") ?? ""
            guard !href.isEmpty else { return }
            package.manifest.append(RawManifestItem(
                id: id,
                href: href,
                mediaType: attr(attributeDict, "media-type") ?? "",
                properties: attr(attributeDict, "properties") ?? ""))
        case "itemref":
            if let idref = attr(attributeDict, "idref") {
                package.spineIDRefs.append(idref)
            }
        case "spine":
            package.spineTocID = attr(attributeDict, "toc")
        case "meta":
            // EPUB2 표지 지정: <meta name="cover" content="cover-image-id"/>
            if let metaName = attr(attributeDict, "name")?.lowercased(), metaName == "cover" {
                package.metaCoverID = attr(attributeDict, "content")
            }
        case "reference":
            break
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let name = localName(elementName)
        let value = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""

        if name == "metadata" { inMetadata = false; return }
        guard inMetadata, !value.isEmpty else { return }

        switch name {
        case "title": if package.title.isEmpty { package.title = value }
        case "creator": package.authors.append(value)
        case "language": if package.language.isEmpty { package.language = value }
        case "publisher": if package.publisher.isEmpty { package.publisher = value }
        case "date": if package.date.isEmpty { package.date = value }
        case "description": if package.description.isEmpty { package.description = value }
        case "identifier": if package.identifier.isEmpty { package.identifier = value }
        default: break
        }
    }
}

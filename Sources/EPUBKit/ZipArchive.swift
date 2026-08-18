import Foundation
import Compression

/// 외부 의존성 없이 ZIP(EPUB 컨테이너)을 읽는 최소 구현.
/// store(0) / deflate(8) 두 가지 압축 방식과 ZIP64 확장 필드를 지원한다.
public struct ZipArchive {
    public struct Entry {
        public let path: String
        public let compressionMethod: UInt16
        public let compressedSize: Int
        public let uncompressedSize: Int
        public let localHeaderOffset: Int
        public var isDirectory: Bool { path.hasSuffix("/") }
    }

    public enum ZipError: Error, LocalizedError {
        case notAZipFile
        case corruptedCentralDirectory
        case entryNotFound(String)
        case decompressionFailed(String)

        public var errorDescription: String? {
            switch self {
            case .notAZipFile: return "ZIP(EPUB) 형식이 아닙니다."
            case .corruptedCentralDirectory: return "ZIP 중앙 디렉터리가 손상되었습니다."
            case .entryNotFound(let p): return "항목을 찾을 수 없습니다: \(p)"
            case .decompressionFailed(let p): return "압축 해제에 실패했습니다: \(p)"
            }
        }
    }

    private let data: Data
    public private(set) var entries: [String: Entry] = [:]
    /// 중앙 디렉터리에 기록된 순서대로의 경로 목록
    public private(set) var orderedPaths: [String] = []

    public init(url: URL) throws {
        // 대용량 EPUB에서 메모리를 아끼기 위해 mmap 사용
        self.data = try Data(contentsOf: url, options: .mappedIfSafe)
        try parseCentralDirectory()
    }

    public init(data: Data) throws {
        self.data = data
        try parseCentralDirectory()
    }

    // MARK: - 읽기 헬퍼

    private func u16(_ offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= data.count else { return 0 }
        return UInt16(data[data.startIndex + offset]) | (UInt16(data[data.startIndex + offset + 1]) << 8)
    }

    private func u32(_ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { return 0 }
        var v: UInt32 = 0
        for i in (0..<4).reversed() {
            v = (v << 8) | UInt32(data[data.startIndex + offset + i])
        }
        return v
    }

    private func u64(_ offset: Int) -> UInt64 {
        guard offset >= 0, offset + 8 <= data.count else { return 0 }
        var v: UInt64 = 0
        for i in (0..<8).reversed() {
            v = (v << 8) | UInt64(data[data.startIndex + offset + i])
        }
        return v
    }

    private func slice(_ offset: Int, _ length: Int) -> Data {
        guard offset >= 0, length >= 0, offset + length <= data.count else { return Data() }
        let start = data.startIndex + offset
        return data.subdata(in: start..<(start + length))
    }

    // MARK: - 중앙 디렉터리 파싱

    private mutating func parseCentralDirectory() throws {
        guard data.count > 22 else { throw ZipError.notAZipFile }

        // EOCD(End Of Central Directory) 탐색 — 주석 최대 65535바이트까지 뒤에서 훑는다.
        let maxBack = min(data.count, 65_557)
        var eocd = -1
        var i = data.count - 22
        let limit = data.count - maxBack
        while i >= max(0, limit) {
            if u32(i) == 0x0605_4B50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ZipError.notAZipFile }

        var entryCount = Int(u16(eocd + 10))
        var cdSize = Int(u32(eocd + 12))
        var cdOffset = Int(u32(eocd + 16))

        // ZIP64 EOCD locator
        let locatorOffset = eocd - 20
        if locatorOffset >= 0, u32(locatorOffset) == 0x0706_4B50 {
            let z64 = Int(u64(locatorOffset + 8))
            if z64 >= 0, z64 + 56 <= data.count, u32(z64) == 0x0606_4B50 {
                entryCount = Int(u64(z64 + 32))
                cdSize = Int(u64(z64 + 40))
                cdOffset = Int(u64(z64 + 48))
            }
        }

        guard cdOffset >= 0, cdSize >= 0, cdOffset + cdSize <= data.count else {
            throw ZipError.corruptedCentralDirectory
        }

        var p = cdOffset
        var parsed = 0
        while parsed < entryCount, p + 46 <= cdOffset + cdSize {
            guard u32(p) == 0x0201_4B50 else { break }

            let method = u16(p + 10)
            var compSize = Int(u32(p + 20))
            var uncompSize = Int(u32(p + 24))
            let nameLen = Int(u16(p + 28))
            let extraLen = Int(u16(p + 30))
            let commentLen = Int(u16(p + 32))
            var localOffset = Int(u32(p + 42))

            let nameData = slice(p + 46, nameLen)
            let name = String(data: nameData, encoding: .utf8)
                ?? String(decoding: nameData, as: UTF8.self)

            // ZIP64 확장 필드(0x0001)에서 실제 크기/오프셋 보정
            if compSize == 0xFFFF_FFFF || uncompSize == 0xFFFF_FFFF || localOffset == 0xFFFF_FFFF {
                var e = p + 46 + nameLen
                let extraEnd = e + extraLen
                while e + 4 <= extraEnd {
                    let tag = u16(e)
                    let size = Int(u16(e + 2))
                    if tag == 0x0001 {
                        var f = e + 4
                        if uncompSize == 0xFFFF_FFFF, f + 8 <= e + 4 + size { uncompSize = Int(u64(f)); f += 8 }
                        if compSize == 0xFFFF_FFFF, f + 8 <= e + 4 + size { compSize = Int(u64(f)); f += 8 }
                        if localOffset == 0xFFFF_FFFF, f + 8 <= e + 4 + size { localOffset = Int(u64(f)) }
                        break
                    }
                    e += 4 + size
                }
            }

            let entry = Entry(path: name,
                              compressionMethod: method,
                              compressedSize: compSize,
                              uncompressedSize: uncompSize,
                              localHeaderOffset: localOffset)
            if entries[name] == nil { orderedPaths.append(name) }
            entries[name] = entry

            p += 46 + nameLen + extraLen + commentLen
            parsed += 1
        }

        guard !entries.isEmpty else { throw ZipError.corruptedCentralDirectory }
    }

    // MARK: - 추출

    public func contains(_ path: String) -> Bool {
        entries[normalize(path)] != nil
    }

    /// ZIP 내부 경로를 정규화한다. 대소문자가 다른 경우도 완만하게 매칭한다.
    private func normalize(_ path: String) -> String {
        var p = path
        if p.hasPrefix("/") { p.removeFirst() }
        if entries[p] != nil { return p }
        let lower = p.lowercased()
        for key in orderedPaths where key.lowercased() == lower { return key }
        return p
    }

    public func data(for path: String) throws -> Data {
        let key = normalize(path)
        guard let entry = entries[key] else { throw ZipError.entryNotFound(path) }
        return try data(for: entry)
    }

    public func data(for entry: Entry) throws -> Data {
        guard entry.uncompressedSize >= 0 else { throw ZipError.decompressionFailed(entry.path) }
        if entry.uncompressedSize == 0 { return Data() }

        // 로컬 헤더에서 실제 데이터 시작 위치 계산 (가변 길이 필드가 중앙 디렉터리와 다를 수 있음)
        let lh = entry.localHeaderOffset
        guard lh + 30 <= data.count, u32(lh) == 0x0403_4B50 else {
            throw ZipError.decompressionFailed(entry.path)
        }
        let nameLen = Int(u16(lh + 26))
        let extraLen = Int(u16(lh + 28))
        let dataStart = lh + 30 + nameLen + extraLen
        let payload = slice(dataStart, entry.compressedSize)
        guard payload.count == entry.compressedSize else {
            throw ZipError.decompressionFailed(entry.path)
        }

        switch entry.compressionMethod {
        case 0:
            return payload
        case 8:
            guard let out = ZipArchive.inflate(payload, expectedSize: entry.uncompressedSize) else {
                throw ZipError.decompressionFailed(entry.path)
            }
            return out
        default:
            throw ZipError.decompressionFailed(entry.path)
        }
    }

    /// raw deflate 스트림을 해제한다.
    static func inflate(_ input: Data, expectedSize: Int) -> Data? {
        guard !input.isEmpty else { return Data() }
        // 크기를 알고 있으므로 한 번에 디코드. 여유분을 조금 둔다.
        let capacity = max(expectedSize, 1) + 4096
        var output = Data(count: capacity)

        let decoded: Int = output.withUnsafeMutableBytes { outRaw -> Int in
            guard let outPtr = outRaw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return input.withUnsafeBytes { inRaw -> Int in
                guard let inPtr = inRaw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(outPtr, capacity,
                                                 inPtr, input.count,
                                                 nil, COMPRESSION_ZLIB)
            }
        }
        guard decoded > 0 else { return nil }
        output.removeSubrange(decoded..<output.count)
        return output
    }

    /// 아카이브 전체를 디렉터리로 풀어낸다. ZIP slip(경로 탈출) 공격을 막는다.
    @discardableResult
    public func extractAll(to destination: URL, maxTotalBytes: Int = 400 * 1024 * 1024) throws -> Int {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let base = destination.standardizedFileURL.path
        var written = 0

        for path in orderedPaths {
            guard let entry = entries[path], !entry.isDirectory else { continue }
            if written + entry.uncompressedSize > maxTotalBytes { break }

            let target = destination.appendingPathComponent(entry.path).standardizedFileURL
            // 목적지 밖으로 벗어나는 경로는 건너뛴다.
            guard target.path == base || target.path.hasPrefix(base + "/") else { continue }

            do {
                let bytes = try data(for: entry)
                try fm.createDirectory(at: target.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                try bytes.write(to: target)
                written += bytes.count
            } catch {
                continue // 개별 항목 실패는 무시하고 계속 진행
            }
        }
        return written
    }
}

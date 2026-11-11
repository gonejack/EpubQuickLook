import Foundation
import Compression

/// A minimal ZIP reader for EPUB containers with no third-party dependencies.
/// Supports store (0), deflate (8), and ZIP64 extra fields.
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
            case .notAZipFile: return "The file is not a ZIP (EPUB) archive."
            case .corruptedCentralDirectory: return "The ZIP central directory is corrupted."
            case .entryNotFound(let p): return "Entry not found: \(p)"
            case .decompressionFailed(let p): return "Failed to decompress: \(p)"
            }
        }
    }

    private let data: Data
    public private(set) var entries: [String: Entry] = [:]
    /// Paths in the order recorded in the central directory.
    public private(set) var orderedPaths: [String] = []

    public init(url: URL) throws {
        // Use memory mapping to reduce memory usage for large EPUB files.
        self.data = try Data(contentsOf: url, options: .mappedIfSafe)
        try parseCentralDirectory()
    }

    public init(data: Data) throws {
        self.data = data
        try parseCentralDirectory()
    }

    // MARK: - Reading Helpers

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

    // MARK: - Central Directory Parsing

    private mutating func parseCentralDirectory() throws {
        guard data.count > 22 else { throw ZipError.notAZipFile }

        // Search backward for EOCD (End of Central Directory), allowing up to 65,535 comment bytes.
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

            // Read the actual sizes and offset from the ZIP64 extra field (0x0001).
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

    // MARK: - Extraction

    public func contains(_ path: String) -> Bool {
        entries[normalize(path)] != nil
    }

    /// Normalizes a ZIP entry path, falling back to a case-insensitive match.
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

        // Calculate the data offset from the local header; variable-length fields may differ from the central directory.
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

    /// Decompresses a raw deflate stream.
    static func inflate(_ input: Data, expectedSize: Int) -> Data? {
        guard !input.isEmpty else { return Data() }
        // Decode in one pass using the expected size plus a small buffer margin.
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

    /// Extracts the archive to a directory while blocking Zip Slip path traversal.
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
            // Skip paths that would escape the destination directory.
            guard target.path == base || target.path.hasPrefix(base + "/") else { continue }

            do {
                let bytes = try data(for: entry)
                try fm.createDirectory(at: target.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                try bytes.write(to: target)
                written += bytes.count
            } catch {
                continue // Ignore failures for individual entries and continue.
            }
        }
        return written
    }
}

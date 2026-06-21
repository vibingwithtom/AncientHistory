//
//  ZipExtractor.swift
//  Ancient History
//
//  Native, in-process ZIP extraction using the Compression framework. Replaces
//  the previous `/usr/bin/unzip` subprocess spawn in MultiFormatImporter, which
//  could not run under the app sandbox and is unnecessary. Supports STORE and
//  DEFLATE entries (what Gmail Takeout archives use), ZIP64, and guards against
//  path-traversal ("zip slip") so a malicious archive cannot write outside the
//  destination directory.
//
//  Forked from MBox Explorer (MIT). Part of milestone M3.
//

import Foundation
import Compression

enum ZipExtractorError: LocalizedError {
    case notAZipArchive
    case corrupt(String)
    case unsupportedCompression(UInt16)
    case unsafeEntryPath(String)

    var errorDescription: String? {
        switch self {
        case .notAZipArchive:
            return "The file is not a valid ZIP archive."
        case .corrupt(let detail):
            return "The ZIP archive is corrupt: \(detail)"
        case .unsupportedCompression(let method):
            return "Unsupported ZIP compression method \(method)."
        case .unsafeEntryPath(let name):
            return "The ZIP archive contains an unsafe entry path: \(name)"
        }
    }
}

/// Extracts ZIP archives without spawning a subprocess.
struct ZipExtractor {

    /// Extract every entry in `zipURL` into `destination` (created if needed).
    static func extract(_ zipURL: URL, to destination: URL) throws {
        let data = try Data(contentsOf: zipURL, options: .mappedIfSafe)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let centralDirectory = try locateCentralDirectory(in: data)
        var offset = centralDirectory.offset
        let fileManager = FileManager.default

        for _ in 0..<centralDirectory.count {
            guard offset + 46 <= data.count, u32(data, offset) == 0x0201_4b50 else {
                throw ZipExtractorError.corrupt("bad central directory header")
            }

            let method = UInt16(u16(data, offset + 10))
            var compressedSize = UInt64(u32(data, offset + 20))
            var uncompressedSize = UInt64(u32(data, offset + 24))
            let nameLength = u16(data, offset + 28)
            let extraLength = u16(data, offset + 30)
            let commentLength = u16(data, offset + 32)
            var localHeaderOffset = UInt64(u32(data, offset + 42))

            let nameStart = offset + 46
            guard nameStart + nameLength <= data.count else {
                throw ZipExtractorError.corrupt("entry name out of bounds")
            }
            let name = String(decoding: data[nameStart..<nameStart + nameLength], as: UTF8.self)

            // ZIP64: pull real sizes/offset from the extra field when the 32-bit
            // fields are saturated.
            let extraStart = nameStart + nameLength
            parseZip64Extra(data, start: extraStart, length: extraLength,
                            uncompressed: &uncompressedSize,
                            compressed: &compressedSize,
                            localHeaderOffset: &localHeaderOffset)

            let targetURL = try safeDestinationURL(for: name, in: destination)

            if name.hasSuffix("/") {
                try fileManager.createDirectory(at: targetURL, withIntermediateDirectories: true)
            } else {
                try fileManager.createDirectory(at: targetURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
                let contents = try extractEntry(data,
                                                localHeaderOffset: Int(localHeaderOffset),
                                                method: method,
                                                compressedSize: Int(compressedSize),
                                                uncompressedSize: Int(uncompressedSize))
                try contents.write(to: targetURL)
            }

            offset = extraStart + extraLength + commentLength
        }
    }

    // MARK: - Central directory location

    private struct CentralDirectory { var offset: Int; var count: Int }

    private static func locateCentralDirectory(in data: Data) throws -> CentralDirectory {
        // Scan backwards for the End Of Central Directory record (0x06054b50).
        let minEOCD = 22
        guard data.count >= minEOCD else { throw ZipExtractorError.notAZipArchive }

        let maxBack = min(data.count, minEOCD + 0xFFFF)
        var eocd = -1
        var i = data.count - minEOCD
        let limit = data.count - maxBack
        while i >= limit {
            if u32(data, i) == 0x0605_4b50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ZipExtractorError.notAZipArchive }

        var count = u16(data, eocd + 10)
        var cdOffset = UInt64(u32(data, eocd + 16))

        // ZIP64: when count/offset are saturated, follow the ZIP64 locator.
        if count == 0xFFFF || cdOffset == 0xFFFF_FFFF {
            let locatorOffset = eocd - 20
            if locatorOffset >= 0, u32(data, locatorOffset) == 0x0706_4b50 {
                let zip64EOCD = Int(u64(data, locatorOffset + 8))
                if zip64EOCD >= 0, zip64EOCD + 56 <= data.count,
                   u32(data, zip64EOCD) == 0x0606_4b50 {
                    count = Int(u64(data, zip64EOCD + 32))
                    cdOffset = u64(data, zip64EOCD + 48)
                }
            }
        }

        guard Int(cdOffset) <= data.count else {
            throw ZipExtractorError.corrupt("central directory offset out of bounds")
        }
        return CentralDirectory(offset: Int(cdOffset), count: count)
    }

    private static func parseZip64Extra(_ data: Data, start: Int, length: Int,
                                        uncompressed: inout UInt64,
                                        compressed: inout UInt64,
                                        localHeaderOffset: inout UInt64) {
        var p = start
        let end = start + length
        while p + 4 <= end, p + 4 <= data.count {
            let headerID = u16(data, p)
            let size = u16(data, p + 2)
            let fieldStart = p + 4
            if headerID == 0x0001 {
                var q = fieldStart
                if uncompressed == 0xFFFF_FFFF, q + 8 <= data.count { uncompressed = u64(data, q); q += 8 }
                if compressed == 0xFFFF_FFFF, q + 8 <= data.count { compressed = u64(data, q); q += 8 }
                if localHeaderOffset == 0xFFFF_FFFF, q + 8 <= data.count { localHeaderOffset = u64(data, q); q += 8 }
            }
            p = fieldStart + size
        }
    }

    // MARK: - Entry extraction

    private static func extractEntry(_ data: Data, localHeaderOffset: Int, method: UInt16,
                                     compressedSize: Int, uncompressedSize: Int) throws -> Data {
        guard localHeaderOffset + 30 <= data.count, u32(data, localHeaderOffset) == 0x0403_4b50 else {
            throw ZipExtractorError.corrupt("bad local file header")
        }
        let nameLength = u16(data, localHeaderOffset + 26)
        let extraLength = u16(data, localHeaderOffset + 28)
        let dataStart = localHeaderOffset + 30 + nameLength + extraLength
        guard dataStart + compressedSize <= data.count else {
            throw ZipExtractorError.corrupt("entry data out of bounds")
        }
        let compressed = data.subdata(in: dataStart..<dataStart + compressedSize)

        switch method {
        case 0: // stored
            return compressed
        case 8: // deflate
            return try inflate(compressed, expectedSize: uncompressedSize)
        default:
            throw ZipExtractorError.unsupportedCompression(method)
        }
    }

    private static func inflate(_ compressed: Data, expectedSize: Int) throws -> Data {
        // Empty payloads decode to nothing.
        if expectedSize == 0 { return Data() }

        let destinationSize = expectedSize
        var result = Data(count: destinationSize)
        let written = result.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
            compressed.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                guard let dstBase = dst.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let srcBase = src.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
                return compression_decode_buffer(dstBase, destinationSize,
                                                 srcBase, compressed.count,
                                                 nil, COMPRESSION_ZLIB)
            }
        }
        guard written == expectedSize else {
            throw ZipExtractorError.corrupt("inflate produced \(written) of \(expectedSize) bytes")
        }
        return result
    }

    // MARK: - Path safety

    /// Resolve `name` under `destination`, rejecting any entry that would escape it.
    private static func safeDestinationURL(for name: String, in destination: URL) throws -> URL {
        let target = destination.appendingPathComponent(name).standardizedFileURL
        let root = destination.standardizedFileURL
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard target.path == root.path || target.path.hasPrefix(rootPath) else {
            throw ZipExtractorError.unsafeEntryPath(name)
        }
        return target
    }

    // MARK: - Little-endian readers (absolute, 0-based offsets)

    private static func u16(_ d: Data, _ o: Int) -> Int {
        let b = d.startIndex
        return Int(d[b + o]) | (Int(d[b + o + 1]) << 8)
    }

    private static func u32(_ d: Data, _ o: Int) -> UInt32 {
        let b = d.startIndex
        return UInt32(d[b + o]) | (UInt32(d[b + o + 1]) << 8)
            | (UInt32(d[b + o + 2]) << 16) | (UInt32(d[b + o + 3]) << 24)
    }

    private static func u64(_ d: Data, _ o: Int) -> UInt64 {
        UInt64(u32(d, o)) | (UInt64(u32(d, o + 4)) << 32)
    }
}

//
//  AttachmentExtractor.swift
//  Ancient History
//
//  Decodes the actual bytes of a named attachment out of a raw MIME email body.
//  Email.body holds everything after the message's top-level headers — i.e. the
//  full multipart body, including each part's headers and its (base64 /
//  quoted-printable) encoded payload — so attachments can be extracted on demand
//  without re-reading the mbox or holding decoded bytes in memory.
//
//  Forked from MBox Explorer (MIT).
//

import Foundation

enum AttachmentExtractor {

    /// Decode the bytes of the attachment named `filename` from a raw MIME `body`.
    /// Returns nil if the part or its payload can't be found/decoded.
    static func extractData(named filename: String, fromBody body: String) -> Data? {
        let lines = body.components(separatedBy: "\n")

        // The header line of the part that declares this filename (in a
        // Content-Type name= or Content-Disposition filename= parameter).
        guard let nameIndex = lines.firstIndex(where: { references(filename, in: $0) }) else { return nil }

        // Part header block: walk back to the boundary/blank that starts it, and
        // forward to the blank line that ends it (the encoded payload follows).
        var headerStart = nameIndex
        while headerStart > 0 {
            let prev = lines[headerStart - 1]
            if prev.hasPrefix("--") || prev.trimmingCharacters(in: .whitespaces).isEmpty { break }
            headerStart -= 1
        }
        var payloadStart = nameIndex
        while payloadStart < lines.count && !lines[payloadStart].trimmingCharacters(in: .whitespaces).isEmpty {
            payloadStart += 1
        }
        payloadStart += 1   // skip the blank line separating headers from payload
        guard payloadStart <= lines.count else { return nil }

        // Content-Transfer-Encoding for this part (anywhere in its header block).
        var encoding = "7bit"
        for line in lines[headerStart..<min(payloadStart, lines.count)]
        where line.lowercased().hasPrefix("content-transfer-encoding:") {
            encoding = line.dropFirst("content-transfer-encoding:".count)
                .trimmingCharacters(in: .whitespaces).lowercased()
        }

        // Encoded payload runs until the next MIME boundary ("--…"). Base64/QP
        // payloads never start a line with "--", so this terminates cleanly.
        var payload: [String] = []
        var i = payloadStart
        while i < lines.count {
            if lines[i].hasPrefix("--") { break }
            payload.append(lines[i])
            i += 1
        }

        return decode(payload.joined(separator: "\n"), transferEncoding: encoding)
    }

    // MARK: - Helpers

    private static func references(_ filename: String, in line: String) -> Bool {
        line.lowercased().contains("name=") && line.contains(filename)
    }

    private static func decode(_ encoded: String, transferEncoding: String) -> Data? {
        switch transferEncoding {
        case "base64":
            return Data(base64Encoded: encoded, options: .ignoreUnknownCharacters)
        case "quoted-printable":
            return decodeQuotedPrintable(encoded)
        default: // 7bit / 8bit / binary
            return encoded.data(using: .utf8) ?? encoded.data(using: .isoLatin1)
        }
    }

    private static func decodeQuotedPrintable(_ s: String) -> Data {
        var bytes: [UInt8] = []
        let scalars = Array(s.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let c = scalars[i]
            if c == "=" {
                // Soft line break: "=\n" or "=\r\n"
                if i + 1 < scalars.count, scalars[i + 1] == "\n" {
                    i += 2; continue
                }
                if i + 2 < scalars.count, scalars[i + 1] == "\r", scalars[i + 2] == "\n" {
                    i += 3; continue
                }
                if i + 2 < scalars.count, let hi = hexValue(scalars[i + 1]), let lo = hexValue(scalars[i + 2]) {
                    bytes.append(UInt8(hi * 16 + lo)); i += 3; continue
                }
                bytes.append(UInt8(c.value & 0xFF)); i += 1
            } else {
                bytes.append(UInt8(c.value & 0xFF)); i += 1
            }
        }
        return Data(bytes)
    }

    private static func hexValue(_ s: Unicode.Scalar) -> Int? {
        switch s {
        case "0"..."9": return Int(s.value - 48)
        case "A"..."F": return Int(s.value - 55)
        case "a"..."f": return Int(s.value - 87)
        default: return nil
        }
    }
}

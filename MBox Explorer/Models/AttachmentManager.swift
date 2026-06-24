//
//  AttachmentManager.swift
//  MBox Explorer
//
//  Manages attachment extraction and filtering
//

import Foundation

class AttachmentManager {
    struct ExtendedAttachmentInfo: Identifiable, Hashable {
        let id: UUID
        let attachment: AttachmentInfo
        let email: Email
        let emailSubject: String
        let emailFrom: String
        let emailDate: Date?

        init(attachment: AttachmentInfo, email: Email, emailSubject: String, emailFrom: String, emailDate: Date?) {
            self.id = UUID()
            self.attachment = attachment
            self.email = email
            self.emailSubject = emailSubject
            self.emailFrom = emailFrom
            self.emailDate = emailDate
        }

        var filename: String { attachment.filename }
        var contentType: String { attachment.contentType }
        var size: Int? { attachment.size }
        var displaySize: String { attachment.displaySize }

        static func == (lhs: ExtendedAttachmentInfo, rhs: ExtendedAttachmentInfo) -> Bool {
            lhs.id == rhs.id
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(id)
        }
        var fileExtension: String {
            (filename as NSString).pathExtension.lowercased()
        }

        var categoryIcon: String {
            switch fileExtension {
            case "pdf": return "doc.fill"
            case "jpg", "jpeg", "png", "gif", "heic", "bmp", "tiff": return "photo.fill"
            case "doc", "docx", "txt", "rtf": return "doc.text.fill"
            case "xls", "xlsx", "csv": return "tablecells.fill"
            case "ppt", "pptx": return "presentation.fill"
            case "zip", "rar", "7z", "tar", "gz": return "doc.zipper"
            case "mp3", "wav", "m4a", "aac": return "music.note"
            case "mp4", "mov", "avi", "mkv": return "video.fill"
            default: return "doc"
            }
        }

        var category: AttachmentCategory {
            switch fileExtension {
            case "pdf": return .pdf
            case "jpg", "jpeg", "png", "gif", "heic", "bmp", "tiff": return .image
            case "doc", "docx", "txt", "rtf": return .document
            case "xls", "xlsx", "csv": return .spreadsheet
            case "ppt", "pptx": return .presentation
            case "zip", "rar", "7z", "tar", "gz": return .archive
            case "mp3", "wav", "m4a", "aac": return .audio
            case "mp4", "mov", "avi", "mkv": return .video
            default: return .other
            }
        }
    }

    enum AttachmentCategory: String, CaseIterable {
        case all = "All"
        case pdf = "PDFs"
        case image = "Images"
        case document = "Documents"
        case spreadsheet = "Spreadsheets"
        case presentation = "Presentations"
        case archive = "Archives"
        case audio = "Audio"
        case video = "Video"
        case other = "Other"
    }

    enum SortField {
        case filename
        case size
        case date
        case type
    }

    enum SortOrder {
        case ascending
        case descending
    }

    static func extractAllAttachments(from emails: [Email]) -> [ExtendedAttachmentInfo] {
        var result: [ExtendedAttachmentInfo] = []

        for email in emails {
            if let attachments = email.attachments {
                for attachment in attachments {
                    let info = ExtendedAttachmentInfo(
                        attachment: attachment,
                        email: email,
                        emailSubject: email.subject,
                        emailFrom: email.from,
                        emailDate: email.dateObject
                    )
                    result.append(info)
                }
            }
        }

        return result
    }

    static func filter(_ attachments: [ExtendedAttachmentInfo],
                      by category: AttachmentCategory,
                      searchText: String) -> [ExtendedAttachmentInfo] {
        var filtered = attachments

        // Category filter
        if category != .all {
            filtered = filtered.filter { $0.category == category }
        }

        // Search filter
        if !searchText.isEmpty {
            filtered = filtered.filter { info in
                info.filename.localizedCaseInsensitiveContains(searchText) ||
                info.emailSubject.localizedCaseInsensitiveContains(searchText) ||
                info.emailFrom.localizedCaseInsensitiveContains(searchText)
            }
        }

        return filtered
    }

    static func sort(_ attachments: [ExtendedAttachmentInfo],
                    by field: SortField,
                    order: SortOrder) -> [ExtendedAttachmentInfo] {
        let sorted: [ExtendedAttachmentInfo]

        switch field {
        case .filename:
            sorted = attachments.sorted { order == .ascending ? $0.filename < $1.filename : $0.filename > $1.filename }
        case .size:
            sorted = attachments.sorted {
                let size1 = $0.size ?? 0
                let size2 = $1.size ?? 0
                return order == .ascending ? size1 < size2 : size1 > size2
            }
        case .date:
            sorted = attachments.sorted {
                let date1 = $0.emailDate ?? .distantPast
                let date2 = $1.emailDate ?? .distantPast
                return order == .ascending ? date1 < date2 : date1 > date2
            }
        case .type:
            sorted = attachments.sorted {
                order == .ascending ? $0.fileExtension < $1.fileExtension : $0.fileExtension > $1.fileExtension
            }
        }

        return sorted
    }

    /// Decode each attachment from its email's raw body and write the actual file
    /// into `directory`. Returns the number successfully decoded + written; any
    /// that can't be decoded are listed in a manifest. Output names are sanitized
    /// to their last path component (attachment filenames are untrusted), so a
    /// crafted "../" name cannot escape the chosen directory.
    @discardableResult
    static func exportAttachments(_ attachments: [ExtendedAttachmentInfo], to directory: URL) throws -> Int {
        var usedNames = Set<String>()
        var exported = 0
        var failed: [String] = []

        for info in attachments {
            let outName = uniqueName(info.filename, in: &usedNames)
            if let data = AttachmentExtractor.extractData(named: info.filename, fromBody: info.email.body) {
                try data.write(to: directory.appendingPathComponent(outName))
                exported += 1
            } else {
                failed.append(info.filename)
            }
        }

        var manifest = "Attachment Export\nExported: \(Date())\nDecoded: \(exported) of \(attachments.count)\n"
        if !failed.isEmpty {
            manifest += "Could not decode (no payload found in message): \(failed.joined(separator: ", "))\n"
        }
        try? manifest.write(to: directory.appendingPathComponent("attachments_manifest.txt"),
                            atomically: true, encoding: .utf8)
        return exported
    }

    /// A collision-free, path-safe output filename (last path component only).
    private static func uniqueName(_ name: String, in used: inout Set<String>) -> String {
        let base = (name as NSString).lastPathComponent.trimmingCharacters(in: .whitespaces)
        var candidate = (base.isEmpty || base == "." || base == "..") ? "attachment" : base
        let ext = (candidate as NSString).pathExtension
        let stem = (candidate as NSString).deletingPathExtension
        var n = 1
        while used.contains(candidate.lowercased()) {
            candidate = ext.isEmpty ? "\(stem)-\(n)" : "\(stem)-\(n).\(ext)"
            n += 1
        }
        used.insert(candidate.lowercased())
        return candidate
    }

    static func getStatistics(from attachments: [ExtendedAttachmentInfo]) -> AttachmentStatistics {
        let totalCount = attachments.count
        let totalSize = attachments.compactMap { $0.size }.reduce(0, +)

        let categoryCounts = Dictionary(grouping: attachments, by: { $0.category })
            .mapValues { $0.count }

        let topFileTypes = Dictionary(grouping: attachments, by: { $0.fileExtension })
            .mapValues { $0.count }
            .sorted { $0.value > $1.value }
            .prefix(10)
            .map { ($0.key, $0.value) }

        return AttachmentStatistics(
            totalCount: totalCount,
            totalSize: totalSize,
            categoryCounts: categoryCounts,
            topFileTypes: topFileTypes
        )
    }

    struct AttachmentStatistics {
        let totalCount: Int
        let totalSize: Int
        let categoryCounts: [AttachmentCategory: Int]
        let topFileTypes: [(String, Int)]

        var totalSizeFormatted: String {
            ByteCountFormatter.string(fromByteCount: Int64(totalSize), countStyle: .file)
        }
    }
}

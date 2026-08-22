import Foundation

struct OpenCodePromptAttachment: Identifiable, Equatable, Sendable {
    static let maximumCount = 10
    static let maximumFileBytes = 20 * 1_024 * 1_024
    static let maximumTotalBytes = 20 * 1_024 * 1_024

    let id: UUID
    let filename: String
    let mimeType: String
    let data: Data

    init(
        id: UUID = UUID(),
        filename: String,
        mimeType: String,
        data: Data
    ) {
        self.id = id
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
    }

    var byteCount: Int { data.count }

    var formattedByteCount: String {
        ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
    }

    var dataURL: String {
        "data:\(mimeType);base64,\(data.base64EncodedString())"
    }

    static func validate(_ attachments: [Self]) throws {
        guard attachments.count <= maximumCount else {
            throw OpenCodePromptAttachmentError.tooMany(maximum: maximumCount)
        }

        var total = 0
        for attachment in attachments {
            guard !attachment.data.isEmpty else {
                throw OpenCodePromptAttachmentError.emptyFile(filename: attachment.filename)
            }
            guard attachment.byteCount <= maximumFileBytes else {
                throw OpenCodePromptAttachmentError.fileTooLarge(
                    filename: attachment.filename,
                    maximumBytes: maximumFileBytes
                )
            }
            total += attachment.byteCount
            guard total <= maximumTotalBytes else {
                throw OpenCodePromptAttachmentError.totalTooLarge(
                    maximumBytes: maximumTotalBytes
                )
            }
        }
    }
}

enum OpenCodePromptAttachmentError: LocalizedError, Equatable, Sendable {
    case tooMany(maximum: Int)
    case emptyFile(filename: String)
    case fileTooLarge(filename: String, maximumBytes: Int)
    case totalTooLarge(maximumBytes: Int)

    var errorDescription: String? {
        switch self {
        case .tooMany(let maximum):
            "Attach up to \(maximum) files to one message."
        case .emptyFile(let filename):
            "\(filename) is empty and can’t be attached."
        case .fileTooLarge(let filename, let maximumBytes):
            "\(filename) is larger than \(Self.formatted(maximumBytes))."
        case .totalTooLarge(let maximumBytes):
            "Attachments can total up to \(Self.formatted(maximumBytes)) per message."
        }
    }

    private static func formatted(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

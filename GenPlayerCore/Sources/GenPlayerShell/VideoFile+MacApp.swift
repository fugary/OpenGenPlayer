#if os(macOS)
import Foundation
import SwiftUI
import GenPlayerCore

public extension VideoFile {
    var normalizedExtension: String {
        URL(fileURLWithPath: name).pathExtension.lowercased()
    }
    
    var supportsTextPreview: Bool {
        ["txt", "md", "csv", "json", "xml", "nfo", "srt", "vtt", "ass", "log", "ini", "conf", "sh", "py", "swift"].contains(normalizedExtension)
    }
    
    var canOpenInPreviewSheet: Bool {
        if type == .video || type == .audio || type == .folder { return false }
        return true
    }
    
    var usesStyledFormatTile: Bool {
        switch type {
        case .document, .unknown:
            return true
        default:
            return false
        }
    }
    
    var formatBadgeText: String? {
        switch normalizedExtension {
        case "pdf": return "PDF"
        case "doc", "docx", "pages": return "DOC"
        case "xls", "xlsx", "csv", "numbers": return "XLS"
        case "ppt", "pptx", "key": return "PPT"
        case "zip", "rar", "7z", "tar", "gz": return "ZIP"
        case "txt", "rtf", "md", "nfo": return "TXT"
        case "xml", "json", "html", "css", "js": return "CODE"
        case "psd", "ai", "sketch", "fig": return "DSGN"
        default: return nil
        }
    }
    
    var iconName: String {
        switch formatBadgeText {
        case "PDF": return "doc.text.fill"
        case "DOC": return "doc.text.fill"
        case "XLS": return "chart.bar.doc.horizontal.fill"
        case "PPT": return "doc.richtext.fill"
        case "ZIP": return "doc.zipper"
        case "TXT", "CODE": return "doc.plaintext.fill"
        case "DSGN": return "paintpalette.fill"
        default: return "doc.fill"
        }
    }
    
    var iconColor: Color {
        switch formatBadgeText {
        case "PDF": return .red
        case "DOC": return .blue
        case "XLS": return .green
        case "PPT": return .orange
        case "ZIP": return .gray
        case "TXT", "CODE": return .gray
        case "DSGN": return .purple
        default: return .gray
        }
    }
    
    var showsMacPreviewIndicatorBadge: Bool {
        type == .video || type == .audio || type == .image
    }
    
    var macPlaybackBadgeSystemImage: String {
        switch type {
        case .audio: return "music.note"
        case .image: return "photo"
        default: return "play.fill"
        }
    }
}
#endif

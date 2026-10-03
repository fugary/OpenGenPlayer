import SwiftUI

struct MetadataInfoView: View {
    let providerIds: [String: String]?
    let genres: [String]?
    let people: [PersonProtocol]?
    var alignment: HorizontalAlignment = .center
    
    var body: some View {
        VStack(alignment: alignment, spacing: 8) {
            // 1. Genres
            if let genres = genres, !genres.isEmpty {
                Text(genres.joined(separator: " / "))
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.8))
                    .multilineTextAlignment(alignment == .leading ? .leading : .center)
            }
            
            // 2. Provider Links Row
            if let providerIds = providerIds, !providerIds.isEmpty {
                // Check if we have any valid badges to show
                let keys = providerIds.keys.sorted()
                let validKeys = keys.filter { key in
                    providerIds[key] != nil && getProviderURL(key: key, id: providerIds[key]!) != nil
                }
                
                if !validKeys.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(validKeys, id: \.self) { key in
                            ProviderBadge(key: key, id: providerIds[key]!)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: 500, alignment: Alignment(horizontal: alignment, vertical: .center))
    }
    
    // Helper to check for valid URL for badge filtering
    private func getProviderURL(key: String, id: String) -> URL? {
        if id.starts(with: "http") { return URL(string: id) }
        let lowerKey = key.lowercased().replacingOccurrences(of: "id", with: "")
        if lowerKey.contains("imdb") || lowerKey.contains("douban") || 
           lowerKey.contains("tmdb") || lowerKey.contains("moviedb") || 
           lowerKey.contains("tvdb") {
            return URL(string: "http://dummy") // Return dummy to signal valid
        }
        return nil
    }
}

// MARK: - Subviews

struct ProviderBadge: View {
    let key: String
    let id: String
    
    var url: URL? {
        getProviderURL(key: key, id: id)
    }
    
    var label: String {
        // Clean up key names (e.g., "DoubanID" -> "Douban")
        key.replacingOccurrences(of: "Id", with: "", options: [.caseInsensitive, .backwards])
           .replacingOccurrences(of: "ID", with: "")
           .uppercased()
    }
    
    var body: some View {
        // Only render if URL exists
        if let url = url {
            Link(destination: url) {
                BadgeContent(label: label, isLink: true)
            }
            .buttonStyle(PlainButtonStyle())
        }
    }
    
    struct BadgeContent: View {
        let label: String
        let isLink: Bool
        
        var body: some View {
            Text(label)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.accentColor.opacity(0.8))
                .cornerRadius(6)
        }
    }
    
    private func getProviderURL(key: String, id: String) -> URL? {
        if id.starts(with: "http") { return URL(string: id) }
        
        let lowerKey = key.lowercased()
        let cleanKey = lowerKey.replacingOccurrences(of: "id", with: "")
        
        var urlString = ""
        
        // Handle various provider keys
        if cleanKey.contains("imdb") {
            urlString = "https://www.imdb.com/title/\(id)/"
        } else if cleanKey.contains("douban") {
            urlString = "https://movie.douban.com/subject/\(id)/"
        } else if cleanKey.contains("tmdb") || cleanKey.contains("moviedb") {
             urlString = "https://www.themoviedb.org/movie/\(id)"
        } else if cleanKey.contains("tvdb") {
             urlString = "https://thetvdb.com/?id=\(id)&tab=series"
        }
        
        // Return nil if no URL generated
        if urlString.isEmpty { return nil }
        
        return URL(string: urlString)
    }
}

struct MetadataRow: View {
    let label: String
    let content: String
    
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.5))
                .frame(width: 70, alignment: .leading)
            
            Text(content)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.9))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct PlaybackCTAProgress: Equatable {
    let playedText: String
    let totalText: String
    let percentText: String
    let fraction: Double

    var clampedFraction: Double {
        min(max(fraction, 0), 1)
    }
}

struct PrimaryPlaybackCTAButton: View {
    let title: String
    var iconSystemName: String = "play.fill"
    var progress: PlaybackCTAProgress? = nil
    var isLoading: Bool = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            if let progress = progress {
                progressButtonContent(progress: progress)
            } else {
                plainButtonContent
            }
        }
        .buttonStyle(PlainButtonStyle())
        .contentShape(Capsule())
    }

    private var plainButtonContent: some View {
        HStack(spacing: 8) {
            if isLoading {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .black))
            } else {
                Image(systemName: iconSystemName)
            }
            Text(title)
                .fontWeight(.bold)
        }
        .font(.headline)
        .frame(maxWidth: .infinity)
        .frame(height: Self.buttonHeight)
        .background(Color.white)
        .foregroundColor(.black)
        .clipShape(Capsule())
    }

    private func progressButtonContent(progress: PlaybackCTAProgress) -> some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.white)

            GeometryReader { geo in
                Capsule()
                    .fill(Color.accentColor.opacity(0.18))
                    .frame(width: geo.size.width * CGFloat(progress.clampedFraction))
            }
            .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.buttonHeight)
        .overlay(
            Capsule()
                .stroke(Color.black.opacity(0.08), lineWidth: 0.6)
        )
        .shadow(color: .black.opacity(0.06), radius: 1, x: 0, y: 1)
        .overlay(
            VStack(alignment: .center, spacing: 4) {
                HStack(spacing: 8) {
                    if isLoading {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .black))
                    } else {
                        Image(systemName: iconSystemName)
                    }
                    Text(title)
                        .fontWeight(.bold)
                }
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .center)

                HStack(spacing: 6) {
                    Text(progress.playedText)
                    Text("/")
                    Text(progress.totalText)
                    Text("·")
                    Text(progress.percentText)
                        .fontWeight(.semibold)
                }
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundColor(.black.opacity(0.72))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .foregroundColor(.black)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        )
        .clipShape(Capsule())
    }

    private static let buttonHeight: CGFloat = 58
}

func personCardSubtitle(role: String?, type: String?) -> String? {
    let cleanedRole = role?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let cleanedType = type?
        .trimmingCharacters(in: .whitespacesAndNewlines)

    if let cleanedRole, !cleanedRole.isEmpty {
        if let cleanedType,
           !cleanedType.isEmpty,
           cleanedRole.compare(cleanedType, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
            return cleanedType
        }
        return cleanedRole
    }

    if let cleanedType, !cleanedType.isEmpty {
        return cleanedType
    }

    return nil
}

// Protocol to abstract Person across Jellyfin and Emby
protocol PersonProtocol {
    var name: String { get }
    var type: String? { get }
}

// Extension to make models conform
extension JellyfinPerson: PersonProtocol {}
extension EmbyPerson: PersonProtocol {}
extension PlexPerson: PersonProtocol {}

struct FilePathBadgeRow: View {
    let path: String
    var onCopy: (() -> Void)? = nil
    
    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Image(systemName: "folder")
                .font(.caption2)
                .foregroundColor(.white.opacity(0.6))
            
            Text(path)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.white.opacity(0.72))
                .lineLimit(1)
                .truncationMode(.middle)
            
            if let onCopy = onCopy {
                Button(action: onCopy) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.9))
                        .padding(4)
                        .background(Color.white.opacity(0.15))
                        .clipShape(Circle())
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color.white.opacity(0.08))
        .cornerRadius(6)
    }
}


#if os(macOS)
import SwiftUI
import AppKit
import GenPlayerCore

public struct MacIPTVProgramGuideSheet: View {
    public let channel: IPTVChannel
    public let server: ServerConfig
    public let onPlay: () -> Void
    public let onDismiss: () -> Void
    
    @ObservedObject private var epgService = EPGService.shared
    @State private var selectedDateIndex: Int = 1 // 0: Yesterday, 1: Today, 2: Tomorrow, 3: Day after
    
    private let availableDates: [Date] = {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return [
            calendar.date(byAdding: .day, value: -1, to: today) ?? today,
            today,
            calendar.date(byAdding: .day, value: 1, to: today) ?? today,
            calendar.date(byAdding: .day, value: 2, to: today) ?? today
        ]
    }()
    
    public init(
        channel: IPTVChannel,
        server: ServerConfig,
        onPlay: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.channel = channel
        self.server = server
        self.onPlay = onPlay
        self.onDismiss = onDismiss
    }
    
    private var selectedDate: Date {
        if selectedDateIndex >= 0 && selectedDateIndex < availableDates.count {
            return availableDates[selectedDateIndex]
        }
        return Date()
    }
    
    private var dayProgrammes: [EPGProgramme] {
        epgService.programmes(for: channel, in: server.id, on: selectedDate)
    }
    
    private var currentLiveProgramme: EPGProgramme? {
        epgService.currentProgramme(for: channel, in: server.id)
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(NSColor.textBackgroundColor).opacity(0.6))
                    
                    if let logoURL = channel.logoURL {
                        MacCachedAsyncImage(url: logoURL) { phase in
                            switch phase {
                            case .success(let img):
                                img.resizable().scaledToFit().padding(4)
                            default:
                                Image(systemName: "play.tv.fill").font(.system(size: 20)).foregroundColor(.secondary.opacity(0.4))
                            }
                        }
                    } else {
                        Image(systemName: "play.tv.fill").font(.system(size: 20)).foregroundColor(.secondary.opacity(0.4))
                    }
                }
                .frame(width: 60, height: 42)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(channel.name)
                        .font(.title3.bold())
                        .foregroundColor(.primary)
                    
                    Text(platformShellString("Program Guide"))
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Button(action: {
                    onDismiss()
                    onPlay()
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "play.fill")
                        Text(platformShellString("Play"))
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            // Date Picker Bar
            HStack(spacing: 8) {
                ForEach(0..<availableDates.count, id: \.self) { idx in
                    let date = availableDates[idx]
                    let isSelected = selectedDateIndex == idx
                    let title = dateTitle(for: date, index: idx)
                    let subtitle = dateSubtitle(for: date)
                    
                    Button(action: { selectedDateIndex = idx }) {
                        VStack(spacing: 2) {
                            Text(title)
                                .font(.system(size: 12, weight: isSelected ? .bold : .medium))
                                .foregroundColor(isSelected ? .white : .primary)
                            Text(subtitle)
                                .font(.system(size: 10))
                                .foregroundColor(isSelected ? Color.white.opacity(0.85) : .secondary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 5)
                        .background(isSelected ? Color.accentColor : Color(NSColor.controlBackgroundColor))
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
            
            Divider()
            
            // Programme List
            if dayProgrammes.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.system(size: 38))
                        .foregroundColor(.secondary.opacity(0.4))
                    Text(platformShellString("No Program Guide Available"))
                        .font(.headline)
                    Text(platformShellString("No schedule data found for this channel."))
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(40)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(dayProgrammes) { prog in
                                MacProgramGuideRow(programme: prog)
                                    .id(prog.id)
                            }
                        }
                        .padding(16)
                    }
                    .onAppear {
                        if selectedDateIndex == 1, let live = currentLiveProgramme {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                withAnimation {
                                    proxy.scrollTo(live.id, anchor: .center)
                                }
                            }
                        }
                    }
                }
            }
        }
        .frame(width: 520, height: 600)
    }
    
    private func dateTitle(for date: Date, index: Int) -> String {
        if index == 0 {
            return platformShellString("Yesterday")
        } else if index == 1 {
            return platformShellString("Today")
        } else if index == 2 {
            return platformShellString("Tomorrow")
        } else {
            return EPGDateFormatter.dayOfWeekFormatter.string(from: date)
        }
    }
    
    private func dateSubtitle(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd"
        return formatter.string(from: date)
    }
}

// MARK: - Mac Program Guide Row

private struct MacProgramGuideRow: View {
    let programme: EPGProgramme
    
    private var isLive: Bool { programme.isLive() }
    private var isPast: Bool { programme.isPast() }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Text(programme.formattedStartTime)
                    .font(.system(size: 13, weight: isLive ? .bold : .semibold, design: .monospaced))
                    .foregroundColor(isLive ? .accentColor : (isPast ? .secondary.opacity(0.6) : .secondary))
                    .frame(width: 46, alignment: .leading)
                
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(programme.title)
                            .font(.system(size: 13.5, weight: isLive ? .bold : .medium))
                            .foregroundColor(isPast ? .secondary : .primary)
                            .lineLimit(1)
                        
                        if isLive {
                            HStack(spacing: 3) {
                                Circle().fill(Color.red).frame(width: 5, height: 5)
                                Text(platformShellString("Live"))
                                    .font(.system(size: 9.5, weight: .bold))
                                    .foregroundColor(.white)
                            }
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(Color.red))
                        }
                    }
                    
                    Text("\(programme.formattedStartTime) - \(programme.formattedEndTime)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                
                Spacer()
            }
            
            if let desc = programme.desc?.trimmingCharacters(in: .whitespacesAndNewlines), !desc.isEmpty {
                Text(desc)
                    .font(.system(size: 11.5))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .padding(.leading, 58)
            }
            
            if isLive {
                let progVal = programme.progress()
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.2)).frame(height: 3)
                        Capsule().fill(Color.accentColor).frame(width: max(0, min(geo.size.width, geo.size.width * CGFloat(progVal))), height: 3)
                    }
                }
                .frame(height: 3)
                .padding(.leading, 58)
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isLive ? Color.accentColor.opacity(0.08) : Color(NSColor.controlBackgroundColor).opacity(0.4))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isLive ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.04), lineWidth: 1)
        )
    }
}
#endif

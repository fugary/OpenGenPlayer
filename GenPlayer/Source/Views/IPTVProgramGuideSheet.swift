import SwiftUI
import GenPlayerCore

public struct IPTVProgramGuideSheet: View {
    public let channel: IPTVChannel
    public let server: ServerConfig
    public let onPlay: () -> Void
    
    @ObservedObject private var epgService = EPGService.shared
    @Environment(\.presentationMode) private var presentationMode
    
    @State private var selectedDateIndex: Int = 1 // 0: Yesterday, 1: Today, 2: Tomorrow, etc.
    
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
    
    public init(channel: IPTVChannel, server: ServerConfig, onPlay: @escaping () -> Void) {
        self.channel = channel
        self.server = server
        self.onPlay = onPlay
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
        NavigationView {
            VStack(spacing: 0) {
                // Channel Header Banner
                channelHeaderBanner
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 10)
                
                // Date Selector Tab Bar
                dateSelectorBar
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                
                Divider()
                
                // Programme Schedule Timeline
                if dayProgrammes.isEmpty {
                    emptyProgrammesView
                } else {
                    programmesTimelineView
                }
            }
            .background(Color(UIColor.systemGroupedBackground).ignoresSafeArea())
            .navigationBarTitle(NSLocalizedString("Program Guide", comment: ""), displayMode: .inline)
            .navigationBarItems(
                leading: Button(action: {
                    presentationMode.wrappedValue.dismiss()
                }) {
                    AppToolbarIcon(systemName: "xmark", style: .secondary)
                },
                trailing: Button(action: {
                    presentationMode.wrappedValue.dismiss()
                    onPlay()
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 12))
                        Text(NSLocalizedString("Play", comment: ""))
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundColor(Color.accentColor)
                }
            )
        }
    }
    
    // MARK: - Channel Header Banner
    
    private var channelHeaderBanner: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(UIColor.tertiarySystemFill).opacity(0.7))
                
                if let logoURL = channel.logoURL {
                    RemoteImage(
                        url: logoURL,
                        placeholderSystemImage: "play.tv.fill",
                        contentMode: .fit
                    )
                    .padding(6)
                } else {
                    Image(systemName: "play.tv.fill")
                        .font(.system(size: 22))
                        .foregroundColor(Color(UIColor.tertiaryLabel))
                }
            }
            .aspectRatio(16/9, contentMode: .fit)
            .frame(width: 72)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(channel.name)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(Color(UIColor.label))
                    .lineLimit(1)
                
                if let live = currentLiveProgramme {
                    HStack(spacing: 6) {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 6, height: 6)
                            Text(NSLocalizedString("Live", comment: ""))
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.white)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.red.opacity(0.9)))
                        
                        Text(live.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(Color(UIColor.secondaryLabel))
                            .lineLimit(1)
                    }
                } else if !channel.group.isEmpty {
                    Text(channel.group)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Color(UIColor.secondaryLabel))
                        .lineLimit(1)
                }
            }
            
            Spacer()
        }
        .padding(12)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(14)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 0.8)
        )
    }
    
    // MARK: - Date Selector Bar
    
    private var dateSelectorBar: some View {
        HStack(spacing: 8) {
            ForEach(0..<availableDates.count, id: \.self) { idx in
                let date = availableDates[idx]
                let isSelected = selectedDateIndex == idx
                let title = dateTitle(for: date, index: idx)
                
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        selectedDateIndex = idx
                    }
                }) {
                    VStack(spacing: 2) {
                        Text(title)
                            .font(.system(size: 13, weight: isSelected ? .bold : .medium))
                            .foregroundColor(isSelected ? .white : Color(UIColor.label))
                        
                        Text(dateSubtitle(for: date))
                            .font(.system(size: 10))
                            .foregroundColor(isSelected ? Color.white.opacity(0.85) : Color(UIColor.secondaryLabel))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(isSelected ? Color.accentColor : Color(UIColor.secondarySystemGroupedBackground))
                    .cornerRadius(10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(isSelected ? Color.accentColor : Color.primary.opacity(0.06), lineWidth: 0.8)
                    )
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
    }
    
    private func dateTitle(for date: Date, index: Int) -> String {
        if index == 0 {
            return NSLocalizedString("Yesterday", comment: "")
        } else if index == 1 {
            return NSLocalizedString("Today", comment: "")
        } else if index == 2 {
            return NSLocalizedString("Tomorrow", comment: "")
        } else {
            return EPGDateFormatter.dayOfWeekFormatter.string(from: date)
        }
    }
    
    private func dateSubtitle(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd"
        return formatter.string(from: date)
    }
    
    // MARK: - Programmes Timeline
    
    private var programmesTimelineView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(dayProgrammes) { prog in
                        EPGProgrammeRow(programme: prog)
                            .id(prog.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .onAppear {
                if selectedDateIndex == 1, let live = currentLiveProgramme {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        withAnimation {
                            proxy.scrollTo(live.id, anchor: .center)
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - Empty State
    
    private var emptyProgrammesView: some View {
        VStack(spacing: 16) {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 48))
                .foregroundColor(Color(UIColor.tertiaryLabel))
            
            Text(NSLocalizedString("No Program Guide Available", comment: ""))
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(Color(UIColor.label))
            
            Text(NSLocalizedString("No schedule data found for this channel.", comment: ""))
                .font(.system(size: 13))
                .foregroundColor(Color(UIColor.secondaryLabel))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 60)
    }
}

// MARK: - Single EPG Programme Row Component

private struct EPGProgrammeRow: View {
    let programme: EPGProgramme
    
    private var isLive: Bool {
        programme.isLive()
    }
    
    private var isPast: Bool {
        programme.isPast()
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                // Time Badge
                Text(programme.formattedStartTime)
                    .font(.system(size: 14, weight: isLive ? .bold : .semibold, design: .monospaced))
                    .foregroundColor(isLive ? Color.accentColor : (isPast ? Color(UIColor.tertiaryLabel) : Color(UIColor.secondaryLabel)))
                    .frame(width: 48, alignment: .leading)
                
                // Title and badges
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(programme.title)
                            .font(.system(size: 15, weight: isLive ? .bold : .medium))
                            .foregroundColor(isPast ? Color(UIColor.secondaryLabel) : Color(UIColor.label))
                            .lineLimit(1)
                        
                        if isLive {
                            HStack(spacing: 3) {
                                Circle()
                                    .fill(Color.red)
                                    .frame(width: 5, height: 5)
                                Text(NSLocalizedString("Live", comment: ""))
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(.white)
                            }
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(Color.red))
                        }
                    }
                    
                    Text("\(programme.formattedStartTime) - \(programme.formattedEndTime)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Color(UIColor.tertiaryLabel))
                }
                
                Spacer()
            }
            
            // Description (if present)
            if let desc = programme.desc?.trimmingCharacters(in: .whitespacesAndNewlines), !desc.isEmpty {
                Text(desc)
                    .font(.system(size: 12))
                    .foregroundColor(Color(UIColor.secondaryLabel))
                    .lineLimit(2)
                    .padding(.leading, 58)
            }
            
            // Progress Bar for currently live programme
            if isLive {
                let progVal = programme.progress()
                VStack(alignment: .leading, spacing: 2) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color(UIColor.tertiarySystemFill))
                                .frame(height: 4)
                            Capsule()
                                .fill(Color.accentColor)
                                .frame(width: geo.size.width * CGFloat(progVal), height: 4)
                        }
                    }
                    .frame(height: 4)
                    .padding(.leading, 58)
                    .padding(.top, 2)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isLive ? Color.accentColor.opacity(0.08) : Color(UIColor.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isLive ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.04), lineWidth: isLive ? 1.2 : 0.6)
        )
    }
}

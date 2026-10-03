#if os(tvOS)
import SwiftUI
import GenPlayerCore

public struct TVIPTVProgramGuideSheet: View {
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
        TVPageScrollView(
            title: channel.name,
            subtitle: platformShellString("Program Guide"),
            handlesExitCommand: true,
            customExitCommand: {
                onDismiss()
                return true
            },
            titleAccessory: AnyView(
                HStack(spacing: 14) {
                    Button(action: {
                        onDismiss()
                        onPlay()
                    }) {
                        TVTopChromeIconButton(
                            title: platformShellString("Play"),
                            systemImageName: "play.fill",
                            diameter: 66
                        )
                    }
                    .buttonStyle(TVPlainButtonStyle())
                    .tvDisableSystemFocusEffect()
                    
                    Button(action: onDismiss) {
                        TVTopChromeIconButton(
                            title: platformShellString("Close"),
                            systemImageName: "xmark",
                            diameter: 66
                        )
                    }
                    .buttonStyle(TVPlainButtonStyle())
                    .tvDisableSystemFocusEffect()
                }
            )
        ) {
            // Date Tabs Bar
            dateTabsRow
                .padding(.bottom, 24)
            
            if dayProgrammes.isEmpty {
                emptyGuideView
            } else {
                programmesList
            }
        }
    }
    
    // MARK: - Date Tabs
    
    private var dateTabsRow: some View {
        HStack(spacing: 16) {
            ForEach(0..<availableDates.count, id: \.self) { idx in
                let date = availableDates[idx]
                let isSelected = selectedDateIndex == idx
                let title = dateTitle(for: date, index: idx)
                let subtitle = dateSubtitle(for: date)
                
                Button(action: {
                    selectedDateIndex = idx
                }) {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(.system(size: 22, weight: .bold))
                        Text(subtitle)
                            .font(.system(size: 16, weight: .semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                Capsule()
                                    .fill(Color.primary.opacity(0.14))
                            )
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                }
                .buttonStyle(TVCategoryTabButtonStyle(isSelected: isSelected))
                .tvDisableSystemFocusEffect()
            }
        }
        .tvFocusSectionIfAvailable()
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
    
    // MARK: - Programmes List
    
    private var programmesList: some View {
        VStack(spacing: 12) {
            ForEach(dayProgrammes) { prog in
                TVProgramGuideRow(programme: prog)
            }
        }
        .tvFocusSectionIfAvailable()
    }
    
    // MARK: - Empty State
    
    private var emptyGuideView: some View {
        VStack(spacing: 20) {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 60))
                .foregroundColor(TVShellStyle.secondary.opacity(0.4))
            Text(platformShellString("No Program Guide Available"))
                .font(.system(size: 32, weight: .bold))
                .foregroundColor(TVShellStyle.primary)
            Text(platformShellString("No schedule data found for this channel."))
                .font(.system(size: 22))
                .foregroundColor(TVShellStyle.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80)
    }
}

// MARK: - TV Program Guide Row

private struct TVProgramGuideRow: View {
    let programme: EPGProgramme
    
    @Environment(\.isFocused) private var isFocused
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme
    
    private var isLive: Bool { programme.isLive() }
    private var isPast: Bool { programme.isPast() }
    
    private var showsFocus: Bool { isFocused && isEnabled }
    
    var body: some View {
        HStack(spacing: 24) {
            // Time Range
            Text(programme.formattedStartTime)
                .font(.system(size: 24, weight: isLive ? .bold : .medium, design: .monospaced))
                .foregroundColor(isLive ? TVShellStyle.accentSoft : (isPast ? TVShellStyle.secondary.opacity(0.6) : TVShellStyle.secondary))
                .frame(width: 80, alignment: .leading)
            
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    Text(programme.title)
                        .font(.system(size: 24, weight: isLive ? .bold : .semibold))
                        .foregroundColor(showsFocus ? TVRowFocusStyle.primary(showsFocus: true, isEnabled: isEnabled, colorScheme: colorScheme) : (isPast ? TVShellStyle.secondary : TVShellStyle.primary))
                        .lineLimit(1)
                    
                    if isLive {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 8, height: 8)
                            Text(platformShellString("Live"))
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.white)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.red))
                    }
                }
                
                if let desc = programme.desc?.trimmingCharacters(in: .whitespacesAndNewlines), !desc.isEmpty {
                    Text(desc)
                        .font(.system(size: 18))
                        .foregroundColor(TVShellStyle.secondary)
                        .lineLimit(2)
                }
                
                if isLive {
                    let progVal = programme.progress()
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.white.opacity(0.15))
                                .frame(height: 5)
                            Capsule()
                                .fill(TVShellStyle.accentSoft)
                                .frame(width: max(0, min(geo.size.width, geo.size.width * CGFloat(progVal))), height: 5)
                        }
                    }
                    .frame(height: 5)
                    .padding(.top, 4)
                }
            }
            
            Spacer()
            
            Text(programme.formattedTimeSpan)
                .font(.system(size: 18, design: .monospaced))
                .foregroundColor(TVShellStyle.secondary)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(isLive ? TVShellStyle.accentSoft.opacity(0.12) : TVShellStyle.surface.opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(isLive ? TVShellStyle.accentSoft.opacity(0.4) : Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}
#endif

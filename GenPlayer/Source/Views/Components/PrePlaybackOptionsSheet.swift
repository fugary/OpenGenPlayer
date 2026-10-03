import SwiftUI

struct PrePlaybackTrackOption: Identifiable, Equatable {
    static let subtitleOffID = "__subtitle_off__"

    let id: String
    let title: String
    let subtitle: String?
    let query: String?

    init(id: String, title: String, subtitle: String? = nil, query: String?) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.query = query
    }
}

struct PrePlaybackOptionsSheet: View {
    let qualityOptions: [PrePlaybackTrackOption]
    let audioOptions: [PrePlaybackTrackOption]
    let subtitleOptions: [PrePlaybackTrackOption]
    @Binding var selectedQualityID: String?
    @Binding var selectedAudioID: String?
    @Binding var selectedSubtitleID: String?
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationView {
            ZStack {
                LinearGradient(
                    colors: [Color.black.opacity(0.96), Color.black.opacity(0.88)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 14) {
                        if !qualityOptions.isEmpty {
                            optionCard(
                                title: NSLocalizedString("Playback Quality", comment: ""),
                                icon: RemotePlaybackQualityCatalog.menuIconSystemName,
                                options: qualityOptions,
                                selectedID: selectedQualityID
                            ) { option in
                                selectedQualityID = option.id
                            }
                        }

                        if !audioOptions.isEmpty {
                            optionCard(
                                title: NSLocalizedString("Audio Track", comment: ""),
                                icon: "speaker.wave.2",
                                options: audioOptions,
                                selectedID: selectedAudioID
                            ) { option in
                                selectedAudioID = option.id
                            }
                        }

                        if !subtitleOptions.isEmpty {
                            optionCard(
                                title: NSLocalizedString("Subtitle Track", comment: ""),
                                icon: "captions.bubble",
                                options: subtitleOptions,
                                selectedID: selectedSubtitleID
                            ) { option in
                                selectedSubtitleID = option.id
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 20)
                }
            }
            .frame(minWidth: 320, idealWidth: 360, minHeight: 300, idealHeight: 450)
            .navigationBarTitle(NSLocalizedString("Playback Options", comment: ""), displayMode: .inline)
            .navigationBarItems(
                leading: Button(NSLocalizedString("Cancel", comment: "")) {
                    onCancel()
                },
                trailing: Button(NSLocalizedString("Play", comment: "")) {
                    onConfirm()
                }
            )
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    private func optionCard(
        title: String,
        icon: String,
        options: [PrePlaybackTrackOption],
        selectedID: String?,
        onSelect: @escaping (PrePlaybackTrackOption) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.85))

                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.white.opacity(0.9))
            }

            VStack(spacing: 8) {
                ForEach(options) { option in
                    Button(action: {
                        onSelect(option)
                    }) {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(option.title)
                                    .font(.system(size: 15))
                                    .foregroundColor(.white.opacity(0.92))
                                    .lineLimit(1)

                                if let subtitle = option.subtitle, !subtitle.isEmpty {
                                    Text(subtitle)
                                        .font(.system(size: 12))
                                        .foregroundColor(.white.opacity(0.6))
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            selectionIndicator(isSelected: selectedID == option.id)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 11)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill((selectedID == option.id ? Color.accentColor : Color.white).opacity(selectedID == option.id ? 0.24 : 0.08))
                        )
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.white.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )
        )
    }

    private func selectionIndicator(isSelected: Bool) -> some View {
        ZStack {
            Circle()
                .stroke(isSelected ? Color.accentColor : Color.white.opacity(0.35), lineWidth: 1.6)
                .frame(width: 20, height: 20)

            if isSelected {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 10, height: 10)
            }
        }
    }
}

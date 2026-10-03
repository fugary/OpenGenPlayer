#if os(macOS)
import SwiftUI
import GenPlayerCore

struct MacSettingsAppIconView: View {
    var onNavigateToDonation: (() -> Void)? = nil

    @ObservedObject private var appIconService = AppIconService.shared
    @ObservedObject private var donationService = DonationService.shared

    @State private var isApplyingIcon = false
    @State private var errorMessage: String? = nil
    @State private var showingErrorAlert = false
    @State private var showingDonationModal = false

    private let previewSize: CGFloat = 64
    private let previewCornerRadius: CGFloat = 14
    private let gridSpacing: CGFloat = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Supporter Exclusive Section
            if !appIconService.exclusiveOptions.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Image(systemName: "crown.fill")
                            .foregroundColor(.yellow)
                        Text(platformShellString("Supporter Exclusive"))
                            .font(.headline)
                            .foregroundColor(.primary)
                        Spacer()
                        if donationService.isLifetimeSupporter {
                            Text(platformShellString("Unlocked"))
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.green)
                        }
                    }

                    Text(platformShellString("Exclusive black and white gold edition icons. Unlocked by supporting GenPlayer."))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Divider()
                        .opacity(0.5)

                    LazyVGrid(
                        columns: [
                            GridItem(.adaptive(minimum: 72, maximum: 88), spacing: gridSpacing, alignment: .top)
                        ],
                        alignment: .leading,
                        spacing: gridSpacing
                    ) {
                        ForEach(appIconService.exclusiveOptions) { option in
                            Button(action: {
                                handleIconTap(option)
                            }) {
                                exclusiveIconCard(option)
                            }
                            .buttonStyle(PlainButtonStyle())
                            .disabled(isApplyingIcon)
                        }
                    }
                }
                .padding(16)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(14)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.secondary.opacity(0.1), lineWidth: 1)
                )
            }

            // Regular Icons Section
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(platformShellString("Launcher Icon Styles"))
                        .font(.headline)
                        .foregroundColor(.primary)
                    Spacer()
                    Button(action: {
                        appIconService.restoreDefaultIcon()
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.caption)
                            Text(platformShellString("Restore Default Icon"))
                                .font(.caption)
                        }
                        .foregroundColor(.secondary)
                    }
                    .buttonStyle(PlainButtonStyle())
                }

                Text(platformShellString("Choose a launcher icon style. Changes apply immediately after selection."))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()
                    .opacity(0.5)

                LazyVGrid(
                    columns: [
                        GridItem(.adaptive(minimum: 72, maximum: 88), spacing: gridSpacing, alignment: .top)
                    ],
                    alignment: .leading,
                    spacing: gridSpacing
                ) {
                    ForEach(appIconService.regularOptions) { option in
                        Button(action: {
                            applyIcon(option)
                        }) {
                            iconOptionCard(option)
                        }
                        .buttonStyle(PlainButtonStyle())
                        .disabled(isApplyingIcon)
                    }
                }
            }
            .padding(16)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(14)
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.secondary.opacity(0.1), lineWidth: 1)
            )
        }
        .sheet(isPresented: $showingDonationModal) {
            VStack(alignment: .trailing, spacing: 0) {
                Button(action: {
                    showingDonationModal = false
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.secondary)
                        .padding(12)
                }
                .buttonStyle(PlainButtonStyle())

                ScrollView {
                    MacSettingsDonationView(isPresentedModally: true, onChangeAppIcon: {
                        showingDonationModal = false
                    })
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                }
            }
            .frame(width: 580, height: 680)
        }
        .alert(isPresented: $showingErrorAlert) {
            Alert(
                title: Text(platformShellString("Notice")),
                message: Text(errorMessage ?? ""),
                dismissButton: .default(Text(platformShellString("OK")))
            )
        }
    }

    private func handleIconTap(_ option: AppIconOption) {
        if appIconService.isUnlocked(option) {
            applyIcon(option)
        } else if donationService.isChinaStorefront {
            if let onNavigate = onNavigateToDonation {
                onNavigate()
            } else {
                showingDonationModal = true
            }
        }
    }

    private func exclusiveIconCard(_ option: AppIconOption) -> some View {
        let isSelected = appIconService.isSelected(option)
        let isUnlocked = appIconService.isUnlocked(option)

        return VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                iconThumbnail(for: option)
                    .overlay(
                        RoundedRectangle(cornerRadius: previewCornerRadius)
                            .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 2.5)
                    )

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.blue)
                        .background(
                            Circle()
                                .fill(Color.white)
                                .frame(width: 14, height: 14)
                        )
                        .offset(x: 4, y: -4)
                } else if !isUnlocked {
                    Image(systemName: "crown.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 18, height: 18)
                        .background(
                            Circle()
                                .fill(Color.orange)
                        )
                        .offset(x: 4, y: -4)
                }
            }
            .frame(width: previewSize, height: previewSize)

            Text(localizedName(for: option))
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .foregroundColor(isSelected ? .primary : .secondary)
                .lineLimit(1)
        }
        .frame(width: 76)
    }

    private func iconOptionCard(_ option: AppIconOption) -> some View {
        let isSelected = appIconService.isSelected(option)

        return VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                iconThumbnail(for: option)
                    .overlay(
                        RoundedRectangle(cornerRadius: previewCornerRadius)
                            .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 2.5)
                    )

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.blue)
                        .background(
                            Circle()
                                .fill(Color.white)
                                .frame(width: 14, height: 14)
                        )
                        .offset(x: 4, y: -4)
                }
            }
            .frame(width: previewSize, height: previewSize)

            Text(localizedName(for: option))
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .foregroundColor(isSelected ? .primary : .secondary)
                .lineLimit(1)
        }
        .frame(width: 76)
    }

    @ViewBuilder
    private func iconThumbnail(for option: AppIconOption) -> some View {
        let nsImage = NSImage(named: option.previewAssetName) ?? (option.iconName.flatMap { NSImage(named: $0) })
        if let nsImage {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: previewSize, height: previewSize)
                .cornerRadius(previewCornerRadius)
                .shadow(color: Color.black.opacity(0.12), radius: 3, x: 0, y: 1)
        } else {
            RoundedRectangle(cornerRadius: previewCornerRadius)
                .fill(Color.secondary.opacity(0.15))
                .frame(width: previewSize, height: previewSize)
        }
    }

    private func localizedName(for option: AppIconOption) -> String {
        switch option.id {
        case "midnight-gold": return platformShellString("Midnight Gold")
        case "ivory-gold": return platformShellString("Ivory Gold")
        case "default": return platformShellString("Aurora")
        case "dark-aurora": return platformShellString("Dark Aurora")
        case "obsidian-white": return platformShellString("Obsidian White")
        case "acrylic": return platformShellString("Acrylic")
        case "platinum": return platformShellString("Platinum")
        case "sunset": return platformShellString("Sunset")
        case "electric-coral": return platformShellString("Electric Coral")
        case "classic": return platformShellString("Classic")
        case "slate": return platformShellString("Slate")
        case "vortex": return platformShellString("Vortex")
        case "coral": return platformShellString("Coral")
        case "neon": return platformShellString("Neon")
        case "eco": return platformShellString("Eco")
        case "golden-glossy": return platformShellString("Golden Glossy")
        case "rose-gold": return platformShellString("Rose Gold")
        case "royal-emerald": return platformShellString("Royal Emerald")
        default: return option.id.capitalized
        }
    }

    private func applyIcon(_ option: AppIconOption) {
        guard !isApplyingIcon else { return }
        isApplyingIcon = true
        appIconService.apply(option) { error in
            isApplyingIcon = false
            if let error {
                errorMessage = error.localizedDescription
                showingErrorAlert = true
            }
        }
    }
}
#endif

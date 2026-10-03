#if os(macOS)
import SwiftUI
import GenPlayerCore

struct MacSettingsDonationView: View {
    var isPresentedModally: Bool = false
    var onChangeAppIcon: (() -> Void)? = nil

    @ObservedObject private var donationService = DonationService.shared
    @ObservedObject private var appIconService = AppIconService.shared
    @Environment(\.presentationMode) private var presentationMode

    @State private var showingAlert = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""

    var body: some View {
        VStack(spacing: 20) {
            heroCard
            statusProgressCard
            if donationService.isChinaStorefront {
                tiersSection
                exclusivePerksCard
                restoreSection
            } else {
                exclusivePerksCard
            }
        }
        .alert(isPresented: $showingAlert) {
            Alert(
                title: Text(alertTitle),
                message: Text(alertMessage),
                dismissButton: .default(Text(platformShellString("OK")))
            )
        }
        .onChange(of: donationService.purchaseErrorMessage) { error in
            if let error = error {
                alertTitle = platformShellString("Notice")
                alertMessage = error
                showingAlert = true
            }
        }
        .onChange(of: donationService.shouldShowThankYou) { show in
            if show {
                alertTitle = platformShellString("Thank You!")
                alertMessage = platformShellString("Thank you so much for supporting GenPlayer! Your support keeps this project growing.")
                showingAlert = true
                DispatchQueue.main.async {
                    donationService.shouldShowThankYou = false
                }
            }
        }
    }

    // MARK: - Hero Card

    private var heroCard: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: [Color.orange, Color.pink]),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 64, height: 64)
                    .shadow(color: Color.orange.opacity(0.3), radius: 8, x: 0, y: 4)

                Image(systemName: "heart.fill")
                    .font(.system(size: 30))
                    .foregroundColor(.white)
            }
            .padding(.top, 6)

            Text(platformShellString("Support Independent Development"))
                .font(.title3.weight(.bold))
                .foregroundColor(.primary)

            Text(platformShellString("GenPlayer is an independent media player built with passion. If you enjoy using it, consider buying the developer a coffee or tea to support continuous updates and new features."))
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)

            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundColor(.green)
                    .font(.caption)
                Text(platformShellString("All core features remain completely open and unrestricted regardless of tipping."))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .padding(.horizontal, 16)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.secondary.opacity(0.1), lineWidth: 1)
        )
    }

    // MARK: - Status Progress Card

    private var statusProgressCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if donationService.isLifetimeSupporter {
                HStack(spacing: 12) {
                    Image(systemName: "crown.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.yellow)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(platformShellString("Lifetime Supporter"))
                            .font(.headline)
                            .foregroundColor(.primary)
                        Text(platformShellString("You have unlocked all exclusive supporter perks and icons. Thank you for your generous support!"))
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 20))
                        .foregroundColor(.orange)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(synthesisStatusTitle)
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.primary)

                        Text(synthesisStatusSubtitle)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(
                    donationService.isLifetimeSupporter
                        ? Color.yellow.opacity(0.12)
                        : Color.orange.opacity(0.08)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(
                    donationService.isLifetimeSupporter
                        ? Color.yellow.opacity(0.3)
                        : Color.orange.opacity(0.2),
                    lineWidth: 1
                )
        )
    }

    private var synthesisStatusTitle: String {
        if donationService.hasPurchasedCoffee && !donationService.hasPurchasedTea {
            return platformShellString("Coffee Tier Unlocked ☕️")
        } else if donationService.hasPurchasedTea && !donationService.hasPurchasedCoffee {
            return platformShellString("Tea Tier Unlocked 🍵")
        } else {
            return platformShellString("Combine Tiers for Lifetime Status")
        }
    }

    private var synthesisStatusSubtitle: String {
        if donationService.hasPurchasedCoffee && !donationService.hasPurchasedTea {
            return platformShellString("Buy a Tea to automatically upgrade to Lifetime Supporter!")
        } else if donationService.hasPurchasedTea && !donationService.hasPurchasedCoffee {
            return platformShellString("Buy a Coffee to automatically upgrade to Lifetime Supporter!")
        } else {
            return platformShellString("Tip a Coffee + Tea to automatically upgrade to Lifetime Supporter!")
        }
    }

    // MARK: - Tiers Section

    private var tiersSection: some View {
        VStack(spacing: 12) {
            tierCard(
                icon: "cup.and.saucer.fill",
                color: Color.brown,
                title: platformShellString("Buy a Coffee"),
                subtitle: platformShellString("A warm cup of coffee to fuel development"),
                productID: DonationProductID.coffee,
                isPurchased: donationService.hasPurchasedCoffee || donationService.isLifetimeSupporter
            )

            tierCard(
                icon: "leaf.fill",
                color: Color.green,
                title: platformShellString("Buy a Tea"),
                subtitle: platformShellString("A refreshing cup of tea to fuel development"),
                productID: DonationProductID.tea,
                isPurchased: donationService.hasPurchasedTea || donationService.isLifetimeSupporter
            )

            tierCard(
                icon: "crown.fill",
                color: Color.yellow,
                title: platformShellString("Lifetime Supporter"),
                subtitle: platformShellString("Directly unlock all supporter perks forever"),
                productID: DonationProductID.lifetime,
                isPurchased: donationService.isLifetimeSupporter,
                isFeatured: true
            )
        }
    }

    private func tierCard(
        icon: String,
        color: Color,
        title: String,
        subtitle: String,
        productID: String,
        isPurchased: Bool,
        isFeatured: Bool = false
    ) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(color.opacity(0.15))
                    .frame(width: 44, height: 44)

                Image(systemName: icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(color)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.body.weight(.semibold))
                        .foregroundColor(.primary)

                    if isFeatured {
                        Text(platformShellString("Best Value"))
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange)
                            .cornerRadius(6)
                    }
                }

                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            if isPurchased {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text(platformShellString("Supported"))
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(.green)
                }
            } else {
                Button(action: {
                    donationService.purchase(productID: productID)
                }) {
                    if donationService.isPurchasing {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle())
                            .frame(width: 68, height: 32)
                    } else {
                        Text(donationService.formattedPrice(for: productID))
                            .font(.subheadline.weight(.bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(isFeatured ? Color.orange : Color.blue)
                            .cornerRadius(16)
                    }
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(donationService.isPurchasing)
            }
        }
        .padding(14)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(14)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(
                    isFeatured && !isPurchased
                        ? Color.orange.opacity(0.35)
                        : Color.secondary.opacity(0.1),
                    lineWidth: isFeatured && !isPurchased ? 1.5 : 1
                )
        )
    }

    // MARK: - Exclusive Perks Card

    private var exclusivePerksCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "gift.fill")
                    .foregroundColor(.purple)
                Text(platformShellString("Supporter Exclusive Perks"))
                    .font(.headline)
                    .foregroundColor(.primary)
                Spacer()
            }

            HStack(spacing: 16) {
                perkIconThumbnail(name: "icon_preview_midnight_gold", label: platformShellString("Midnight Gold"))
                perkIconThumbnail(name: "icon_preview_ivory_gold", label: platformShellString("Ivory Gold"))

                VStack(alignment: .leading, spacing: 6) {
                    perkBulletPoint(text: platformShellString("2 Exclusive Gold App Icons"))
                    perkBulletPoint(text: platformShellString("Permanent Supporter Badge"))
                    perkBulletPoint(text: platformShellString("Lifetime Recognition"))
                }
                .padding(.leading, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()
                .opacity(0.5)
                .padding(.vertical, 2)

            Button(action: {
                if isPresentedModally {
                    presentationMode.wrappedValue.dismiss()
                }
                onChangeAppIcon?()
            }) {
                HStack {
                    Image(systemName: "app.badge.fill")
                        .foregroundColor(.blue)
                    Text(platformShellString("Change App Icon"))
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(16)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(14)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.secondary.opacity(0.1), lineWidth: 1)
        )
    }

    private func perkIconThumbnail(name: String, label: String) -> some View {
        VStack(spacing: 6) {
            if let nsImage = NSImage(named: name) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 48, height: 48)
                    .cornerRadius(11)
                    .shadow(color: Color.black.opacity(0.15), radius: 3, x: 0, y: 1)
            } else {
                RoundedRectangle(cornerRadius: 11)
                    .fill(Color.secondary.opacity(0.15))
                    .frame(width: 48, height: 48)
            }

            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }

    private func perkBulletPoint(text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 13))
                .foregroundColor(.yellow)
            Text(text)
                .font(.footnote)
                .foregroundColor(.primary)
        }
    }

    // MARK: - Restore Section

    private var restoreSection: some View {
        VStack(spacing: 12) {
            Button(action: {
                donationService.restorePurchases()
            }) {
                HStack {
                    if donationService.isRestoring {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle())
                            .padding(.trailing, 4)
                    }
                    Text(donationService.isRestoring
                        ? platformShellString("Restoring Purchases...")
                        : platformShellString("Restore Purchases"))
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(.blue)
                }
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(donationService.isRestoring)

            Text(platformShellString("Tips are voluntary contributions processed by Apple In-App Purchase. Whether you choose to tip or not, all features of GenPlayer remain 100% free and fully functional. Tap Restore Purchases to recover your status on new devices."))
                .font(.caption2)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
        }
        .padding(.top, 4)
        .padding(.bottom, 12)
    }
}
#endif

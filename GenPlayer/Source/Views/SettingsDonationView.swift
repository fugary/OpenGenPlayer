import SwiftUI

struct SettingsDonationView: View {
    var isPresentedModally: Bool = false
    @ObservedObject private var donationService = DonationService.shared
    @ObservedObject private var appIconService = AppIconService.shared
    @Environment(\.presentationMode) private var presentationMode

    @State private var showingAlert = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""

    var body: some View {
        ScrollView {
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
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
        }
        .background(Color(UIColor.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(NSLocalizedString("Support GenPlayer", comment: ""))
        .alert(isPresented: $showingAlert) {
            Alert(
                title: Text(alertTitle),
                message: Text(alertMessage),
                dismissButton: .default(Text(NSLocalizedString("OK", comment: "")))
            )
        }
        .onChange(of: donationService.purchaseErrorMessage) { error in
            if let error = error {
                alertTitle = NSLocalizedString("Notice", comment: "")
                alertMessage = error
                showingAlert = true
            }
        }
        .onChange(of: donationService.shouldShowThankYou) { show in
            if show {
                alertTitle = NSLocalizedString("Thank You!", comment: "")
                alertMessage = NSLocalizedString("Thank you so much for supporting GenPlayer! Your support keeps this project growing.", comment: "")
                showingAlert = true
                donationService.shouldShowThankYou = false
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
                            gradient: Gradient(colors: [Color(UIColor.systemOrange), Color(UIColor.systemPink)]),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 72, height: 72)
                    .shadow(color: Color(UIColor.systemOrange).opacity(0.3), radius: 8, x: 0, y: 4)

                Image(systemName: "heart.fill")
                    .font(.system(size: 34))
                    .foregroundColor(.white)
            }
            .padding(.top, 8)

            Text(NSLocalizedString("Support Independent Development", comment: ""))
                .font(.title3)
                .fontWeight(.bold)
                .foregroundColor(.primary)

            Text(NSLocalizedString("GenPlayer is an independent media player built with passion. If you enjoy using it, consider buying the developer a coffee or tea to support continuous updates and new features.", comment: ""))
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)

            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundColor(Color(UIColor.systemGreen))
                    .font(.caption)
                Text(NSLocalizedString("All core features remain completely open and unrestricted regardless of tipping.", comment: ""))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .padding(.horizontal, 16)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(18)
    }

    // MARK: - Status Progress Card

    private var statusProgressCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if donationService.isLifetimeSupporter {
                HStack(spacing: 12) {
                    Image(systemName: "crown.fill")
                        .font(.system(size: 24))
                        .foregroundColor(Color(UIColor.systemYellow))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(NSLocalizedString("Lifetime Supporter", comment: ""))
                            .font(.headline)
                            .foregroundColor(.primary)
                        Text(NSLocalizedString("You have unlocked all exclusive supporter perks and icons. Thank you for your generous support!", comment: ""))
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 20))
                        .foregroundColor(Color(UIColor.systemOrange))

                    VStack(alignment: .leading, spacing: 3) {
                        Text(synthesisStatusTitle)
                            .font(.subheadline)
                            .fontWeight(.semibold)
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
                        ? Color(UIColor.systemYellow).opacity(0.12)
                        : Color(UIColor.systemOrange).opacity(0.08)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(
                    donationService.isLifetimeSupporter
                        ? Color(UIColor.systemYellow).opacity(0.3)
                        : Color(UIColor.systemOrange).opacity(0.2),
                    lineWidth: 1
                )
        )
    }

    private var synthesisStatusTitle: String {
        if donationService.hasPurchasedCoffee && !donationService.hasPurchasedTea {
            return NSLocalizedString("Coffee Tier Unlocked ☕️", comment: "")
        } else if donationService.hasPurchasedTea && !donationService.hasPurchasedCoffee {
            return NSLocalizedString("Tea Tier Unlocked 🍵", comment: "")
        } else {
            return NSLocalizedString("Combine Tiers for Lifetime Status", comment: "")
        }
    }

    private var synthesisStatusSubtitle: String {
        if donationService.hasPurchasedCoffee && !donationService.hasPurchasedTea {
            return NSLocalizedString("Buy a Tea to automatically upgrade to Lifetime Supporter!", comment: "")
        } else if donationService.hasPurchasedTea && !donationService.hasPurchasedCoffee {
            return NSLocalizedString("Buy a Coffee to automatically upgrade to Lifetime Supporter!", comment: "")
        } else {
            return NSLocalizedString("Tip a Coffee + Tea to automatically upgrade to Lifetime Supporter!", comment: "")
        }
    }

    // MARK: - Tiers Section

    private var tiersSection: some View {
        VStack(spacing: 12) {
            tierCard(
                icon: "cup.and.saucer.fill",
                color: Color(UIColor.systemBrown),
                title: NSLocalizedString("Buy a Coffee", comment: ""),
                subtitle: NSLocalizedString("A warm cup of coffee to fuel development", comment: ""),
                productID: DonationProductID.coffee,
                isPurchased: donationService.hasPurchasedCoffee || donationService.isLifetimeSupporter
            )

            tierCard(
                icon: "leaf.fill",
                color: Color(UIColor.systemGreen),
                title: NSLocalizedString("Buy a Tea", comment: ""),
                subtitle: NSLocalizedString("A refreshing cup of tea to fuel development", comment: ""),
                productID: DonationProductID.tea,
                isPurchased: donationService.hasPurchasedTea || donationService.isLifetimeSupporter
            )

            tierCard(
                icon: "crown.fill",
                color: Color(UIColor.systemYellow),
                title: NSLocalizedString("Lifetime Supporter", comment: ""),
                subtitle: NSLocalizedString("Directly unlock all supporter perks forever", comment: ""),
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
                        .font(.body)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)

                    if isFeatured {
                        Text(NSLocalizedString("Best Value", comment: ""))
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color(UIColor.systemOrange))
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
                        .foregroundColor(Color(UIColor.systemGreen))
                    Text(NSLocalizedString("Supported", comment: ""))
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(Color(UIColor.systemGreen))
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
                            .font(.subheadline)
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(isFeatured ? Color(UIColor.systemOrange) : Color(UIColor.systemBlue))
                            .cornerRadius(18)
                    }
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(donationService.isPurchasing)
            }
        }
        .padding(14)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(
                    isFeatured && !isPurchased
                        ? Color(UIColor.systemOrange).opacity(0.35)
                        : Color.clear,
                    lineWidth: 1.5
                )
        )
    }

    // MARK: - Exclusive Perks Card

    private var exclusivePerksCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "gift.fill")
                    .foregroundColor(Color(UIColor.systemPurple))
                Text(NSLocalizedString("Supporter Exclusive Perks", comment: ""))
                    .font(.headline)
                    .foregroundColor(.primary)
                Spacer()
            }

            HStack(spacing: 16) {
                perkIconThumbnail(name: "icon_preview_midnight_gold", label: NSLocalizedString("Midnight Gold", comment: ""))
                perkIconThumbnail(name: "icon_preview_ivory_gold", label: NSLocalizedString("Ivory Gold", comment: ""))

                VStack(alignment: .leading, spacing: 6) {
                    perkBulletPoint(text: NSLocalizedString("2 Exclusive Gold App Icons", comment: ""))
                    perkBulletPoint(text: NSLocalizedString("Permanent Supporter Badge", comment: ""))
                    perkBulletPoint(text: NSLocalizedString("Lifetime Recognition", comment: ""))
                }
                .padding(.leading, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()
                .padding(.vertical, 2)

            if isPresentedModally {
                Button(action: {
                    presentationMode.wrappedValue.dismiss()
                }) {
                    changeAppIconRowContent
                }
                .buttonStyle(PlainButtonStyle())
            } else {
                NavigationLink(destination: SettingsAppIconView()) {
                    changeAppIconRowContent
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(16)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(16)
    }

    private var changeAppIconRowContent: some View {
        HStack {
            Image(systemName: "app.badge.fill")
                .foregroundColor(Color(UIColor.systemBlue))
            Text(NSLocalizedString("Change App Icon", comment: ""))
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(.primary)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundColor(Color(UIColor.tertiaryLabel))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func perkIconThumbnail(name: String, label: String) -> some View {
        VStack(spacing: 6) {
            Image(uiImage: UIImage(named: name) ?? UIImage())
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 48, height: 48)
                .cornerRadius(11)
                .shadow(color: Color.black.opacity(0.12), radius: 3, x: 0, y: 1)

            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }

    private func perkBulletPoint(text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 13))
                .foregroundColor(Color(UIColor.systemYellow))
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
                        ? NSLocalizedString("Restoring Purchases...", comment: "")
                        : NSLocalizedString("Restore Purchases", comment: ""))
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(Color(UIColor.systemBlue))
                }
            }
            .disabled(donationService.isRestoring)

            Text(NSLocalizedString("Tips are voluntary contributions processed by Apple In-App Purchase. Whether you choose to tip or not, all features of GenPlayer remain 100% free and fully functional. Tap Restore Purchases to recover your status on new devices.", comment: ""))
                .font(.caption2)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
        }
        .padding(.top, 4)
        .padding(.bottom, 12)
    }
}

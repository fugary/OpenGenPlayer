#if os(iOS)
import SwiftUI
import GenPlayerCore
import GenPlayerShell

struct TVPairingCompanionSheet: View {
    let session: TVPairingSession
    @ObservedObject private var service = TVPairingCompanionService.shared

    private var brandColor: Color {
        switch session.serverType {
        case .googledrive:
            return Color(red: 0.96, green: 0.70, blue: 0.12)
        case .onedrive:
            return Color(red: 0.0, green: 0.47, blue: 0.84)
        default:
            return Color.blue
        }
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                // Header Icon & Title
                VStack(spacing: 12) {
                    ServerTypeIconBadge(type: session.serverType, size: 64, iconSize: 34)
                        .padding(.top, 16)

                    Text(NSLocalizedString("Apple TV Authorization", comment: ""))
                        .font(.title2.weight(.bold))

                    Text(String(
                        format: NSLocalizedString("Apple TV (%@) is requesting access to %@.", comment: ""),
                        session.ip,
                        session.serverType.displayName
                    ))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                }

                if service.isAuthenticating || service.isSuccess {
                    // Loading or Success State
                    VStack(spacing: 16) {
                        if service.isSuccess {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 54))
                                .foregroundColor(.green)
                        } else {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: brandColor))
                                .scaleEffect(1.5)
                                .frame(height: 54)
                        }

                        Text(service.statusMessage)
                            .font(.headline)
                            .foregroundColor(.primary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // Action Content
                    VStack(spacing: 18) {
                        if let error = service.errorMessage {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                Text(error)
                                    .font(.footnote)
                                    .foregroundColor(.red)
                            }
                            .padding(12)
                            .background(Color.red.opacity(0.08))
                            .cornerRadius(10)
                        }

                        // Primary Action: Direct Login
                        Button(action: {
                            service.startDirectOAuthLogin(for: session)
                        }) {
                            HStack(spacing: 10) {
                                Image(systemName: "lock.shield")
                                    .font(.headline)
                                Text(String(
                                    format: NSLocalizedString("Sign in with %@ & Authorize TV", comment: ""),
                                    session.serverType.displayName
                                ))
                                .font(.headline.weight(.semibold))
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(brandColor)
                            .foregroundColor(.white)
                            .cornerRadius(14)
                            .shadow(color: brandColor.opacity(0.3), radius: 8, y: 4)
                        }
                        .buttonStyle(.plain)

                        Spacer()

                        Text(NSLocalizedString("Credentials will be sent directly to Apple TV over your local network. Please ensure both devices are on the same Wi-Fi.", comment: ""))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 16)
                    }
                    .padding(.horizontal, 20)
                }
            }
            .padding(.top, 8)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        service.dismissSession()
                    }) {
                        AppToolbarIcon(systemName: "xmark", style: .secondary)
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
        .interactiveDismissDisabled(service.isAuthenticating)
    }
}
#endif

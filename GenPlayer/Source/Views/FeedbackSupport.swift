import Foundation
#if os(iOS)
import MessageUI
#endif
import SwiftUI
#if os(iOS)
import UIKit
#endif

struct FeedbackDraft: Identifiable {
    let id = UUID()
    let recipient: String
    let subject: String
    let messageBody: String
}

enum FeedbackSupport {
    // Replace with the actual feedback mailbox if it differs from the default project support address.
    static let recipientEmail = "fufuguo86+genplayer@gmail.com"

    static func makeDraft() -> FeedbackDraft {
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        #if os(iOS)
        let systemVersion = UIDevice.current.systemVersion
        #else
        let systemVersion = ProcessInfo.processInfo.operatingSystemVersionString
        #endif
        let deviceLabel = deviceDescription
        let themeLabel = themeDescription
        let languageLabel = languageDescription
        let systemLanguageLabel = systemLanguageDescription
        let timestamp = ISO8601DateFormatter().string(from: Date())

        let body = """
        \(NSLocalizedString("Feedback Body Intro", comment: ""))

        \(NSLocalizedString("Feedback Body What Happened", comment: ""))
        \(NSLocalizedString("Feedback Body Reproduce", comment: ""))
        \(NSLocalizedString("Feedback Body Expected", comment: ""))

        ---
        \(NSLocalizedString("Feedback Field App", comment: "")): Gen Player \(appVersion) (\(buildNumber))
        \(NSLocalizedString("Feedback Field OS", comment: "")): iOS \(systemVersion)
        \(NSLocalizedString("Feedback Field Device", comment: "")): \(deviceLabel)
        \(NSLocalizedString("Feedback Field Theme", comment: "")): \(themeLabel)
        \(NSLocalizedString("Feedback Field App Language", comment: "")): \(languageLabel)
        \(NSLocalizedString("Feedback Field System Language", comment: "")): \(systemLanguageLabel)
        \(NSLocalizedString("Feedback Field Time", comment: "")): \(timestamp)
        """

        return FeedbackDraft(
            recipient: recipientEmail,
            subject: NSLocalizedString("Feedback Email Subject", comment: ""),
            messageBody: body
        )
    }

    static func makeServiceRequestDraft(requestedService: String) -> FeedbackDraft {
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        #if os(iOS)
        let systemVersion = UIDevice.current.systemVersion
        #else
        let systemVersion = ProcessInfo.processInfo.operatingSystemVersionString
        #endif
        let deviceLabel = deviceDescription
        let themeLabel = themeDescription
        let languageLabel = languageDescription
        let systemLanguageLabel = systemLanguageDescription
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let normalizedService = requestedService.trimmingCharacters(in: .whitespacesAndNewlines)

        let body = """
        \(NSLocalizedString("Service Request Body Intro", comment: ""))

        \(NSLocalizedString("Requested Service Type", comment: "")): \(normalizedService.isEmpty ? NSLocalizedString("Unknown", comment: "") : normalizedService)

        \(NSLocalizedString("Service Request Body Usage", comment: ""))
        \(NSLocalizedString("Service Request Body Why", comment: ""))
        \(NSLocalizedString("Service Request Body Reference", comment: ""))

        ---
        \(NSLocalizedString("Feedback Field App", comment: "")): Gen Player \(appVersion) (\(buildNumber))
        \(NSLocalizedString("Feedback Field OS", comment: "")): iOS \(systemVersion)
        \(NSLocalizedString("Feedback Field Device", comment: "")): \(deviceLabel)
        \(NSLocalizedString("Feedback Field Theme", comment: "")): \(themeLabel)
        \(NSLocalizedString("Feedback Field App Language", comment: "")): \(languageLabel)
        \(NSLocalizedString("Feedback Field System Language", comment: "")): \(systemLanguageLabel)
        \(NSLocalizedString("Feedback Field Time", comment: "")): \(timestamp)
        """

        return FeedbackDraft(
            recipient: recipientEmail,
            subject: NSLocalizedString("Service Request Email Subject", comment: ""),
            messageBody: body
        )
    }

    static func mailtoURL(for draft: FeedbackDraft) -> URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = draft.recipient
        components.queryItems = [
            URLQueryItem(name: "subject", value: draft.subject),
            URLQueryItem(name: "body", value: draft.messageBody)
        ]
        return components.url
    }

    private static var deviceDescription: String {
        #if os(iOS)
        switch UIDevice.current.userInterfaceIdiom {
        case .pad: return "iPad"
        case .phone: return "iPhone"
        case .tv: return "Apple TV"
        case .mac: return "Mac"
        default: return NSLocalizedString("Unknown", comment: "")
        }
        #else
        return "Mac"
        #endif
    }

    private static var languageDescription: String {
        Bundle.localizedAppLanguageSummary(for: AppSettings.shared.appLanguage)
    }
    private static var themeDescription: String {
        let setting = AppSettings.shared.userTheme
        switch setting {
        case "Light":
            return NSLocalizedString("Light", comment: "")
        case "Dark":
            return NSLocalizedString("Dark", comment: "")
        default:
            return NSLocalizedString("System", comment: "")
        }
    }

    private static var systemLanguageDescription: String {
        let identifier = Bundle.systemLanguageIdentifier()
        return Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }
}

#if os(iOS)
struct MailComposeSheet: UIViewControllerRepresentable {
    let draft: FeedbackDraft
    let onFinish: (Result<MFMailComposeResult, Error>) -> Void

    static var canSendMail: Bool {
        MFMailComposeViewController.canSendMail()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let controller = MFMailComposeViewController()
        controller.mailComposeDelegate = context.coordinator
        controller.setToRecipients([draft.recipient])
        controller.setSubject(draft.subject)
        controller.setMessageBody(draft.messageBody, isHTML: false)
        return controller
    }

    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {
    }

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        private let onFinish: (Result<MFMailComposeResult, Error>) -> Void

        init(onFinish: @escaping (Result<MFMailComposeResult, Error>) -> Void) {
            self.onFinish = onFinish
        }

        func mailComposeController(
            _ controller: MFMailComposeViewController,
            didFinishWith result: MFMailComposeResult,
            error: Error?
        ) {
            controller.dismiss(animated: true) {
                if let error = error {
                    self.onFinish(.failure(error))
                } else {
                    self.onFinish(.success(result))
                }
            }
        }
    }
}
#endif

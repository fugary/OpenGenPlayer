import SwiftUI

#if os(iOS) || os(tvOS)
import UIKit
public typealias VLCPlatformView = UIView
#elseif os(macOS)
import AppKit
public typealias VLCPlatformView = NSView
#endif

public enum VLCPlayerSurfaceRole {
    case inline
    case detail
    case fullscreen
}

public struct VLCPlayerWrapperConfiguration {
    public var role: VLCPlayerSurfaceRole
    public var allowsPictureInPicture: Bool
    public var prefersTransparentBackground: Bool

    public init(
        role: VLCPlayerSurfaceRole,
        allowsPictureInPicture: Bool,
        prefersTransparentBackground: Bool
    ) {
        self.role = role
        self.allowsPictureInPicture = allowsPictureInPicture
        self.prefersTransparentBackground = prefersTransparentBackground
    }

    public static let defaultInline = VLCPlayerWrapperConfiguration(
        role: .inline,
        allowsPictureInPicture: false,
        prefersTransparentBackground: false
    )
}

public protocol VLCPlayerWrapper: AnyObject {
    var configuration: VLCPlayerWrapperConfiguration { get }
    func attach(to hostView: VLCPlatformView)
    func detach()
}

public struct VLCPlayerSurfacePlaceholderView: View {
    public init() {}

    public var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "play.rectangle")
                .font(.system(size: 30, weight: .semibold))
                .foregroundColor(.accentColor)
            Text(platformShellString("Platform Shell Player Placeholder Title"))
                .font(.headline)
            Text(platformShellString("Platform Shell Player Placeholder Body"))
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }
}

import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

public enum AppIconServiceErrorCode {
    public static let unsupported = 1
    public static let iconNotRegistered = 2
    public static let changeInProgress = 3
    public static let systemBusy = 4
}

public struct AppIconOption: Identifiable, Equatable {
    public let id: String
    public let iconName: String?
    public let previewAssetName: String
    public let isExclusive: Bool
    public let isDeprecated: Bool

    public init(
        id: String,
        iconName: String?,
        previewAssetName: String,
        isExclusive: Bool = false,
        isDeprecated: Bool = false
    ) {
        self.id = id
        self.iconName = iconName
        self.previewAssetName = previewAssetName
        self.isExclusive = isExclusive
        self.isDeprecated = isDeprecated
    }
}

public final class AppIconService: ObservableObject {
    public static let shared = AppIconService()

    private let allOptions: [AppIconOption] = [
        AppIconOption(
            id: "midnight-gold",
            iconName: "AppIconMidnightGold",
            previewAssetName: "icon_preview_midnight_gold",
            isExclusive: true
        ),
        AppIconOption(
            id: "ivory-gold",
            iconName: "AppIconIvoryGold",
            previewAssetName: "icon_preview_ivory_gold",
            isExclusive: true
        ),
        AppIconOption(
            id: "default",
            iconName: nil,
            previewAssetName: "icon_preview_aurora"
        ),
        AppIconOption(
            id: "dark-aurora",
            iconName: "AppIconDarkAurora",
            previewAssetName: "icon_preview_dark_aurora"
        ),
        AppIconOption(
            id: "obsidian-white",
            iconName: "AppIconObsidianWhite",
            previewAssetName: "icon_preview_obsidian_white"
        ),
        AppIconOption(
            id: "acrylic",
            iconName: "AppIconAcrylic",
            previewAssetName: "icon_preview_acrylic"
        ),
        AppIconOption(
            id: "platinum",
            iconName: "AppIconPlatinum",
            previewAssetName: "icon_preview_platinum"
        ),
        AppIconOption(
            id: "sunset",
            iconName: "AppIconSunset",
            previewAssetName: "icon_preview_sunset"
        ),
        AppIconOption(
            id: "electric-coral",
            iconName: "AppIconElectricCoral",
            previewAssetName: "icon_preview_electric_coral"
        ),
        AppIconOption(
            id: "classic",
            iconName: "AppIconClassic",
            previewAssetName: "icon_preview_classic",
            isDeprecated: true
        ),
        AppIconOption(
            id: "slate",
            iconName: "AppIconSlate",
            previewAssetName: "icon_preview_slate",
            isDeprecated: true
        ),
        AppIconOption(
            id: "vortex",
            iconName: "AppIconVortex",
            previewAssetName: "icon_preview_vortex",
            isDeprecated: true
        ),
        AppIconOption(
            id: "coral",
            iconName: "AppIconCoral",
            previewAssetName: "icon_preview_coral",
            isDeprecated: true
        ),
        AppIconOption(
            id: "neon",
            iconName: "AppIconNeon",
            previewAssetName: "icon_preview_neon",
            isDeprecated: true
        ),
        AppIconOption(
            id: "eco",
            iconName: "AppIconEco",
            previewAssetName: "icon_preview_eco",
            isDeprecated: true
        ),
        AppIconOption(
            id: "golden-glossy",
            iconName: "AppIconGoldenGlossy",
            previewAssetName: "icon_preview_golden_glossy",
            isDeprecated: true
        ),
        AppIconOption(
            id: "rose-gold",
            iconName: "AppIconRoseGold",
            previewAssetName: "icon_preview_rose_gold",
            isDeprecated: true
        ),
        AppIconOption(
            id: "royal-emerald",
            iconName: "AppIconRoyalEmerald",
            previewAssetName: "icon_preview_royal_emerald",
            isDeprecated: true
        )
    ]

    public var options: [AppIconOption] {
        #if os(iOS)
        let configuredAlternates = configuredAlternateIconNames
        return allOptions.filter { option in
            if let iconName = option.iconName, !configuredAlternates.contains(iconName) {
                return false
            }
            if !option.isDeprecated {
                return true
            }
            return isSelected(option)
        }
        #else
        return allOptions.filter { option in
            if !option.isDeprecated {
                return true
            }
            return isSelected(option)
        }
        #endif
    }

    public var exclusiveOptions: [AppIconOption] {
        options.filter { $0.isExclusive }
    }

    public var regularOptions: [AppIconOption] {
        options.filter { !$0.isExclusive }
    }

    public func isUnlocked(_ option: AppIconOption) -> Bool {
        guard option.isExclusive else { return true }
        return DonationService.shared.isLifetimeSupporter
    }

    @Published public private(set) var currentIconName: String?
    private var isApplyingChange = false
    private let macSavedIconKey = "macSelectedAppIcon"

    private init() {
        #if os(iOS)
        currentIconName = UIApplication.shared.alternateIconName
        #elseif os(macOS)
        let savedId = UserDefaults.standard.string(forKey: macSavedIconKey)
        if let savedId, savedId != "default", let option = allOptions.first(where: { $0.id == savedId && $0.iconName != nil }) {
            currentIconName = option.iconName
            applyMacIcon(option)
        } else {
            currentIconName = nil
        }
        #else
        currentIconName = nil
        #endif
    }

    public var supportsAlternateIcons: Bool {
        #if os(iOS)
        return UIApplication.shared.supportsAlternateIcons
        #elseif os(macOS)
        return true
        #else
        return false
        #endif
    }

    public func isSelected(_ option: AppIconOption) -> Bool {
        #if os(iOS)
        return currentIconName == option.iconName
        #elseif os(macOS)
        if option.iconName == nil {
            return currentIconName == nil
        }
        return currentIconName == option.iconName
        #else
        return false
        #endif
    }

    public func refresh() {
        #if os(iOS)
        currentIconName = UIApplication.shared.alternateIconName
        #elseif os(macOS)
        let savedId = UserDefaults.standard.string(forKey: macSavedIconKey)
        if let savedId, savedId != "default", let option = allOptions.first(where: { $0.id == savedId && $0.iconName != nil }) {
            currentIconName = option.iconName
            applyMacIcon(option)
        } else {
            currentIconName = nil
        }
        #endif
    }

    public func apply(_ option: AppIconOption, completion: @escaping (Error?) -> Void) {
        #if os(iOS)
        applyIOS(option, completion: completion)
        #elseif os(macOS)
        applyMacOS(option, completion: completion)
        #else
        completion(
            NSError(
                domain: "AppIconService",
                code: AppIconServiceErrorCode.unsupported,
                userInfo: nil
            )
        )
        #endif
    }

    #if os(macOS)
    public func restoreDefaultIcon() {
        if let defaultIcon = NSImage(named: NSImage.applicationIconName) {
            NSApplication.shared.applicationIconImage = defaultIcon
        } else {
            NSApplication.shared.applicationIconImage = nil
        }
        UserDefaults.standard.removeObject(forKey: macSavedIconKey)
        currentIconName = nil
    }

    private func applyMacOS(_ option: AppIconOption, completion: @escaping (Error?) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            if option.iconName == nil {
                self.restoreDefaultIcon()
                completion(nil)
                return
            }

            self.applyMacIcon(option)
            self.currentIconName = option.iconName
            UserDefaults.standard.set(option.id, forKey: self.macSavedIconKey)
            completion(nil)
        }
    }

    private func applyMacIcon(_ option: AppIconOption) {
        let imageName = "app_icon_\(option.id)"
        let rawImage = NSImage(named: imageName)
            ?? NSImage(named: option.previewAssetName)
            ?? (option.iconName.flatMap { NSImage(named: $0) })
        guard let rawImage else {
            return
        }

        let dockIcon = renderMacDockIcon(from: rawImage)
        NSApplication.shared.applicationIconImage = dockIcon
    }

    /// 根据 Apple macOS Human Interface Guidelines (HIG) 图标规范合成 Dock 图标
    /// - 画布尺寸：1024 x 1024 pt
    /// - 主体 Squircle 尺寸：824 x 824 pt (约占 80.5% 黄金比例)
    /// - 四周留白：左右各 100 pt，垂直居中微偏上以容纳落影 (底留白 104pt，顶留白 96pt)
    /// - 圆角半径：185 pt (连续曲率平滑圆角)
    /// - 投影：双层系统级 Drop Shadow (Ambient + Contact)
    /// - 边缘微光：1.0pt 细微内描边，解决深色图标在深色 Dock 下的轮廓隐形问题
    private func renderMacDockIcon(from sourceImage: NSImage) -> NSImage {
        let canvasSize = NSSize(width: 1024, height: 1024)
        let bodySize = NSSize(width: 824, height: 824)
        let cornerRadius: CGFloat = 185
        
        // Cocoa 坐标系（左下角为原点，y 向上递增）
        // 水平居中：(1024 - 824) / 2 = 100
        // 垂直偏上留出底部投影空间：底部留 104 pt，顶部留 96 pt
        let bodyRect = NSRect(x: 100, y: 104, width: bodySize.width, height: bodySize.height)

        let resultImage = NSImage(size: canvasSize)
        resultImage.lockFocus()
        
        guard let context = NSGraphicsContext.current?.cgContext else {
            resultImage.unlockFocus()
            return sourceImage
        }

        let squirclePath = NSBezierPath(roundedRect: bodyRect, xRadius: cornerRadius, yRadius: cornerRadius)

        // 1. 绘制双层 Drop Shadow
        // 1.1 漫反射环境阴影 (Ambient Shadow)
        context.saveGState()
        let ambientShadow = NSShadow()
        ambientShadow.shadowColor = NSColor.black.withAlphaComponent(0.24)
        ambientShadow.shadowBlurRadius = 24.0
        ambientShadow.shadowOffset = NSSize(width: 0, height: -12.0)
        ambientShadow.set()
        NSColor.black.setFill()
        squirclePath.fill()
        context.restoreGState()

        // 1.2 贴地接触阴影 (Contact Shadow)
        context.saveGState()
        let contactShadow = NSShadow()
        contactShadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
        contactShadow.shadowBlurRadius = 6.0
        contactShadow.shadowOffset = NSSize(width: 0, height: -4.0)
        contactShadow.set()
        NSColor.black.setFill()
        squirclePath.fill()
        context.restoreGState()

        // 2. 绘制主体图标内容 (带圆角裁切)
        context.saveGState()
        squirclePath.addClip()
        sourceImage.draw(in: bodyRect, from: NSRect(origin: .zero, size: sourceImage.size), operation: .copy, fraction: 1.0)
        
        // 3. 绘制精细的边缘轮廓微光 (Rim Highlight)
        let innerStrokePath = NSBezierPath(
            roundedRect: bodyRect.insetBy(dx: 0.5, dy: 0.5),
            xRadius: cornerRadius - 0.5,
            yRadius: cornerRadius - 0.5
        )
        innerStrokePath.lineWidth = 1.0
        NSColor.white.withAlphaComponent(0.18).setStroke()
        innerStrokePath.stroke()
        context.restoreGState()

        resultImage.unlockFocus()
        return resultImage
    }
    #endif

    #if os(iOS)
    private func applyIOS(_ option: AppIconOption, completion: @escaping (Error?) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            guard self.supportsAlternateIcons else {
                completion(
                    NSError(
                        domain: "AppIconService",
                        code: AppIconServiceErrorCode.unsupported,
                        userInfo: nil
                    )
                )
                return
            }

            guard !self.isApplyingChange else {
                completion(
                    NSError(
                        domain: "AppIconService",
                        code: AppIconServiceErrorCode.changeInProgress,
                        userInfo: [
                            NSLocalizedDescriptionKey: NSLocalizedString("Another icon change is still in progress. Please wait a moment and try again.", comment: "")
                        ]
                    )
                )
                return
            }

            self.currentIconName = UIApplication.shared.alternateIconName
            guard self.currentIconName != option.iconName else {
                completion(nil)
                return
            }

            if let iconName = option.iconName, !self.configuredAlternateIconNames.contains(iconName) {
                completion(
                    NSError(
                        domain: "AppIconService",
                        code: AppIconServiceErrorCode.iconNotRegistered,
                        userInfo: [
                            NSLocalizedDescriptionKey: NSLocalizedString("Requested icon resource is not registered in this build.", comment: "")
                        ]
                    )
                )
                return
            }

            self.isApplyingChange = true
            self.setAlternateIcon(option.iconName, remainingRetryCount: 4) { [weak self] error in
                guard let self else {
                    completion(error)
                    return
                }

                DispatchQueue.main.async {
                    self.isApplyingChange = false
                    self.currentIconName = UIApplication.shared.alternateIconName

                    if self.currentIconName == option.iconName {
                        completion(nil)
                        return
                    }

                    if let nsError = error as NSError?,
                       self.shouldRetry(for: nsError) {
                        completion(
                            NSError(
                                domain: "AppIconService",
                                code: AppIconServiceErrorCode.systemBusy,
                                userInfo: [
                                    NSLocalizedDescriptionKey: NSLocalizedString("The system is temporarily busy changing the app icon. Please try again in a moment.", comment: "")
                                ]
                            )
                        )
                        return
                    }

                    completion(error)
                }
            }
        }
    }

    private var configuredAlternateIconNames: Set<String> {
        func keys(from dictionary: [String: Any]?) -> Set<String> {
            guard let dictionary,
                  let alternates = dictionary["CFBundleAlternateIcons"] as? [String: Any] else {
                return []
            }
            return Set(alternates.keys)
        }

        let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any]
        let iconsIPad = Bundle.main.infoDictionary?["CFBundleIcons~ipad"] as? [String: Any]
        return keys(from: icons).union(keys(from: iconsIPad))
    }

    private func setAlternateIcon(
        _ iconName: String?,
        remainingRetryCount: Int,
        completion: @escaping (Error?) -> Void
    ) {
        UIApplication.shared.setAlternateIconName(iconName) { [weak self] error in
            guard let self else {
                completion(error)
                return
            }

            DispatchQueue.main.async {
                self.currentIconName = UIApplication.shared.alternateIconName

                if self.currentIconName == iconName {
                    completion(nil)
                    return
                }

                if let nsError = error as NSError?,
                   self.isBenignCancellation(error: nsError) {
                    completion(nil)
                    return
                }

                if let nsError = error as NSError?,
                   remainingRetryCount > 0,
                   self.shouldRetry(for: nsError) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + self.retryDelay(for: remainingRetryCount)) {
                        self.setAlternateIcon(
                            iconName,
                            remainingRetryCount: remainingRetryCount - 1,
                            completion: completion
                        )
                    }
                    return
                }

                completion(error)
            }
        }
    }

    private func retryDelay(for remainingRetryCount: Int) -> TimeInterval {
        switch remainingRetryCount {
        case 4:
            return 0.4
        case 3:
            return 0.6
        case 2:
            return 0.9
        default:
            return 1.2
        }
    }

    private func shouldRetry(for error: NSError) -> Bool {
        let localized = error.localizedDescription.lowercased()
        return localized.contains("temporarily unavailable")
            || localized.contains("resource temporarily unavailable")
            || localized.contains("system busy")
            || localized.contains("busy")
            || localized.contains("暂时不可用")
            || localized.contains("资源暂时不可用")
    }

    private func isBenignCancellation(error: NSError) -> Bool {
        let localized = error.localizedDescription.lowercased()
        return localized.contains("operation is canceled")
            || localized.contains("operation was canceled")
            || localized.contains("操作已被取消")
            || (error.domain == NSCocoaErrorDomain && error.code == NSUserCancelledError)
    }
    #endif
}

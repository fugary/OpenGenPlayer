import Foundation

#if canImport(UIKit)
import UIKit
public typealias AppImage = UIImage
public typealias AppColor = UIColor
#elseif canImport(AppKit)
import AppKit
public typealias AppImage = NSImage
public typealias AppColor = NSColor
#endif

import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

public enum ActivityHUDLayout {
    public static let profileChipHorizontalPadding: CGFloat = 8
    public static let profileChipVerticalPadding: CGFloat = 6
    public static let profileChipHeight: CGFloat = 32

    public static func profileChipContentRect(in bounds: CGRect) -> CGRect {
        let dx = min(profileChipHorizontalPadding, max(0, bounds.width / 2))
        let dy = min(profileChipVerticalPadding, max(0, bounds.height / 2))
        return CGRect(x: bounds.minX + dx, y: bounds.minY + dy,
                      width: max(0, bounds.width - dx * 2), height: max(0, bounds.height - dy * 2))
    }

    public static func cardHeight(profileRows: Int) -> CGFloat {
        116 + (profileRows > 0 ? 22 + CGFloat(min(4, profileRows)) * (profileChipHeight + 4) : 0)
    }

    public static func frame(in visible: CGRect, profileRows: Int = 0) -> CGRect {
        let cardHeight = cardHeight(profileRows: profileRows)
        let visibleWidth: CGFloat = visible.size.width
        let visibleHeight: CGFloat = visible.size.height
        let inset: CGFloat = min(20, max(0, min(visibleWidth, visibleHeight) / 8))
        let horizontalScale: CGFloat = max(0, visibleWidth - inset * 2) / 272
        let verticalScale: CGFloat = max(0, visibleHeight - inset * 2) / cardHeight
        let scale: CGFloat = min(1, min(horizontalScale, verticalScale))
        let width: CGFloat = 272 * scale
        let height: CGFloat = cardHeight * scale
        return CGRect(x: visible.minX + inset, y: visible.midY - height / 2,
                      width: width, height: height)
    }
}

public struct ActivityHUDContent {
    public let heading: String
    public let subtitle: String
    public let time: String?
    public let recording: Bool
    public let processing: Bool

    public init(title: String, detail: String, elapsed: TimeInterval? = nil) {
        recording = title == "Recording"
        processing = title == "Transcribing" || title == "Pasting"
        switch title {
        case "Recording": heading = "Listening"
        case "Transcribing": heading = "Finding your words"
        case "Pasting": heading = "Placing your words"
        case "Microphone permission": heading = "One little permission"
        default: heading = title
        }
        subtitle = detail
        if let elapsed, elapsed.isFinite {
            let seconds = Int(min(5999, max(0, elapsed)))
            time = String(format: "%02d:%02d", seconds / 60, seconds % 60)
        } else {
            time = nil
        }
    }
}

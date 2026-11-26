import CoreGraphics

/// Where the popup goes. All rects use AppKit screen coordinates (y grows upward).
public enum PopupPlacement {
    /// Above the selection, or below it when there is no room, clamped to the visible screen area.
    public static func frame(
        size: CGSize, anchor: CGRect, visible: CGRect, gap: CGFloat = 6
    ) -> CGRect {
        var y = anchor.maxY + gap
        if y + size.height > visible.maxY {
            y = anchor.minY - gap - size.height
        }
        y = min(max(y, visible.minY), max(visible.minY, visible.maxY - size.height))

        var x = anchor.midX - size.width / 2
        x = min(max(x, visible.minX), max(visible.minX, visible.maxX - size.width))

        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }
}

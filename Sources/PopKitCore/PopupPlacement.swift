import CoreGraphics

/// Which side of the selection the popup prefers.
public enum PopupSide: String, CaseIterable, Identifiable {
    case above
    case below

    public var id: String { rawValue }
    public var opposite: PopupSide { self == .above ? .below : .above }
}

/// Where the popup goes. All rects use AppKit screen coordinates (y grows upward).
public enum PopupPlacement {
    /// On the preferred side of the selection, or the other side when there is no room,
    /// clamped to the visible screen area.
    public static func frame(
        size: CGSize, anchor: CGRect, visible: CGRect, gap: CGFloat = 6,
        preferred: PopupSide = .above
    ) -> CGRect {
        let aboveY = anchor.maxY + gap
        let belowY = anchor.minY - gap - size.height
        let fitsAbove = aboveY + size.height <= visible.maxY
        let fitsBelow = belowY >= visible.minY

        var y: CGFloat
        switch preferred {
        case .above: y = (fitsAbove || !fitsBelow) ? aboveY : belowY
        case .below: y = (fitsBelow || !fitsAbove) ? belowY : aboveY
        }
        y = min(max(y, visible.minY), max(visible.minY, visible.maxY - size.height))

        var x = anchor.midX - size.width / 2
        x = min(max(x, visible.minX), max(visible.minX, visible.maxX - size.width))

        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }
}

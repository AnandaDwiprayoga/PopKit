import Foundation

/// Per-app workarounds for selection reading.
public enum AppQuirks {
    /// Chromium browsers only build their accessibility tree after `AXEnhancedUserInterface` is set.
    private static let chromiumBundleIDs: Set<String> = [
        "com.google.chrome", "com.google.chrome.beta", "com.google.chrome.canary",
        "org.chromium.chromium", "com.microsoft.edgemac", "com.brave.browser",
        "company.thebrowser.browser", "com.vivaldi.vivaldi", "com.operasoftware.opera",
    ]

    /// Apps where a synthetic ⌘C would do something other than copy text (Finder copies files).
    private static let noCopyFallbackBundleIDs: Set<String> = [
        "com.apple.finder",
    ]

    public static func isChromium(_ bundleID: String?) -> Bool {
        guard let id = bundleID?.lowercased() else { return false }
        return chromiumBundleIDs.contains(id)
    }

    public static func allowsCopyFallback(_ bundleID: String?) -> Bool {
        guard let id = bundleID?.lowercased() else { return true }
        return !noCopyFallbackBundleIDs.contains(id)
    }
}

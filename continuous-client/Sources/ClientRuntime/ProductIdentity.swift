import Foundation

/// Stable public identifiers shared by the app, its data directory, and its Keychain items.
public enum ProductIdentity {
    public static let bundleIdentifier = "io.github.ziqiangyzq-cyber.meeting-copilot"
    public static let dataDirectoryName = bundleIdentifier
    public static let keychainService = bundleIdentifier + ".backend-api"
}

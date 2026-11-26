import Foundation
import Security

/// Where `secret` options live.
public protocol SecretStore {
    func secret(for account: String) -> String?
    func setSecret(_ value: String, for account: String)
}

/// Secrets in the login keychain: service "PopKit", account "<extensionID>.<option>".
public final class KeychainSecretStore: SecretStore {
    private let service = "PopKit"

    public init() {}

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func secret(for account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let value = String(data: data, encoding: .utf8) else { return nil }
        return value
    }

    public func setSecret(_ value: String, for account: String) {
        SecItemDelete(query(account) as CFDictionary)
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var q = query(account)
        q[kSecValueData as String] = Data(trimmed.utf8)
        q[kSecAttrLabel as String] = "PopKit extension option"
        SecItemAdd(q as CFDictionary, nil)
    }
}

/// The values of each extension's options. Plain options live in UserDefaults, secrets in the
/// Keychain. For headless runs, `POPKIT_OPT_<IDENTIFIER>` in the environment wins over both.
public final class OptionsStore {
    private let defaults: UserDefaults
    private let secrets: SecretStore
    private let environment: [String: String]

    public init(defaults: UserDefaults = .standard,
                secrets: SecretStore = KeychainSecretStore(),
                environment: [String: String] = [:]) {
        self.defaults = defaults
        self.secrets = secrets
        self.environment = environment
    }

    private func defaultsKey(_ spec: OptionSpec, _ extensionID: String) -> String {
        "popkit.ext.\(extensionID).\(spec.identifier)"
    }

    private func account(_ spec: OptionSpec, _ extensionID: String) -> String {
        "\(extensionID).\(spec.identifier)"
    }

    public func value(for spec: OptionSpec, extensionID: String) -> OptionValue {
        if let fromEnvironment = environment["POPKIT_OPT_\(spec.identifier.uppercased())"] {
            return spec.kind == .boolean ? .bool(OptionValue.string(fromEnvironment).boolValue) : .string(fromEnvironment)
        }

        switch spec.kind {
        case .secret:
            return .string(secrets.secret(for: account(spec, extensionID)) ?? "")
        case .string:
            return .string(defaults.string(forKey: defaultsKey(spec, extensionID)) ?? spec.effectiveDefault.stringValue)
        case .multiple:
            if let stored = defaults.string(forKey: defaultsKey(spec, extensionID)), spec.values.contains(stored) {
                return .string(stored)
            }
            return spec.effectiveDefault
        case .boolean:
            let key = defaultsKey(spec, extensionID)
            guard defaults.object(forKey: key) != nil else { return spec.effectiveDefault }
            return .bool(defaults.bool(forKey: key))
        }
    }

    public func set(_ value: OptionValue, for spec: OptionSpec, extensionID: String) {
        switch spec.kind {
        case .secret:
            secrets.setSecret(value.stringValue, for: account(spec, extensionID))
        case .string, .multiple:
            defaults.set(value.stringValue, forKey: defaultsKey(spec, extensionID))
        case .boolean:
            defaults.set(value.boolValue, forKey: defaultsKey(spec, extensionID))
        }
    }

    public func values(for manifest: ExtensionManifest, extensionID: String) -> [String: OptionValue] {
        Dictionary(uniqueKeysWithValues: manifest.options.map {
            ($0.identifier, value(for: $0, extensionID: extensionID))
        })
    }

    /// Forgets everything stored for an extension, including its secrets.
    public func clear(_ manifest: ExtensionManifest, extensionID: String) {
        for spec in manifest.options {
            switch spec.kind {
            case .secret: secrets.setSecret("", for: account(spec, extensionID))
            default: defaults.removeObject(forKey: defaultsKey(spec, extensionID))
            }
        }
    }
}

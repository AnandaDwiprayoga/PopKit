import Foundation

public enum ExtensionError: LocalizedError, Equatable {
    case missingConfig(String)
    case invalidConfig(String)
    case missingModule(String)
    case conflictsWithBuiltIn(String)
    case notADirectory(String)
    case loadFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingConfig(let path): return "No Config.json found in \(path)."
        case .invalidConfig(let detail): return "Config.json is invalid: \(detail)"
        case .missingModule(let file): return "The module file \"\(file)\" named in Config.json is missing."
        case .conflictsWithBuiltIn(let id): return "\"\(id)\" is the name of a built-in extension. Rename the folder to install it."
        case .notADirectory(let path): return "\(path) is not an extension folder."
        case .loadFailed(let detail): return detail
        }
    }
}

/// A stored or default value for an extension option.
public enum OptionValue: Equatable, Decodable {
    case string(String)
    case bool(Bool)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let number = try? container.decode(Double.self) {
            self = .string(number.rounded() == number ? String(Int(number)) : String(number))
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported option value")
        }
    }

    public var stringValue: String {
        switch self {
        case .string(let value): return value
        case .bool(let value): return value ? "true" : "false"
        }
    }

    public var boolValue: Bool {
        switch self {
        case .bool(let value): return value
        case .string(let value): return ["true", "1", "yes"].contains(value.lowercased())
        }
    }

    /// The value as it is handed to JavaScript.
    public var jsonObject: Any {
        switch self {
        case .string(let value): return value
        case .bool(let value): return value
        }
    }
}

/// One entry of Config.json's `options`, shown as a field in the extension's settings.
public struct OptionSpec: Decodable, Equatable, Identifiable {
    public enum Kind: String, Equatable {
        /// A text field.
        case string
        /// A password field, kept in the Keychain.
        case secret
        /// A picker over `values`.
        case multiple
        /// A toggle.
        case boolean
    }

    public let identifier: String
    public let kind: Kind
    public let label: String
    public let description: String?
    public let values: [String]
    public let valueLabels: [String]?
    public let defaultValue: OptionValue?

    public var id: String { identifier }

    private enum CodingKeys: String, CodingKey {
        case identifier, type, label, description, values, defaultValue
        case valueLabels, valueLabelsSpaced = "value labels"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        identifier = try c.decode(String.self, forKey: .identifier)
        let type = try c.decodeIfPresent(String.self, forKey: .type) ?? "string"
        guard let kind = Kind(rawValue: type) else {
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unsupported option type \(type)")
        }
        self.kind = kind
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? identifier
        description = try c.decodeIfPresent(String.self, forKey: .description)
        values = try c.decodeIfPresent([String].self, forKey: .values) ?? []
        valueLabels = try c.decodeIfPresent([String].self, forKey: .valueLabels)
            ?? c.decodeIfPresent([String].self, forKey: .valueLabelsSpaced)
        defaultValue = try c.decodeIfPresent(OptionValue.self, forKey: .defaultValue)
    }

    public init(identifier: String, kind: Kind, label: String? = nil, description: String? = nil,
                values: [String] = [], valueLabels: [String]? = nil, defaultValue: OptionValue? = nil) {
        self.identifier = identifier
        self.kind = kind
        self.label = label ?? identifier
        self.description = description
        self.values = values
        self.valueLabels = valueLabels
        self.defaultValue = defaultValue
    }

    /// What the option holds before the user changes it.
    public var effectiveDefault: OptionValue {
        switch kind {
        case .boolean: return .bool(defaultValue?.boolValue ?? false)
        case .multiple: return .string(defaultValue?.stringValue ?? values.first ?? "")
        case .string, .secret: return .string(defaultValue?.stringValue ?? "")
        }
    }

    public func displayLabel(forValue value: String) -> String {
        guard let index = values.firstIndex(of: value), let labels = valueLabels, labels.indices.contains(index) else {
            return value
        }
        return labels[index]
    }
}

/// An extension's Config.json: the same keys PopClip uses, as far as PopKit supports them.
public struct ExtensionManifest: Decodable, Equatable {
    public let name: String
    public let description: String?
    /// An emoji or short text, `symbol:<SF Symbol>`, or a PNG file in the extension folder.
    public let icon: String?
    /// Overrides the folder name as the extension's id.
    public let identifier: String?
    public let entitlements: [String]
    /// The JavaScript file that exports `actions`. Defaults to index.js.
    public let module: String
    public let options: [OptionSpec]

    public var allowsNetwork: Bool { entitlements.contains("network") }

    private enum CodingKeys: String, CodingKey {
        case name, description, icon, identifier, entitlements, module, options
    }

    /// Lets one unsupported option type (a heading, say) be skipped instead of failing the whole file.
    private struct Lenient<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let name = try c.decodeIfPresent(String.self, forKey: .name),
              !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw DecodingError.keyNotFound(CodingKeys.name, .init(codingPath: [], debugDescription: "\"name\" is required"))
        }
        self.name = name
        description = try c.decodeIfPresent(String.self, forKey: .description)
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        identifier = try c.decodeIfPresent(String.self, forKey: .identifier)
        entitlements = try c.decodeIfPresent([String].self, forKey: .entitlements) ?? []
        module = try c.decodeIfPresent(String.self, forKey: .module) ?? "index.js"
        options = (try c.decodeIfPresent([Lenient<OptionSpec>].self, forKey: .options) ?? []).compactMap(\.value)
    }

    public static func parse(_ data: Data) throws -> ExtensionManifest {
        do {
            return try JSONDecoder().decode(ExtensionManifest.self, from: data)
        } catch let DecodingError.keyNotFound(key, _) {
            throw ExtensionError.invalidConfig("\"\(key.stringValue)\" is required")
        } catch {
            throw ExtensionError.invalidConfig("\(error.localizedDescription)")
        }
    }

    public static func load(directory: URL) throws -> ExtensionManifest {
        let url = directory.appendingPathComponent("Config.json")
        guard let data = try? Data(contentsOf: url) else {
            throw ExtensionError.missingConfig(directory.path)
        }
        return try parse(data)
    }

    /// The extension's id: `identifier`, or the folder name without its extension.
    public func id(directory: URL) -> String {
        if let identifier, !identifier.isEmpty { return identifier }
        return directory.deletingPathExtension().lastPathComponent
    }
}

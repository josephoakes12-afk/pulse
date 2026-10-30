import Foundation

/// A portable setup template. Decoding never fetches data, saves a project or
/// reads Keychain; credentials are supplied by the user after import.
public enum ProjectPreset {
    public static let maximumBytes = 65_536

    public static func decode(_ data: Data) throws -> ProjectConnection {
        guard data.count <= maximumBytes else {
            throw PulseError.invalidConfiguration("Choose a project file smaller than 64 KB.")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data), let root = object as? [String: Any] else {
            throw PulseError.invalidConfiguration("This isn’t a valid Pulse project file.")
        }
        guard !containsSecretKey(root) else {
            throw PulseError.invalidConfiguration("Project files must not contain credentials. Add the credential after importing.")
        }
        let allowedRoot: Set<String> = ["version", "name", "kind", "endpoint", "authHeader", "query", "metrics", "symbol", "link"]
        guard Set(root.keys).isSubset(of: allowedRoot),
              let metrics = root["metrics"] as? [[String: Any]],
              metrics.allSatisfy({ Set($0.keys).isSubset(of: ["label", "path"]) }) else {
            throw PulseError.invalidConfiguration("This project file contains unsupported settings.")
        }

        let preset: Payload
        do { preset = try JSONDecoder().decode(Payload.self, from: data) }
        catch { throw PulseError.invalidConfiguration("This project file is missing a valid name, source, URL or metric.") }
        guard preset.version == nil || preset.version == 1 else {
            throw PulseError.invalidConfiguration("This project file needs a different version of Pulse.")
        }
        guard preset.kind == .postgres || (preset.query ?? "").isEmpty else {
            throw PulseError.invalidConfiguration("Only database project files can include a query.")
        }

        let symbol = preset.symbol ?? "square.stack.3d.up"
        let allowedSymbolCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "."))
        guard !symbol.isEmpty, symbol.count <= 80, symbol.unicodeScalars.allSatisfy(allowedSymbolCharacters.contains) else {
            throw PulseError.invalidConfiguration("Choose a project file with a valid icon name.")
        }
        let link = (preset.link ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !link.isEmpty {
            guard link.count <= 2_048, HTTPConnector.safeLink(link) != nil,
                  !(URLComponents(string: link)?.queryItems ?? []).contains(where: { secretKeys.contains(normalizedKey($0.name)) }) else {
                throw PulseError.invalidConfiguration("Project links must be web URLs without credentials.")
            }
        }
        let connection = ProjectConnection(
            name: preset.name.trimmingCharacters(in: .whitespacesAndNewlines),
            symbol: symbol,
            kind: preset.kind,
            endpoint: preset.endpoint.trimmingCharacters(in: .whitespacesAndNewlines),
            query: preset.query ?? "",
            authHeader: preset.authHeader ?? "Authorization",
            metrics: preset.metrics.map {
                MetricDefinition(label: $0.label.trimmingCharacters(in: .whitespacesAndNewlines),
                                 path: $0.path.trimmingCharacters(in: .whitespacesAndNewlines))
            },
            link: link
        )
        try ConnectorValidation.validate(connection)
        return connection
    }

    private struct Payload: Decodable {
        var version: Int?
        var name: String
        var kind: ConnectorKind
        var endpoint: String
        var authHeader: String?
        var query: String?
        var metrics: [Metric]
        var symbol: String?
        var link: String?
        struct Metric: Decodable {
            var label: String
            var path: String
        }
    }

    private static let secretKeys: Set<String> = [
        "password", "passwd", "secret", "token", "apikey", "accesstoken",
        "refreshtoken", "authorization", "credential", "credentials", "signature"
    ]

    private static func normalizedKey(_ key: String) -> String {
        String(key.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains))
    }

    private static func containsSecretKey(_ value: Any) -> Bool {
        if let dictionary = value as? [String: Any] {
            return dictionary.contains { secretKeys.contains(normalizedKey($0.key)) || containsSecretKey($0.value) }
        }
        if let array = value as? [Any] { return array.contains(where: containsSecretKey) }
        return false
    }
}

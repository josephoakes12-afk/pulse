import Foundation

/// Browser destinations contain no connection credentials or API request paths.
public enum SourceLink {
    public static func url(for connection: ProjectConnection) -> URL? {
        let explicit = connection.link.trimmingCharacters(in: .whitespacesAndNewlines)
        if !explicit.isEmpty { return safeWebURL(explicit) }

        guard let source = URLComponents(string: connection.endpoint),
              let host = source.host?.lowercased(), !host.isEmpty,
              source.password == nil, source.fragment == nil else { return nil }
        let scheme = source.scheme?.lowercased() ?? ""
        guard connection.kind == .postgres ? ["postgres", "postgresql"].contains(scheme) : ["http", "https"].contains(scheme) else { return nil }
        if connection.kind != .postgres && source.user != nil { return nil }

        let components = host.split(separator: ".").map(String.init)
        var reference: String?
        let path = source.path.split(separator: "/")
        if connection.kind == .supabase, host == "api.supabase.com", path.count == 6,
           path[0] == "v1", path[1] == "projects", path[3] == "database", path[4] == "query", path[5] == "read-only" {
            reference = String(path[2])
        }
        if components.count == 3, components[1] == "supabase", components[2] == "co" {
            reference = components[0]
        } else if components.count == 4, components[0] == "db", components[2] == "supabase", components[3] == "co" {
            reference = components[1]
        } else if host.hasSuffix(".pooler.supabase.com"), connection.kind == .postgres,
                  let user = source.user, user.split(separator: ".").count == 2 {
            reference = user.split(separator: ".").last.map(String.init)
        }
        if let reference, validReference(reference) {
            return URL(string: "https://supabase.com/dashboard/project/\(reference)")
        }

        if connection.kind == .postgres {
            // Endpoint IDs do not identify Neon dashboard projects. Open its console
            // rather than inventing a project URL from an endpoint name.
            return host.hasSuffix(".neon.tech") ? URL(string: "https://console.neon.tech/") : nil
        }
        var origin = URLComponents()
        origin.scheme = scheme
        origin.host = source.host
        origin.port = source.port
        return origin.url
    }

    private static func validReference(_ value: String) -> Bool {
        value.count == 20 && value.unicodeScalars.allSatisfy { (97...122).contains($0.value) || (48...57).contains($0.value) }
    }

    private static func safeWebURL(_ value: String) -> URL? {
        guard value.count <= 2_048, let parts = URLComponents(string: value),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              !host.contains(where: { $0.isWhitespace }),
              !(parts.queryItems ?? []).contains(where: { isCredentialParameter($0.name) }),
              !fragmentContainsCredential(parts.fragment) else { return nil }
        return parts.url
    }

    private static func fragmentContainsCredential(_ fragment: String?) -> Bool {
        guard let fragment, !fragment.isEmpty else { return false }
        let query = fragment.split(separator: "?", omittingEmptySubsequences: false).last.map(String.init) ?? fragment
        return (URLComponents(string: "https://example.invalid/?" + query)?.queryItems ?? []).contains { isCredentialParameter($0.name) }
    }

    private static func isCredentialParameter(_ key: String) -> Bool {
        let normalized = String(key.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
        return ["key", "apikey", "accesskey", "token", "accesstoken", "refreshtoken", "password", "passwd", "secret", "signature", "authorization", "credential", "credentials", "session", "sessionid", "jwt", "code", "authcode", "auth"].contains(normalized)
            || normalized.hasSuffix("token") || normalized.hasSuffix("password") || normalized.hasSuffix("secret")
            || normalized.hasSuffix("signature") || normalized.hasSuffix("credential")
    }
}

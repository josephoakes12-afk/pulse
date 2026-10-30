import Foundation
import Testing
@testable import PulseCore

private let sourceLinkReference = "abcdefghijklmnopqrst"

@Test func sourceLinkResolvesSupabaseAPIAndDirectDatabase() {
    let api = ProjectConnection(name: "Example", endpoint: "https://\(sourceLinkReference).supabase.co/rest/v1/summary?select=total")
    let database = ProjectConnection(name: "Example", kind: .postgres, endpoint: "postgresql://reader@db.\(sourceLinkReference).supabase.co:5432/postgres")
    let expected = "https://supabase.com/dashboard/project/\(sourceLinkReference)"
    #expect(SourceLink.url(for: api)?.absoluteString == expected)
    #expect(SourceLink.url(for: database)?.absoluteString == expected)
}

@Test func sourceLinkResolvesSupabasePoolerWithoutLeakingRoleOrDatabase() {
    for role in ["postgres", "pulse_reader"] {
        let connection = ProjectConnection(name: "Example", kind: .postgres, endpoint: "postgresql://\(role).\(sourceLinkReference)@aws-0-eu-west-2.pooler.supabase.com:6543/postgres?sslmode=require")
        #expect(SourceLink.url(for: connection)?.absoluteString == "https://supabase.com/dashboard/project/\(sourceLinkReference)")
    }
}

@Test func sourceLinkPrefersExplicitSafeDashboard() {
    let connection = ProjectConnection(name: "Example", endpoint: "https://api.example.test/summary", link: " https://dashboard.example.test/projects/demo?tab=usage ")
    #expect(SourceLink.url(for: connection)?.absoluteString == "https://dashboard.example.test/projects/demo?tab=usage")
    var hashRoute = connection
    hashRoute.link = "https://dashboard.example.test/#/projects/demo?tab=usage"
    #expect(SourceLink.url(for: hashRoute)?.absoluteString == hashRoute.link)
}

@Test func sourceLinkRejectsCredentialDestinationsAndUnexpectedProtocols() {
    for link in ["javascript:alert(1)", "file:///tmp/private", "postgresql://reader@db.example.test/app", "https://reader:password@example.test/", "https://example.test/?access_token=private", "https://example.test/?auth_token=private", "https://example.test/?api-key=private", "https://example.test/?session_id=private", "https://example.test/?code=private", "https://example.test/#access_token=private"] {
        let connection = ProjectConnection(name: "Example", endpoint: "https://api.example.test/summary", link: link)
        #expect(SourceLink.url(for: connection) == nil)
    }
    let embedded = ProjectConnection(name: "Example", kind: .postgres, endpoint: "postgresql://reader:private@db.\(sourceLinkReference).supabase.co/postgres")
    #expect(SourceLink.url(for: embedded) == nil)
}

@Test func sourceLinkNeverTreatsLookalikeHostsAsProviders() {
    for host in ["db.\(sourceLinkReference).supabase.co.evil.test", "db.\(sourceLinkReference).supabase-co.test", "aws-0.pooler.supabase.com.evil.test", "ep-example.neon.tech.evil.test"] {
        let connection = ProjectConnection(name: "Example", kind: .postgres, endpoint: "postgresql://postgres.\(sourceLinkReference)@\(host)/postgres")
        #expect(SourceLink.url(for: connection) == nil)
    }
    let invalidReference = ProjectConnection(name: "Example", kind: .postgres, endpoint: "postgresql://reader@db.short.supabase.co/postgres")
    #expect(SourceLink.url(for: invalidReference) == nil)
}

@Test func sourceLinkUsesOnlyTheOriginForGenericAPIs() {
    let connection = ProjectConnection(name: "Example", endpoint: "http://127.0.0.1:8765/api/private/summary?token=private#private")
    // Fragments are not valid connection addresses, even though no fragment can
    // leak to the generated browser destination.
    #expect(SourceLink.url(for: connection) == nil)
    var valid = connection
    valid.endpoint = "https://api.example.test:8443/private/summary?token=private"
    #expect(SourceLink.url(for: valid)?.absoluteString == "https://api.example.test:8443")
    valid.endpoint = "http://127.0.0.1:8765/private/summary"
    #expect(SourceLink.url(for: valid)?.absoluteString == "http://127.0.0.1:8765")
}

@Test func sourceLinkOpensNeonConsoleWithoutInventingAProjectID() {
    let connection = ProjectConnection(name: "Example", kind: .postgres, endpoint: "postgresql://reader@ep-example.eu-west-2.aws.neon.tech/neondb")
    #expect(SourceLink.url(for: connection)?.absoluteString == "https://console.neon.tech/")
    let generic = ProjectConnection(name: "Example", kind: .postgres, endpoint: "postgresql://reader@db.example.test/app")
    #expect(SourceLink.url(for: generic) == nil)
}

import Foundation
import Testing
@testable import PulseCore

@Test func discoveryKeepsPlainNumericKeysAndRejectsControlCharacterKeys() throws {
    // This also runs under `swift test -c release`: a temporary bound CharacterSet
    // method was miscompiled under -O and incorrectly rejected every ordinary key.
    let data = Data(#"{"metrics":{"accounts":12,"bookings7d":38,"hidden\u0001count":99,"counts":{"games":4}}}"#.utf8)
    let found = try HTTPConnector.discover(data: data)
    #expect(found.map(\.path) == ["metrics.accounts", "metrics.bookings7d", "metrics.counts.games"])
    #expect(found.map(\.previewValue) == ["12", "38", "4"])
}

@Test func generatedCountsAcceptOrdinaryIdentifiersAndRejectControlCharacters() throws {
    let base = ProjectConnection(name: "Database", kind: .postgres, endpoint: "postgresql://reader@db.example.test/app")
    let ordinary = try PostgresConnector.countingConnection(base: base, tables: [DatabaseTable(schema: "public", name: "accounts", isView: false)])
    #expect(ordinary.metrics.map(\.path) == ["metric_0"])
    #expect(throws: PulseError.self) {
        try PostgresConnector.countingConnection(base: base, tables: [DatabaseTable(schema: "public", name: "hidden\u{1}count", isView: false)])
    }
}

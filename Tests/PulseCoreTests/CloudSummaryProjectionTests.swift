import Foundation
import PulseWidgetData
import Testing
@testable import PulseCore

struct CloudSummaryProjectionTests {
    @Test func promotedHeadlineChoicesKeepRangeValuesWithoutExportingDrawerRecordsOrSourceDetails() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let project = ProjectConnection(name: "Studio", symbol: "calendar", iconImageData: Data([1, 2, 3]),
            endpoint: "https://private-source.example.invalid", query: "private query text", authHeader: "Private-Auth",
            link: "https://private-dashboard.example.invalid")
        let accountsID = UUID(), bookingsID = UUID(), averageID = UUID(), detailID = UUID()
        let metrics = [MetricValue(id: accountsID, label: "Accounts", value: "12"),
                       MetricValue(id: bookingsID, label: "Bookings", value: "24")]
        let details = [MetricValue(id: averageID, label: "Bookings / account", value: "2"),
                       MetricValue(id: detailID, label: "Private drawer label", value: "999")]
        let rows = [MetricBreakdown(id: "private-group", title: "Private group title", rows: [
            MetricBreakdownRow(id: "private-row-id", label: "person@example.invalid", value: "14")
        ])]
        var weekDetails = details
        weekDetails[0].value = "1.5"
        let source = ProjectSnapshot(projectID: project.id, metrics: metrics,
            events: [PulseEvent(id: "private-event", title: "Private event title", occurredAt: now)],
            measuredAt: now.addingTimeInterval(-60), fetchedAt: now, coverage: "Private coverage text",
            details: details, breakdowns: rows,
            ranges: ["7d": MetricRangeSnapshot(metrics: metrics, details: weekDetails, breakdowns: rows),
                     "lifetime": MetricRangeSnapshot(metrics: metrics, details: details, breakdowns: rows)],
            alertObservations: AlertObservations(counters: [
                CounterAlertObservation(id: "private-alert-id", label: "Private alert label", value: 99,
                                        unitSingular: "private alert unit", unitPlural: "private alert units")
            ]))
        let visibility = MetricVisibility(headlineMetricIDs: [averageID, accountsID], detailMetricIDs: [detailID], visibleBreakdownIDs: ["private-group"])
        let widget = WidgetSnapshotBuilder.make(connections: [project], snapshots: [project.id: source],
            visibility: [project.id: visibility], defaultRange: .last7Days, now: now)
        let cloud = try CloudSyncSnapshot.prepared(publisherID: UUID(), snapshot: widget, now: now)

        #expect(cloud.snapshot.projects[0].id == project.id)
        #expect(cloud.snapshot.defaultRangeRawValue == "7d")
        #expect(cloud.snapshot.projects[0].range(rawValue: "7d")?.metrics.map(\.id) == [averageID, accountsID])
        #expect(cloud.snapshot.projects[0].range(rawValue: "7d")?.metrics.map(\.value) == ["1.5", "12"])
        #expect(cloud.snapshot.projects[0].range(rawValue: "lifetime")?.metrics.map(\.value) == ["2", "12"])
        #expect(cloud.snapshot.projects[0].range(rawValue: "30d") == nil)
        #expect(cloud.snapshot.projects[0].ranges.allSatisfy { $0.measuredAt == source.measuredAt })
        #expect(widget.projects[0].iconImageData == Data([1, 2, 3]))
        #expect(cloud.snapshot.projects[0].iconImageData == nil)

        let data = try cloud.encoded(now: now)
        let json = String(decoding: data, as: UTF8.self)
        for privateValue in ["private-source", "private-dashboard", "private query", "Private-Auth", "Private drawer", detailID.uuidString,
                             "private-group", "Private group", "private-row", "person@example.invalid", "private-event", "Private event",
                             "Private coverage", "private-alert", "Private alert", "private alert unit"] {
            #expect(!json.contains(privateValue))
        }
        #expect(try CloudSyncSnapshot.decode(data, now: now) == cloud)
    }
}

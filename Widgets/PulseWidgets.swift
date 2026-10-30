import AppKit
import SwiftUI
import WidgetKit

enum WidgetData {
    static func snapshot() -> WidgetSnapshot? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "PulseAppGroupIdentifier") as? String,
              !group.isEmpty,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { return nil }
        return WidgetSnapshotStore(directoryURL: container.appendingPathComponent("Widget", isDirectory: true)).load()
    }
    static func link(project: UUID? = nil, range: String? = nil) -> URL? {
        var components = URLComponents()
        components.scheme = "pulse-metrics"
        components.host = project == nil ? "open" : "project"
        if let project { components.path = "/" + project.uuidString }
        if let range { components.queryItems = [URLQueryItem(name: "range", value: range)] }
        return components.url
    }
}

struct PulseEntry: TimelineEntry {
    var date: Date
    var snapshot: WidgetSnapshot?
    var projectID: UUID?
    var range: String?
    var isPlaceholder = false
    var resolvedRange: String { range ?? snapshot?.defaultRangeRawValue ?? "7d" }
    var rangeTitle: String {
        switch resolvedRange { case "24h": "24h"; case "30d": "30d"; case "lifetime": "All time"; default: "7d" }
    }
}

struct ProjectProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> PulseEntry { PulseEntry(date: .now, isPlaceholder: true) }
    func snapshot(for configuration: ProjectWidgetConfiguration, in context: Context) async -> PulseEntry {
        entry(configuration)
    }
    func timeline(for configuration: ProjectWidgetConfiguration, in context: Context) async -> Timeline<PulseEntry> {
        Timeline(entries: [entry(configuration)], policy: .after(Date().addingTimeInterval(30 * 60)))
    }
    private func entry(_ configuration: ProjectWidgetConfiguration) -> PulseEntry {
        PulseEntry(date: .now, snapshot: WidgetData.snapshot(),
                   projectID: configuration.project.flatMap { UUID(uuidString: $0.id) }, range: configuration.range.requestedRange)
    }
}

struct OverviewProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> PulseEntry { PulseEntry(date: .now, isPlaceholder: true) }
    func snapshot(for configuration: OverviewWidgetConfiguration, in context: Context) async -> PulseEntry {
        PulseEntry(date: .now, snapshot: WidgetData.snapshot(), range: configuration.range.requestedRange)
    }
    func timeline(for configuration: OverviewWidgetConfiguration, in context: Context) async -> Timeline<PulseEntry> {
        Timeline(entries: [await snapshot(for: configuration, in: context)], policy: .after(Date().addingTimeInterval(30 * 60)))
    }
}

struct ProjectWidgetView: View {
    let entry: PulseEntry
    var body: some View {
        if let project = entry.snapshot?.project(id: entry.projectID, rangeRawValue: entry.range),
           let range = project.range(rawValue: entry.resolvedRange) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    ProjectIcon(project: project)
                    Text(project.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 0)
                    if !project.enabled { Image(systemName: "pause.fill").font(.system(size: 9)).foregroundStyle(.secondary) }
                    else if project.hasError { Image(systemName: "exclamationmark.circle").font(.system(size: 10)).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 0)
                VStack(spacing: 2) {
                    ForEach(range.metrics) { metric in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(metric.label).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                            Spacer(minLength: 0)
                            Text(metric.value).font(.system(size: range.metrics.count > 2 ? 20 : 26, weight: .medium, design: .rounded))
                                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                        }.accessibilityElement(children: .combine)
                    }
                }
                Spacer(minLength: 0)
                HStack(spacing: 3) {
                    Text(entry.rangeTitle).lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "clock").font(.system(size: 8))
                    Text(range.measuredAt, style: .relative).lineLimit(1).minimumScaleFactor(0.7)
                }.font(.system(size: 9)).foregroundStyle(.tertiary)
            }
            .privacySensitive()
            .widgetURL(WidgetData.link(project: project.id, range: entry.resolvedRange))
            .containerBackground(.background, for: .widget)
        } else {
            EmptyWidgetView(rangeTitle: entry.rangeTitle, noHistory: entry.projectID != nil || !(entry.snapshot?.projects.isEmpty ?? true), placeholder: entry.isPlaceholder)
        }
    }
}

struct OverviewWidgetView: View {
    let entry: PulseEntry
    var body: some View {
        let projects = entry.snapshot?.overview(rangeRawValue: entry.range) ?? []
        if !projects.isEmpty {
            VStack(spacing: 4) {
                HStack {
                    Label("Pulse", systemImage: "waveform.path.ecg").font(.system(size: 11, weight: .semibold))
                    Spacer()
                    HStack(spacing: 4) {
                        Text(entry.rangeTitle)
                        if let oldest = projects.compactMap({ $0.range(rawValue: entry.resolvedRange)?.measuredAt }).min() {
                            Text("·")
                            Image(systemName: "clock").font(.system(size: 8))
                            Text(oldest, style: .relative).lineLimit(1).minimumScaleFactor(0.7)
                        }
                    }.font(.system(size: 9)).foregroundStyle(.secondary)
                }
                VStack(spacing: 4) {
                    ForEach(projects) { project in
                        if let range = project.range(rawValue: entry.resolvedRange),
                           let link = WidgetData.link(project: project.id, range: entry.resolvedRange) {
                            Link(destination: link) {
                                HStack(spacing: 10) {
                                    HStack(spacing: 6) {
                                        ProjectIcon(project: project)
                                        Text(project.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                                        if project.hasError { Image(systemName: "exclamationmark.circle").font(.system(size: 9)).foregroundStyle(.secondary) }
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                    ForEach(range.metrics.prefix(2)) { metric in
                                        VStack(alignment: .trailing, spacing: 1) {
                                            Text(metric.value).font(.system(size: 18, weight: .medium, design: .rounded)).monospacedDigit()
                                            Text(metric.label).font(.system(size: 8)).foregroundStyle(.secondary)
                                        }.lineLimit(1).minimumScaleFactor(0.6).frame(width: 67, alignment: .trailing)
                                            .accessibilityElement(children: .combine)
                                    }
                                }
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .privacySensitive()
            .widgetURL(WidgetData.link(range: entry.resolvedRange))
            .containerBackground(.background, for: .widget)
        } else {
            EmptyWidgetView(rangeTitle: entry.rangeTitle, noHistory: !(entry.snapshot?.projects.isEmpty ?? true), placeholder: entry.isPlaceholder)
        }
    }
}

private struct ProjectIcon: View {
    let project: WidgetProject
    var body: some View {
        Group {
            if let data = project.iconImageData, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFit()
            } else { Image(systemName: project.symbol).resizable().scaledToFit().foregroundStyle(.secondary) }
        }.frame(width: 14, height: 14).accessibilityHidden(true)
    }
}

private struct EmptyWidgetView: View {
    var rangeTitle: String
    var noHistory: Bool
    var placeholder: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Pulse", systemImage: "waveform.path.ecg").font(.system(size: 12, weight: .semibold))
            Spacer()
            Text(placeholder ? "—" : noHistory ? "No data · \(rangeTitle)" : "Open Pulse").font(.system(size: 13)).foregroundStyle(.secondary)
            Spacer()
        }.frame(maxWidth: .infinity, alignment: .leading)
            .widgetURL(WidgetData.link()).containerBackground(.background, for: .widget)
    }
}

struct PulseProjectWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "PulseProject", intent: ProjectWidgetConfiguration.self, provider: ProjectProvider()) { entry in
            ProjectWidgetView(entry: entry)
        }.configurationDisplayName("Project").description("Your project's key numbers.").supportedFamilies([.systemSmall])
    }
}

struct PulseOverviewWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "PulseOverview", intent: OverviewWidgetConfiguration.self, provider: OverviewProvider()) { entry in
            OverviewWidgetView(entry: entry)
        }.configurationDisplayName("Overview").description("Your projects at a glance.").supportedFamilies([.systemMedium])
    }
}

@main
struct PulseWidgets: WidgetBundle {
    var body: some Widget { PulseProjectWidget(); PulseOverviewWidget() }
}

import AppKit
import PulseCore
import SwiftUI

struct PulsePanel: View {
    @ObservedObject var store: AppStore
    @State private var expanded: UUID?
    @State private var hovered: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        IntegralPanelLayout { panelContent }.background(.regularMaterial)
    }

    private var panelContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.path.ecg").font(.system(size: 17, weight: .medium)).foregroundStyle(.tint)
                Text("Pulse").font(.system(size: 16, weight: .semibold))
                Spacer()
                if store.isDemo { Text("DEMO").font(.system(size: 9, weight: .semibold, design: .rounded)).tracking(0.6).padding(.horizontal, 7).padding(.vertical, 4).background(.quaternary, in: Capsule()).foregroundStyle(.secondary).accessibilityLabel("Example data") }
                Button { AppWindows.showAddProject(store: store) } label: { Image(systemName: "plus").frame(width: 14, height: 14) }
                    .buttonStyle(.borderless).help("Add Project").accessibilityLabel("Add Project").keyboardShortcut("n")
                if store.isRefreshing { ProgressView().controlSize(.mini).frame(width: 14, height: 14).accessibilityLabel("Updating") }
            }.padding(.horizontal, 20).padding(.top, 19).padding(.bottom, 17)
            Divider().padding(.horizontal, 20)

            if store.displayedConnections.isEmpty { emptyState }
            else if store.displayedConnections.count > 3 {
                ScrollView { projectList }.scrollBounceBehavior(.basedOnSize).frame(height: 460)
            } else { projectList }

            if let storageError = store.storageError {
                Label(storageError, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange).padding(.horizontal, 20).padding(.bottom, 12)
            }
            Divider()
            HStack(spacing: 8) {
                Circle().fill(statusColor).frame(width: 5, height: 5).accessibilityHidden(true)
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(footer(now: context.date)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 2)
                Menu {
                    Button("Add Project…") { AppWindows.showAddProject(store: store) }
                    Button("Refresh") { Task { await store.refreshAll() } }.keyboardShortcut("r").disabled(store.isDemo || store.isRefreshing || store.connections.isEmpty)
                    Button("Connections…") { AppWindows.showConnections(store: store) }.keyboardShortcut(",")
                    if store.connections.isEmpty { Button(store.showExamples ? "Hide example projects" : "Show example projects") { store.showExamples.toggle() } }
                    Divider()
                    Button("Quit Pulse") { NSApp.terminate(nil) }.keyboardShortcut("q")
                } label: { Image(systemName: "gearshape").font(.system(size: 12)) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Pulse settings").accessibilityLabel("Pulse settings")
            }.padding(.horizontal, 20).padding(.vertical, 13)
        }.frame(width: 364).fixedSize(horizontal: false, vertical: true)
    }

    private var projectList: some View {
        VStack(spacing: 0) {
            ForEach(Array(store.displayedConnections.enumerated()), id: \.element.id) { index, connection in
                projectRow(connection)
                if index < store.displayedConnections.count - 1 { Divider().padding(.leading, 65).padding(.trailing, 20) }
            }
        }.padding(.vertical, 4)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up").font(.system(size: 28, weight: .light)).foregroundStyle(.secondary)
            Button("Add Project") { AppWindows.showAddProject(store: store) }.buttonStyle(.borderedProminent).controlSize(.small)
        }.frame(maxWidth: .infinity).padding(.vertical, 32)
    }

    private func projectRow(_ project: ProjectConnection) -> some View {
        let snapshot = store.snapshot(for: project.id)
        let details = snapshot?.details ?? []
        let breakdowns = snapshot?.breakdowns ?? []
        let hasDetails = !details.isEmpty || !breakdowns.isEmpty
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: project.symbol).font(.system(size: 16)).foregroundStyle(.secondary)
                    .frame(width: 32, height: 34).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        projectName(project)
                        Spacer()
                        if !project.enabled { Image(systemName: "pause.circle").font(.system(size: 11)).foregroundStyle(.secondary).help("Paused") }
                        else if let error = store.errors[project.id] { Image(systemName: "exclamationmark.circle").font(.system(size: 11)).foregroundStyle(.orange).help(error).accessibilityLabel("Connection needs attention") }
                        else if let snapshot, !store.isDemo, Date().timeIntervalSince(snapshot.measuredAt) > Double(project.intervalSeconds * 3) { Image(systemName: "clock").font(.system(size: 11)).foregroundStyle(.orange).help("Data is older than expected") }
                        if hasDetails {
                            Button {
                                withAnimation(reduceMotion ? nil : DrawerMotion.reveal) { expanded = expanded == project.id ? nil : project.id }
                            } label: {
                                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                                    .rotationEffect(.degrees(expanded == project.id ? 90 : 0)).frame(width: 18, height: 18).contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityLabel("\(expanded == project.id ? "Collapse" : "Expand") \(project.name) statistics")
                        }
                    }
                    if let snapshot {
                        HStack(alignment: .firstTextBaseline, spacing: 15) {
                            ForEach(snapshot.metrics.prefix(3)) { metric in metricCell(metric, large: true).frame(maxWidth: .infinity, alignment: .leading) }
                        }
                    } else {
                        Text(project.enabled ? "—" : "Paused").font(.system(size: 20, weight: .medium)).foregroundStyle(.secondary)
                    }
                }
            }.padding(.horizontal, 20).padding(.vertical, 16)

            if hasDetails {
                DrawerReveal(isExpanded: expanded == project.id) {
                    drawer(details: details, breakdowns: breakdowns)
                }.padding(.leading, 65).padding(.trailing, 20)
            }
        }
    }

    @ViewBuilder private func projectName(_ project: ProjectConnection) -> some View {
        if let url = SourceLink.url(for: project) {
            Link(destination: url) {
                Text(project.name).underline(hovered == project.id).foregroundStyle(hovered == project.id ? Color.accentColor : Color.primary)
            }.buttonStyle(.plain).font(.system(size: 13, weight: .semibold)).help(url.absoluteString)
                .onHover { hovered = $0 ? project.id : nil }
                .accessibilityHint("Open the source in your default browser")
                .contextMenu { Button("Settings…") { AppWindows.showConnections(store: store, selecting: project.id) } }
        } else {
            Text(project.name).font(.system(size: 13, weight: .semibold))
                .contextMenu { Button("Settings…") { AppWindows.showConnections(store: store, selecting: project.id) } }
        }
    }

    private func metricCell(_ metric: MetricValue, large: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(metric.value).font(.system(size: large ? 22 : 17, weight: .medium, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.65)
                .contentTransition(.numericText()).animation(reduceMotion ? nil : DrawerMotion.numbers, value: metric.value)
            Text(metric.label).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).help(metric.label)
        }.accessibilityElement(children: .combine)
    }

    private func drawer(details: [MetricValue], breakdowns: [MetricBreakdown]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if !details.isEmpty {
                let metrics = Array(details.prefix(6))
                VStack(spacing: 12) {
                    ForEach(Array(stride(from: 0, to: metrics.count, by: 2)), id: \.self) { index in
                        HStack(alignment: .top, spacing: 16) {
                            metricCell(metrics[index], large: false).frame(maxWidth: .infinity, alignment: .leading)
                            if index + 1 < metrics.count {
                                metricCell(metrics[index + 1], large: false).frame(maxWidth: .infinity, alignment: .leading)
                            } else { Color.clear.frame(maxWidth: .infinity, maxHeight: 0) }
                        }
                    }
                }
            }
            ForEach(breakdowns.prefix(2)) { breakdown in
                VStack(alignment: .leading, spacing: 7) {
                    Text(breakdown.title + (breakdown.truncated ? " · \(breakdown.rows.count) shown" : "")).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).lineLimit(1).help(breakdown.title)
                    ForEach(breakdown.rows) { row in
                        HStack {
                            Text(row.label).lineLimit(1).help(row.label)
                            Spacer(minLength: 12)
                            Text(row.value).monospacedDigit().foregroundStyle(.secondary).lineLimit(1).help(row.value)
                                .contentTransition(.numericText()).animation(reduceMotion ? nil : DrawerMotion.numbers, value: row.value)
                        }.font(.system(size: 11)).accessibilityElement(children: .combine)
                    }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func footer(now: Date) -> String {
        if store.isDemo { return "Example data" }
        if store.connections.isEmpty { return "Local to this Mac" }
        if store.isRefreshing { return "Updating…" }
        if !store.errors.isEmpty { return "Connection needs attention" }
        let active = store.connections.filter(\.enabled)
        if active.isEmpty { return "Paused" }
        guard let oldest = active.compactMap({ store.snapshots[$0.id]?.measuredAt }).min() else { return "—" }
        return now.timeIntervalSince(oldest) < 60 ? "Updated just now" : "Updated \(oldest.formatted(.relative(presentation: .numeric)))"
    }

    private var statusColor: Color {
        if store.isDemo || store.connections.isEmpty || store.connections.allSatisfy({ !$0.enabled }) { return .secondary }
        if !store.errors.isEmpty || store.connections.filter(\.enabled).contains(where: { project in
            guard let snapshot = store.snapshots[project.id] else { return true }
            return Date().timeIntervalSince(snapshot.measuredAt) > Double(project.intervalSeconds * 3)
        }) { return .orange }
        return .green
    }
}

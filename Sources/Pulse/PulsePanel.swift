import AppKit
import PulseCore
import SwiftUI

struct PulsePanel: View {
    @ObservedObject var store: AppStore
    @State private var expanded: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.path.ecg").font(.system(size: 17, weight: .medium)).foregroundStyle(.tint)
                Text("Pulse").font(.system(size: 16, weight: .semibold))
                Spacer()
                if store.isDemo { Text("DEMO").font(.system(size: 9, weight: .semibold, design: .rounded)).tracking(0.6).padding(.horizontal, 7).padding(.vertical, 4).background(.quaternary, in: Capsule()).foregroundStyle(.secondary).accessibilityLabel("Example data") }
                Button { Task { await store.refreshAll() } } label: {
                    if store.isRefreshing { ProgressView().controlSize(.mini).frame(width: 14, height: 14) }
                    else { Image(systemName: "arrow.clockwise").frame(width: 14, height: 14) }
                }
                .buttonStyle(.borderless).disabled(store.isDemo || store.isRefreshing || store.connections.isEmpty)
                .help("Refresh all connections").accessibilityLabel("Refresh all connections")
            }
            .padding(.horizontal, 20).padding(.top, 19).padding(.bottom, 17)
            Divider().padding(.horizontal, 20)

            if store.displayedConnections.isEmpty {
                emptyState
            } else {
                if store.displayedConnections.count > 3 {
                    ScrollView { projectList }.scrollBounceBehavior(.basedOnSize).frame(height: 460)
                } else {
                    projectList
                }
            }

            if let storageError = store.storageError {
                Label(storageError, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange).padding(.horizontal, 20).padding(.bottom, 12)
            }

            Divider()
            HStack(spacing: 8) {
                Circle().fill(statusColor).frame(width: 5, height: 5).accessibilityHidden(true)
                Text(footer).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 2)
                if store.isDemo {
                    Button("Connect…") { AppWindows.showConnections(store: store) }.font(.system(size: 11, weight: .medium)).buttonStyle(.borderless)
                }
                Menu {
                    Button("Connections…") { AppWindows.showConnections(store: store) }.keyboardShortcut(",")
                    if store.connections.isEmpty { Button(store.showExamples ? "Hide example projects" : "Show example projects") { store.showExamples.toggle() } }
                    Divider()
                    Button("Quit Pulse") { NSApp.terminate(nil) }.keyboardShortcut("q")
                } label: { Image(systemName: "gearshape").font(.system(size: 12)) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Pulse settings").accessibilityLabel("Pulse settings")
            }.padding(.horizontal, 20).padding(.vertical, 13)
        }
        .frame(width: 364)
        .fixedSize(horizontal: false, vertical: true)
        .background(.regularMaterial)
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
        VStack(spacing: 10) {
            Image(systemName: "square.stack.3d.up").font(.system(size: 28, weight: .light)).foregroundStyle(.secondary)
            Text("Your projects, at a glance.").font(.headline)
            Text("Connect a source to see its numbers here.").font(.caption).foregroundStyle(.secondary)
            Button("Add a connection") { AppWindows.showConnections(store: store) }.buttonStyle(.borderedProminent).controlSize(.small).padding(.top, 4)
        }.frame(maxWidth: .infinity).padding(.vertical, 32).padding(.horizontal, 20)
    }

    private func projectRow(_ project: ProjectConnection) -> some View {
        let snapshot = store.snapshot(for: project.id)
        let error = store.errors[project.id]
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) { expanded = expanded == project.id ? nil : project.id }
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: project.symbol).font(.system(size: 16, weight: .regular)).foregroundStyle(.secondary)
                        .frame(width: 32, height: 34).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 9))
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text(project.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary)
                            Spacer()
                            if !project.enabled { Text("Paused").font(.system(size: 10)).foregroundStyle(.secondary) }
                            else if error != nil { Image(systemName: "exclamationmark.circle").font(.system(size: 11)).foregroundStyle(.orange).accessibilityLabel("Connection needs attention") }
                            else if let snapshot, !store.isDemo, Date().timeIntervalSince(snapshot.measuredAt) > Double(project.intervalSeconds * 3) { Image(systemName: "clock").font(.system(size: 11)).foregroundStyle(.orange).accessibilityLabel("Data is older than expected") }
                            Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary).rotationEffect(.degrees(expanded == project.id ? 90 : 0))
                        }
                        if let snapshot {
                            HStack(alignment: .firstTextBaseline, spacing: 15) {
                                ForEach(snapshot.metrics.prefix(3)) { metric in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(metric.value).font(.system(size: 22, weight: .medium, design: .rounded)).monospacedDigit().foregroundStyle(.primary).lineLimit(1).minimumScaleFactor(0.65)
                                        Text(metric.label).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        } else {
                            Text(error != nil ? "Couldn’t update" : project.enabled ? "Waiting for the first update" : "Connection paused").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }.padding(.horizontal, 20).padding(.vertical, 16).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(([project.name] + (snapshot?.metrics.map { "\($0.value) \($0.label)" } ?? ["Waiting for data"])).joined(separator: ", ")).accessibilityHint("Show connection details")

            if expanded == project.id {
                VStack(alignment: .leading, spacing: 9) {
                    if store.isDemo { Text("Example numbers. Connect your own source to see real activity.").foregroundStyle(.secondary) }
                    else {
                        if let error { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.orange).textSelection(.enabled).lineLimit(3) }
                        if let snapshot {
                            HStack { Text("Measured").foregroundStyle(.secondary); Spacer(); Text(snapshot.measuredAt, style: .relative).foregroundStyle(.secondary) }
                            if let coverage = snapshot.coverage { Text(coverage).foregroundStyle(.secondary).lineLimit(3) }
                        }
                        ForEach(store.recentEvents[project.id] ?? []) { event in
                            HStack(alignment: .top) { Image(systemName: "circle.fill").font(.system(size: 4)).padding(.top, 5); Text(event.title).lineLimit(2); Spacer(); Text(event.occurredAt, style: .relative).foregroundStyle(.secondary) }
                        }
                        HStack {
                            Button("Edit connection…") { AppWindows.showConnections(store: store) }
                            Spacer()
                            if let url = URL(string: project.link), ["https", "http"].contains(url.scheme?.lowercased() ?? "") { Link("Open project ↗", destination: url) }
                        }.buttonStyle(.link)
                    }
                }.font(.system(size: 11)).padding(.leading, 65).padding(.trailing, 20).padding(.bottom, 16)
            }
        }
    }

    private var footer: String {
        if store.isDemo { return "Example data · stored locally" }
        if store.connections.isEmpty { return "Local to this Mac" }
        if store.isRefreshing { return "Updating…" }
        if !store.errors.isEmpty { return "Some connections need attention" }
        let active = store.connections.filter(\.enabled)
        if active.isEmpty { return "All connections paused" }
        guard let oldest = active.compactMap({ store.snapshots[$0.id]?.measuredAt }).min() else { return "Waiting for an update" }
        return "Measured \(oldest.formatted(.relative(presentation: .numeric)))"
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

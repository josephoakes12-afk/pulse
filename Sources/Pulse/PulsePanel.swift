import AppKit
import PulseCore
import PulseWidgetData
import SwiftUI

struct PulsePanel: View {
    @ObservedObject var store: AppStore
    @State private var expanded: UUID?
    @State private var hovered: UUID?
    @State private var viewError: String?
    @State private var errorTitle = "Couldn’t save changes"
    @State private var infoProject: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        IntegralPanelLayout { panelContent }.background(.regularMaterial)
            .onChange(of: store.selectedRange) { _, _ in
                expanded = nil
                infoProject = nil
            }
            .onChange(of: store.metricVisibilities) { _, _ in
                if let expanded, let snapshot = store.snapshot(for: expanded),
                   (snapshot.details ?? []).isEmpty, (snapshot.breakdowns ?? []).isEmpty {
                    self.expanded = nil
                }
            }
            .onChange(of: store.widgetFocusProjectID) { _, id in
                guard let id else { return }
                if let snapshot = store.snapshot(for: id),
                   !(snapshot.details ?? []).isEmpty || !(snapshot.breakdowns ?? []).isEmpty {
                    expanded = id
                }
                DispatchQueue.main.async { store.widgetFocusProjectID = nil }
            }
            .alert(errorTitle, isPresented: Binding(get: { viewError != nil }, set: { if !$0 { viewError = nil } })) {
                Button("OK") { viewError = nil }
            } message: { Text(viewError ?? "") }
    }

    private var panelContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.path.ecg").font(.system(size: 17, weight: .medium)).foregroundStyle(.tint)
                Text("Pulse").font(.system(size: 16, weight: .semibold))
                Spacer()
                if store.isDemo { Text("DEMO").font(.system(size: 9, weight: .semibold, design: .rounded)).tracking(0.6).padding(.horizontal, 7).padding(.vertical, 4).background(.quaternary, in: Capsule()).foregroundStyle(.secondary).accessibilityLabel("Example data") }
                Menu {
                    ForEach(MetricTimeRange.allCases, id: \.self) { range in
                        Button {
                            store.selectRange(range)
                        } label: {
                            if range == store.selectedRange { Label(range.title, systemImage: "checkmark") }
                            else { Text(range.title) }
                        }
                    }
                    if !store.unavailableConnections.isEmpty {
                        Divider()
                        Section("No history for this range") {
                            ForEach(store.unavailableConnections) { project in
                                Button(project.name) { AppWindows.showConnections(store: store, selecting: project.id) }
                            }
                        }
                    }
                } label: { Text(store.selectedRange.shortTitle).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary) }
                .menuStyle(.borderlessButton).fixedSize().help("Time range").accessibilityLabel("Time range: \(store.selectedRange.title)")
                Button { AppWindows.showAddProject(store: store) } label: { Image(systemName: "plus").frame(width: 14, height: 14) }
                    .buttonStyle(.borderless).help("Add Project").accessibilityLabel("Add Project").keyboardShortcut("n")
                if store.isRefreshing { ProgressView().controlSize(.mini).frame(width: 14, height: 14).accessibilityLabel("Updating") }
            }.padding(.horizontal, 20).padding(.top, 19).padding(.bottom, 17)
            Divider().padding(.horizontal, 20)

            if store.isCloudReceiver { cloudProjectList }
            else if store.displayedConnections.isEmpty { emptyState }
            else if store.displayedConnections.count > 3 {
                ScrollViewReader { proxy in
                    ScrollView { projectList }.scrollBounceBehavior(.basedOnSize).frame(height: 460)
                        .onChange(of: store.widgetFocusProjectID) { _, id in
                            if let id { proxy.scrollTo(id, anchor: .top) }
                        }
                }
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
                    Button("Connections…") { AppWindows.showConnections(store: store) }
                    Button("Settings…") { AppWindows.showGeneralSettings(store: store) }.keyboardShortcut(",")
                    Button("iCloud…") { AppWindows.showCloudSync(store: store) }
                    if store.connections.isEmpty { Button(store.showExamples ? "Hide example projects" : "Show example projects") { store.showExamples.toggle() } }
                    Divider()
                    Button("Quit Pulse") { NSApp.terminate(nil) }.keyboardShortcut("q")
                } label: { Image(systemName: "gearshape").font(.system(size: 12)) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Pulse settings").accessibilityLabel("Pulse settings")
            }.padding(.horizontal, 20).padding(.vertical, 13)
        }.frame(width: 364).fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var cloudProjectList: some View {
        if store.cloudProjects.count > 3 {
            ScrollView { cloudProjectRows }.scrollBounceBehavior(.basedOnSize).frame(height: 460)
        } else { cloudProjectRows }
    }

    private var cloudProjectRows: some View {
        VStack(spacing: 0) {
            if store.cloudProjects.isEmpty {
                Text("No summary for this range").font(.system(size: 12)).foregroundStyle(.secondary).padding(24)
            } else {
                ForEach(Array(store.cloudProjects.enumerated()), id: \.element.id) { index, project in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: project.symbol).font(.system(size: 17)).foregroundStyle(.secondary)
                            .frame(width: 32, height: 32).background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text(project.name).font(.system(size: 13, weight: .semibold))
                                Spacer()
                                Image(systemName: "icloud").font(.system(size: 10)).foregroundStyle(.secondary).help("Summary from your iCloud account")
                            }
                            if let range = project.range(rawValue: store.selectedRange.rawValue) {
                                HStack(alignment: .firstTextBaseline, spacing: 15) {
                                    ForEach(range.metrics) { metric in
                                        metricCell(MetricValue(id: metric.id, label: metric.label, value: metric.value), large: true)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                            }
                        }
                    }.padding(.horizontal, 20).padding(.vertical, 16)
                    if index < store.cloudProjects.count - 1 { Divider().padding(.leading, 65).padding(.trailing, 20) }
                }
            }
        }.padding(.vertical, 4)
    }

    private var projectList: some View {
        VStack(spacing: 0) {
            ForEach(Array(store.displayedConnections.enumerated()), id: \.element.id) { index, connection in
                projectRow(connection).id(connection.id)
                if index < store.displayedConnections.count - 1 { Divider().padding(.leading, 65).padding(.trailing, 20) }
            }
        }.padding(.vertical, 4)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            if !store.unavailableConnections.isEmpty {
                Text("No data for this range").font(.system(size: 12)).foregroundStyle(.secondary)
                if let range = MetricTimeRange.allCases.first(where: { candidate in
                    store.unavailableConnections.contains { store.rawSnapshot(for: $0.id)?.supports(candidate) == true }
                }) {
                    Button("Show \(range == .lifetime ? "lifetime" : range.shortTitle)") { store.selectRange(range) }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            } else {
                Image(systemName: "square.stack.3d.up").font(.system(size: 28, weight: .light)).foregroundStyle(.secondary)
                Button("Add Project") { AppWindows.showAddProject(store: store) }.buttonStyle(.borderedProminent).controlSize(.small)
            }
        }.frame(maxWidth: .infinity).padding(.vertical, 32)
    }

    private func projectRow(_ project: ProjectConnection) -> some View {
        let snapshot = store.snapshot(for: project.id)
        let rawSnapshot = store.rawSnapshot(for: project.id)
        let drawerSnapshot = snapshot ?? rawSnapshot
        let details = drawerSnapshot?.details ?? []
        let breakdowns = drawerSnapshot?.breakdowns ?? []
        let hasDrawer = !details.isEmpty || !breakdowns.isEmpty
        let hasDetails = snapshot != nil && hasDrawer
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                ConnectionIconButton(symbol: project.symbol, imageData: project.iconImageData) { symbol, imageData in
                    Task {
                        do { try await store.updateIcon(projectID: project.id, symbol: symbol, imageData: imageData) }
                        catch { errorTitle = "Couldn’t change icon"; viewError = error.localizedDescription }
                    }
                }.accessibilityLabel("Change \(project.name) icon")
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        projectName(project)
                        Spacer()
                        if !project.enabled { Image(systemName: "pause.circle").font(.system(size: 11)).foregroundStyle(.secondary).help("Paused") }
                        else if let error = store.errors[project.id] { Image(systemName: "exclamationmark.circle").font(.system(size: 11)).foregroundStyle(.orange).help(error).accessibilityLabel("Connection needs attention") }
                        else if let snapshot, !store.isDemo, Date().timeIntervalSince(snapshot.measuredAt) > Double(project.intervalSeconds * 3) { Image(systemName: "clock").font(.system(size: 11)).foregroundStyle(.orange).help("Data is older than expected") }
                        if let source = store.sourceSnapshot(for: project.id) ?? rawSnapshot {
                            metricMenu(project, source: source)
                        }
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
                            .help(rawSnapshot == nil ? "Waiting for data" : "\(store.selectedRange.title) is not available for this connection. \(rawSnapshot?.coverage ?? "")")
                    }
                }
            }.padding(.horizontal, 20).padding(.vertical, 16)

            if hasDrawer {
                DrawerReveal(isExpanded: expanded == project.id && hasDetails) {
                    drawer(details: details, breakdowns: breakdowns)
                }.padding(.leading, 65).padding(.trailing, 20)
            }
        }
    }

    private func metricMenu(_ project: ProjectConnection, source: ProjectSnapshot) -> some View {
        let candidates = source.metricCatalog
        let headlines = store.snapshot(for: project.id)?.metrics ?? []
        return Menu {
            Section("Headline") {
                ForEach(candidates) { metric in
                    if headlines.count == 3, !headlines.contains(where: { $0.id == metric.id }) {
                        Menu(metric.label) {
                            ForEach(headlines) { current in
                                Button("Replace \(current.label)") {
                                    Task {
                                        do { try await store.replaceHeadline(metric.id, replacing: current.id, projectID: project.id) }
                                        catch { errorTitle = "Couldn’t save KPIs"; viewError = error.localizedDescription }
                                    }
                                }
                            }
                        }
                    } else { metricToggle(metric, projectID: project.id, placement: .headline) }
                }
            }
            Menu("More") {
                ForEach(candidates) { metric in
                    metricToggle(metric, projectID: project.id, placement: .drawer)
                }
            }
            if let groups = source.breakdowns, !groups.isEmpty {
                Menu("Breakdowns") {
                    ForEach(groups) { group in
                        Toggle(group.title, isOn: Binding(
                            get: { store.breakdownIsVisible(group.id, projectID: project.id) },
                            set: { visible in
                                Task {
                                    do { try await store.setBreakdownVisible(visible, breakdownID: group.id, projectID: project.id) }
                                    catch { errorTitle = "Couldn’t save KPIs"; viewError = error.localizedDescription }
                                }
                            }
                        )).disabled(!store.breakdownIsVisible(group.id, projectID: project.id) && (store.snapshot(for: project.id)?.breakdowns?.count ?? 0) >= 2)
                    }
                }
            }
            if store.metricVisibilities[project.id].map({ $0 != MetricVisibility() }) ?? false {
                Divider()
                Button("Reset KPIs") {
                    Task {
                        do { try await store.resetKPIs(projectID: project.id) }
                        catch { errorTitle = "Couldn’t save KPIs"; viewError = error.localizedDescription }
                    }
                }
            }
            if source.coverage != nil {
                Divider()
                Button("About this data") {
                    DispatchQueue.main.async { infoProject = project.id }
                }
            }
        } label: {
            Image(systemName: "info.circle").font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(width: 18, height: 18).contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("Choose KPIs").accessibilityLabel("\(project.name) KPIs")
        .popover(isPresented: Binding(get: { infoProject == project.id }, set: { if !$0, infoProject == project.id { infoProject = nil } }), arrowEdge: .trailing) {
            Text(source.coverage ?? "").font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled).frame(width: 250, alignment: .leading).padding(14)
        }
    }

    private func metricToggle(_ metric: MetricValue, projectID: UUID, placement: MetricPlacement) -> some View {
        Toggle(metric.label, isOn: Binding(
            get: { store.metricIsVisible(metric.id, projectID: projectID, placement: placement) },
            set: { visible in
                Task {
                    do { try await store.setMetricVisible(visible, metricID: metric.id, projectID: projectID, placement: placement) }
                    catch { errorTitle = "Couldn’t save KPIs"; viewError = error.localizedDescription }
                }
            }
        ))
        .disabled(!store.canSetMetric(metric.id, visible: !store.metricIsVisible(metric.id, projectID: projectID, placement: placement), projectID: projectID, placement: placement))
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
            Text(metric.label).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8).help(metric.label)
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
        if store.isCloudReceiver {
            guard let oldest = store.cloudProjects.compactMap({ $0.range(rawValue: store.selectedRange.rawValue)?.measuredAt }).min() else { return "From iCloud" }
            return now.timeIntervalSince(oldest) < 60 ? "iCloud · Updated just now" : "iCloud · Updated \(oldest.formatted(.relative(presentation: .numeric)))"
        }
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
        if store.isCloudReceiver {
            return store.cloudProjects.contains { project in
                project.hasError || project.range(rawValue: store.selectedRange.rawValue).map { Date().timeIntervalSince($0.measuredAt) > 900 } ?? true
            } ? .orange : .green
        }
        if store.isDemo || store.connections.isEmpty || store.connections.allSatisfy({ !$0.enabled }) { return .secondary }
        if !store.errors.isEmpty || store.connections.filter(\.enabled).contains(where: { project in
            guard let snapshot = store.snapshots[project.id] else { return true }
            return Date().timeIntervalSince(snapshot.measuredAt) > Double(project.intervalSeconds * 3)
        }) { return .orange }
        return .green
    }
}

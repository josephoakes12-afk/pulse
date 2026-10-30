import AppKit
import PulseCore
import SwiftUI

struct ConnectionsView: View {
    @ObservedObject var store: AppStore
    var initialSelection: UUID? = nil
    @State private var selectedID: UUID?
    @State private var editor: EditorItem?
    @State private var removeCandidate: ProjectConnection?
    @State private var error: String?

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedID) {
                Section("Connections") {
                    ForEach(store.connections) { project in
                        Label(project.name, systemImage: project.symbol).tag(project.id).padding(.vertical, 3)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button { AppWindows.showAddProject(store: store) } label: { Image(systemName: "plus") }.help("Add Project").accessibilityLabel("Add Project")
                    Button { removeCandidate = store.connections.first { $0.id == selectedID } } label: { Image(systemName: "minus") }.disabled(selectedID == nil).help("Remove connection").accessibilityLabel("Remove connection")
                    Spacer()
                }.buttonStyle(.borderless).padding(12).background(.bar)
            }
        } detail: {
            if let project = store.connections.first(where: { $0.id == selectedID }) {
                Form {
                    Section {
                        LabeledContent("Connection", value: project.kind.title)
                        LabeledContent("Refresh", value: "Every \(project.intervalSeconds / 60) minutes")
                        LabeledContent("Status", value: !project.enabled ? "Paused" : store.errors[project.id] != nil ? "Needs attention" : store.snapshots[project.id] != nil ? "Connected" : "Waiting for data")
                        if let snapshot = store.snapshots[project.id] {
                            ForEach(snapshot.metrics) { metric in LabeledContent(metric.label, value: metric.value) }
                            LabeledContent("Last update") { Text(snapshot.fetchedAt, style: .relative).foregroundStyle(.secondary) }
                        }
                        if let message = store.errors[project.id] { Text(message).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                    } header: {
                        Label(project.name, systemImage: project.symbol).font(.title3.weight(.semibold))
                    }
                    Section {
                        HStack {
                            Button("Credentials…") { editor = EditorItem(connection: project, credentialsOnly: true) }
                            Button("Advanced…") { editor = EditorItem(connection: project) }
                            Button("Refresh") { Task { await store.refreshAll() } }.disabled(store.isRefreshing || !project.enabled)
                        }
                    }
                    localDataSection
                }.formStyle(.grouped)
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 40, weight: .light)).foregroundStyle(.secondary)
                    Text("Bring your projects together.").font(.title3.weight(.semibold))
                    Text("Connect an API or database. Pick a few numbers.").font(.callout).foregroundStyle(.secondary)
                    Button("Add Project") { AppWindows.showAddProject(store: store) }.buttonStyle(.borderedProminent).controlSize(.regular)
                    Text("Credentials stay in Keychain. Data stays on this Mac.").font(.caption).foregroundStyle(.tertiary).padding(.top, 14)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
            }
        }
        .frame(minWidth: 600, minHeight: 440)
        .sheet(item: $editor) { item in
            if item.credentialsOnly, let connection = item.connection { CredentialEditor(store: store, connection: connection) }
            else { ConnectionEditor(store: store, existing: item.connection) }
        }
        .confirmationDialog("Remove \(removeCandidate?.name ?? "connection")?", isPresented: Binding(get: { removeCandidate != nil }, set: { if !$0 { removeCandidate = nil } })) {
            Button("Remove connection", role: .destructive) {
                guard let project = removeCandidate else { return }
                Task { do { try await store.remove(project); selectedID = nil } catch { self.error = error.localizedDescription }; removeCandidate = nil }
            }
            Button("Cancel", role: .cancel) { removeCandidate = nil }
        } message: { Text("This removes its settings, saved counts and credential from this Mac.") }
        .alert("Couldn’t update connection", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
        .onChange(of: store.connections) { _, connections in
            if selectedID == nil { selectedID = connections.first?.id }
        }
        .onAppear { if selectedID == nil { selectedID = initialSelection ?? store.connections.first?.id } }
        .onReceive(NotificationCenter.default.publisher(for: .pulseSelectProject)) { if let id = $0.object as? UUID { selectedID = id } }
    }

    private var localDataSection: some View {
        Section {
            Text("Saved on this Mac. Refreshing pauses during sleep and resumes on wake.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private struct EditorItem: Identifiable {
        var id = UUID()
        var connection: ProjectConnection?
        var credentialsOnly = false
    }
}

struct CredentialEditor: View {
    @ObservedObject var store: AppStore
    let connection: ProjectConnection
    @Environment(\.dismiss) private var dismiss
    @State private var secret = ""
    @State private var bearer = false
    @State private var loaded = false
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "key").foregroundStyle(.tint)
                Text("\(connection.name) Credentials").font(.headline)
                Spacer()
            }.padding(20)
            Form {
                SecureField(connection.kind == .postgres ? "Password" : bearer ? "Token" : "Header value", text: $secret)
                Text("Saved securely in Keychain. Leave blank to remove the credential.").font(.caption).foregroundStyle(.secondary)
            }.formStyle(.grouped).disabled(saving || !loaded)
            if let error { Text(error).foregroundStyle(.red).font(.callout).padding(.horizontal, 20).padding(.bottom, 12) }
            Divider()
            HStack {
                if saving { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                Button("Save") {
                    saving = true
                    Task {
                        do {
                            let value = bearer && !secret.isEmpty && !secret.lowercased().hasPrefix("bearer ") ? "Bearer \(secret)" : secret
                            try await store.save(connection, secret: value)
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                        saving = false
                    }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!loaded || saving)
            }.padding(16)
        }.frame(width: 440, height: 230)
        .onAppear {
            do {
                let value = try store.secret(for: connection.id)
                bearer = connection.kind == .http && connection.authHeader.lowercased() == "authorization" && (value.isEmpty || value.lowercased().hasPrefix("bearer "))
                secret = bearer && value.lowercased().hasPrefix("bearer ") ? String(value.dropFirst(7)) : value
                loaded = true
            } catch { self.error = "The saved credential couldn’t be read. Unlock Keychain and reopen this window." }
        }
    }
}

extension Notification.Name { static let pulseSelectProject = Notification.Name("local.pulse.select-project") }

struct ConnectionEditor: View {
    @ObservedObject var store: AppStore
    let existing: ProjectConnection?
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ProjectConnection(name: "", metrics: [MetricDefinition(label: "Users", path: "metrics.users"), MetricDefinition(label: "Bookings · 7d", path: "metrics.bookings")])
    @State private var secret = ""
    @State private var error: String?
    @State private var testResult: ProjectSnapshot?
    @State private var working = false
    @State private var saving = false
    @State private var credentialLoaded = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(existing == nil ? "New Connection" : "Edit Connection").font(.headline)
                Spacer()
                Image(systemName: "lock.shield").foregroundStyle(.secondary).help("Credentials are saved in your Mac’s Keychain")
            }.padding(20)
            Divider()
            Form {
                Section {
                    TextField("Name", text: $draft.name, prompt: Text("My project"))
                    Picker("Source", selection: $draft.kind) { ForEach(ConnectorKind.allCases, id: \.self) { Text($0.title).tag($0) } }
                    Picker("Icon", selection: $draft.symbol) {
                        Label("Project", systemImage: "square.stack.3d.up").tag("square.stack.3d.up")
                        Label("Bookings", systemImage: "calendar").tag("calendar")
                        Label("Game", systemImage: "gamecontroller").tag("gamecontroller")
                        Label("Publication", systemImage: "newspaper").tag("newspaper")
                        Label("Website", systemImage: "globe").tag("globe")
                        Label("Shop", systemImage: "bag").tag("bag")
                    }
                }
                Section {
                    if draft.kind == .http {
                        TextField("URL", text: $draft.endpoint, prompt: Text("https://example.com/api/summary"))
                        TextField("Auth header", text: $draft.authHeader, prompt: Text("Authorization"))
                        SecureField("Header value", text: $secret, prompt: Text("Optional · e.g. Bearer token"))
                    } else {
                        TextField("Database URL", text: $draft.endpoint, prompt: Text("postgresql://reader@host/database"))
                        SecureField("Password", text: $secret)
                        LabeledContent("Query") {
                            TextEditor(text: $draft.query).font(.system(.caption, design: .monospaced)).frame(minHeight: 74).padding(4).background(.background, in: RoundedRectangle(cornerRadius: 5)).overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
                        }
                        Text("Use a read-only database account and one SELECT returning a single summary row. Passwords belong in the field above.").font(.caption).foregroundStyle(.secondary)
                    }
                } header: { Text("Connection") } footer: {
                    if draft.kind == .http { Text("Read-only GET. Use HTTPS, or HTTP for a local source. The header value is stored in Keychain.") }
                }
                Section {
                    ForEach($draft.metrics) { $metric in
                        HStack(spacing: 8) {
                            TextField("Label", text: $metric.label).labelsHidden().accessibilityLabel("Metric label").frame(maxWidth: .infinity)
                            TextField(draft.kind == .http ? "JSON path" : "Column", text: $metric.path).labelsHidden().font(.system(.body, design: .monospaced)).frame(maxWidth: .infinity)
                            Button { draft.metrics.removeAll { $0.id == metric.id } } label: { Image(systemName: "minus.circle").foregroundStyle(.secondary) }.buttonStyle(.borderless).disabled(draft.metrics.count <= 1).accessibilityLabel("Remove \(metric.label) metric")
                        }
                    }
                    if draft.metrics.count < 3 { Button("Add a number") { draft.metrics.append(MetricDefinition(label: "", path: "")) }.buttonStyle(.link) }
                } header: { Text("Numbers to show") } footer: {
                    Text(draft.kind == .http ? "Choose up to three values. For example, metrics.users reads users inside the metrics object." : "Choose up to three columns from the returned row.")
                }
                Section {
                    Picker("Refresh", selection: $draft.intervalSeconds) {
                        Text("Every minute").tag(60)
                        Text("Every 5 minutes").tag(300)
                        Text("Every 15 minutes").tag(900)
                        Text("Every 30 minutes").tag(1800)
                        Text("Every hour").tag(3600)
                    }
                    TextField("Project link", text: $draft.link, prompt: Text("Optional · opens your project"))
                    Toggle("Show desktop alerts for new events", isOn: $draft.notificationsEnabled)
                    Toggle("Keep this connection active", isOn: $draft.enabled)
                } footer: { Text("The first update sets a baseline. Alerts start with new events after that.") }
                if let result = testResult {
                    Section {
                        Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        ForEach(result.metrics) { LabeledContent($0.label, value: $0.value) }
                        if let coverage = result.coverage { Text(coverage).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                if let error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            }.formStyle(.grouped).scrollBounceBehavior(.basedOnSize).disabled(working || saving)
            Divider()
            HStack {
                Button(working ? "Testing…" : "Test connection") { Task { await test() } }.disabled(working || saving || !credentialLoaded || draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if working || saving { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                Button("Save") { Task { await save() } }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(working || saving || !credentialLoaded)
            }.padding(16)
        }
        .frame(width: 550, height: 650)
        .onAppear {
            if let existing {
                draft = existing
                do { secret = try store.secret(for: existing.id) } catch { credentialLoaded = false; self.error = "The saved credential couldn’t be read. Unlock Keychain and reopen this connection." }
            }
        }
        .onChange(of: draft.kind) { _, kind in
            testResult = nil
            if existing == nil && kind == .postgres {
                draft.endpoint = ""
                draft.query = "SELECT count(*) AS users FROM your_table"
                draft.metrics = [MetricDefinition(label: "Users", path: "users")]
            }
        }
        .onChange(of: draft) { _, _ in testResult = nil }
        .onChange(of: secret) { _, _ in testResult = nil }
    }

    private func cleanDraft() -> ProjectConnection {
        var connection = draft
        connection.name = connection.name.trimmingCharacters(in: .whitespacesAndNewlines)
        connection.endpoint = connection.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        connection.link = connection.link.trimmingCharacters(in: .whitespacesAndNewlines)
        connection.metrics = connection.metrics.map { var metric = $0; metric.label = metric.label.trimmingCharacters(in: .whitespacesAndNewlines); metric.path = metric.path.trimmingCharacters(in: .whitespacesAndNewlines); return metric }
        return connection
    }
    private func test() async {
        working = true; error = nil; testResult = nil
        defer { working = false }
        do {
            let connection = cleanDraft()
            try ConnectorValidation.validate(connection)
            testResult = try await store.collect(connection, secret: secret.isEmpty ? nil : secret)
        } catch { self.error = error.localizedDescription }
    }
    private func save() async {
        saving = true; error = nil
        defer { saving = false }
        do { try await store.save(cleanDraft(), secret: secret); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}

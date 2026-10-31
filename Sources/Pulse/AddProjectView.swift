import AppKit
import PulseCore
import SwiftUI
import UniformTypeIdentifiers

struct AddProjectView: View {
    @ObservedObject var store: AppStore
    let finish: () -> Void
    @State private var step: Step = .connection
    @State private var kind: ConnectorKind = .http
    @State private var address = ""
    @State private var secret = ""
    @State private var auth: Authentication = .bearer
    @State private var header = "X-API-Key"
    @State private var projectName = ""
    @State private var iconSymbol = "square.stack.3d.up"
    @State private var iconImageData: Data?
    @State private var iconWasChosen = false
    @State private var candidates: [DiscoveredMetric] = []
    @State private var selection: Set<String> = []
    @State private var tables: [DatabaseTable] = []
    @State private var relationships: [DatabaseRelationship] = []
    @State private var tableSelection: Set<String> = []
    @State private var search = ""
    @State private var connected: ProjectConnection?
    @State private var imported: ProjectConnection?
    @State private var busy = false
    @State private var saving = false
    @State private var error: String?
    @State private var advanced = false
    @State private var task: Task<Void, Never>?
    @FocusState private var focused: Field?

    private enum Step { case connection, tables, numbers }
    private enum Field { case address, secret }
    private enum Authentication: String, CaseIterable { case none = "None", bearer = "Bearer token", header = "API key / custom header" }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ConnectionIconButton(symbol: iconSymbol, imageData: iconImageData, size: 42) { symbol, imageData in
                    iconSymbol = symbol; iconImageData = imageData; iconWasChosen = true
                }.accessibilityLabel("Choose project icon").disabled(busy || saving)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 18, weight: .semibold))
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(22)
            Divider()
            Group {
                switch step {
                case .connection: connectionForm
                case .tables: tablePicker
                case .numbers: numberPicker
                }
            }.disabled(busy || saving)
            if let error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 22).padding(.bottom, 14)
            }
            Divider()
            HStack {
                if step == .connection {
                    Menu("More…") {
                        Button("Import Project Setup…") { importSetup() }
                        Button("Advanced Setup…") { advanced = true }
                    }.fixedSize().disabled(busy || saving)
                } else {
                    Button("Back") { error = nil; step = step == .numbers && kind == .postgres && imported == nil ? .tables : .connection }.disabled(busy || saving)
                }
                if busy || saving { ProgressView().controlSize(.small).padding(.leading, 4) }
                Spacer()
                Button("Cancel") { task?.cancel(); finish() }.keyboardShortcut(.cancelAction).disabled(saving)
                Button(primaryTitle) { startAction() }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(busy || saving || !canContinue)
            }.padding(16)
        }
        .frame(width: 510, height: 470)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { focused = .address }
        .onDisappear { task?.cancel() }
        .onChange(of: address) { _, value in
            invalidate()
            if imported?.endpoint != value.trimmingCharacters(in: .whitespacesAndNewlines) { imported = nil }
            if value.lowercased().hasPrefix("postgres://") || value.lowercased().hasPrefix("postgresql://") { kind = .postgres }
        }
        .onChange(of: kind) { _, value in if imported?.kind != value { imported = nil }; invalidate() }
        .onChange(of: secret) { _, _ in invalidate() }
        .onChange(of: auth) { _, _ in invalidate() }
        .onChange(of: header) { _, _ in invalidate() }
        .onChange(of: store.connections) { previous, current in
            let previousIDs = Set(previous.map(\.id))
            if advanced && current.contains(where: { !previousIDs.contains($0.id) }) {
                finish(); NotificationCenter.default.post(name: .pulseShowPanel, object: nil)
            }
        }
        .sheet(isPresented: $advanced) {
            ConnectionEditor(store: store, existing: nil, initialSymbol: iconSymbol, initialIconImageData: iconImageData)
        }
    }

    private var title: String { step == .connection ? "Add a Project" : step == .tables ? "What would you like to count?" : "Headline numbers" }
    private var subtitle: String { step == .connection ? "Connect a source. Pulse finds the numbers." : step == .tables ? "Choose up to three tables or views." : "Choose up to three." }
    private var primaryTitle: String { saving ? "Adding…" : busy ? "Connecting…" : step == .connection ? "Connect" : step == .tables ? "Preview" : "Add Project" }
    private var canContinue: Bool { step == .connection ? !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : step == .tables ? !tableSelection.isEmpty : !selection.isEmpty && !projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var connectionForm: some View {
        Form {
            Section {
                Picker("Source", selection: $kind) {
                    Text("API / JSON").tag(ConnectorKind.http)
                    Text("PostgreSQL").tag(ConnectorKind.postgres)
                    Text("Supabase").tag(ConnectorKind.supabase)
                }.pickerStyle(.segmented).labelsHidden()
                HStack {
                    if kind == .postgres {
                        SecureField("Connection string", text: $address, prompt: Text("postgresql://user:password@host/database")).focused($focused, equals: .address)
                    } else {
                        TextField("URL", text: $address, prompt: Text(kind == .supabase ? "https://project.supabase.co/rest/v1" : "https://example.com/api/summary")).focused($focused, equals: .address)
                    }
                    Button { pasteAddress() } label: { Image(systemName: "doc.on.clipboard") }
                        .buttonStyle(.borderless).help("Paste a connection URL").accessibilityLabel("Paste connection URL")
                }
                if kind == .http {
                    Picker("Authentication", selection: $auth) { ForEach(Authentication.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    if auth == .header { TextField("Header", text: $header) }
                    if auth != .none { SecureField(auth == .bearer ? "Token (optional)" : "API key", text: $secret).focused($focused, equals: .secret) }
                } else if kind == .postgres {
                    SecureField("Password", text: $secret, prompt: Text("Or include it in the connection string")).focused($focused, equals: .secret)
                } else {
                    SecureField("Access token / API key", text: $secret).focused($focused, equals: .secret)
                }
            } footer: {
                Text(kind == .http ? "Use an API that returns summary numbers. Leave the token blank for a public endpoint." : kind == .postgres ? "Use the connection string from your database provider and a read-only account." : "Import a setup for your project’s counts.")
            }
            if let imported {
                Section { Label("Setup loaded: \(imported.name)", systemImage: "doc.badge.checkmark").font(.callout) }
            }
            Section { Label("Credentials stay in your Mac’s Keychain.", systemImage: "lock").font(.caption).foregroundStyle(.secondary) }
        }.formStyle(.grouped).scrollBounceBehavior(.basedOnSize)
    }

    private var tablePicker: some View {
        VStack(spacing: 12) {
            TextField("Find a table", text: $search).textFieldStyle(.roundedBorder).padding(.horizontal, 20).padding(.top, 18)
            List(tables.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.schema.localizedCaseInsensitiveContains(search) }) { table in
                Toggle(isOn: Binding(get: { tableSelection.contains(table.id) }, set: { enabled in if enabled { tableSelection.insert(table.id) } else { tableSelection.remove(table.id) } })) {
                    HStack {
                        Image(systemName: table.isView ? "tablecells.badge.ellipsis" : "tablecells").foregroundStyle(.secondary).frame(width: 20)
                        Text(table.name)
                        Spacer()
                        Text(table.schema).font(.caption).foregroundStyle(.secondary)
                    }
                }.toggleStyle(.checkbox).disabled(!tableSelection.contains(table.id) && tableSelection.count >= 3).padding(.vertical, 4)
            }.listStyle(.inset)
            Text("Counts every row this account can read. Advanced setup supports custom filters.")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.bottom, 16)
        }
    }

    private var numberPicker: some View {
        VStack(spacing: 0) {
            Form { TextField("Project name", text: $projectName) }.formStyle(.grouped).frame(height: 80)
            List(candidates) { candidate in
                Toggle(isOn: Binding(get: { selection.contains(candidate.id) }, set: { enabled in if enabled { selection.insert(candidate.id) } else { selection.remove(candidate.id) } })) {
                    HStack {
                        Text(candidate.label).lineLimit(1)
                        Spacer()
                        Text(candidate.previewValue).monospacedDigit().foregroundStyle(.secondary)
                    }
                }.toggleStyle(.checkbox).disabled(!selection.contains(candidate.id) && selection.count >= 3).padding(.vertical, 6)
            }.listStyle(.inset)
            HStack {
                Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Spacer()
                Text("\(selection.count) of 3 selected").foregroundStyle(.secondary)
            }.font(.caption).padding(20)
        }
    }

    private func startAction() {
        task = Task { switch step { case .connection: await connect(); case .tables: await previewTables(); case .numbers: await addProject() } }
    }

    private func connect() async {
        busy = true; error = nil
        defer { busy = false }
        do {
            let importedSetup = imported
            let selectedKind = importedSetup?.kind ?? kind
            let parsed = try ProjectSetup.parseAddress(address)
            if selectedKind == .supabase && parsed.kind != .http {
                throw PulseError.invalidConfiguration("Use an HTTPS Supabase URL.")
            }
            let effectiveSecret = parsed.secret ?? secret
            address = parsed.endpoint
            kind = selectedKind == .supabase ? .supabase : parsed.kind
            secret = effectiveSecret
            if projectName.isEmpty { projectName = importedSetup?.name ?? parsed.suggestedName }
            var base = importedSetup ?? ProjectConnection(name: projectName, kind: kind, endpoint: parsed.endpoint)
            base.name = projectName
            base.kind = kind
            base.symbol = iconSymbol; base.iconImageData = iconImageData
            base.endpoint = parsed.endpoint
            base.authHeader = auth == .header ? header.trimmingCharacters(in: .whitespacesAndNewlines) : "Authorization"
            if let importedSetup, !importedSetup.metrics.isEmpty {
                let snapshot = try await store.collect(base, secret: credential)
                try Task.checkCancellation()
                candidates = zip(importedSetup.metrics, snapshot.metrics).map { DiscoveredMetric(path: $0.path, label: $0.label, previewValue: $1.value) }
                selection = Set(candidates.map(\.id))
                connected = base; step = .numbers
            } else if kind == .http {
                let discovered = try await HTTPConnector().discover(connection: base, secret: credential)
                try Task.checkCancellation()
                candidates = discovered
                selection = Set(discovered.prefix(2).map(\.id))
                connected = base; step = .numbers
            } else if kind == .supabase {
                throw PulseError.invalidConfiguration("Import a Supabase setup, or use Advanced Setup.")
            } else {
                let discovered = try await PostgresConnector().discoverTables(connection: base, secret: effectiveSecret.isEmpty ? nil : effectiveSecret)
                try Task.checkCancellation()
                guard !discovered.isEmpty else { throw PulseError.response("No readable tables were found. Check this account’s access.") }
                let foundRelationships = (try? await PostgresConnector().discoverRelationships(connection: base, secret: effectiveSecret.isEmpty ? nil : effectiveSecret, tables: discovered)) ?? []
                try Task.checkCancellation()
                connected = base; tables = discovered; relationships = foundRelationships
                let recommended = PostgresConnector.recommendedTables(from: foundRelationships)
                if !recommended.isEmpty {
                    tableSelection = Set(recommended.map(\.id))
                    var configured = try PostgresConnector.countingConnection(base: base, tables: recommended)
                    let columns = (try? await PostgresConnector().discoverColumns(connection: base, secret: credential, tables: recommended)) ?? []
                    try Task.checkCancellation()
                    configured = PostgresConnector.configureAnalytics(base: configured, tables: recommended, relationships: foundRelationships, columns: columns)
                    let snapshot = try await store.collect(configured, secret: effectiveSecret.isEmpty ? nil : effectiveSecret)
                    try Task.checkCancellation()
                    connected = configured
                    candidates = zip(configured.metrics, snapshot.metrics).map { DiscoveredMetric(path: $0.path, label: $0.label, previewValue: $1.value) }
                    selection = Set(candidates.map(\.id)); step = .numbers
                } else { tableSelection = []; step = .tables }
            }
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription; focused = secret.isEmpty ? .address : .secret }
    }

    private func previewTables() async {
        guard let connected else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let selectedTables = tables.filter { tableSelection.contains($0.id) }
            var configured = try PostgresConnector.countingConnection(base: connected, tables: selectedTables)
            let columns = (try? await PostgresConnector().discoverColumns(connection: connected, secret: secret.isEmpty ? nil : secret, tables: selectedTables)) ?? []
            try Task.checkCancellation()
            configured = PostgresConnector.configureAnalytics(base: configured, tables: selectedTables, relationships: relationships, columns: columns)
            let snapshot = try await store.collect(configured, secret: secret.isEmpty ? nil : secret)
            try Task.checkCancellation()
            self.connected = configured
            candidates = zip(configured.metrics, snapshot.metrics).map { DiscoveredMetric(path: $0.path, label: $0.label, previewValue: $1.value) }
            selection = Set(candidates.map(\.id)); step = .numbers
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }

    private func addProject() async {
        guard var connection = connected else { return }
        saving = true; error = nil
        defer { saving = false }
        connection.name = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        connection.symbol = iconSymbol; connection.iconImageData = iconImageData
        do {
            if kind == .postgres && imported == nil {
                connection = try PostgresConnector.selectedCountingConnection(base: connection, metricPaths: selection)
            } else {
                connection.metrics = candidates.filter { selection.contains($0.id) }.map { MetricDefinition(label: $0.label, path: $0.path) }
            }
            try await store.save(connection, secret: credential ?? "")
            finish()
            NotificationCenter.default.post(name: .pulseShowPanel, object: nil)
        } catch { self.error = error.localizedDescription }
    }

    private var credential: String? {
        guard !secret.isEmpty else { return nil }
        if kind == .postgres || kind == .supabase || auth == .header { return secret }
        if auth == .none { return nil }
        return secret.lowercased().hasPrefix("bearer ") ? secret : "Bearer \(secret)"
    }

    private func invalidate() {
        // Normalising a pasted URL can trigger deferred SwiftUI changes after a
        // fast response. Hidden connection fields must not erase that preview.
        guard step == .connection else { return }
        candidates = []; selection = []; error = nil
    }

    private func pasteAddress() {
        guard let value = NSPasteboard.general.string(forType: .string) else { return }
        do {
            let parsed = try ProjectSetup.parseAddress(value)
            kind = kind == .supabase && parsed.kind == .http ? .supabase : parsed.kind
            address = parsed.endpoint
            if let password = parsed.secret { secret = password }
        } catch { self.error = error.localizedDescription }
    }

    private func importSetup() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a Pulse project setup file. Credentials are added separately."
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 65_536 else { throw PulseError.invalidConfiguration("Choose a setup file smaller than 64 KB.") }
                let preset = try ProjectPreset.decode(Data(contentsOf: url))
                let sameEndpoint = address.trimmingCharacters(in: .whitespacesAndNewlines) == preset.endpoint
                let existingSecret = sameEndpoint ? secret : ""
                let existingName = sameEndpoint && !projectName.isEmpty ? projectName : preset.name
                kind = preset.kind; address = preset.endpoint; secret = existingSecret; projectName = existingName
                if !iconWasChosen { iconSymbol = preset.symbol; iconImageData = preset.iconImageData }
                auth = preset.authHeader.lowercased() == "authorization" ? .bearer : .header
                header = preset.authHeader
                imported = preset
                error = nil
            } catch { self.error = error.localizedDescription }
        }
    }
}

extension Notification.Name { static let pulseShowPanel = Notification.Name("local.pulse.show-panel") }

import StarEmuCore
import SwiftUI

@main
struct StarEmuApp: App {
    @State private var settings: AppSettings
    @State private var model: AppModel

    init() {
        let settings = AppSettings()
        _settings = State(initialValue: settings)
        _model = State(initialValue: AppModel(settings: settings))
    }

    var body: some Scene {
        Window("PRNT Emulator", id: "main") {
            ContentView()
                .environment(model)
                .task { model.start() }
                .frame(minWidth: 860, minHeight: 560)
        }
        .commands { AppCommands(model: model) }

        Settings {
            SettingsView()
                .environment(model)
                .environment(settings)
        }

        MenuBarExtra("PRNT Emulator", systemImage: "printer", isInserted: $settings.showMenuBarIcon) {
            MenuBarContent()
                .environment(model)
        }
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            VStack(spacing: 0) {
                PrinterStatusView()
                Divider()
                JobListView()
            }
            .navigationSplitViewColumnWidth(min: 270, ideal: 300)
        } detail: {
            if let job = model.selectedJob {
                JobDetailView(job: job)
            } else if model.selection.count > 1 {
                ContentUnavailableView(
                    "\(model.selection.count) jobs selected",
                    systemImage: "doc.on.doc",
                    description: Text("Press Delete to remove them.")
                )
            } else {
                ContentUnavailableView(
                    "No job selected",
                    systemImage: "printer",
                    description: Text("Print to this Mac (port \(String(model.settings.printPort))) or drop a .bin file here.")
                )
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.importFiles(urls)
            return true
        }
        .alert("Something went wrong", isPresented: Binding(get: { model.lastError != nil }, set: { if !$0 { model.lastError = nil } })) {
            Button("OK") { model.lastError = nil }
        } message: {
            Text(model.lastError ?? "")
        }
    }
}

struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Import Job…") { model.presentImportPanel() }
                .keyboardShortcut("o")
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save PNG…") { model.selectedJob.map(model.presentSavePanel) }
                .keyboardShortcut("s")
                .disabled(model.selectedJob == nil)
        }
        CommandGroup(after: .pasteboard) {
            Button("Copy Receipt Image") { model.selectedJob.map(model.copyImage) }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(model.selectedJob == nil)
            Divider()
            Button("Delete All Jobs…") { model.confirmClearAll() }
                .keyboardShortcut(.delete, modifiers: [.command, .shift])
                .disabled(model.jobs.isEmpty)
        }
    }
}

struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model
        Text(model.isRunning ? "\(model.profile.displayName) emulator running" : "Emulator stopped")
        if let job = model.jobs.first {
            Text("Last job \(job.receivedAt.formatted(date: .omitted, time: .standard))")
            Button("Copy Last Receipt Image") { model.copyImage(of: job) }
        }
        Divider()
        Toggle("Cover open", isOn: $model.faults.coverOpen)
        Toggle("Paper empty", isOn: $model.faults.paperEmpty)
        Toggle("Paper near end", isOn: $model.faults.paperNearEnd)
        Toggle("Offline", isOn: $model.faults.offline)
        Toggle("Unreachable", isOn: $model.unreachable)
        Divider()
        Button("Open Window") {
            openWindow(id: "main")
            NSApp.activate()
        }
        Button(model.isRunning ? "Stop Emulator" : "Start Emulator") { model.isRunning ? model.stop() : model.start() }
        Divider()
        Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

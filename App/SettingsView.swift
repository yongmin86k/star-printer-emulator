import ServiceManagement
import StarEmuCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        @Bindable var settings = settings
        TabView {
            Form {
                Picker("Model", selection: $settings.modelID) {
                    ForEach(DeviceProfile.all) { Text("\($0.displayName) (\($0.modelName))").tag($0.id) }
                }
                .onChange(of: settings.modelID) { if model.isRunning { model.restart() } }
                .help("Clients see a different printer model, so they may need to search for printers again.")
                TextField("Print port", value: $settings.printPort, format: .number.grouping(.never))
                Toggle("Answer discovery (UDP 22222)", isOn: $settings.discoveryEnabled)
                TextField("MAC address override", text: $settings.macOverride, prompt: Text(model.identity.macString))
                    .help("Leave empty to use this Mac's stable random identity. StarIO10 uses the MAC as the printer identifier.")
                if !settings.macOverride.isEmpty, DeviceIdentity(macString: settings.macOverride) == nil {
                    Text("Not a valid MAC (use 02:53:54:41:52:01 format)").foregroundStyle(.red).font(.caption)
                }
                LabeledContent("SDK identifier", value: model.identity.sdkIdentifier)
                HStack {
                    Spacer()
                    Button("Apply & Restart Emulator") { model.restart() }
                }
            }
            .tabItem { Label("Printer", systemImage: "printer") }

            Form {
                Slider(value: $settings.idleTimeout, in: 0.2...5, step: 0.1) {
                    Text("Idle job timeout: \(settings.idleTimeout, specifier: "%.1f") s")
                }
                .help("Ends a job when a client without StarIO10 framing stops sending (raw TCP clients, nc).")
                Toggle("Select new jobs automatically", isOn: $settings.autoSelectNewJobs)
                Stepper("Keep last \(settings.keepLastJobs) jobs", value: $settings.keepLastJobs, in: 10...5000, step: 10)
            }
            .tabItem { Label("Jobs", systemImage: "tray.full") }

            Form {
                Picker("Multi-page jobs", selection: $settings.exportMode) {
                    Text("One stacked PNG").tag(JobExport.Mode.stacked)
                    Text("One PNG per page").tag(JobExport.Mode.separate)
                }
                Toggle("Auto-save every job as PNG", isOn: $settings.autoSaveEnabled)
                    .disabled(settings.autoSaveFolder == nil)
                HStack {
                    Text(settings.autoSaveFolder?.path(percentEncoded: false) ?? "No folder chosen")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Choose…") { model.chooseAutoSaveFolder() }
                }
            }
            .tabItem { Label("Export", systemImage: "square.and.arrow.down") }

            Form {
                Toggle("Show menu bar icon", isOn: $settings.showMenuBarIcon)
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        try? enabled ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                    }
            }
            .tabItem { Label("General", systemImage: "gearshape") }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 320)
    }
}

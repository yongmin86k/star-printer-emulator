import StarEmuCore
import SwiftUI

struct PrinterStatusView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle().fill(statusColor).frame(width: 10, height: 10)
                Text(model.profile.displayName).font(.headline)
                Spacer()
                Button(model.isRunning ? "Stop" : "Start") {
                    model.isRunning ? model.stop() : model.start()
                }
                .disabled(model.unreachable)
            }

            Text(statusText)
                .font(.callout)
                .foregroundStyle(isFailed ? .red : .secondary)
                .textSelection(.enabled)

            if case .running = model.state {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Identifier \(model.identity.sdkIdentifier)")
                        Text(activity(model.lastDiscovery?.at, label: "Discovery", now: context.date))
                        Text(activity(model.lastStatusPoll, label: "Status poll", now: context.date))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                }
            }

            Divider()
            Text("Simulate").font(.caption).foregroundStyle(.secondary)
            Toggle("Cover open", isOn: $model.faults.coverOpen)
            Toggle("Paper empty", isOn: $model.faults.paperEmpty)
            Toggle("Paper near end", isOn: $model.faults.paperNearEnd)
            Toggle("Offline", isOn: $model.faults.offline)
            Toggle("Unreachable", isOn: $model.unreachable)
                .help("Stops answering discovery and refuses connections, like an unplugged printer.")
        }
        .toggleStyle(.checkbox)
        .padding(12)
    }

    private func activity(_ date: Date?, label: String, now: Date) -> String {
        guard let date else { return "\(label): none yet" }
        let seconds = Int(now.timeIntervalSince(date))
        return "\(label): \(seconds < 2 ? "just now" : "\(Self.elapsed(seconds)) ago")"
    }

    /// 45s · 5m 3s · 1h 7s · 2d 5m 1s · 1m. Zero units are left out.
    static func elapsed(_ total: Int) -> String {
        let parts = [(total / 86400, "d"), (total % 86400 / 3600, "h"), (total % 3600 / 60, "m"), (total % 60, "s")]
        let shown = parts.filter { $0.0 > 0 }.map { "\($0.0)\($0.1)" }
        return shown.isEmpty ? "0s" : shown.joined(separator: " ")
    }

    private var isFailed: Bool {
        if case .failed = model.state { return true }
        return false
    }

    private var statusColor: Color {
        switch model.state {
        case .running: model.faults.hasError ? .orange : .green
        case .starting: .yellow
        case .stopped: .gray
        case .failed: .red
        }
    }

    private var statusText: String {
        switch model.state {
        case .stopped: return model.unreachable ? "Unreachable (simulated)" : "Stopped"
        case .starting: return "Starting…"
        case .failed(let reason): return reason
        case .running(let port, _, let discovery):
            let endpoints = model.addresses.map { "\($0.address):\(port)" }
            let where_ = endpoints.isEmpty ? "port \(port)" : endpoints.joined(separator: ", ")
            return "Listening on \(where_)" + (discovery == nil ? " (discovery off)" : "")
        }
    }
}

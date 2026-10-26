import StarEmuCore
import SwiftUI

struct JobListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            HStack {
                Text("Jobs").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Clear All") { model.confirmClearAll() }
                    .disabled(model.jobs.isEmpty)
                    .help("Delete all jobs (⇧⌘⌫)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            List(selection: $model.selection) {
                ForEach(model.jobs) { job in
                    JobRow(job: job)
                        .padding(.vertical, 4)
                        .tag(job.id)
                        .listRowSeparator(.visible)
                        .listRowInsets(EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10))
                }
            }
            // Inset style draws separators between rows, outside the selection highlight (the sidebar style
            // has neither separators nor content-sized rows). Hide its background to keep the sidebar material.
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .contextMenu(forSelectionType: Job.ID.self) { ids in
                let targets = model.jobs.filter { ids.contains($0.id) }
                if let job = targets.first, targets.count == 1 {
                    Button("Save PNG…") { model.presentSavePanel(for: job) }
                    Button("Copy Receipt Image") { model.copyImage(of: job) }
                    Button("Show Raw File in Finder") { model.revealInFinder(job) }
                    Divider()
                }
                if !targets.isEmpty {
                    Button(targets.count == 1 ? "Delete…" : "Delete \(targets.count) Jobs…", role: .destructive) {
                        model.confirmDelete(targets)
                    }
                }
            }
            .contentMargins(.bottom, 12, for: .scrollContent)
        }
        .onDeleteCommand {
            model.confirmDelete(model.selectedJobs)
        }
    }
}

private struct JobRow: View {
    @Environment(AppModel.self) private var model
    let job: Job

    var body: some View {
        let pages = model.pages(for: job)
        let selected = model.selection.contains(job.id)
        let drawerOnly = pages.isDrawerOnly
        let caption = drawerOnly ? "Cash drawer kick · " : pages.isBlank ? "Nothing printed · " : ""
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Image(systemName: drawerOnly ? "tray" : "printer")
                    .foregroundStyle(selected ? AnyShapeStyle(.primary) : drawerOnly ? AnyShapeStyle(.blue) : AnyShapeStyle(.secondary))
                    .frame(width: 18)
                    .help(drawerOnly ? "Cash drawer kick" : "Print job")
                Text(job.title)
                    .monospacedDigit()
                Spacer()
                Text(Int64(job.byteCount), format: .byteCount(style: .file))
                    .foregroundStyle(.secondary)
            }
            Text(caption + job.remote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

extension Job {
    /// "2026-10-26 12:38:29 PM", local time.
    var title: String { Self.titleFormatter.string(from: receivedAt) }

    private static let titleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd hh:mm:ss a"
        return formatter
    }()
}

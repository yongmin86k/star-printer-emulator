import StarEmuCore
import SwiftUI
import UniformTypeIdentifiers

struct JobDetailView: View {
    enum Tab: String, CaseIterable {
        case preview = "Preview", commands = "Commands", hex = "Hex"
    }

    @Environment(AppModel.self) private var model
    let job: Job
    @State private var tab: Tab = .preview
    @State private var zoom: ReceiptPreviewView.Zoom = .actual

    var body: some View {
        let pages = model.pages(for: job)
        VStack(spacing: 0) {
            HStack {
                Picker("View", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 300)
                Spacer()
                if tab == .preview {
                    Picker("Zoom", selection: $zoom) {
                        ForEach(ReceiptPreviewView.Zoom.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 90)
                }
                Group {
                    Button { model.copyImage(of: job) } label: { Image(systemName: "doc.on.doc") }
                        .help("Copy receipt image (⇧⌘C)")
                    Button { model.presentSavePanel(for: job) } label: { Image(systemName: "square.and.arrow.down") }
                        .help("Save PNG (⌘S)")
                }
                .disabled(!pages.contains { $0.bitmap.height > 0 })
            }
            .padding(8)
            Divider()
            switch tab {
            case .preview: ReceiptPreviewView(pages: pages, zoom: zoom, exportName: JobExport.baseName(for: job))
            case .commands: CommandListView(commands: model.commands(for: job))
            case .hex: HexInspectorView(job: job, data: model.data(for: job))
            }
            Divider()
            JobStatusLine(job: job, pages: pages)
        }
        .navigationTitle(job.title)
    }
}

private struct JobStatusLine: View {
    let job: Job
    let pages: [Page]

    var body: some View {
        let width = pages.first?.bitmap.width ?? 0
        let height = pages.reduce(0) { $0 + $1.bitmap.height }
        let warnings = pages.flatMap(\.warnings)
        HStack(spacing: 12) {
            Text("\(pages.count) page\(pages.count == 1 ? "" : "s")")
            Text("\(width)×\(height) dots (\(String(format: "%.0f", Double(height) / 8)) mm)")
            Text("from \(job.remote)")
            Spacer()
            if !warnings.isEmpty {
                Label("\(warnings.count) warning\(warnings.count == 1 ? "" : "s")", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .help(warnings.joined(separator: "\n"))
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }
}

struct ReceiptPreviewView: View {
    enum Zoom: Hashable, CaseIterable {
        case fit, half, actual, double, triple

        var label: String {
            switch self {
            case .fit: "Fit"
            case .half: "50%"
            case .actual: "100%"
            case .double: "200%"
            case .triple: "300%"
            }
        }

        func scale(paperWidth: Int, available: CGFloat) -> CGFloat {
            switch self {
            case .fit: max(min((available - 48) / CGFloat(max(paperWidth, 1)), 4), 0.25)
            case .half: 0.5
            case .actual: 1
            case .double: 2
            case .triple: 3
            }
        }
    }

    let pages: [Page]
    let zoom: Zoom
    let exportName: String

    var body: some View {
        if pages.isBlank {
            ContentUnavailableView {
                Label("Nothing printed", systemImage: "doc")
            } description: {
                Text("This job has no printable content. StarGraphic printers such as the TSP100IIIW don't receive text, barcodes or alignment: StarIO10 sends them only images and QR codes.")
            }
        } else if pages.isDrawerOnly {
            ContentUnavailableView {
                Label("Cash drawer kick", systemImage: "tray")
            } description: {
                Text("This job opened drawer \(pages.flatMap(\.drawerKicks).map(String.init).joined(separator: ", ")) and printed nothing.")
            }
        } else {
            paper
        }
    }

    private var paper: some View {
        GeometryReader { geometry in
            let scale = zoom.scale(paperWidth: pages.first?.bitmap.width ?? 576, available: geometry.size.width)
            ScrollView([.vertical, .horizontal]) {
                VStack(spacing: 0) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { index, page in
                        PageView(page: page, scale: scale, exportName: pages.count == 1 ? exportName : "\(exportName)-p\(index + 1)")
                    }
                }
                .padding(24)
                .frame(minWidth: geometry.size.width)
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}

private struct PageView: View {
    let page: Page
    let scale: CGFloat
    let exportName: String

    var body: some View {
        VStack(spacing: 6) {
            if let image = page.bitmap.cgImage() {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: CGFloat(page.bitmap.width) * scale, height: CGFloat(page.bitmap.height) * scale)
                    .background(Color.white)   // paper stays white in Dark Mode
                    .overlay(alignment: .topLeading) { EventMarkers(page: page, scale: scale) }
                    .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                    .draggable(PNGFile(name: "\(exportName).png", bitmap: page.bitmap))
            } else {
                Text("No paper printed").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(page.drawerKicks.enumerated()), id: \.offset) { _, channel in
                Label("Drawer \(channel) kicked", systemImage: "tray")
                    .font(.caption)
                    .foregroundStyle(.blue)
            }
            CutMarker(cut: page.cut, width: CGFloat(page.bitmap.width) * scale)
        }
    }
}

/// Small icons in the left margin at the row where a drawer kick or warning happened.
private struct EventMarkers: View {
    let page: Page
    let scale: CGFloat

    var body: some View {
        ForEach(Array(page.events.enumerated()), id: \.offset) { _, event in
            switch event {
            case .drawerKick(let channel, let row):
                marker("tray.fill", .blue, "Drawer \(channel) kicked", row: row)
            case .warning(let message, let row):
                marker("exclamationmark.triangle.fill", .orange, message, row: row)
            }
        }
    }

    private func marker(_ symbol: String, _ color: Color, _ help: String, row: Int) -> some View {
        Image(systemName: symbol)
            .foregroundStyle(color)
            .help(help)
            .offset(x: -20, y: CGFloat(row) * scale - 6)
    }
}

private struct CutMarker: View {
    let cut: CutType?
    let width: CGFloat

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: cut == nil ? "scribble" : "scissors")
            Text(label)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .frame(width: max(width, 160))
        .padding(.vertical, 6)
        .overlay(alignment: .center) {
            Rectangle()
                .stroke(style: StrokeStyle(lineWidth: 1, dash: cut?.isPartial == false ? [] : [4, 3]))
                .frame(height: 0.5)
                .foregroundStyle(.secondary.opacity(0.5))
                .offset(y: -10)
        }
    }

    private var label: String {
        switch cut {
        case .none: "no cut (job ended)"
        case .some(let type): type.isPartial ? "partial cut" : "full cut"
        }
    }
}

/// Drag-out PNG of one page.
struct PNGFile: Transferable {
    let name: String
    let bitmap: PaperBitmap

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .png) { file in
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(file.name)
            try PNGExporter.png(file.bitmap).write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
    }
}

struct CommandListView: View {
    let commands: [Command]

    var body: some View {
        List(Array(commands.enumerated()), id: \.offset) { index, command in
            HStack(alignment: .firstTextBaseline) {
                Text(String(format: "%4d", index)).foregroundStyle(.secondary)
                Text(command.description).foregroundStyle(color(for: command))
            }
            .font(.system(.body, design: .monospaced))
            .textSelection(.enabled)
        }
    }

    private func color(for command: Command) -> Color {
        switch command {
        case .unknown, .malformed: .red
        case _ where command.isSessionControl: .secondary
        default: .primary
        }
    }
}

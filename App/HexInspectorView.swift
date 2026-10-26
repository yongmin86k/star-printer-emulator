import AppKit
import StarEmuCore
import SwiftUI

struct HexInspectorView: View {
    let job: Job
    let data: Data

    private var lines: [String] { HexDump.lines(data) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("\(job.byteCount) bytes from \(job.remote)")
                Spacer()
                Button("Copy Hex") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(HexDump.format(data), forType: .string)
                }
            }
            .padding(10)
            Divider()
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                    }
                }
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
            }
        }
    }
}

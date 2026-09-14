import AppKit
import AppNTFSKit
import SwiftUI
import UniformTypeIdentifiers

struct LogsView: View {
    let coordinator: AppCoordinator
    @State private var entries: [LogEntry] = []

    var body: some View {
        List(entries.reversed()) { entry in
            HStack(alignment: .top) {
                Text(entry.timestamp, style: .time)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(entry.message)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(color(for: entry.level))
                    .textSelection(.enabled)
            }
        }
        .frame(minWidth: 420, minHeight: 300)
        .toolbar {
            ToolbarItem {
                Button("Copiar todo", action: copyTranscript)
                    .disabled(entries.isEmpty)
            }
            ToolbarItem {
                Button("Exportar…", action: exportTranscript)
                    .disabled(entries.isEmpty)
            }
            ToolbarItem {
                Button("Limpiar registros") {
                    coordinator.logger.clear()
                }
            }
        }
        .task {
            // Pushed, not polled: `AppLogger.updates` yields the current buffer
            // on subscribe and again on every write, so a line shows up the
            // moment it is logged instead of up to a second later — and an idle
            // window costs nothing.
            for await snapshot in coordinator.logger.updates {
                entries = snapshot
            }
        }
    }

    /// Errors and warnings are what somebody opens this window to find; before,
    /// every line rendered identically and the level was invisible.
    private func color(for level: LogEntry.Level) -> Color {
        switch level {
        case .info: return .primary
        case .warning: return .orange
        case .error: return .red
        }
    }

    private func copyTranscript() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(coordinator.logger.transcript, forType: .string)
    }

    /// Writing a file the user picks, rather than offering the text and hoping
    /// they paste it somewhere: a log attached to a bug report is the whole
    /// point of keeping the buffer.
    private func exportTranscript() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "AppNTFS-\(Self.fileTimestamp()).log"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try coordinator.logger.transcript.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            coordinator.logger.error("Could not export the log to \(url.path): \(error)")
        }
    }

    private static func fileTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.string(from: Date())
    }
}

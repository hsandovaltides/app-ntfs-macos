import AppNTFSKit
import SwiftUI

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
            }
        }
        .frame(minWidth: 420, minHeight: 300)
        .toolbar {
            ToolbarItem {
                Button("Limpiar registros") {
                    coordinator.logger.clear()
                    entries = []
                }
            }
        }
        .task {
            // Polling rather than wiring AppLogger into Observation: it's a
            // debug-only view, so a 1s refresh is simple and cheap enough.
            while !Task.isCancelled {
                entries = coordinator.logger.entries
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

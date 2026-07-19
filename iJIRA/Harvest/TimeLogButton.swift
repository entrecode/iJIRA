import SwiftUI

/// „⏱ 1:45"-Button in der Issue-Ansicht: zeigt meine bereits geloggte Zeit
/// (Harvest) und öffnet ein Popover zum Loggen in 15-Minuten-Schritten
/// bis 3 h. Nur sichtbar, wenn Harvest konfiguriert ist.
struct TimeLogButton: View {
    @Bindable var model: IssueDetailModel
    @State private var showPopover = false

    var body: some View {
        if let harvest = HarvestState.shared, harvest.isConfigured {
            Button {
                showPopover = true
                Task { await model.refreshLoggedTime() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                    Text(model.loggedHours.map(Self.format) ?? "–")
                        .monospacedDigit()
                        .font(.callout)
                }
            }
            .buttonStyle(.borderless)
            .help("Zeit loggen (Harvest) — bisher von dir geloggt")
            .popover(isPresented: $showPopover, arrowEdge: .bottom) {
                TimeLogPopover(model: model, harvest: harvest) {
                    showPopover = false
                }
            }
        }
    }

    /// 1.75 → "1:45"
    static func format(_ hours: Double) -> String {
        let minutes = Int((hours * 60).rounded())
        return "\(minutes / 60):" + String(format: "%02d", minutes % 60)
    }
}

private struct TimeLogPopover: View {
    @Bindable var model: IssueDetailModel
    let harvest: HarvestState
    let dismiss: () -> Void

    private let durations = stride(from: 0.25, through: 3.0, by: 0.25).map { $0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Zeit loggen").font(.headline)
                Spacer()
                if let logged = model.loggedHours {
                    Text("bisher \(TimeLogButton.format(logged))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if model.isLoggingTime {
                    ProgressView().controlSize(.small)
                }
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4),
                      spacing: 6) {
                ForEach(durations, id: \.self) { hours in
                    Button {
                        Task {
                            if await model.logTime(hours: hours) {
                                dismiss()
                            }
                        }
                    } label: {
                        Text(TimeLogButton.format(hours))
                            .monospacedDigit()
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(model.isLoggingTime)
                }
            }

            Divider()

            Text("Heute auf \(harvest.projectName ?? "?") · \(harvest.taskName ?? "?")")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Notiz: \(model.issueKey): Titel — in Harvest mit Link aufs Issue.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(width: 300)
    }
}

import SwiftUI

struct AccessibilityReportsView: View {
    @Environment(AccessibilityReportService.self) private var accessibilityReportService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if accessibilityReportService.reports.isEmpty {
                    ContentUnavailableView(
                        AppLocalization.localized("No Personal Reports"),
                        systemImage: "person.crop.circle.badge.exclamationmark",
                        description: Text(AppLocalization.localized("Open a station, scroll to Station Essentials, and tap the report button to add accessibility notes. Reports stay on your device."))
                    )
                } else {
                    Section {
                        ForEach(accessibilityReportService.reports) { report in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(report.title)
                                        .font(.headline)
                                    Spacer()
                                    Text(report.severity.title)
                                        .font(.caption)
                                        .foregroundStyle(report.severity >= .high ? .red : .orange)
                                }
                                Text("\(report.itemType.title) • \(report.status.title)")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Text(report.displayNote)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .swipeActions {
                                Button(role: .destructive) {
                                    accessibilityReportService.deleteReport(id: report.id)
                                } label: {
                                    Label(AppLocalization.localized("Delete"), systemImage: "trash")
                                }
                            }
                        }
                    } footer: {
                        Text(AppLocalization.localized("These reports stay on this device and are not official data."))
                    }
                }
            }
            .listStyle(.plain)
            .background(Color.appBackground)
            .navigationTitle(AppLocalization.localized("My Reports"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppLocalization.localized("Done")) { dismiss() }
                }
            }
        }
    }
}

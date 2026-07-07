import SwiftUI

extension RouteDetailView {
    var routeReportSheet: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(AppLocalization.localized("Severity"), selection: $routeReportSeverity) {
                        ForEach(AccessibilityReportSeverity.allCases, id: \.self) { severity in
                            Text(severity.title).tag(severity)
                        }
                    }

                    TextEditor(text: $routeReportNote)
                        .frame(minHeight: 120)
                } header: {
                    Text(AppLocalization.localized("Route Issue"))
                } footer: {
                    Text(AppLocalization.localized("This stays on your device and affects your own route warnings."))
                }
            }
            .navigationTitle(AppLocalization.localized("Report Route Issue"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLocalization.localized("Cancel")) { showRouteReport = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppLocalization.localized("Save")) {
                        accessibilityReportService.createRouteReport(
                            cityID: route.networkCityID ?? appState.selectedCity?.id ?? "",
                            route: route,
                            status: .note,
                            severity: routeReportSeverity,
                            note: routeReportNote
                        )
                        showRouteReport = false
                    }
                    .disabled(routeReportNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    var tripNoteSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $tripNote)
                        .frame(minHeight: 120)
                } header: {
                    Text(AppLocalization.localized("Trip Note"))
                } footer: {
                    Text(AppLocalization.localized("Trip history is stored locally on this device."))
                }
            }
            .navigationTitle(AppLocalization.localized("Complete Trip"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLocalization.localized("Cancel")) { showTripNote = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppLocalization.localized("Save")) {
                        tripMemoryService.markTripComplete(
                            route: route,
                            cityID: route.networkCityID ?? appState.selectedCity?.id ?? "",
                            accessibilityFilter: accessibilityFilter,
                            note: tripNote
                        )
                        tripLoggedConfirmation = true
                        showTripNote = false
                    }
                }
            }
        }
    }
}

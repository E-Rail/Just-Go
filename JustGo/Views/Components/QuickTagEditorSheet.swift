import SwiftUI

/// The shared quick-tag editor: a kind picker (Home / Work / Custom… / Delete) plus the
/// custom-label alert. Callers own the actual save/delete so the same surface works for
/// stations and arbitrary map places.
private struct QuickTagEditor: ViewModifier {
    @Binding var isPresented: Bool
    let title: String
    let currentQuickTag: StationQuickTag?
    let onSave: (StationQuickTagKind) -> Void
    let onDelete: () -> Void

    @State private var showCustomAlert = false
    @State private var customText = ""

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                title,
                isPresented: $isPresented,
                titleVisibility: .visible
            ) {
                Button(StationQuickTagKind.home.title) { onSave(.home) }
                Button(StationQuickTagKind.work.title) { onSave(.work) }
                Button(AppLocalization.text(english: "Custom…", simplified: "自定义…", traditional: "自訂…")) {
                    customText = currentQuickTag?.kind.customLabel ?? ""
                    showCustomAlert = true
                }
                if currentQuickTag != nil {
                    Button(AppLocalization.localized("Delete Quick Tag"), role: .destructive) {
                        onDelete()
                    }
                }
            } message: {
                Text(AppLocalization.localized("Quick Tags appear as one-tap chips in Route Planner."))
            }
            .alert(
                AppLocalization.text(english: "Custom Tag", simplified: "自定义标签", traditional: "自訂標籤"),
                isPresented: $showCustomAlert
            ) {
                TextField(
                    AppLocalization.text(english: "Tag name", simplified: "标签名称", traditional: "標籤名稱"),
                    text: $customText
                )
                Button(AppLocalization.localized("Save")) {
                    let label = customText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !label.isEmpty else { return }
                    onSave(.custom(label))
                }
                Button(AppLocalization.localized("Cancel"), role: .cancel) {}
            }
    }
}

extension View {
    func quickTagEditor(
        isPresented: Binding<Bool>,
        title: String,
        currentQuickTag: StationQuickTag?,
        onSave: @escaping (StationQuickTagKind) -> Void,
        onDelete: @escaping () -> Void
    ) -> some View {
        modifier(QuickTagEditor(
            isPresented: isPresented,
            title: title,
            currentQuickTag: currentQuickTag,
            onSave: onSave,
            onDelete: onDelete
        ))
    }
}

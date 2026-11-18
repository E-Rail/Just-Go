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
                    Button(AppLocalization.text(english: "Remove Saved Place", simplified: "移除常用地点", traditional: "移除常用地點"), role: .destructive) {
                        onDelete()
                    }
                }
            } message: {
                Text(AppLocalization.text(english: "Saved places sit on the map, ready to plan a trip there in one tap.", simplified: "常用地点会显示在地图上，点一下即可规划前往。", traditional: "常用地點會顯示在地圖上，點一下即可規劃前往。"))
            }
            .alert(
                AppLocalization.text(english: "Name This Place", simplified: "为地点命名", traditional: "為地點命名"),
                isPresented: $showCustomAlert
            ) {
                TextField(
                    AppLocalization.text(english: "Name", simplified: "名称", traditional: "名稱"),
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

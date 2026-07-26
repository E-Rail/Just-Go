import SwiftUI

struct QuickTagsView: View {
    @Environment(TripMemoryService.self) private var tripMemoryService
    @Environment(DIContainer.self) private var container
    @Environment(\.dismiss) private var dismiss
    @State private var editingQuickTag: StationQuickTag?
    @State private var customQuickTag: StationQuickTag?
    @State private var customTagText = ""
    @State private var showAddTag = false

    private var tagActionTitle: String {
        AppLocalization.text(english: "Tag", simplified: "标签", traditional: "標籤")
    }

    var body: some View {
        NavigationStack {
            List {
                Group {
                    Section {
                        if tripMemoryService.stationQuickTags.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: "tag.circle")
                                    .font(.largeTitle)
                                    .foregroundStyle(.secondary)
                                Text(AppLocalization.localized("No Quick Tags yet"))
                                    .font(.headline)
                                    .foregroundStyle(.secondary)
                                Text(AppLocalization.text(
                                    english: "Tap + to add one.",
                                    simplified: "点击 + 添加。",
                                    traditional: "點擊 + 新增。"
                                ))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 32)
                        } else {
                            ForEach(tripMemoryService.stationQuickTags) { quickTag in
                                HStack(spacing: 10) {
                                    if quickTag.resolvedTargetType == .station {
                                        NavigationLink(destination: StationDetailView(station: quickTag.toStation())) {
                                            quickTagRow(quickTag)
                                        }
                                    } else {
                                        // Map-place tags have no station page to open.
                                        quickTagRow(quickTag)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }

                                    Button {
                                        editingQuickTag = quickTag
                                    } label: {
                                        Image(systemName: "tag")
                                            .imageScale(.medium)
                                    }
                                    .buttonStyle(.borderless)
                                    .accessibilityLabel(AppLocalization.localized("Edit Quick Tag"))

                                    Button(role: .destructive) {
                                        tripMemoryService.deleteQuickTag(id: quickTag.id)
                                    } label: {
                                        Image(systemName: "trash")
                                            .imageScale(.medium)
                                    }
                                    .buttonStyle(.borderless)
                                    .accessibilityLabel(AppLocalization.localized("Delete Quick Tag"))
                                }
                                .swipeActions(edge: .leading) {
                                    Button {
                                        editingQuickTag = quickTag
                                    } label: {
                                        Label(tagActionTitle, systemImage: "tag")
                                    }
                                    .tint(.accentColor)
                                }
                                .swipeActions {
                                    Button(role: .destructive) {
                                        tripMemoryService.deleteQuickTag(id: quickTag.id)
                                    } label: {
                                        Label(AppLocalization.localized("Delete"), systemImage: "trash")
                                    }
                                }
                                .contextMenu {
                                    Button {
                                        editingQuickTag = quickTag
                                    } label: {
                                        Label(tagActionTitle, systemImage: "tag")
                                    }
                                }
                            }
                        }
                    } header: {
                        HStack {
                            Text(AppLocalization.text(
                                english: "Saved tags",
                                simplified: "已保存标签",
                                traditional: "已儲存標籤"
                            ))
                            Spacer()
                            Text("\(tripMemoryService.stationQuickTags.count)")
                                .monospacedDigit()
                        }
                    }
                }
                .listRowBackground(Color.clear)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.appBackground)
            .navigationTitle(AppLocalization.localized("Quick Tags"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showAddTag = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel(AppLocalization.text(english: "Add Tag", simplified: "添加标签", traditional: "新增標籤"))
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppLocalization.localized("Done")) { dismiss() }
                }
            }
            .sheet(isPresented: $showAddTag) {
                QuickTagAddView()
            }
            .confirmationDialog(
                editingQuickTag?.displayName ?? tagActionTitle,
                isPresented: Binding(
                    get: { editingQuickTag != nil },
                    set: { if !$0 { editingQuickTag = nil } }
                ),
                titleVisibility: .visible,
                presenting: editingQuickTag
            ) { quickTag in
                Button(StationQuickTagKind.home.title) {
                    tripMemoryService.updateQuickTag(id: quickTag.id, kind: .home)
                }
                Button(StationQuickTagKind.work.title) {
                    tripMemoryService.updateQuickTag(id: quickTag.id, kind: .work)
                }
                Button(AppLocalization.text(english: "Custom…", simplified: "自定义…", traditional: "自訂…")) {
                    customTagText = quickTag.kind.customLabel ?? ""
                    customQuickTag = quickTag
                }
                Button(AppLocalization.localized("Delete Quick Tag"), role: .destructive) {
                    tripMemoryService.deleteQuickTag(id: quickTag.id)
                }
            } message: { _ in
                Text(AppLocalization.text(
                    english: "Quick Tags appear as one-tap chips in the route planner.",
                    simplified: "快捷标签会显示在路线规划的一键填入按钮中。",
                    traditional: "快捷標籤會顯示在路線規劃的一鍵填入按鈕中。"
                ))
            }
            .alert(
                AppLocalization.text(english: "Custom Tag", simplified: "自定义标签", traditional: "自訂標籤"),
                isPresented: Binding(
                    get: { customQuickTag != nil },
                    set: { if !$0 { customQuickTag = nil } }
                ),
                presenting: customQuickTag
            ) { quickTag in
                TextField(
                    AppLocalization.text(english: "Tag name", simplified: "标签名称", traditional: "標籤名稱"),
                    text: $customTagText
                )
                Button(AppLocalization.localized("Save")) {
                    let label = customTagText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !label.isEmpty else { return }
                    tripMemoryService.updateQuickTag(id: quickTag.id, kind: .custom(label))
                }
                Button(AppLocalization.localized("Cancel"), role: .cancel) {}
            }
        }
        .task {
            tripMemoryService.repairQuickTagCityMetadata { cityID in
                container.cityService.getCity(byID: cityID)
            }
        }
    }

    private func quickTagRow(_ quickTag: StationQuickTag) -> some View {
        HStack(spacing: 12) {
            Image(systemName: quickTag.kind.icon)
                .foregroundStyle(Color.accentColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(quickTag.displayName)
                        .font(.headline)
                    Text(quickTag.kind.title)
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                }
                Text(quickTag.displayCityName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let address = quickTag.address, !address.isEmpty {
                    Text(address)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if !quickTag.lineNames.isEmpty {
                    Text(quickTag.displayLineNames.joined(separator: " • "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

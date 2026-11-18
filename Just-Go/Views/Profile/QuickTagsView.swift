import SwiftUI

struct QuickTagsView: View {
    /// False in a detail column, where `dismiss()` has nothing to dismiss and a Done button would
    /// do nothing.
    var showsDoneButton = true
    @Environment(TripMemoryService.self) private var tripMemoryService
    @Environment(DIContainer.self) private var container
    @Environment(\.dismiss) private var dismiss
    @State private var editingQuickTag: StationQuickTag?
    @State private var customQuickTag: StationQuickTag?
    @State private var customTagText = ""
    @State private var showAddTag = false

    private var tagActionTitle: String {
        AppLocalization.text(english: "Edit", simplified: "编辑", traditional: "編輯")
    }

    /// True when pushed onto an existing stack: a `NavigationStack` inside a pushed destination
    /// renders blank, so the Trips tab asks for the content alone.
    var embedded = false

    var body: some View {
        if embedded {
            content
        } else {
            NavigationStack { content }
        }
    }

    private var content: some View {
        List {
            Group {
                Section {
                    if tripMemoryService.stationQuickTags.isEmpty {
                        // Apple's own empty state. A hand-rolled centred row would get a `List`
                        // separator aligned to its centred content, starting a third of the way
                        // across.
                        ContentUnavailableView {
                            Label(AppLocalization.text(english: "No Saved Places Yet", simplified: "暂无常用地点", traditional: "暫無常用地點"), systemImage: "bookmark.circle")
                        } description: {
                            Text(AppLocalization.text(
                                english: "Tap + to add one.",
                                simplified: "点击 + 添加。",
                                traditional: "點擊 + 新增。"
                            ))
                        }
                        .listRowSeparator(.hidden)
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
                                    Image(systemName: "bookmark")
                                        .imageScale(.medium)
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel(AppLocalization.text(english: "Edit Saved Place", simplified: "编辑常用地点", traditional: "編輯常用地點"))

                                Button(role: .destructive) {
                                    tripMemoryService.deleteQuickTag(id: quickTag.id)
                                } label: {
                                    Image(systemName: "trash")
                                        .imageScale(.medium)
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel(AppLocalization.text(english: "Remove Saved Place", simplified: "移除常用地点", traditional: "移除常用地點"))
                            }
                            .swipeActions(edge: .leading) {
                                Button {
                                    editingQuickTag = quickTag
                                } label: {
                                    Label(tagActionTitle, systemImage: "bookmark")
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
                                    Label(tagActionTitle, systemImage: "bookmark")
                                }
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text(AppLocalization.text(
                            english: "Places",
                            simplified: "地点",
                            traditional: "地點"
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
        .navigationTitle(AppLocalization.text(english: "Saved Places", simplified: "常用地点", traditional: "常用地點"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // A title with the symbol: the system shows it when the bar overflows into a menu.
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showAddTag = true
                } label: {
                    Label(AppLocalization.text(english: "Add Place", simplified: "添加地点", traditional: "新增地點"), systemImage: "plus")
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                if showsDoneButton {
                    Button(AppLocalization.localized("Done")) { dismiss() }
                }
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
            Button(AppLocalization.text(english: "Remove Saved Place", simplified: "移除常用地点", traditional: "移除常用地點"), role: .destructive) {
                tripMemoryService.deleteQuickTag(id: quickTag.id)
            }
        } message: { _ in
            Text(AppLocalization.text(
                english: "Saved places sit on the map, ready to plan a trip there in one tap.",
                simplified: "常用地点会显示在地图上，点一下即可规划前往。",
                traditional: "常用地點會顯示在地圖上，點一下即可規劃前往。"
            ))
        }
        .alert(
            AppLocalization.text(english: "Name This Place", simplified: "为地点命名", traditional: "為地點命名"),
            isPresented: Binding(
                get: { customQuickTag != nil },
                set: { if !$0 { customQuickTag = nil } }
            ),
            presenting: customQuickTag
        ) { quickTag in
            TextField(
                AppLocalization.text(english: "Name", simplified: "名称", traditional: "名稱"),
                text: $customTagText
            )
            Button(AppLocalization.localized("Save")) {
                let label = customTagText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !label.isEmpty else { return }
                tripMemoryService.updateQuickTag(id: quickTag.id, kind: .custom(label))
            }
            Button(AppLocalization.localized("Cancel"), role: .cancel) {}
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

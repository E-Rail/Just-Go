import SwiftUI

/// Paged first-run tour: what the app does and where things live, in plain language.
/// Shown automatically on first launch (ContentView) and replayable from Settings →
/// App Tour. `onFinish` runs on both Skip and Get Started.
struct OnboardingTourView: View {
    let onFinish: () -> Void
    @State private var pageIndex = 0

    private struct TourPage {
        let icon: String
        let title: String
        let points: [(icon: String, text: String)]
    }

    private var pages: [TourPage] {
        [
            TourPage(
                icon: "tram.circle.fill",
                title: AppLocalization.text(english: "Welcome to JustGo", simplified: "欢迎使用 JustGo", traditional: "歡迎使用 JustGo"),
                points: [
                    ("building.2", AppLocalization.text(
                        english: "Metro route planning for 46+ Chinese cities — pick your city at the top of the Route tab.",
                        simplified: "支持中国46+城市的地铁路线规划——在“路线”页顶部选择城市。",
                        traditional: "支援中國46+城市的地鐵路線規劃——在「路線」頁頂部選擇城市。"
                    )),
                    ("magnifyingglass", AppLocalization.text(
                        english: "Type where you start and where you're going — stations, places, or addresses all work.",
                        simplified: "输入出发地和目的地——车站、地点或地址都可以。",
                        traditional: "輸入出發地和目的地——車站、地點或地址都可以。"
                    )),
                    ("location.fill", AppLocalization.text(
                        english: "The chips under the fields fill them in one tap: your current location, Home, Work.",
                        simplified: "输入框下方的快捷标签一点即填：当前位置、家、公司。",
                        traditional: "輸入框下方的快捷標籤一點即填：目前位置、家、公司。"
                    ))
                ]
            ),
            TourPage(
                icon: "arrow.triangle.branch",
                title: AppLocalization.text(english: "Compare and go", simplified: "比较路线，出发", traditional: "比較路線，出發"),
                points: [
                    ("list.bullet", AppLocalization.text(
                        english: "Every search shows alternatives — fastest, fewest transfers, least walking — with what each is best for.",
                        simplified: "每次搜索都给出多条备选：最快、换乘最少、步行最少，并标明各自适合谁。",
                        traditional: "每次搜尋都給出多條備選:最快、換乘最少、步行最少，並標明各自適合誰。"
                    )),
                    ("figure.walk.circle.fill", AppLocalization.text(
                        english: "\"Navigate step-by-step\" walks you through the trip one step at a time, with a reminder before your stop.",
                        simplified: "“分步导航”一步一步带您走完全程，到站前还会提醒。",
                        traditional: "「分步導航」一步一步帶您走完全程，到站前還會提醒。"
                    )),
                    ("arrow.triangle.2.circlepath", AppLocalization.text(
                        english: "Tap a transfer step for official station links and verified indoor guidance when available. Missing paths and doors are clearly marked.",
                        simplified: "点按换乘步骤可查看官方车站链接及可用的已核实站内指引。缺少通道或车门数据时会明确说明。",
                        traditional: "點按換乘步驟可查看官方車站連結及可用的已核實站內指引。缺少通道或車門資料時會明確說明。"
                    ))
                ]
            ),
            TourPage(
                icon: "checkmark.seal.fill",
                title: AppLocalization.text(english: "Honest information", simplified: "诚实的信息", traditional: "誠實的資訊"),
                points: [
                    ("checkmark.seal", AppLocalization.text(
                        english: "Green \"official\" labels mean verified city data; orange means estimated. Missing data says so — never guessed.",
                        simplified: "绿色“官方”标签代表已核实的城市数据；橙色代表估算。缺失的数据会如实说明，绝不编造。",
                        traditional: "綠色「官方」標籤代表已核實的城市資料；橙色代表估算。缺失的資料會如實說明，絕不編造。"
                    )),
                    ("accessibility", AppLocalization.text(
                        english: "Elevators, ramps and step-free exits are shown per station where cities publish them.",
                        simplified: "在城市公开数据的车站，会显示电梯、坡道和无障碍出入口。",
                        traditional: "在城市公開資料的車站，會顯示電梯、坡道和無障礙出入口。"
                    )),
                    ("clock", AppLocalization.text(
                        english: "Live arrivals appear only where an official provider exists. Otherwise the app shows a licensed static schedule or an honest unavailable state.",
                        simplified: "仅在官方提供实时数据时显示到站信息；否则显示许可的静态时刻表或明确的不可用状态。",
                        traditional: "僅在官方提供即時資料時顯示到站資訊；否則顯示授權的靜態時刻表或明確的不可用狀態。"
                    ))
                ]
            ),
            TourPage(
                icon: "person.fill",
                title: AppLocalization.text(english: "Make it yours", simplified: "打造您的专属", traditional: "打造您的專屬"),
                points: [
                    ("tag.fill", AppLocalization.text(
                        english: "Save Home, Work, and unlimited custom tags, then fill them with one tap in the planner.",
                        simplified: "保存家、公司以及任意数量的自定义标签，即可在路线规划中一键填入。",
                        traditional: "儲存家、公司以及任意數量的自訂標籤，即可在路線規劃中一鍵填入。"
                    )),
                    ("bookmark.fill", AppLocalization.text(
                        english: "Save trips you repeat — they come back as one-tap cards, morning and evening.",
                        simplified: "保存常用行程——早晚高峰时一键直达。",
                        traditional: "儲存常用行程——早晚高峰時一鍵直達。"
                    )),
                    ("gearshape.fill", AppLocalization.text(
                        english: "Set accessibility needs once in Profile → Accessibility Settings; every route search respects them. Replay this tour anytime from Settings.",
                        simplified: "在“个人 → 无障碍设置”中设置一次出行需求，之后每次搜索都会遵循。本导览可随时在设置中重看。",
                        traditional: "在「個人 → 無障礙設定」中設定一次出行需求，之後每次搜尋都會遵循。本導覽可隨時在設定中重看。"
                    ))
                ]
            )
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button(AppLocalization.text(english: "Skip", simplified: "跳过", traditional: "跳過")) {
                    onFinish()
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding()
            }

            TabView(selection: $pageIndex) {
                ForEach(Array(pages.enumerated()), id: \.offset) { index, page in
                    tourPageView(page)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            Button {
                if pageIndex < pages.count - 1 {
                    withAnimation { pageIndex += 1 }
                } else {
                    onFinish()
                }
            } label: {
                Text(pageIndex < pages.count - 1
                    ? AppLocalization.text(english: "Continue", simplified: "继续", traditional: "繼續")
                    : AppLocalization.text(english: "Get Started", simplified: "开始使用", traditional: "開始使用"))
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .padding([.horizontal, .bottom], 24)
        }
        .background(Color.appBackground)
    }

    private func tourPageView(_ page: TourPage) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: page.icon)
                    .font(.system(size: 44))
                    .foregroundStyle(Color.accentColor)
                Text(page.title)
                    .font(.title2)
                    .fontWeight(.bold)
            }

            ForEach(Array(page.points.enumerated()), id: \.offset) { _, point in
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: point.icon)
                        .font(.title3)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 30)
                    Text(point.text)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 28)
        .padding(.top, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

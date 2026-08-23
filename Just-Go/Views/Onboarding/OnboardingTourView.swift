import SwiftUI

/// Paged first-run tour: what the app does and where things live, in plain language.
/// Shown automatically on first launch (ContentView) and replayable from Settings →
/// App Tour. `onFinish` runs on both Skip and Get Started.
struct OnboardingTourView: View {
    let onFinish: () -> Void
    @State private var pageIndex = 0
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    // Raw theme hex for the Continue/Get Started button's solid fill. See
    // RouteEntryView's identical declaration for why `Color.accentColor`
    // (dark-mode-lightened for foreground use) isn't used as a fill under white text.
    @AppStorage("selectedThemeHex") private var selectedThemeHex = AppTheme.default.rawValue

    private struct TourPage {
        let icon: String
        let title: String
        let points: [(icon: String, text: String)]
        /// The last page offers the colour choice. Once, here, at the moment it means something.
        /// The alternative is a preference the rider only discovers by going looking in Settings.
        var showsThemePicker = false
    }

    private var pages: [TourPage] {
        [
            TourPage(
                icon: "map.fill",
                title: AppLocalization.text(english: "Welcome to Just-Go", simplified: "欢迎使用 Just-Go", traditional: "歡迎使用 Just-Go"),
                points: [
                    ("map", AppLocalization.text(
                        english: "Metro routing for 53 Chinese cities. Pan the map, or search for a place.",
                        simplified: "覆盖中国 53 个城市的地铁规划。可以拖动地图，也可以搜索地点。",
                        traditional: "涵蓋中國 53 個城市的地鐵規劃。可以拖曳地圖，也可以搜尋地點。"
                    )),
                    ("wifi.slash", AppLocalization.text(
                        english: "Routes are planned on your phone. They work underground, and with no signal.",
                        simplified: "路线在手机本地规划，地下无信号也能用。",
                        traditional: "路線在手機本機規劃，地下無訊號也能用。"
                    )),
                    ("magnifyingglass", AppLocalization.text(
                        english: "Tap a start or destination field to search stations, places and addresses.",
                        simplified: "点按起点或终点输入框，可搜索车站、地点和地址。",
                        traditional: "點按起點或終點輸入框，可搜尋車站、地點和地址。"
                    ))
                ]
            ),
            TourPage(
                icon: "arrow.triangle.branch",
                title: AppLocalization.text(english: "Compare and go", simplified: "比较路线，出发", traditional: "比較路線，出發"),
                points: [
                    ("list.bullet", AppLocalization.text(
                        english: "A search returns several routes. Sort them by time, by fare, or by fewest changes.",
                        simplified: "一次搜索会给出多条路线，可按时间、票价或换乘次数排序。",
                        traditional: "一次搜尋會給出多條路線，可按時間、票價或轉乘次數排序。"
                    )),
                    ("figure.walk", AppLocalization.text(
                        english: "A long first or last stretch switches to cycling or driving. The route says which.",
                        simplified: "首末段较长时会改为骑行或驾车，路线上会注明。",
                        traditional: "首末段較長時會改為騎行或駕車，路線上會註明。"
                    )),
                    ("play.circle.fill", AppLocalization.text(
                        english: "Navigate gives one step at a time, and alerts before your stop.",
                        simplified: "“导航”每次只给一步，到站前会提醒。",
                        traditional: "「導航」每次只給一步，到站前會提醒。"
                    ))
                ]
            ),
            TourPage(
                icon: "checkmark.seal.fill",
                title: AppLocalization.text(english: "Where the data comes from", simplified: "数据来自哪里", traditional: "資料來自哪裡"),
                points: [
                    ("checkmark.seal", AppLocalization.text(
                        english: "Green means the operator published it. Orange means estimated. Missing data says so.",
                        simplified: "绿色表示运营方公布的数据，橙色表示估算。没有的数据会如实说明。",
                        traditional: "綠色表示營運方公布的資料，橙色表示估算。沒有的資料會如實說明。"
                    )),
                    ("figure.stairs", AppLocalization.text(
                        english: "Lifts and step-free exits are shown per station where the city publishes them.",
                        simplified: "在城市公开数据的车站，会显示电梯与无障碍出入口。",
                        traditional: "在城市公開資料的車站，會顯示電梯與無障礙出入口。"
                    )),
                    ("clock", AppLocalization.text(
                        english: "Each leg is checked against first and last train times where those are published.",
                        simplified: "有首末班车数据时，每一段行程都会据此核对。",
                        traditional: "有首末班車資料時，每一段行程都會據此核對。"
                    ))
                ]
            ),
            TourPage(
                icon: "paintpalette.fill",
                title: AppLocalization.text(english: "Set it up", simplified: "个性化设置", traditional: "個人化設定"),
                points: [
                    ("tag.fill", AppLocalization.text(
                        english: "Save Home, Work and your own tags, then fill a field by tapping one.",
                        simplified: "保存家、公司和自定义标签，之后点一下就能填入。",
                        traditional: "儲存家、公司和自訂標籤，之後點一下就能填入。"
                    )),
                    ("figure.roll", AppLocalization.text(
                        english: "Set step-free needs once in Profile → Accessibility. Route search follows them.",
                        simplified: "在“个人 → 无障碍”中设置一次无障碍需求，路线搜索会据此规划。",
                        traditional: "在「個人 → 無障礙」中設定一次無障礙需求，路線搜尋會據此規劃。"
                    ))
                ],
                showsThemePicker: true
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
            // Dots off, drawn below instead. As an overlay they float *over* the page's content,
            // so at accessibility text sizes a line of copy scrolled underneath them and the dots
            // sat on top of the words. Content and chrome do not share space here.
            .tabViewStyle(.page(indexDisplayMode: .never))

            HStack(spacing: 7) {
                ForEach(pages.indices, id: \.self) { index in
                    Circle()
                        .fill(index == pageIndex ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 7, height: 7)
                }
            }
            .padding(.top, 4)
            .padding(.bottom, 10)
            .accessibilityHidden(true)

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
                    .background(Color(hex: selectedThemeHex), in: Capsule())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .padding([.horizontal, .bottom], 24)
        }
        .background(Color.appBackground)
    }

    /// Scrolls, because it has to.
    ///
    /// This page had no `ScrollView` and no Dynamic Type handling at all, with bullets over 150
    /// characters, so at accessibility text sizes the first screen a new rider ever sees simply
    /// clipped, and the people most likely to be running those sizes are the ones this app is for.
    /// `LaunchStageView`, in this same folder, has adapted to `dynamicTypeSize` all along.
    ///
    /// Only the content scrolls: the page dots and the Continue button live outside this view, so
    /// the way forward can never be the thing that scrolled off the bottom.
    private func tourPageView(_ page: TourPage) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    Image(systemName: page.icon)
                        .font(.system(size: dynamicTypeSize.isAccessibilitySize ? 34 : 44))
                        .foregroundStyle(Color.accentColor)
                    Text(page.title)
                        .font(.title2)
                        .fontWeight(.bold)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ForEach(Array(page.points.enumerated()), id: \.offset) { _, point in
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: point.icon)
                            .font(.title3)
                            .foregroundStyle(Color.accentColor)
                            // Fixed at accessibility sizes: a symbol column that grows with the
                            // text leaves no room for the text it is labelling.
                            .frame(width: dynamicTypeSize.isAccessibilitySize ? 26 : 30)
                        Text(point.text)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if page.showsThemePicker {
                    ThemePickerRow()
                        .padding(.top, 4)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 8)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

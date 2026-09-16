import SwiftUI
import AppKit
import UniformTypeIdentifiers   // 拖动排序要声明接受的类型(.text)

// MARK: - 单个格子(支持 app / 文件夹)

/// 只为「后台算完 → 交给主线程」这一次性传递而用的盒子。
/// `NSScreen` / `NSImage` 都不是 `Sendable`,但这里不存在并发读写
/// (算完之后只被读一次),用 `@unchecked` 标一下,
/// 比把整个模糊计算搬回主线程要划算得多。
private struct TransferBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

struct AppCell: View {
    /// 图标显示尺寸(点)。改这里就够了 —— IconCache 会按它 × 屏幕倍数取纹理。
    static let iconPointSize: CGFloat = 78

    /// 网格图标的"卡片样式":图标 + 圆角 14 + 投影(r4 / y2 / 35%)。
    /// 这些参数和 v1.11 里 `.cornerRadius(14).shadow(radius:4,y:2,opacity:0.35)`
    /// 完全一致 —— 改的是"在哪烤",不是"长什么样"。
    static let cardStyle = CardStyle.grid

    /// 卡片整体的显示尺寸(比图标本体大一圈,多的那圈是投影的容身之处)。
    static var cardPointSize: CGFloat { cardStyle.cardPointSize }

    /// 卡片每侧多出来的留白(点)。用它做负 padding,把占位高度收回图标本体尺寸。
    static var cardVerticalInset: CGFloat { (cardPointSize - iconPointSize) / 2 }

    let item: LaunchpadItem
    var onTap: () -> Void

    /// 开始拖这个格子时通知外层 —— 外层要用它算"其他格子往哪让位"。
    ///
    /// ★ 为什么从 `.draggable` 换成 `.onDrag`:
    ///   `.draggable` 没有"拖动开始"的回调,外层永远不知道被拖的是谁,
    ///   而"实时让位"必须要知道。`.onDrag` 的闭包正好在拖动开始时执行。
    ///   代价是失去 `.draggable` 的自定义预览(用系统默认快照,反而更接近原生)。
    var onDragStart: (String) -> Void = { _ in }

    /// 这个格子是否是"即将建文件夹"的高亮目标 —— 由外层按停留时长判定后传进来。
    /// 拖到格子上的**手势**已经全部收到外层去了(见 TopLevelView),
    /// 格子本身只负责"被高亮时放大"。
    var isFolderTarget: Bool = false

    @State private var icon: NSImage?
    @State private var isHovered = false
    @State private var isPressed = false

    var body: some View {
        VStack(spacing: 9) {
            iconView
                // ★ 卡片比图标本体大一圈(98 vs 78),多出来的是投影的容身之处。
                //
                //   为什么用**负 padding** 而不是"`.frame(98)` 再 `.frame(78)`":
                //   卡片必须在布局上只占 78pt 的高度,否则行距、落点、格子高度
                //   会跟 v1.11 不一样(整屏会往下挪)。padding 只改布局尺寸、不缩放内容,
                //   正好:卡片照 98pt 画、上下各溢出 10pt(那 10pt 本来就是留白),
                //   于是**图标本体在屏幕上的位置和大小和 v1.11 完全一致**。
                .frame(width: Self.cardPointSize, height: Self.cardPointSize)
                .padding(.vertical, -Self.cardVerticalInset)
            Text(item.name)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 118)
                .foregroundStyle(.white)
                .modifier(PerfShadow(radius: 3, y: 1, opacity: 0.55))
        }
        .frame(width: 124, height: 124)
        // ★ 注意:这里绝对不能挂 DragGesture(minimumDistance: 0) 之类的手势,
        //   它会跟 .onDrag 抢主动权,导致永远拖不起来。
        //   按下缩放的反馈只能靠 hover / drop 状态来做。
        .scaleEffect(isPressed ? 0.9 : (isFolderTarget ? 1.18 : (isHovered ? 1.07 : 1.0)))
        .animation(.spring(response: 0.32, dampingFraction: 0.66),
                   value: isHovered || isFolderTarget)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(isFolderTarget ? 0.22 : 0))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(isFolderTarget ? 0.95 : 0), lineWidth: 2)
        )
        .contentShape(Rectangle())
        // ★ 点击反馈:按下先缩到 0.9,约 0.11s 后弹回并执行动作。
        //   动作刻意延后到动画之后 —— 因为"打开 App"会立刻关窗,
        //   不延后的话反馈根本来不及被看见。
        .onTapGesture {
            withAnimation(.spring(response: 0.14, dampingFraction: 0.6)) {
                isPressed = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.11) {
                withAnimation(.spring(response: 0.26, dampingFraction: 0.62)) {
                    isPressed = false
                }
                onTap()
            }
        }
        .onHover { hovering in
            isHovered = hovering
        }
        .onAppear { loadIcon() }
        .onDrag {
            // 先告诉外层"拖的是我",再交出手势
            onDragStart(item.id)
            return NSItemProvider(object: item.id as NSString)
        }
    }

    /// 三条路径,只影响"图标怎么画",不影响布局:
    ///
    ///   ① 默认(卡片):圆角 + 投影已经烤进缓存位图 → 每帧只是贴图
    ///   ② LP_OLDICON :v1.11 原样 —— 大图 + 每帧高质量重采样 + SwiftUI 阴影(只做对照用)
    ///   ③ LP_NOSHADOW:素图标、不圆角不阴影(用来量"阴影到底占多少")
    @ViewBuilder
    private var iconView: some View {
        switch item {
        case .app:
            if PerfFlags.oldIconLoading {
                // v1.11 原样:大图 + 每帧高质量重采样 + SwiftUI 离屏阴影
                plainOrPlaceholder
                    .modifier(LegacyIconChrome())
            } else if PerfFlags.noShadow {
                plainOrPlaceholder
            } else {
                cardOrPlaceholder
            }
        case .folder(let folder):
            FolderIcon(folder: folder)
        }
    }

    /// 素图标(还没有时先占一块灰底,避免闪)。
    ///
    /// ★ 必须自己钉一个 `iconPointSize` 的框 —— 外层给的框是 **98pt(卡片尺寸)**,
    ///   不再钉的话图标会顺着 98pt 铺开,可见内容变成 80pt,
    ///   而卡片路径只有 64pt。那样"对照组"和"实验组"画的根本不是同一个大小,
    ///   压测数字也就没意义了。
    ///
    ///   (2026-09-15 就是栽在这:对照组虚胖 16pt,量出来"新版比旧版小 5pt",
    ///    于是跑去修一个**不存在**的问题,反倒把图标真的改大了 18%。)
    @ViewBuilder
    private var plainOrPlaceholder: some View {
        Group {
            if let icon {
                // `.interpolation` 是 Image 独有的修饰符,只能挂在这里 ——
                // 不能提到外面挂到 ViewModifier 的 content 上(那样编译不过)。
                // 只有对照路径才需要它(每帧高质量重采样正是要被优化掉的东西)。
                if PerfFlags.oldIconLoading {
                    Image(nsImage: icon).resizable().interpolation(.high)
                } else {
                    Image(nsImage: icon).resizable()
                }
            } else {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.white.opacity(0.14))
            }
        }
        .frame(width: Self.iconPointSize, height: Self.iconPointSize)
    }

    /// 烤好的卡片。
    ///
    /// ★ 故意**不写** `.interpolation(.high)`、`.cornerRadius`、`.shadow`:
    ///   高质量插值 = 每帧白做一次降采样;
    ///   圆角和投影已经烤进位图,在这里再挂一次 = 每帧多一次离屏模糊,
    ///   等于把 IconCache 里省的又还回去。
    @ViewBuilder
    private var cardOrPlaceholder: some View {
        if let icon {
            Image(nsImage: icon).resizable()
        } else {
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.white.opacity(0.14))
                .frame(width: Self.iconPointSize, height: Self.iconPointSize)
        }
    }

    private func loadIcon() {
        guard case .app(let app) = item, icon == nil else { return }

        if PerfFlags.oldIconLoading {
            // 对照路径:同步取图 —— 这正是"滚动时一顿一顿"的根源。
            // 单个 1~6ms,而 LazyVGrid 是滚动时才建格子的,于是每冒出一个新格子
            // 主线程就被占住几毫秒,一屏七八个同时出现就是几十毫秒。
            icon = NSWorkspace.shared.icon(forFile: app.pathString)
            return
        }
        if PerfFlags.noShadow {
            IconCache.shared.icon(for: app.pathString, pointSize: Self.iconPointSize) { img in
                self.icon = img
            }
            return
        }

        // 走缓存:命中就立刻返回(同一帧内),没命中才去后台烤。
        // 正常启动时全部已经预热过,所以这里基本都是"立刻"。
        IconCache.shared.card(for: app.pathString, style: Self.cardStyle) { img in
            self.icon = img
        }
    }
}

// MARK: - 阴影的"可关断"包装(只为压测存在)
//
// `LP_NOSHADOW=1` 时直接返回原视图,**完全不挂 `.shadow`** ——
// 而不是把颜色改成 `.clear`。因为 `.shadow(color: .clear)` 依然会让
// SwiftUI 开离屏层做一次模糊,只是模糊出来是透明的,性能一分没省,
// 测出来的数据也就没有意义了。
struct PerfShadow: ViewModifier {
    let radius: CGFloat
    let y: CGFloat
    let opacity: Double

    func body(content: Content) -> some View {
        if PerfFlags.noShadow {
            content
        } else {
            content.shadow(color: .black.opacity(opacity), radius: radius, y: y)
        }
    }
}

/// v1.11 的图标外观:圆角 + SwiftUI 离屏阴影。
/// (高质量插值挂不到这里 —— 它是 Image 独有的,已放在 `plainOrPlaceholder` 里。)
/// **只给 `LP_OLDICON=1` 的对照路径用**,正常路径不要碰它。
struct LegacyIconChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .cornerRadius(14)
            .shadow(color: Color.black.opacity(0.35), radius: 4, y: 2)
    }
}

// MARK: - 文件夹格子(3x3 缩略图 + 名字)

/// 文件夹图标里那个小缩略网格。
///
/// ★ v1.12:从 **2×2 改成 3×3**。
///   2×2 只放得下 4 个应用,观感上也确实不如 3×3 —— 原生启动台
///   本来就是 3×3(最多 9 个),2×2 是我们自己当初图省事的做法。
///
///   尺寸是算出来的,不是拍脑袋定的 —— 外层格子固定 78×78:
///     78 = 网格宽(3×20 + 2×3 = 66) + 左右内边距(6×2 = 12) ✓ 正好
///   所以小图标 20pt、间距 3、内边距 6,能把 78×78 填满且不溢出。
struct FolderIcon: View {
    let folder: FolderItem

    /// 小图标显示尺寸(点)。也给 IconCache 当尺寸参数用。
    static let miniPointSize: CGFloat = 20
    private static let miniCount = 9
    private static let miniSpacing: CGFloat = 3
    private static let gridPadding: CGFloat = 6

    @State private var icons: [NSImage?] = Array(repeating: nil, count: 9)

    var body: some View {
        let previewApps = Array(folder.apps.prefix(Self.miniCount))
        return ZStack {
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.white.opacity(0.16))
                .modifier(PerfShadow(radius: 4, y: 2, opacity: 0.35))

            VStack(spacing: Self.miniSpacing) {
                ForEach(0..<3, id: \.self) { row in
                    HStack(spacing: Self.miniSpacing) {
                        ForEach(0..<3, id: \.self) { col in
                            let index = row * 3 + col
                            miniIcon(
                                index,
                                app: previewApps.indices.contains(index) ? previewApps[index] : nil
                            )
                        }
                    }
                }
            }
            .padding(Self.gridPadding)
        }
        // ★ 必须自己钉成 78pt。
        //   上面那整套尺寸(小图标 20 + 间距 3 + 内边距 6)都是**按 78×78 算出来的**,
        //   而外层给的框是 98pt(卡片尺寸,多出来的是投影的容身之处)。
        //   不钉的话文件夹卡片会跟着长到 98pt —— 比应用图标(可见 64pt)大出一半,
        //   一屏看过去文件夹像被单独放大了。v1.11 里这个框是 78pt,必须保持一致。
        .frame(width: AppCell.iconPointSize, height: AppCell.iconPointSize)
        .onAppear { loadIcons() }
        // 文件夹内容变了就整个重建(比监听 onChange 稳,也躲开 macOS 14 的废弃警告)
        .id("\(folder.id)-\(folder.apps.count)-\(folder.apps.first?.pathString ?? "")")
    }

    @ViewBuilder
    private func miniIcon(_ index: Int, app: AppItem?) -> some View {
        // ★ 空位画 Color.clear(占位但不显示),不画灰块 ——
        //   原生启动台的文件夹也是"有几个显示几个",空位一片干净,
        //   画灰块会让只有两三个 App 的文件夹看着像坏了。
        if app == nil {
            Color.clear.frame(width: Self.miniPointSize, height: Self.miniPointSize)
        } else {
            ZStack {
                if let img = icons[index] {
                    Image(nsImage: img)
                        .resizable()
                } else {
                    // 图标还没到(通常只有冷启动那一瞬间)先放个底色,避免闪
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white.opacity(0.12))
                }
            }
            .frame(width: Self.miniPointSize, height: Self.miniPointSize)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }

    private func loadIcons() {
        let apps = Array(folder.apps.prefix(Self.miniCount))
        for i in 0..<icons.count { icons[i] = nil }
        for (i, app) in apps.enumerated() {
            // 跟主网格共用同一个缓存,只是尺寸小一号 —— 不重复读盘、不重复解码
            IconCache.shared.icon(for: app.pathString, pointSize: Self.miniPointSize) { img in
                if i < icons.count { icons[i] = img }
            }
        }
    }
}

// MARK: - 单个格子淡入 —— 已删除(v1.12)
//
// 原来每个格子挂 `CellAppearEffect`(onAppear 里把 opacity 从 0 淡到 1,0.22s)。
// 删掉的理由:
//
//   1. **滚动时会反复触发**。LazyVGrid 会销毁/重建滚出屏幕的格子,
//      于是每次滚动都会有新格子从透明淡进来 —— 看起来像"没跟上手",
//      这正是用户说的"卡顿 / 手感差异"的一部分。原生启动台的图标是**直接出现**的。
//   2. **入场动画并没有丢**。整个内容层在 LaunchpadRoot 里已经有一次
//      `scale + opacity` 的入场动画(见 contentLayer),那才是用户真正看到的入场效果;
//      每个格子再各自淡入一遍是重复的,而且是 91 个动画同时跑。
//
// 结论:删掉之后入场观感不变,滚动则明显更跟手。别再把它加回来。

// MARK: - 顶层网格
struct TopLevelView: View {
    @Binding var structure: LaunchpadStructure
    @Binding var search: String

    var onOpenApp: (AppItem) -> Void
    var onOpenFolder: (String) -> Void
    var onDeleteFolder: (String) -> Void

    @State private var confirmDeleteID: String?

    // MARK: 拖动排序的状态

    /// 正在被拖的项 id。`.onDrag` 一开始就写进来,拖动期间非 nil。
    @State private var draggingID: String?
    /// 松手后会插到第几个(基于"已排除被拖项"的数组)。
    @State private var dropIndex: Int?
    /// 当前鼠标停在哪一项上(用于判定"停留建文件夹")。
    @State private var hoverItemID: String?
    /// 停留够久、确定要建文件夹的目标。
    @State private var folderTargetID: String?
    /// 停留计时的任务 —— 一旦换目标就取消重来。
    @State private var folderCheckTask: Task<Void, Never>?
    /// 拖出网格后的延迟清理任务。见 scheduleDragCancel() 的说明。
    @State private var exitCleanupTask: Task<Void, Never>?

    /// ★ 固定 7 列(与原生启动台一致),列宽随屏幕宽度自适应。
    ///   原来是 `.adaptive(minimum: 100, maximum: 112)`,会按可用宽度自动塞列 ——
    ///   在 1440 宽的屏幕上算出 10 列,图标小、间距挤,所以看着凌乱。
    ///   原生启动台是 7 列,单个格子更大、四周留白更足,这才是"看着整齐"的真正原因。
    private let columnCount = 7
    private let columnSpacing: CGFloat = 20
    private let rowSpacing: CGFloat = 22
    /// 格子内容尺寸(见 AppCell 的 .frame(width: 124, height: 124))
    private let cellHeight: CGFloat = 124
    private let maxGridWidth: CGFloat = 1080

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: columnSpacing), count: columnCount)
    }

    private var filtered: [LaunchpadItem] {
        let s = search.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return structure.topLevel }
        return structure.topLevel.filter { $0.name.localizedCaseInsensitiveContains(s) }
    }

    /// 搜索状态下**禁止排序** —— 那时候画面里只是子集,
    /// 算出来的落点下标跟真实数组对不上,一旦执行就会把顺序打乱。
    private var canReorder: Bool {
        search.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// 拖动期间画面里真正要渲染的东西 = 去掉被拖项 + 在落点插一个空位。
    ///
    /// 这就是"让位"的实现:插入一个透明格子,后面的项自然就往后挪,
    /// LazyVGrid 会把它当成一个正常格子来排布,不需要自己算位移。
    private enum GridSlot: Identifiable {
        case item(LaunchpadItem)
        case placeholder

        var id: String {
            switch self {
            case .item(let i): return i.id
            case .placeholder: return "\u{0}placeholder"
            }
        }
    }

    private var displaySlots: [GridSlot] {
        guard canReorder, let dragID = draggingID else {
            return filtered.map { GridSlot.item($0) }
        }
        var slots = filtered
            .filter { $0.id != dragID }          // 被拖的那个跟着鼠标走了,不在网格里
            .map { GridSlot.item($0) }
        let idx = max(0, min(dropIndex ?? slots.count, slots.count))
        slots.insert(.placeholder, at: idx)
        return slots
    }

    /// 排除被拖项之后的可见列表 —— 落点下标就是基于它的。
    private var reorderableItems: [LaunchpadItem] {
        guard let dragID = draggingID else { return filtered }
        return filtered.filter { $0.id != dragID }
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar.probeFrame("顶层topBar")
            searchBar
            grid
        }
        .alert("删除文件夹?", isPresented: Binding(
            get: { confirmDeleteID != nil },
            set: { if !$0 { confirmDeleteID = nil } }
        )) {
            Button("删除", role: .destructive) {
                if let id = confirmDeleteID { onDeleteFolder(id) }
                confirmDeleteID = nil
            }
            Button("取消", role: .cancel) { confirmDeleteID = nil }
        } message: {
            Text("文件夹里的 App 会回到顶层")
        }
    }

    /// 背景模糊半径(0~40,UserDefaults 持久化)。
    /// WallpaperBackground 那边读的是同一个键,这里改完根视图 onChange 重算背景。
    @AppStorage("wallpaper.blurRadius") private var blurRadius: Double = 16
    /// 模糊度调节条是否展开。
    @State private var showBlurPanel = false

    private var topBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Spacer()
                // 右上角:模糊度调节的开关(原来是"n 个"数量,没用处已删)。
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        showBlurPanel.toggle()
                    }
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(showBlurPanel ? 0.95 : 0.55))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(Color.white.opacity(showBlurPanel ? 0.16 : 0)))
                }
                .buttonStyle(.plain)
                .help("调节背景模糊程度")
            }
            .padding(.horizontal, 40)

            if showBlurPanel {
                BlurSliderPanel(radius: $blurRadius)
                    .padding(.horizontal, 40)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        // 吞掉顶栏区域的单击,不让它落到根视图被当成"点空白"(关窗/回主页)。
        // 滑杆的拖动手势优先级本来就更高,这里只兜单击。
        .onTapGesture {}
        .padding(.top, ScreenMetrics.topBarTopPadding)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.white.opacity(0.6))
            TextField("", text: $search,
                      prompt: Text("搜索").foregroundStyle(.white.opacity(0.5)))
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .foregroundStyle(.white)
            if !search.isEmpty {
                Button { search = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: 380)
        .background(.black.opacity(0.32))
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.18), lineWidth: 1))
        .padding(.top, 14)
    }

    private var grid: some View {
        GeometryReader { geo in
            // 网格实际宽度 = min(可用宽, 1080),必须和下面 .frame(maxWidth: 1080) 一致 ——
            // 对不上的话算出来的列距跟真实布局有偏差,落点会整体偏一格。
            let gridWidth = min(geo.size.width, maxGridWidth)
            let cellWidth = (gridWidth - columnSpacing * CGFloat(columnCount - 1)) / CGFloat(columnCount)
            let columnPitch = cellWidth + columnSpacing
            let rowPitch = cellHeight + rowSpacing

            ScrollView {
                if filtered.isEmpty {
                    Text(search.isEmpty ? "没有 App" : "没有匹配的 App")
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.top, 100)
                        .frame(maxWidth: .infinity)
                } else {
                    LazyVGrid(columns: columns, spacing: rowSpacing) {
                        ForEach(displaySlots) { slot in
                            switch slot {
                            case .placeholder:
                                // 空位:什么都不画,但占住格子尺寸 —— 后面的项自然"让"开了
                                Color.clear.frame(width: 124, height: 124)
                            case .item(let item):
                                AppCell(
                                    item: item,
                                    onTap: { handleTap(item) },
                                    onDragStart: { id in beginDrag(id) },
                                    isFolderTarget: folderTargetID == item.id
                                )
                                .transition(.opacity)
                                // 编辑模式删掉之后,删文件夹的入口挪到这里:
                                // 右键(或触控板双指点按)文件夹 → 删除。macOS 的常规做法。
                                .contextMenu {
                                    if case .folder = item {
                                        Button("删除文件夹", role: .destructive) {
                                            confirmDeleteID = item.id
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: maxGridWidth)
                    // ★ onDrop 必须挂在两个 frame **中间**,不能挂最外面 ——
                    //   `.frame(maxWidth: 1080)` 让视图宽度变成 1080(内容聚拢居中),
                    //   `.frame(maxWidth: .infinity)` 又把它包进一个全宽容器里。
                    //   如果挂在最外面,info.location.x 是相对**全宽 1440** 的坐标,
                    //   而列距是按 1080 算的 → 落点会整体偏一大截,插错位置。
                    .onDrop(of: [.text], delegate: GridDropDelegate(
                        visibleItems: reorderableItems,
                        idOf: { $0.id },
                        columnCount: columnCount,
                        columnPitch: columnPitch,
                        rowPitch: rowPitch,
                        draggingID: $draggingID,
                        dropIndex: $dropIndex,
                        hoverItemID: $hoverItemID,
                        folderTargetID: $folderTargetID,
                        onEnterOrUpdate: { exitCleanupTask?.cancel() },
                        onExit: { scheduleDragCancel() },
                        onCommit: { id, index, folderTarget in
                            commitDrop(draggedID: id, index: index, folderTarget: folderTarget)
                        }
                    ))
                    .frame(maxWidth: .infinity)
                    .padding(.top, 24)
                    .padding(.bottom, 100)  // 给 Dock 留位置,最后一行 + 名字不被 Dock 挡住
                    .animation(.spring(response: 0.34, dampingFraction: 0.8),
                               value: displaySlots.map { $0.id })
                }
            }
        }
        // ★ "停留 0.9 秒 → 建文件夹"的计时器。
        //   放在 View 里而不是 DropDelegate 里:delegate 是 struct,
        //   每次 body 求值都会重建,计时状态放进去会被反复重置。
        .onChange(of: hoverItemID) { _, newValue in
            folderCheckTask?.cancel()
            folderTargetID = nil
            guard let id = newValue, canReorder else { return }
            folderCheckTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 900_000_000)
                guard !Task.isCancelled, hoverItemID == id else { return }
                folderTargetID = id
            }
        }
    }

    // MARK: - 拖动排序

    private func beginDrag(_ id: String) {
        guard canReorder else { return }
        exitCleanupTask?.cancel()

        // ★ 初始落点 = 它**自己原来的位置**。
        //   不设的话 dropIndex 是 nil,占位符会被插到末尾 ——
        //   一开拖,被拖的格子从原位消失、后面所有图标往左挤一格,画面会"跳"一下。
        if let idx = filtered.firstIndex(where: { $0.id == id }) {
            dropIndex = idx
        }
        draggingID = id
        hoverItemID = nil
        folderTargetID = nil
    }

    /// 拖出网格后延迟清理。
    ///
    /// 为什么需要它:SwiftUI **没有"拖动被取消"的回调**。
    /// 用户把图标拖到网格外面松手(等于放弃),`dropExited` 会触发,
    /// 但我们分不清"只是从边缘划出去了"和"真的不要了" ——
    /// 立刻清掉的话,划出去再划回来就没法让位了。
    /// 所以延迟 0.5 秒:期间回到网格就取消清理,没回来才当真放弃。
    private func scheduleDragCancel() {
        exitCleanupTask?.cancel()
        exitCleanupTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            draggingID = nil
            dropIndex = nil
            hoverItemID = nil
            folderTargetID = nil
        }
    }

    /// 松手时统一收口:要么建文件夹/加进文件夹,要么排序。
    ///
    /// 复刻原生启动台的交互 —— **拖过去先让位,停一下才成形**:
    ///   拖到某格上 → 立刻让位(能看见会插到哪)
    ///   停够 0.9 秒  → 才"吸"成文件夹(格子放大 + 高亮)
    private func commitDrop(draggedID id: String, index: Int, folderTarget: String?) {
        // ① 停留够久 → 建文件夹
        if let targetID = folderTarget, targetID != id,
           let dragged = structure.findItem(id: id),
           let target = structure.findItem(id: targetID) {

            var s = structure
            switch (dragged, target) {
            case (.app(let d), .app(let t)):
                s.createFolder(with: d, containing: t)
                structure = s
                LaunchpadStorage.save(s)
                return
            case (.app(let d), .folder(let f)):
                s.addAppToFolder(d, folderID: f.id)
                structure = s
                LaunchpadStorage.save(s)
                return
            default:
                // 文件夹拖到 App 上 → 不支持合成,退回排序逻辑
                break
            }
        }

        // ② 否则按落点排序
        var s = structure
        s.moveItem(id: id, to: index)
        structure = s
        LaunchpadStorage.save(s)
    }

    private func handleTap(_ item: LaunchpadItem) {
        switch item {
        case .app(let a): onOpenApp(a)
        case .folder(let f): onOpenFolder(f.id)
        }
    }

    // handleDrop 已删除 —— 建文件夹/加入文件夹的逻辑搬进了上面 commitDrop,
    // 和排序收口在同一处。以前"每个格子自己处理 drop"是没法排序的根因。

}

// MARK: - 网格的放置代理(拖拽排序的核心)

/// 落点计算 + 让位 + 松手提交,全部在这里。
///
/// 为什么用 `DropDelegate` 而不是给每个格子挂 `dropDestination`:
///   `dropDestination` 只能告诉"落在哪个格子上了",拿不到**鼠标坐标**,
///   所以算不出"插到第几格"。`DropDelegate.dropUpdated(info:)` 里带 `info.location`,
///   有坐标才能算出扁平下标,这是排序的前提。
///
/// 泛型于条目类型:顶层网格用 `LaunchpadItem`、文件夹内页用 `AppItem`,
/// 两边只有"怎么取 id"不一样,落点计算完全相同 —— 所以收成一个泛型实现。
///
// MARK: - 背景模糊度调节(macOS 27 风格)

/// 顶栏展开的模糊度调节面板。
/// 视觉参照系统设置里"显示器"亮度条:深色胶囊面板 + 两端图标 + 细滑杆。
/// 左端 = 模糊弱(空心方块),右端 = 模糊强(实心方块),对应壁纸的模糊半径 0~40。
///
/// 数值走 `@AppStorage("wallpaper.blurRadius")` 持久化,
/// LaunchpadRoot 监听同一个键的变化去重算背景(见 refreshWallpaper)。
struct BlurSliderPanel: View {
    @Binding var radius: Double   // 0...40,直接就是模糊半径

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "square.on.square")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
            BlurSliderTrack(value: Binding(
                get: { max(0, min(40, radius)) / 40 },
                set: { radius = ($0 * 40).rounded() }
            ))
            Image(systemName: "square.fill.on.square.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
        }
        .padding(.leading, 16)
        .padding(.trailing, 14)
        .padding(.vertical, 9)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.38))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.10)))
        )
        // 吞掉面板上的单击 —— 不然会落到根视图被当成"点空白"把启动台关掉。
        .onTapGesture {}
    }
}

/// 滑杆本体:细胶囊轨道 + 白色进度 + 白色圆钮,拖到哪算哪。
/// 不用系统 Slider —— macOS 的 Slider 样式跟"系统设置 27"那种胶囊条差太远,
/// 自己画反而简单:一个 ZStack + DragGesture,没有隐藏行为。
struct BlurSliderTrack: View {
    @Binding var value: Double   // 0...1(已归一化)
    @State private var trackWidth: CGFloat = 0

    private let knobSize: CGFloat = 16

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let fill = max(0, min(w, w * value))
            ZStack(alignment: .leading) {
                // 轨道底
                Capsule()
                    .fill(Color.white.opacity(0.28))
                    .frame(height: 5)
                // 已滑过的部分
                Capsule()
                    .fill(Color.white)
                    .frame(width: fill, height: 5)
                // 圆钮
                Circle()
                    .fill(Color.white)
                    .frame(width: knobSize, height: knobSize)
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                    .offset(x: max(0, min(w - knobSize, fill - knobSize / 2)))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        // 点击轨道任意位置也能直接跳到那个值
                        value = max(0, min(1, (g.location.x - knobSize / 2) / (w - knobSize)))
                    }
            )
            .onAppear { trackWidth = w }
        }
        .frame(width: 190, height: 24)
    }
}

/// 注意它是个 struct —— 每次 body 求值都会重建,所以
/// **所有跨帧状态必须走 Binding**,不能在 struct 里存 var,否则会被重置。
private struct GridDropDelegate<Item>: DropDelegate {
    /// 已排除被拖项之后的可见列表(落点下标就是基于它的)
    let visibleItems: [Item]
    let idOf: (Item) -> String
    let columnCount: Int
    let columnPitch: CGFloat
    let rowPitch: CGFloat

    @Binding var draggingID: String?
    @Binding var dropIndex: Int?
    @Binding var hoverItemID: String?
    /// 停留建文件夹的目标(只有顶层网格用;文件夹内不套文件夹,永远传 nil Binding)
    @Binding var folderTargetID: String?

    /// 进入网格 / 有新的落点更新 —— 用来取消"拖出网格"的延迟清理
    let onEnterOrUpdate: () -> Void
    /// 拖出网格 —— 不算立刻放弃,交给 View 层延迟判断(见 scheduleDragCancel)
    let onExit: () -> Void

    /// 松手:(被拖的 id, 插入下标, 建文件夹目标 id —— 没有则为 nil)
    let onCommit: (String, Int, String?) -> Void

    func validateDrop(info: DropInfo) -> Bool { draggingID != nil }

    func dropEntered(info: DropInfo) {
        onEnterOrUpdate()
        update(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        onEnterOrUpdate()
        update(info)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        // 刻意**不**清 dropIndex:清掉的话占位符会被插回末尾,
        // 图标"哗"地挤回原位 —— 从边缘划出去再划回来的常见操作会看到明显乱跳。
        // 真正的放弃由 View 层的 scheduleDragCancel() 统一收尾。
        hoverItemID = nil
        folderTargetID = nil
        onExit()
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let id = draggingID else { return false }
        let index = dropIndex ?? visibleItems.count
        let folderTarget = folderTargetID

        // 先把状态清干净,再提交 —— 否则 commitDrop 里改数组时会带着旧的下标
        draggingID = nil
        dropIndex = nil
        hoverItemID = nil
        folderTargetID = nil

        onCommit(id, index, folderTarget)
        return true
    }

    /// 把鼠标坐标换算成"插到第几个"
    private func update(_ info: DropInfo) {
        guard draggingID != nil else { return }

        let loc = info.location
        let col = min(columnCount - 1, max(0, Int(loc.x / columnPitch)))
        let row = max(0, Int(loc.y / rowPitch))
        let flat = row * columnCount + col
        let clamped = min(flat, visibleItems.count)

        if dropIndex != clamped { dropIndex = clamped }

        let hovered = clamped < visibleItems.count ? idOf(visibleItems[clamped]) : nil
        if hoverItemID != hovered {
            hoverItemID = hovered
            // 换目标就取消高亮 —— 重新计时由 View 层的 onChange 负责
            if folderTargetID != nil { folderTargetID = nil }
        }
    }
}

// MARK: - 文件夹内页
/// 文件夹内页:打开里面的 app、双击文件夹名改名、拖动排序、把 app 拖出去。
///
/// 拖动在这里有两套落点,由**内层优先**的规则自然区分:
///
///   · 拖到**网格里**(某个格子上)→ `GridDropDelegate` 处理 = 文件夹内排序,
///     其他图标实时让位,松手落位 —— 和顶层网格同一套交互;
///   · 拖到**网格外**(顶部提示条 / 空白处)→ `dropDestination` 处理 = 移出文件夹,
///     app 回到顶层网格,插在文件夹后面一格。
///
/// 顶部的"移出文件夹"提示条**只在拖动期间出现**,就是为了解决
/// "拖起来之后不知道松手会发生什么" —— 提示条把"拖出去会去哪"写在字面上。
struct FolderDetailView: View {
    let folder: FolderItem
    var onOpenApp: (AppItem) -> Void
    /// 把 app 移出文件夹、放回顶层(拖到提示条或空白处松手)
    var onMoveAppToTopLevel: (AppItem) -> Void
    /// 文件夹内拖动排序:(app 路径, 目标下标 —— 基于已排除被拖项的数组)
    var onReorderApps: (String, Int) -> Void
    var onRenameFolder: (String, String) -> Void

    @State private var isRenaming = false
    @State private var renameText = ""
    @State private var isNameHovered = false
    @FocusState private var isRenameFocused: Bool

    // MARK: 拖动状态(与顶层网格同一套机制,只是没有"停留建文件夹" —— 文件夹不嵌套)

    @State private var draggingID: String?
    @State private var dropIndex: Int?
    @State private var hoverItemID: String?
    @State private var folderTargetID: String?
    @State private var exitCleanupTask: Task<Void, Never>?
    /// 鼠标正悬在"移出文件夹"提示条上(高亮用)
    @State private var isOverExitZone = false

    /// ★ 固定 7 列(与原生启动台一致),列宽随屏幕宽度自适应。
    ///   原来是 `.adaptive(minimum: 100, maximum: 112)`,会按可用宽度自动塞列 ——
    ///   在 1440 宽的屏幕上算出 10 列,图标小、间距挤,所以看着凌乱。
    ///   原生启动台是 7 列,单个格子更大、四周留白更足,这才是"看着整齐"的真正原因。
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 20), count: 7)
    private let columnCount = 7
    private let columnSpacing: CGFloat = 20
    private let rowSpacing: CGFloat = 22
    private let cellHeight: CGFloat = 124
    private let maxGridWidth: CGFloat = 1080

    /// 文件夹内页的"让位"槽位:被拖项从网格里消失、落点处插一个空位。
    /// 机制和 TopLevelView.GridSlot 完全一样,只是条目是 AppItem(不会是文件夹)。
    private enum FolderSlot: Identifiable {
        case app(AppItem)
        case placeholder

        var id: String {
            switch self {
            case .app(let a): return a.pathString
            case .placeholder: return "\u{0}placeholder"
            }
        }
    }

    private var displaySlots: [FolderSlot] {
        guard let dragID = draggingID else {
            return folder.apps.map { FolderSlot.app($0) }
        }
        var slots = folder.apps
            .filter { $0.pathString != dragID }
            .map { FolderSlot.app($0) }
        let idx = max(0, min(dropIndex ?? slots.count, slots.count))
        slots.insert(.placeholder, at: idx)
        return slots
    }

    private var reorderableApps: [AppItem] {
        guard let dragID = draggingID else { return folder.apps }
        return folder.apps.filter { $0.pathString != dragID }
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar.probeFrame("文件夹topBar")
            dragOutBanner
            grid
        }
    }

    /// "移出文件夹"提示条 —— **只在拖动期间出现**。
    ///
    /// 它同时是 drop 目标:拖到它上面松手 = app 回到顶层网格。
    /// 悬停时变橙色,明确告诉用户"现在松手就是这个结果"。
    @ViewBuilder
    private var dragOutBanner: some View {
        if let dragID = draggingID,
           let app = folder.apps.first(where: { $0.pathString == dragID }) {
            HStack(spacing: 8) {
                Image(systemName: "arrowshape.turn.up.backward")
                    .font(.system(size: 12, weight: .semibold))
                Text("松手:「\(app.name)」移出文件夹,回到主页")
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(
                Capsule().fill(isOverExitZone ? Color.orange.opacity(0.85)
                                              : Color.black.opacity(0.55))
            )
            .overlay(
                Capsule().stroke(Color.white.opacity(isOverExitZone ? 1 : 0.4), lineWidth: 1)
            )
            // 这个提示条自己就是"移出"的落点。网格里的落点由网格自己的
            // DropDelegate 接管(SwiftUI 的 drop 从内层往外层匹配),
            // 所以两条路不会打架:格子上 = 排序,提示条/空白处 = 移出。
            .dropDestination(for: String.self) { ids, _ in
                guard let app = appFrom(providerIDs: ids) else { return false }
                onMoveAppToTopLevel(app)
                return true
            } isTargeted: { isOverExitZone = $0 }
            .padding(.top, 10)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    private var grid: some View {
        GeometryReader { geo in
            let gridWidth = min(geo.size.width, maxGridWidth)
            let cellWidth = (gridWidth - columnSpacing * CGFloat(columnCount - 1)) / CGFloat(columnCount)
            let columnPitch = cellWidth + columnSpacing
            let rowPitch = cellHeight + rowSpacing

            ScrollView {
                if folder.apps.isEmpty {
                    Text("空文件夹")
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.top, 100)
                        .frame(maxWidth: .infinity)
                } else {
                    LazyVGrid(columns: columns, spacing: rowSpacing) {
                        ForEach(displaySlots) { slot in
                            switch slot {
                            case .placeholder:
                                Color.clear.frame(width: 124, height: 124)
                            case .app(let app):
                                AppCell(
                                    item: .app(app),
                                    onTap: { onOpenApp(app) },
                                    onDragStart: { _ in beginDrag(app.pathString) }
                                )
                                .transition(.opacity)
                            }
                        }
                    }
                    .frame(maxWidth: maxGridWidth)
                    // 落点坐标是相对这个视图的,必须挂在 .frame(maxWidth: 1080) 和
                    // .frame(maxWidth: .infinity) 之间 —— 理由见 TopLevelView.grid 的说明。
                    .onDrop(of: [.text], delegate: GridDropDelegate(
                        visibleItems: reorderableApps,
                        idOf: { $0.pathString },
                        columnCount: columnCount,
                        columnPitch: columnPitch,
                        rowPitch: rowPitch,
                        draggingID: $draggingID,
                        dropIndex: $dropIndex,
                        hoverItemID: $hoverItemID,
                        folderTargetID: $folderTargetID,
                        onEnterOrUpdate: { exitCleanupTask?.cancel() },
                        onExit: { scheduleDragCancel() },
                        onCommit: { id, index, _ in
                            // 文件夹内不建子文件夹,落点一律按排序处理
                            onReorderApps(id, index)
                        }
                    ))
                    .frame(maxWidth: .infinity)
                    .padding(.top, 24)
                    .padding(.bottom, 100)  // 给 Dock 留位置,最后一行 + 名字不被 Dock 挡住
                    .animation(.spring(response: 0.34, dampingFraction: 0.8),
                               value: displaySlots.map { $0.id })
                }
            }
            // 网格**外面**的空白处也是"移出文件夹"的落点 —— 跟顶层网格
            // "拖出网格 = 放弃"不同,这里语义是明确的:不想留在文件夹里。
            .dropDestination(for: String.self) { ids, _ in
                guard let app = appFrom(providerIDs: ids) else { return false }
                onMoveAppToTopLevel(app)
                return true
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: draggingID != nil)
    }

    /// 把 drop 回调里拿到的 id 还原成文件夹里的 AppItem
    private func appFrom(providerIDs ids: [String]) -> AppItem? {
        guard let draggedID = ids.first else { return nil }
        // 去掉 LaunchpadItem.id 加的 "app:" 前缀,还原成 pathString
        let path = draggedID.hasPrefix("app:") ? String(draggedID.dropFirst(4)) : draggedID
        return folder.apps.first(where: { $0.pathString == path })
    }

    // MARK: - 拖动排序(机制与 TopLevelView 相同)

    private func beginDrag(_ path: String) {
        exitCleanupTask?.cancel()
        // 初始落点 = 它自己原来的位置,避免一开拖就"跳"一下
        if let idx = folder.apps.firstIndex(where: { $0.pathString == path }) {
            dropIndex = idx
        }
        draggingID = path
        hoverItemID = nil
        folderTargetID = nil
    }

    /// 拖出网格后延迟清理 —— SwiftUI 没有"拖动被取消"的回调,
    /// 只能靠 dropExited + 延时来区分"划出去又划回来"和"真的放弃"。
    private func scheduleDragCancel() {
        exitCleanupTask?.cancel()
        exitCleanupTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            draggingID = nil
            dropIndex = nil
            hoverItemID = nil
            folderTargetID = nil
        }
    }

    /// 文件夹内页的顶栏 —— **只剩一个居中的文件夹名**(双击它改名)。
    ///
    /// ★ 2026-09-15 大精简:原来左边有「返回」、右边有「编辑」两个胶囊按钮。
    ///   实测发现,在文件夹里点这两个东西会"跳到另外一个 app" ——
    ///   其实是**单击掉进了根视图的"点空白关窗"**,窗口一关就露出后面的 app,
    ///   看起来就像"跳走了"。结论:两个按钮都删掉,只保留双击改名。
    ///
    ///   三个东西为什么都能删:
    ///     - 「返回」→ 改成**点空白处回主页**(见 LaunchpadRoot 的 onTapGesture)。
    ///       这本来也更接近原生启动台:点文件夹外面的地方就退出文件夹。
    ///     - 「编辑」→ 文件夹内不需要它。想把某个 app 移出去,
    ///       直接把图标拖到空白区就行(见下面 ScrollView 上的 dropDestination)。
    ///     - 铅笔图标 → 用户以为它是"修改按钮",**其实它只是个提示图示、没有任何动作**,
    ///       点了没反应还容易掉进"关窗"。删掉,不再误导。
    private var topBar: some View {
        HStack {
            Spacer()

            if isRenaming {
                TextField("文件夹", text: $renameText, onCommit: commitRename)
                    .textFieldStyle(.plain)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .focused($isRenameFocused)
                    .frame(width: 220)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.white.opacity(0.18))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.white.opacity(0.55), lineWidth: 1)
                    )
            } else {
                Text(folder.name)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    // hover 时给个淡淡的底,提示"这块是可以操作的"
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.white.opacity(isNameHovered ? 0.16 : 0))
                    )
                    .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
                    .contentShape(Rectangle())
                    // ★ 双击改名 —— 现在这是**唯一**的改名入口
                    .onTapGesture(count: 2) {
                        startRename()
                    }
                    .onHover { hovering in
                        isNameHovered = hovering
                    }
            }

            Spacer()
        }
        .padding(.horizontal, 40)
        // ★ 必须避开菜单栏(窗口铺满整屏,盖住了菜单栏那块区域)
        .padding(.top, ScreenMetrics.topBarTopPadding)
    }

    private func startRename() {
        renameText = folder.name
        isRenaming = true
        // TextField 要先上树才能抢焦点,延一拍再 focus,
        // 否则 isRenameFocused = true 会被吞掉、光标不出现。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            isRenameFocused = true
        }
    }

    private func commitRename() {
        onRenameFolder(folder.id, renameText)
        isRenameFocused = false
        isRenaming = false
    }
}

// MARK: - 调试探针(只在设了环境变量时生效,正常启动完全不影响)

/// 用途:排查「文件夹内页布局坏了」这类必须**进去看**的问题。
///
/// 为什么需要它:本机没给辅助功能权限,合成鼠标事件(`CGEvent.post`)全部无效,
/// 所以没法"点开文件夹再截图"。改成让 app 自己进,就能无人值守地抓到真实渲染结果。
///
/// 用法(启动前设环境变量):
///     LP_PROBE=folder        → 进第一个非空文件夹
///     LP_PROBE=<folder-id>   → 进指定 id 的文件夹
///     LP_PROBE=top           → 停在顶层(当作对照)
///
/// 只读,不写盘、不改 structure.json。同时会让 main.swift 跳过「失活自动关窗」,
/// 免得截图的瞬间窗口自己收起来。
enum LaunchpadProbe {
    static var value: String? {
        guard let v = ProcessInfo.processInfo.environment["LP_PROBE"],
              !v.isEmpty else { return nil }
        return v
    }
    static var isActive: Bool { value != nil }
}

/// 探针专用:把"我这个视图在窗口坐标系里的 frame"写进诊断日志。
/// 只在 LP_PROBE 生效时挂载,正常启动是空 modifier。
struct ProbeFrame: ViewModifier {
    let label: String
    func body(content: Content) -> some View {
        if LaunchpadProbe.isActive {
            content.background(
                GeometryReader { g in
                    Color.clear
                        .onAppear { Diag.log("探针·frame [\(label)] = \(g.frame(in: .global))") }
                        .onChange(of: g.frame(in: .global)) { _, f in
                            Diag.log("探针·frame [\(label)] → \(f)")
                        }
                }
            )
        } else {
            content
        }
    }
}

extension View {
    func probeFrame(_ label: String) -> some View { modifier(ProbeFrame(label: label)) }
}

/// 屏幕度量 —— 目前只有一项,但它是**必需**的,不是可选的美化。
///
/// 背景:我们的窗口是 `.borderless` + `setFrame(screen.frame)`,**铺满整屏、
/// 连菜单栏那一块也盖住**(这样模糊壁纸才能一直铺到屏幕最上沿)。
/// 代价是:窗口自己不知道菜单栏在哪,顶栏如果贴着 y=0 放,
/// 就会被菜单栏盖在下面 —— 看得见一点点,但**点击全被菜单栏吃掉**。
///
/// 菜单栏高度不是常数:普通外接屏约 24pt,带刘海/缩放屏能到 31~37pt。
/// 所以不能写死,按 `frame.maxY - visibleFrame.maxY` 现算。
enum ScreenMetrics {
    /// 当前屏菜单栏高度(点)。拿不到屏幕时退回 24(最常见的值)。
    static var menuBarHeight: CGFloat {
        guard let s = NSScreen.main ?? NSScreen.screens.first else { return 24 }
        return max(0, s.frame.maxY - s.visibleFrame.maxY)
    }

    /// 顶栏上边距 = 菜单栏高度 + 一段留白。
    /// 留白不只是好看 —— 它是"手滑点到菜单栏"的缓冲区。
    static var topBarTopPadding: CGFloat { menuBarHeight + 12 }
}

// MARK: - 启动台根视图(秒开 loading + 后台扫描 + 动画)
struct LaunchpadRoot: View {
    var onEscape: () -> Void

    @State private var structure = LaunchpadStructure()
    @State private var scanComplete = false
    @State private var activeFolderID: String?
    @State private var appeared = false
    @State private var search = ""
    /// 系统「辅助功能 → 显示 → 减少透明度」是否开启。
    /// 已经模糊好的壁纸(见 WallpaperBackground.swift)。静态位图,不参与任何动画。
    @State private var wallpaper: NSImage?
    /// 背景模糊半径(0~40)。TopLevelView 顶栏的滑杆写它,这里监听变化重算背景。
    /// 两边读写的是同一个 UserDefaults 键,所以用 @AppStorage 天然同步。
    @AppStorage("wallpaper.blurRadius") private var wallpaperBlurRadius: Double = 16

    private var activeFolder: FolderItem? {
        guard let id = activeFolderID else { return nil }
        for item in structure.topLevel {
            if case .folder(let f) = item, f.id == id { return f }
        }
        return nil
    }

    /// 顶栏那一条的"高度豁免区"。
    ///
    /// 意义:在这个 y 范围内的单击**一律不当作"点了空白"**。
    /// 为什么需要它 —— 见下面 `onTapGesture` 的注释:顶栏上的单击
    /// (文件夹名、铅笔、两个胶囊按钮)会掉进根视图的 tap 里,
    /// 之前直接关窗,用户看到的就是"跳到另外一个 app"。
    ///
    /// 取值 = 顶栏上边距 + 名字条高度(约 30)+ 一点余量。
    /// 顶部这一条本来也没有"点空白"的语义,豁免掉不会有任何损失。
    private static var topBarExclusionHeight: CGFloat {
        ScreenMetrics.topBarTopPadding + 38
    }

    var body: some View {
        ZStack {
            // ★★ 性能关键:背景层和内容层分开。
            //    以前 scaleEffect/opacity 是挂在整个 ZStack(含毛玻璃层)上的,
            //    入场动画每一帧都要把「实时模糊」重新做一次缩放合成,极耗 GPU。
            //    现在毛玻璃只当静态底,只有内容层参与缩放/淡入。
            backgroundLayer.probeFrame("背景层")

            contentLayer
                .scaleEffect(appeared ? 1.0 : 0.9)
                .opacity(appeared ? 1.0 : 0.0)
                .animation(.spring(response: 0.42, dampingFraction: 0.8), value: appeared)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .probeFrame("根内容区")
        .contentShape(Rectangle())
        // 点空白处的行为 —— ★ 2026-09-15 改过,原来只有"关窗"一种
        //
        // 这两个问题其实是**同一个根因**:
        //   ① 在文件夹里点「编辑」按钮 / 点文件夹名旁边的铅笔 → "跳到另一个 app"
        //   ② 在文件夹里点空白处 → "跳到另一个 app"
        // 都是因为**单击掉进了这里**的 `onEscape()` → 窗口一关,后面的 app 就露出来了,
        // 用户看到的现象就是"跳走了"。
        //
        // 所以现在分三档:
        //   · 顶栏那一条(y 很小)→ **什么都不做**。文件夹名在那儿(双击改名),
        //     单击它不该被当成"点了空白"。顺带也挡掉了顶栏按钮万一漏下来的单击。
        //   · 在文件夹里 → 回主页(比"关掉整个启动台"合理,也更像原生)
        //   · 在主页   → 关掉启动台(保持原行为)
        //
        // ★ 用带坐标的 onTapGesture,才能把"顶栏"这一条排除掉。
        //   这是修 ① 的关键:光删按钮治不了根,因为掉下来的单击还在。
        .onTapGesture(coordinateSpace: .local) { location in
            if location.y <= Self.topBarExclusionHeight { return }

            if activeFolderID != nil {
                closeFolder()
            } else {
                onEscape()
            }
        }
        // ★ 注意:这里之前挂过 LongPressGesture 来进编辑模式,
        //   它会跟格子的拖拽手势抢事件,导致拖不起来。已删掉 —— 编辑请用右上角按钮。
        .onAppear {
            loadAndScan()
            appeared = true
            refreshWallpaper()
        }
        .onChange(of: wallpaperBlurRadius) { _ in
            // 滑杆拖动/点击后重算背景。渲染约 20ms 且在后台线程,
            // 拖动过程会连发多次 —— 反正都是后台算,后到的覆盖先到的,无感。
            refreshWallpaper()
        }
    }

    /// (重)算模糊壁纸。冷启动约 130ms、调滑杆重算约 20ms,都丢后台,主线程只贴图。
    private func refreshWallpaper() {
        // 模糊壁纸要读文件 + 解码 + 高斯模糊。冷启动实测约 130ms
        // (ImageIO 框架首次加载 + CIContext 创建都算在里面),
        // 之后命中内存缓存只要 3ms。130ms 放主线程会卡一下首屏,所以丢后台算。
        let screen = TransferBox(NSScreen.main ?? NSScreen.screens.first)
        Task.detached(priority: .userInitiated) {
            let made = TransferBox(screen.value.flatMap {
                WallpaperBackground.image(for: $0)
            })
            await MainActor.run { wallpaper = made.value }
        }
    }

    /// 背景层:静态,不参与任何动画
    @ViewBuilder
    private var backgroundLayer: some View {
        // ★★ 2026-09-15 关键修复:背景图必须"钉死"成容器尺寸,绝不能参与尺寸计算。
        //
        //   踩的坑(实测数据在下面):`.resizable().aspectRatio(contentMode: .fill)`
        //   在容器里会**把自己撑大** —— 图片宽高比 ≠ 屏幕宽高比时,fill 会算出
        //   一个超出容器的尺寸。本机壁纸源图是 3:2、屏幕是 16:10(1440×900),
        //   于是背景图算成 1440×963。
        //
        //   后果链条:
        //     ZStack 取子视图最大值 → 根内容区变成 1440×963
        //     → 比窗口高 63pt → 被窗口垂直居中 → 整体上移 31.5pt
        //     → **顶栏(返回 / 文件夹名 / 编辑)正好落进菜单栏那 31pt 里**
        //     → 看得见一点点、完全点不到
        //     → 用户表现:「进了文件夹改不了名、也回不去」(2026-09-15 反馈)
        //
        //   探针实测(修复前):
        //     探针·frame [根内容区] = (0.0, -31.5, 1440.0, 963.0)
        //     探针·frame [背景层]   = (0.0, -31.5, 1440.0, 963.0)
        //
        //   解法:`Color.clear` 当尺寸基准(它只吃 proposal、绝不长大),
        //   图片用 `.overlay` 叠上去(overlay 不影响父视图尺寸),
        //   最后 `.clipped()` 把超出容器的部分裁掉。
        //   这样无论壁纸是什么比例,背景层都恒等于窗口大小。
        Color.clear
            .overlay {
                if let wallpaper {
                    // ★ 自己模糊好的壁纸(见 WallpaperBackground.swift)。
                    //   静态位图,每帧只是贴一张图,零实时模糊开销;
                    //   也不受系统「减少透明度」影响 —— 好看和流畅同时拿到,
                    //   不用像上一版那样被迫二选一。
                    Image(nsImage: wallpaper)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    // 回退:极少数情况拿不到壁纸文件时(比如动态壁纸解析失败)。
                    //
                    // ★ v1.12 起不再用 `.behindWindow` 毛玻璃:窗口已经改成**不透明**
                    //   (为了省掉每帧的窗口×桌面混合),那种毛玻璃在窗口内部
                    //   采不到桌面,只会采到窗口自己的底色 —— 用了反而更难看。
                    //   换成一块干净的深色底,行为可预测、也不会闪。
                    //   正常路径下几乎走不到这里(NSScreen 上一定算得出壁纸)。
                    Color(white: 0.12)
                }
            }
            .clipped()
            .ignoresSafeArea()
            .probeFrame("背景层")
    }
    // ↑ 注意:以上 `Color.clear + overlay + clipped` 的写法是**有意的**,不是啰嗦。
    //   直接写 `Image(...).resizable().aspectRatio(contentMode: .fill).clipped()`
    //   不行 —— clipped 只裁绘制、不改尺寸,容器照样会被撑大。必须让 Color.clear 定尺寸。

    /// 内容层
    @ViewBuilder
    private var contentLayer: some View {
        if scanComplete {
            if let folder = activeFolder {
                FolderDetailView(
                    folder: folder,
                    onOpenApp: openApp,
                    onMoveAppToTopLevel: moveAppToTopLevel,
                    onReorderApps: { path, index in
                        var s = structure
                        s.moveAppInFolder(folderID: folder.id, appPath: path, to: index)
                        structure = s
                        LaunchpadStorage.save(s)
                    },
                    onRenameFolder: { id, name in
                        var s = structure
                        s.renameFolder(id: id, to: name)
                        structure = s
                        LaunchpadStorage.save(s)
                    }
                )
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.4).combined(with: .opacity),
                    removal: .scale(scale: 1.3).combined(with: .opacity)
                ))
                .zIndex(1)
            } else {
                TopLevelView(
                    structure: $structure,
                    search: $search,
                    onOpenApp: openApp,
                    onOpenFolder: openFolder,
                    onDeleteFolder: { id in
                        var s = structure
                        s.removeFolder(id: id)
                        structure = s
                        LaunchpadStorage.save(s)
                    }
                )
                .transition(.opacity)
            }
        } else {
            VStack(spacing: 14) {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    .scaleEffect(1.4)
                Text("正在载入 App…")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.8))
            }
            .transition(.opacity)
        }
    }

    private func loadAndScan() {
        let saved = LaunchpadStorage.load()
        Task.detached(priority: .userInitiated) {
            let scanned = AppScanner.scan()
            await MainActor.run {
                var s = saved
                s.merge(with: scanned)
                structure = s
                withAnimation(.easeIn(duration: 0.25)) {
                    scanComplete = true
                }
                preloadIcons(for: s)
                applyProbeIfNeeded(s)
            }
        }
    }

    /// ★ v1.12 性能关键:App 列表一拿到,就把所有图标在后台缩好塞进缓存。
    ///
    /// 这样一来 **滚动期间一次图标加载都不会发生** —— 滚到哪都是直接命中缓存。
    /// 之前是"格子出现才去取图标",滚动时主线程会被一批批到位的图标反复打断,
    /// 那就是用户感受到的"一顿一顿"。
    ///
    /// 两种尺寸都要预热:主网格 78pt、文件夹缩略图 20pt(后者只对文件夹里的 App 需要)。
    private func preloadIcons(for s: LaunchpadStructure) {
        // 对照路径跳过预热 —— 老行为就是"不预热,格子出现时才同步取图"
        if PerfFlags.oldIconLoading {
            Diag.log("图标预热:已跳过(对照模式 LP_OLDICON=1,走 v1.11 同步加载)")
            return
        }

        var topLevelPaths: [String] = []
        var folderPaths: [String] = []

        for item in s.topLevel {
            switch item {
            case .app(let a):
                topLevelPaths.append(a.pathString)
            case .folder(let f):
                folderPaths.append(contentsOf: f.apps.map { $0.pathString })
            }
        }

        // 主网格 / 文件夹详情页的图标 = 78pt 的"卡片"(圆角 + 投影已烤进图里)
        let gridPaths = topLevelPaths + folderPaths
        if PerfFlags.noShadow {
            // 对照路径:素图标,不烤阴影,用来量"阴影到底占多少"
            IconCache.shared.preload(paths: gridPaths, pointSize: AppCell.iconPointSize, tag: "主网格(素图)")
        } else {
            IconCache.shared.preloadCards(paths: gridPaths, style: AppCell.cardStyle, tag: "主网格")
        }
        // 文件夹图标里的 3×3 小缩略图 = 20pt,不需要圆角阴影
        IconCache.shared.preload(paths: folderPaths,
                                 pointSize: FolderIcon.miniPointSize, tag: "文件夹缩略图")

        Diag.log("图标预热:主网格 \(gridPaths.count) 个,文件夹缩略图 \(folderPaths.count) 个")
    }

    /// 见 `LaunchpadProbe` 的说明 —— 仅调试用,正常启动是空操作。
    private func applyProbeIfNeeded(_ s: LaunchpadStructure) {
        guard let probe = LaunchpadProbe.value, probe != "top" else { return }
        let folders: [FolderItem] = s.topLevel.compactMap {
            if case .folder(let f) = $0 { return f } else { return nil }
        }
        if probe == "folder" {
            guard let f = folders.first(where: { !$0.apps.isEmpty }) ?? folders.first else {
                Diag.log("探针:没有找到任何文件夹,停在顶层")
                return
            }
            Diag.log("探针:进入文件夹「\(f.name)」(\(f.apps.count) 个 App)")
            activeFolderID = f.id
        } else {
            Diag.log("探针:进入指定文件夹 id=\(probe)")
            activeFolderID = probe
        }
    }

    private func openApp(_ app: AppItem) {
        NSWorkspace.shared.open(app.path)
        onEscape()
    }

    private func openFolder(id: String) {
        withAnimation(.spring(response: 0.48, dampingFraction: 0.78)) {
            activeFolderID = id
        }
    }

    private func closeFolder() {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            activeFolderID = nil
        }
    }

    /// 把 app 从文件夹里拖出来、放回顶层网格(紧跟在文件夹后面一格)
    private func moveAppToTopLevel(_ app: AppItem) {
        var s = structure
        s.moveAppToTopLevel(app)
        structure = s
        LaunchpadStorage.save(s)
    }
}

// MARK: - 毛玻璃桥接 —— 已删除(v1.12)
//
// 原来这里有个 `VisualEffectView`(NSVisualEffectView 的 SwiftUI 桥),
// 给"拿不到壁纸文件"的兜底路径用。
//
// v1.12 起窗口改成 `isOpaque = true`,而 `.behindWindow` 那种毛玻璃
// **必须依赖窗口透明才能采到桌面** —— 在不透明窗口里它只会采到窗口自己的底色,
// 等于白做一层还可能发灰。所以兜底改成一块纯色,这个桥就没用了,删掉。
//
// 顺带记一笔:`WallpaperBackground.swift` 的文件头解释了
// **为什么主路径一直不用系统实时毛玻璃**(要么慢、要么被"减少透明度"变成死白)。
// 那条结论不受这次改动影响,仍然是这个项目最重要的一条设计决定。

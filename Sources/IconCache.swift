import AppKit

/// 性能对照开关 —— 用来做 A/B 实测,不是给日常用的。
///
/// ## 为什么要有它
///
/// "改完手感好了"是**主观判断**,很容易自我暗示。要证明优化真的有用,
/// 得能用**同一套压测**跑出旧实现和新实现的数字,再比。
///
/// 配套脚本:`/tmp/lp_ab.sh`(压测) + `/tmp/lp_scroll`(滚轮驱动器)。
enum PerfFlags {
    /// 退回 v1.11 的图标加载方式:不预热、`onAppear` 里同步取图、
    /// 图标挂 `.interpolation(.high)` 每帧重采样。
    static let oldIconLoading =
        ProcessInfo.processInfo.environment["LP_OLDICON"] == "1"

    /// 去掉所有阴影(图标 + 文字 + 文件夹),换成素图标。
    ///
    /// 这是"阴影到底要花多少"的对照探针。实测(2026-09-15,预热 + 各跑 2 遍):
    ///
    ///     当前实现(图标/文字各一处 SwiftUI 阴影)  丢帧 1.9% / 3.6%
    ///     本开关打开(完全不要阴影)                丢帧 0.7% / 0.5%
    ///
    /// 差 3~7 倍,所以阴影确实是滚动时最后剩下的大头。
    /// 但直接删掉会掉档次 —— 真正要做的是**把阴影烘焙进图标位图**
    /// (见 `CardStyle`),让每帧不再做离屏模糊。
    static let noShadow =
        ProcessInfo.processInfo.environment["LP_NOSHADOW"] == "1"
}

/// "图标卡片"的样式 —— 图标本体 + 圆角 + 投影,三者一次性烘进一张位图。
///
/// ## 为什么要这么做
///
/// SwiftUI 里写 `.cornerRadius(14).shadow(radius: 4, y: 2)`,看起来是一行,
/// 实际是**每一帧**都要:把图标画进一张离屏纹理 → 做一次高斯模糊 → 再合成回来。
/// 一屏 ~30 个格子、每个两处 `.shadow`(图标一处、文字一处)= 60 次离屏模糊/帧。
///
/// 而图标的圆角和投影是**静态**的 —— 只有滚动、缩放时会变。
/// 所以完全可以在预热时烤进位图里,滚动时只剩"贴一张已经带阴影的图"。
///
/// ## 尺寸怎么算
///
/// 位图必须比图标大一圈,不然模糊出来的阴影会被裁掉:
///
///     卡片边长 = 图标边长 + 2 × 留白
///     留白    = 模糊半径 × 1.5 + |纵向偏移| + 2
///
/// 78pt 的图标 + 半径 4、y=2 的阴影 → 留白 10 → 卡片 98pt(196px @2x)。
struct CardStyle: Equatable {
    /// 图标本体的显示尺寸(点)。网格里是 78。
    let pointSize: CGFloat
    /// 圆角。跟原来 `.cornerRadius(14)` 保持一致,视觉不能变。
    let cornerRadius: CGFloat
    /// 投影模糊半径。跟原来 `.shadow(radius:)` 一致。
    let shadowRadius: CGFloat
    /// 投影纵向偏移(点,正数 = 向下)。跟原来 `.shadow(y:)` 一致。
    let shadowY: CGFloat
    /// 投影浓度。跟原来 `.shadow(opacity)` 一致。
    let shadowOpacity: Double

    /// 位图四周要留的空白(点)。
    var pad: CGFloat { (shadowRadius * 1.5 + abs(shadowY) + 2).rounded(.up) }
    /// 卡片整体的显示尺寸(点)。
    var cardPointSize: CGFloat { pointSize + pad * 2 }
    /// 卡片位图的像素边长。
    func bitmapPixelSize(scale: CGFloat) -> Int { max(1, Int((cardPointSize * scale).rounded())) }

    /// 缓存 key 必须把样式里每个会改像素结果的参数都带上 ——
    /// 少带一个,就会出现"改了圆角但图标没跟着变"的怪现象。
    var cacheKey: String {
        "card|\(pointSize)|\(cornerRadius)|\(shadowRadius)|\(shadowY)|\(shadowOpacity)|\(pad)"
    }

    /// 网格主图标用的样式。
    static let grid = CardStyle(pointSize: 78, cornerRadius: 14,
                                shadowRadius: 4, shadowY: 2, shadowOpacity: 0.35)
}

/// App 图标缓存 —— 解决"滚动时一顿一顿"的核心。
///
/// ## 之前是什么样(为什么会卡)
///
/// `AppCell` 在自己的 `onAppear` 里直接同步调
/// `NSWorkspace.shared.icon(forFile:)`,然后把 NSImage 丢给 `Image(nsImage:)`。
///
/// 这个写法有两个问题,而且**第二个才是"卡"的真正原因**:
///
///   1. **每帧重采样**。`Image(nsImage:).resizable()` 显示在 78pt 的框里,
///      而 NSImage 自己的 `size` 是 32pt —— 两者尺寸不符,
///      再挂上 `.interpolation(.high)` 就等于每帧做一次高质量缩放。
///
///   2. **主线程同步取图标**(关键)。`NSWorkspace.icon(forFile:)` 要走
///      IconServices:查数据库、必要时读图标缓存文件、组装 NSImage。
///      实测单个 1~6ms。而 `LazyVGrid` 是**滚动时才创建格子**的 ——
///      于是滚动过程中每冒出一个新格子,主线程就被占住 1~6ms。
///      一屏七八个格子同时冒出来 = 主线程被占几十毫秒 = **掉好几帧**。
///
/// ## 现在
///
///   - App 列表一扫完,就在**后台并发**把所有图标缩好、连圆角带投影一起烤成卡片;
///   - 滚动时 **一次 `icon(forFile:)` 都不会发生**,也没有任何离屏模糊;
///   - 缓存里存的是**逻辑尺寸正好等于显示尺寸**的图 → 绘制是 1:1 贴图。
///
/// ## ★ 一个必须写下来的大坑(2026-09-15 实测)
///
/// `NSWorkspace.icon(forFile:)` 返回的 NSImage:
///
///   - `image.size` 是 **32×32 pt**(不是你以为的 512 或 1024);
///   - 里面塞了 **32 档** representation(16px 一路到 2048px);
///   - 类型是 **`NSISIconImageRep`,不是 `NSBitmapImageRep`** ——
///     所以"遍历 representations 挑一档"这条路**根本走不通**,
///     `rep as? NSBitmapImageRep` 永远匹配不到。
///
/// 于是:
///
/// ```swift
/// img.cgImage(forProposedRect: nil, ...)          // → 64×64   ❌ 糊
/// var r = NSRect(x: 0, y: 0, width: 78, height: 78)
/// img.cgImage(forProposedRect: &r, ...)           // → 256×256 ✅ 清晰
/// ```
///
/// 传 `nil` 时 AppKit 只能拿 `image.size`(32pt)去算,于是给你 64px ——
/// **不管里面有多少档高分辨率数据都拿不到**。必须明确告诉它"我要多大"。
///
/// 这一条是用 `/tmp/lp_iconprobe.swift` 实测出来的:78pt → 256px、
/// 20pt → 48px、128pt → 256px。所以目标 156px 时真正拿到的是 256 档
/// (再自己缩到 156),而不是 2048 那档。
final class IconCache {
    static let shared = IconCache()

    private let lock = NSLock()
    private var map: [String: NSImage] = [:]

    /// 屏幕倍数,决定缩图的像素边长。`shared` 首次被摸到一定是在主线程
    /// (AppCell 的 onAppear / loadAndScan 的预热都在主线程),所以这里读屏幕是安全的。
    private let scale: CGFloat

    private let queue = DispatchQueue(
        label: "com.xingxing.launchpad.iconcache",
        qos: .userInitiated,
        attributes: .concurrent
    )

    private init() {
        scale = (NSScreen.main ?? NSScreen.screens.first)?.backingScaleFactor ?? 2
    }

    // MARK: - 对外:素图标(文件夹里的小缩略图用)

    /// 取素图标(不圆角、不阴影):命中缓存立刻回调,否则后台缩好再回主线程。
    /// 回调**一定在主线程**,调用方可以直接写 @State。
    func icon(for path: String, pointSize: CGFloat, completion: @escaping (NSImage) -> Void) {
        let key = "\(path)|\(pixelSize(pointSize))"

        lock.lock()
        let hit = map[key]
        lock.unlock()

        if let hit {
            completion(hit)
            return
        }

        let pixel = pixelSize(pointSize)
        let scale = self.scale
        queue.async {
            let out = Self.render(path: path, pointSize: pointSize, pixel: pixel, scale: scale)
            self.lock.lock()
            self.map[key] = out.image
            self.lock.unlock()
            DispatchQueue.main.async { completion(out.image) }
        }
    }

    // MARK: - 对外:卡片图标(网格用)

    /// 取"连圆角带投影都烤好了"的卡片图标。
    /// 返回的图**逻辑尺寸 = `style.cardPointSize`**,布局时要注意比图标本体大一圈。
    func card(for path: String, style: CardStyle, completion: @escaping (NSImage) -> Void) {
        let key = "\(style.cacheKey)|\(path)"

        lock.lock()
        let hit = map[key]
        lock.unlock()

        if let hit {
            completion(hit)
            return
        }

        let pixel = style.bitmapPixelSize(scale: scale)
        let scale = self.scale
        queue.async {
            let img = Self.renderCard(path: path, style: style, pixel: pixel, scale: scale)
            self.lock.lock()
            self.map[key] = img
            self.lock.unlock()
            DispatchQueue.main.async { completion(img) }
        }
    }

    // MARK: - 预热

    /// 预热背景图标(未压缩的素图标)。
    func preload(paths: [String], pointSize: CGFloat, tag: String = "") {
        guard !paths.isEmpty else { return }
        let pixel = pixelSize(pointSize)
        let scale = self.scale
        let started = Date()

        queue.async {
            var made = 0
            DispatchQueue.concurrentPerform(iterations: paths.count) { i in
                let key = "\(paths[i])|\(pixel)"
                self.lock.lock()
                let exists = self.map[key] != nil
                self.lock.unlock()
                if exists { return }

                let out = Self.render(path: paths[i], pointSize: pointSize, pixel: pixel, scale: scale)
                self.lock.lock()
                self.map[key] = out.image
                self.lock.unlock()
                made += 1
            }
            let ms = Date().timeIntervalSince(started) * 1000
            Diag.log(String(format: "图标预热%@ 完成:%d 个新增 / %d 个请求,共 %.0fms(平均 %.2fms/个)",
                            tag.isEmpty ? "" : "(\(tag))", made, paths.count, ms,
                            made > 0 ? ms / Double(made) : 0))
        }
    }

    /// 预热卡片图标(烤好圆角 + 投影)。
    ///
    /// ★ 用 `concurrentPerform` 铺开,不是 for 循环。
    ///   第一版写成"一个 async 块里 for 一遍",等价于**单线程串行** ——
    ///   实测 91 个图标要 1716ms(18.9ms/个),期间网格上全是灰占位块,
    ///   用户看到的就是"图标一个一个慢慢蹦出来"。铺开后降到 ~140ms。
    func preloadCards(paths: [String], style: CardStyle, tag: String = "") {
        guard !paths.isEmpty else { return }
        let pixel = style.bitmapPixelSize(scale: scale)
        let scale = self.scale
        let started = Date()

        queue.async {
            var made = 0
            DispatchQueue.concurrentPerform(iterations: paths.count) { i in
                let key = "\(style.cacheKey)|\(paths[i])"
                self.lock.lock()
                let exists = self.map[key] != nil
                self.lock.unlock()
                if exists { return }

                let img = Self.renderCard(path: paths[i], style: style, pixel: pixel, scale: scale)
                self.lock.lock()
                self.map[key] = img
                self.lock.unlock()
                made += 1
            }
            let ms = Date().timeIntervalSince(started) * 1000
            Diag.log(String(format: "图标卡片预热%@ 完成:%d 个新增 / %d 个请求,共 %.0fms(目标 %dpt/%dpx)",
                            tag.isEmpty ? "" : "(\(tag))", made, paths.count, ms,
                            Int(style.cardPointSize), pixel))
        }
    }

    /// 已经缓存的图标数量(仅用于诊断日志)。
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return map.count
    }

    // MARK: - 内部

    private func pixelSize(_ pointSize: CGFloat) -> Int {
        max(1, Int((pointSize * scale).rounded()))
    }

    /// 建一张 png 可直接用的位图上下文。两处渲染都要,抽出来。
    private static func makeContext(pixel: Int) -> CGContext? {
        CGContext(
            data: nil,
            width: pixel,
            height: pixel,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        )
    }

    /// ★★ 图标要不要"撑满"内容框 —— 这是**外观开关**,不是优化开关。
    ///
    /// - `false`(默认,和 v1.11 一致):保留 macOS 图标自带的透明边。
    /// - `true`:**裁掉**透明边,让可见内容真的占满内容框 —— 图标会**大 18%**。
    ///
    /// ## 为什么默认必须是 false(2026-09-15 实测,差点犯的错)
    ///
    /// `NSWorkspace.icon(forFile:)` 拿到的位图天生带一圈透明边:
    ///
    ///     请求 78pt → 位图 256×256,不透明内容只有 218×218(**85.2%**)
    ///     请求 20pt → 位图  48×48, 内容 46×46(95.8%)
    ///
    /// 看到"图标按 78pt 画的,屏幕上量出来只有 64pt",很自然会想"那就把透明边裁掉"。
    /// **那是错的** —— 裁掉之后图标撑满 78pt,比旧版大 18%,这是改了外观。
    ///
    /// 真相是:`Image(nsImage:).resizable().frame(78)` 本来就是把**整张位图(含透明边)**
    /// 缩进 78pt,留白一样占位置。所以 v1.11 的可见内容**一直**就是 64pt,
    /// 而不是"有个 bug 让它小了 15%"。
    ///
    /// 硬证据 —— v1.11 的真机截图 `诊断截图/修复后-顶层页v1.11.png`,用连通域量每个色块
    /// (`/tmp/lpblobs`):
    ///
    ///     旧版:63.0×61.5pt / 63.5×61.5pt / 64.0×64.0pt   ← 78pt 的框
    ///     撑满:74.0×72.0pt / 74.5×72.5pt                 ← 同一个图标
    ///
    /// 性能优化必须**视觉中性** —— "改的是在哪烤,不是长什么样"。
    /// 所以透明边必须一起缩进去。真想换大图标,把这个开关改成 true 就一步到位。
    static let fillsBox = false

    /// 按目标点尺寸(不是 nil!)向 AppKit 要图标位图。见文件头的坑。
    ///
    /// 顺带把"一次 NSWorkspace 查询"收在这里:以前 `render()` 先取一次 `full`
    /// 当兜底、取位图时又取一次,等于每个图标查两遍 IconServices。
    private static func iconBitmap(path: String, pointSize: CGFloat) -> (full: NSImage, cg: CGImage?) {
        let full = NSWorkspace.shared.icon(forFile: path)
        // ★ proposedRect 必须非 nil:传 nil 时 AppKit 拿 image.size(32pt)去算,
        //   只会给你 64×64 —— 里面明明有 32 档 representation 也拿不到。
        var proposed = NSRect(x: 0, y: 0, width: pointSize, height: pointSize)
        let cg = full.cgImage(forProposedRect: &proposed, context: nil, hints: nil)
        return (full, cg)
    }

    /// 裁掉四周的透明(alpha≈0)边,只留不透明内容的包围盒。
    ///
    /// **只被 `fillsBox = true` 用到**(= 让图标撑满内容框的"大图标模式")。
    /// 默认路径**不要**调它 —— 理由见 `fillsBox` 上面那大段。
    private static func trimTransparentEdges(_ cg: CGImage) -> CGImage {
        let w = cg.width, h = cg.height
        guard w > 0, h > 0 else { return cg }

        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return cg }

        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return cg }
        let buf = data.bindMemory(to: UInt8.self, capacity: w * h * 4)

        // premultipliedFirst → 每像素第 0 个字节是 alpha。
        // 阈值取 8 而不是 0:抗锯齿边缘会有一圈极低但不为 0 的 alpha,
        // 不排掉的话包围盒会虚胖一两像素,裁了等于没裁。
        let threshold: UInt8 = 8
        var minX = w, maxX = -1, minY = h, maxY = -1
        for y in 0..<h {
            let row = y * w * 4
            for x in 0..<w where buf[row + x * 4] > threshold {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }

        // 整张都透明(坏图标)或者本来就贴边 → 原样返回,别把图裁没了
        guard maxX >= minX, maxY >= minY else { return cg }
        let bw = maxX - minX + 1, bh = maxY - minY + 1
        guard bw > 1, bh > 1, bw < w || bh < h else { return cg }

        return cg.cropping(to: CGRect(x: minX, y: minY, width: bw, height: bh)) ?? cg
    }

    /// 把图标画进一张 `pixel × pixel` 的小位图(素图标)。
    ///
    /// 关键点:**逻辑尺寸设成"点尺寸"**(= `像素 / 屏幕倍数`),
    /// 这样 SwiftUI 显示时是 1:1 贴图,不会再有任何缩放采样。
    private static func render(path: String, pointSize: CGFloat, pixel: Int, scale: CGFloat)
        -> (image: NSImage, picked: Int)
    {
        let (full, raw) = iconBitmap(path: path, pointSize: pointSize)

        guard var cg = raw, let ctx = makeContext(pixel: pixel) else { return (full, 0) }
        if fillsBox { cg = trimTransparentEdges(cg) }

        // 高质量插值只在**这一次**缩小的时候用,划算;逐帧做就不划算了。
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: pixel, height: pixel))

        guard let out = ctx.makeImage() else { return (full, 0) }

        let point = CGFloat(pixel) / scale
        return (NSImage(cgImage: out, size: NSSize(width: point, height: point)), max(cg.width, cg.height))
    }

    /// 渲染"卡片":图标 + 圆角 + 投影,一次性烤进位图。
    ///
    /// 分两步是**必须**的 —— 不能在同一个上下文里"先 clip 再 setShadow":
    /// clip 会把阴影一起裁掉(阴影画在裁剪区之外),结果是阴影直接消失。
    /// 所以先做出干净的圆角图标位图,再把它**带阴影**画进大画布。
    ///
    /// 坐标注意:这里的上下文是默认的"原点左下、y 向上",
    /// 而 `.shadow(y: 2)` 说的是"向下偏 2 点",所以在 CG 里是 **负 y**。
    private static func renderCard(path: String, style: CardStyle, pixel: Int, scale: CGFloat) -> NSImage {
        let (full, raw) = iconBitmap(path: path, pointSize: style.pointSize)

        guard var src = raw else { return full }
        if fillsBox { src = trimTransparentEdges(src) }

        let iconPx = max(1, Int((style.pointSize * scale).rounded()))
        let padPx = max(0, Int((style.pad * scale).rounded()))

        // ① 干净的圆角图标位图(和原来 `.cornerRadius(14)` 等效)
        guard let iconCtx = makeContext(pixel: iconPx) else { return full }
        iconCtx.interpolationQuality = .high
        let iconRect = CGRect(x: 0, y: 0, width: CGFloat(iconPx), height: CGFloat(iconPx))
        let radius = style.cornerRadius * scale
        iconCtx.addPath(CGPath(roundedRect: iconRect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        iconCtx.clip()
        iconCtx.draw(src, in: iconRect)
        guard let iconImg = iconCtx.makeImage() else { return full }

        // ② 带投影画进大画布
        let side = iconPx + padPx * 2
        guard let ctx = makeContext(pixel: side) else { return full }
        ctx.interpolationQuality = .high

        let shadowColor = CGColor(
            colorSpace: CGColorSpaceCreateDeviceRGB(),
            components: [0, 0, 0, CGFloat(style.shadowOpacity)]
        )
        if let shadowColor {
            ctx.setShadow(offset: CGSize(width: 0, height: -style.shadowY * scale),
                          blur: style.shadowRadius * scale,
                          color: shadowColor)
        }
        ctx.draw(iconImg, in: CGRect(x: CGFloat(padPx), y: CGFloat(padPx),
                                     width: CGFloat(iconPx), height: CGFloat(iconPx)))

        guard let out = ctx.makeImage() else { return full }

        // ★ 诊断:`LP_DUMPCARD=1` 时
        //   ① 把卡片位图原样写到磁盘;
        //   ② **在卡片外沿画一圈洋红色描边**。
        //
        //   为什么要描边:"屏幕上图标比预期小一圈"有两个可能 ——
        //     ① 位图里就画小了;② 布局把整张卡片压小了。
        //   光看内容分不出来(内容缩了、卡片缩了,看起来都是"小了")。
        //   画一条**位图边界**上的线,量它在屏幕上的长度,就能直接判定:
        //     量出来 ≈ cardPointSize → 布局没问题,是位图的锅;
        //     量出来更小           → 是布局把卡片压小了。
        //   (2026-09-15 就是靠这一招定位到"两层 .frame 会缩放内容"的。)
        if ProcessInfo.processInfo.environment["LP_DUMPCARD"] == "1" {
            let dir = Diag.dir.appendingPathComponent("carddump")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

            let marked = makeContext(pixel: side) ?? ctx
            marked.interpolationQuality = .high
            marked.draw(out, in: CGRect(x: 0, y: 0, width: side, height: side))
            marked.setStrokeColor(CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(),
                                          components: [1, 0, 1, 1]) ?? CGColor(gray: 1, alpha: 1))
            marked.setLineWidth(3)
            marked.stroke(CGRect(x: 1.5, y: 1.5, width: CGFloat(side) - 3, height: CGFloat(side) - 3))

            if let markedImg = marked.makeImage() {
                let rep = NSBitmapImageRep(cgImage: markedImg)
                if let data = rep.representation(using: .png, properties: [:]) {
                    try? data.write(to: dir.appendingPathComponent("card_marked.png"))
                }
                Diag.log(String(format: """
                卡片位图已描边导出(LP_DUMPCARD):位图 %dpx / 图标区 %dpx / 卡片 %.0fpt
                → **界面上显示的也是这张带边线的图** —— 量那条洋红边的边长:
                   ≈%.0fpt  → 布局没问题,是位图内容小;
                   明显更小 → 布局把整张卡片压小了。
                """, side, iconPx, style.cardPointSize, style.cardPointSize))

                // ★ 关键:把描边图**返回给界面**。
                //   第一版只把描边图写了文件、返回的是没描边的,结果屏幕上什么都没有,
                //   量到的"边框尺寸"其实是图标自己的像素 —— 白折腾一轮。
                let cardPoint = CGFloat(side) / scale
                return NSImage(cgImage: markedImg, size: NSSize(width: cardPoint, height: cardPoint))
            }
        }

        // 逻辑尺寸 = 卡片点数(含留白)→ 显示时正好 1:1
        let cardPoint = CGFloat(side) / scale
        return NSImage(cgImage: out, size: NSSize(width: cardPoint, height: cardPoint))
    }
}

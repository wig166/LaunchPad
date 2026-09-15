import AppKit
import CoreImage
import ImageIO

/// 拿到"当前桌面壁纸"的模糊版,做成一张静态位图当背景。
///
/// ## 为什么不用 `NSVisualEffectView` 的实时毛玻璃
///
/// 这是踩出来的两个坑:
///
///   1. **慢**:`.underWindowBackground + .behindWindow` 每帧都要重新模糊整个屏幕
///      (2880×1800 = 518 万像素),M1 8GB 上直接掉到 24fps。
///
///   2. **白**:只要用户在系统设置里打开「辅助功能 → 显示 → 减少透明度」
///      **或**「增加对比度」(两者任一即可),macOS 会强制把所有实时毛玻璃
///      变成不透明纯色 —— 背景就成了一片死白。
///      ★ 原生启动台不受这两个设置影响,因为它压根不用系统毛玻璃,
///        而是自己取壁纸、自己做模糊。这正是这里要复刻的做法。
///
/// ## 怎么找壁纸文件
///
/// `NSWorkspace.desktopImageURL(for:)` 有两种情况:
///
///   - **普通静态壁纸**:直接给到图片文件的 URL —— 直接用。
///
///   - **「照片随机播放」壁纸**:返回的是一个**目录**,而且**这个目录
///     比真正的照片池高多少级,是不确定的 —— 跟着系统版本漂**:
///
///         | 系统 | `desktopImageURL` 返回 | 真实照片池 |
///         |---|---|---|
///         | macOS 26 | `~/Library/Application Support` | 低 1 级 |
///         | macOS 27 | `~/Library` | **低 2 级** |
///
///     所以**不能写死"往下探一层"**,必须逐级下探去搜
///     `com.apple.desktop.photos` 这个名字。实测从 `~/Library` 出发
///     只要访问 2 个目录、耗时 2.1ms 就能找到,便宜到可以忽略。
///
///     池子里是从照片图库导出的几十张候选图,系统按设定定时轮换。
///     这个目录里**没有任何字段记录"当前是第几张"**
///     (翻遍 `com.apple.wallpaper/Store/Index.plist` 的 Configuration 也没有——
///     只有 `type: imageFolder` 和池子路径,没有索引)。
///     但系统每次真正拿某张图去渲染桌面时,该文件的**访问时间(atime)**
///     会被刷新 —— 所以取 atime 最新的那张,就是当前壁纸。
///
/// ### ★ atime 法的两个已知局限(2026-09-15 macOS 27 上实测到)
///
///   1. **会被自己污染**:排序只读元数据、不碰文件内容,所以不脏;但最后
///      `CGImageSourceCreateWithURL` 真读内容那一下,会把选中那张的 atime
///      刷成"现在"。**下次启动它还是最新的 → 自我锁定**。
///      选对了就稳定不闪,选错了就一直错。macOS 没有 Linux 的 `O_NOATIME`,
///      这个副作用躲不掉。
///
///   2. **同秒多张无法区分**:实测系统设壁纸时会一次读好几张
///      (2026-09-15 16:57:57 一批 4 个文件 atime 完全相同,系统可能在预载
///      下一张)。`max(by:)` 在这种情况下选谁取决于目录遍历顺序,不稳定。
///
///   缓解:池子里的图都是同一批照片,选错也只是换一张,不会显示成空白或
///   纯色。真要彻底准确,只能去解析 `com.apple.wallpaper/Store/Index.plist`
///   里按 display UUID 索引的 Configuration blob —— 那是嵌套二进制 plist,
///   还要把 display UUID 映射到 `NSScreen`,复杂度不划算,没做。
///
/// 读壁纸文件**不需要任何权限**:读的是磁盘上的图片文件,不是截屏,
/// 跟「屏幕录制」权限毫无关系 —— 不要再把权限地狱请回来。
///
/// ## 性能(2026-09-15 在本机实测)
///
/// | 步骤 | 耗时 |
/// |---|---|
/// | `desktopImageURL` | 4.3 ms |
/// | 目录扫描 + atime 排序(61 个文件) | 0.9 ms |
/// | HEIC 从 3024px 原图生成缩略图 | **184.5 ms** |
/// | **HEIC 改用文件内嵌缩略图** | **3.8 ms** ← 快 48 倍 |
/// | 高斯模糊(CPU 渲染,480px 图) | 10.9 ms |
/// | 高斯模糊(GPU 渲染,同样 480px) | 20.1 ms |
///
/// 合计约 20ms,主线程直接算完即可,不需要异步,
/// 也就避免了 `NSImage` 跨线程传递的 Sendable 麻烦。
enum WallpaperBackground {

    /// ★ 用 CPU 渲染,而不是 GPU。
    ///   在这个尺寸(约 480px)下实测 CPU 10.9ms、GPU 20.1ms ——
    ///   图太小,GPU 那套上下文创建 + 纹理上传的开销远大于它的算力优势。
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: true])

    private static let cacheLock = NSLock()
    private static var cache: [String: NSImage] = [:]

    /// 最近一次解析用到的源文件路径,仅供诊断/自检。
    private(set) static var lastSourcePath: String = "(尚未解析)"

    private static let imageExtensions: Set<String> =
        ["jpg", "jpeg", "png", "heic", "heif", "tiff", "tif", "bmp", "gif", "webp"]

    /// macOS「照片随机播放」壁纸的候选池目录名。
    private static let desktopPhotoPoolName = "com.apple.desktop.photos"

    /// 内嵌缩略图低于这个宽度就不用它 —— 有些 JPEG 内嵌图只有 160×120,
    /// 拉到全屏会糊出马赛克,宁可多花 20ms 从原图重新生成。
    private static let minAcceptableThumbnailWidth = 320

    /// 取某块屏幕壁纸的模糊版。取不到返回 nil,调用方自行回退。
    ///
    /// - Parameter darken: 额外压暗比例,保证白色图标名在任何壁纸上都读得清。
    static func image(for screen: NSScreen, darken: CGFloat = 0.18) -> NSImage? {
        guard let file = locateWallpaperFile(for: screen) else {
            lastSourcePath = "(未找到壁纸文件)"
            return nil
        }
        lastSourcePath = file.path

        let size = screen.frame.size
        // 缓存 key 带源文件路径 —— 换壁纸后自动失效重算。
        let key = "\(file.path)|\(Int(size.width))x\(Int(size.height))|\(darken)"

        cacheLock.lock()
        if let hit = cache[key] {
            cacheLock.unlock()
            return hit
        }
        cacheLock.unlock()

        guard let made = render(url: file, displaySize: size, darken: darken) else { return nil }

        cacheLock.lock()
        cache[key] = made
        cacheLock.unlock()
        return made
    }

    // MARK: - 定位壁纸文件

    private static func locateWallpaperFile(for screen: NSScreen) -> URL? {
        if let url = NSWorkspace.shared.desktopImageURL(for: screen) {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
                if !isDirectory.boolValue {
                    return url          // 普通静态壁纸
                }
                // 目录本身就是照片池
                if let hit = mostRecentlyAccessedImage(in: url) { return hit }
                // ★ 不然就往下搜 —— 往下几级不确定,见文件头说明。
                if let pool = findPhotoPool(under: url),
                   let hit = mostRecentlyAccessedImage(in: pool) { return hit }
            }
        }

        // 兜底:照片随机播放壁纸的固定位置。
        // 这个路径是实测的绝对位置,不受 desktopImageURL 返回值漂移影响。
        let fallback = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/\(desktopPhotoPoolName)")
        return mostRecentlyAccessedImage(in: fallback)
    }

    /// 从 `root` 出发广度优先下探,找到名为 `com.apple.desktop.photos` 的目录。
    ///
    /// 限制:最多 2 层、每层最多看 256 个条目。实测正常情况访问 2 个目录、
    /// 2.1ms 就命中,限流只是为了在异常目录结构下别把主线程拖住。
    private static func findPhotoPool(under root: URL) -> URL? {
        let maxDepth = 2
        let maxEntriesPerDirectory = 256
        let keys: Set<URLResourceKey> = [.isDirectoryKey]

        var queue: [(url: URL, depth: Int)] = [(root, 0)]
        var head = 0

        while head < queue.count {
            let (dir, depth) = queue[head]
            head += 1

            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            ) else { continue }

            for entry in entries.prefix(maxEntriesPerDirectory) {
                if entry.lastPathComponent == desktopPhotoPoolName { return entry }
                if depth < maxDepth,
                   (try? entry.resourceValues(forKeys: keys))?.isDirectory == true {
                    queue.append((entry, depth + 1))
                }
            }
        }
        return nil
    }

    /// 「照片随机播放」下定位当前那张:取访问时间(atime)最新的图片。
    private static func mostRecentlyAccessedImage(in directory: URL) -> URL? {
        let keys: Set<URLResourceKey> = [.contentAccessDateKey, .isRegularFileKey]

        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return nil }

        let candidates: [(URL, Date)] = entries.compactMap { url in
            guard imageExtensions.contains(url.pathExtension.lowercased()) else { return nil }
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  let accessed = values.contentAccessDate else { return nil }
            return (url, accessed)
        }

        return candidates.max(by: { $0.1 < $1.1 })?.0
    }

    // MARK: - 渲染

    private static func render(url: URL, displaySize: CGSize, darken: CGFloat) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

        // ★ 优先用文件内嵌的缩略图:相机/手机拍的图内部本来就带一张小图,
        //   直接取它,比从 3024px 原图重新缩放快几十倍(实测 184ms → 3.8ms)。
        var decoded = thumbnail(from: source, maxPixel: 480, preferEmbedded: true)

        // 内嵌缩略图有时小得离谱,那就老实从原图生成。
        if decoded == nil || (decoded?.width ?? 0) < minAcceptableThumbnailWidth {
            decoded = thumbnail(from: source, maxPixel: 480, preferEmbedded: false)
        }
        guard let cgImage = decoded else { return nil }

        let small = CIImage(cgImage: cgImage)
        guard small.extent.width > 1 else { return nil }

        // 在高斯模糊本就抹掉细节的前提下,480px 上算和原图上算,
        // 放大回全屏后肉眼几乎没差别,但像素量差两个数量级。
        let blurred = small
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 16])

        // ★★ 按屏幕宽高比居中裁切(cover 语义)。
        //
        //   为什么必须裁(2026-09-15 踩到):
        //     源照片是 3:2(缩略图 480×321),屏幕是 16:10(1440×900)。
        //     不裁的话,这张位图的**像素宽高比 ≠ 屏幕宽高比**,而
        //     `NSImage(cgImage:size:)` 里的 `size` 只改"逻辑尺寸"、不改像素 ——
        //     于是这张图"说自己是 1440×900,像素其实是 3:2",自相矛盾。
        //
        //     SwiftUI 的 `Image.resizable().aspectRatio(contentMode: .fill)`
        //     最终按**像素**比例算,于是把背景撑成 1440×963,
        //     连带把整个根视图撑高 63pt、顶栏被顶进菜单栏(详见 AppGrid.swift
        //     backgroundLayer 的注释)。
        //
        //   裁完之后"逻辑尺寸"和"像素比例"一致,任何消费方都不会再算错,
        //   而且保存下来的像素也正好是真正要显示的那部分,不浪费。
        let aspect = displaySize.width / displaySize.height
        let e = small.extent
        let cropRect: CGRect
        if e.width / e.height > aspect {
            // 图比屏幕更宽 → 裁掉左右
            let w = e.height * aspect
            cropRect = CGRect(x: e.midX - w / 2, y: e.minY, width: w, height: e.height)
        } else {
            // 图比屏幕更高 → 裁掉上下
            let h = e.width / aspect
            cropRect = CGRect(x: e.minX, y: e.midY - h / 2, width: e.width, height: h)
        }

        // 整体压暗,替代原来那层 Color.black.opacity
        let dimmed = blurred.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1 - darken, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 1 - darken, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 1 - darken, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])

        // ★ 用 cropRect 而不是 dimmed.extent:clampedToExtent() 之后
        //   extent 会变成无限大,直接拿去 createCGImage 会失败。
        guard let out = ciContext.createCGImage(dimmed, from: cropRect) else { return nil }

        // size 传屏幕点尺寸,让 SwiftUI 里 resizable 时按屏幕铺满。
        // (裁切之后像素比例已经 == displaySize 的比例,这里不再有矛盾。)
        return NSImage(cgImage: out, size: displaySize)
    }

    private static func thumbnail(from source: CGImageSource,
                                  maxPixel: Int,
                                  preferEmbedded: Bool) -> CGImage? {
        var options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            // 顺带处理 EXIF 旋转,否则竖拍的照片会躺着
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        options[preferEmbedded
                ? kCGImageSourceCreateThumbnailFromImageIfAbsent
                : kCGImageSourceCreateThumbnailFromImageAlways] = true

        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

//
//  LaunchPad —— macOS 启动台
//
//  作者:阿星
//  创作者-星之所向-阿星陪你走过丝绸之路
//
//  一句话:把系统启动台的手感找回来。7 列大图标、文件夹、拖动排序、
//  模糊壁纸背景、全局快捷键,滚动不卡。
//
//  本项目以 MIT 协议开源,详见仓库根目录的 LICENSE 文件。
//  如果你也在做自己的小工具,欢迎交流。
//

import AppKit
import SwiftUI
import Carbon.HIToolbox

/// 全局快捷键的 four-char 签名 'LPAD'
private let kHotKeySignature: OSType = 0x4C504144

/// 诊断日志 —— 专门为了抓「截图后跳走」这个问题。
///
/// 为什么不靠猜:这个 bug 前后改过两次都没根治,每次都是"大概率是这样吧"。
/// 与其猜第三次,不如把真实事件流记下来:
/// 谁在什么时候被激活、失活那一瞬间前台是谁、延迟检查时前台又变成了谁。
///
/// 落盘位置:`~/Library/Application Support/LaunchPad/diagnostic.log`
/// 超过 200KB 自动清空,不会无限长。用户复现一次之后直接读这个文件即可。
enum Diag {
    private static let queue = DispatchQueue(label: "com.xingxing.launchpad.diag")

    static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/LaunchPad", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("diagnostic.log")
    }()

    /// 主线程卡顿探针的开关文件。
    /// 存在 = 开。用文件而不是环境变量,是因为用户要能"正常双击打开 app"就复现,
    /// 不该为了排查去开终端敲命令。
    static let dir: URL = url.deletingLastPathComponent()

    /// 不用 DateFormatter —— 它在 Swift 6 严格并发下不算 Sendable,
    /// 每次新建又要多花时间。直接拆 DateComponents 拼字符串,简单且无并发问题。
    private static func stamp() -> String {
        let c = Calendar.current.dateComponents([.hour, .minute, .second, .nanosecond],
                                                from: Date())
        return String(format: "%02d:%02d:%02d.%03d",
                      c.hour ?? 0, c.minute ?? 0, c.second ?? 0,
                      (c.nanosecond ?? 0) / 1_000_000)
    }

    static func log(_ message: String) {
        let line = "[\(stamp())] \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }

    /// 启动时调用:日志太长就清掉,避免无限增长。
    static func rotateIfNeeded() {
        let maxBytes = 200 * 1024
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int, size > maxBytes {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// 写一行明显的分隔,方便在日志里定位"这一次复现"
    static func markSession() {
        log(String(repeating: "=", count: 46))
        log("启动台启动 (pid \(ProcessInfo.processInfo.processIdentifier))")
    }
}

/// 主线程卡顿探针 —— 只在 `~/Library/Application Support/LaunchPad/perf.on` 存在时开。
///
/// ## 为什么需要它
///
/// 「用起来卡」是**主观描述**。要改就得先分清卡在哪一类:
///
///   - **主线程被打断**(CPU):滚动时在同步做图标解码 / 布局 / 字符串处理;
///   - **主线程没被打断**但画面仍不流畅(GPU / 合成):每帧贴图太重、
///     大图逐帧降采样、透明窗口混合……
///
/// 这两类的解法完全相反,猜错了就是白改。探针能把它们区分开。
///
/// ## 原理
///
/// 在**主队列**上挂一个 60Hz 的 `DispatchSourceTimer`。
/// 主队列只在主线程空闲时才跑 —— 所以"两次打点的实际间隔"就等于
/// **主线程被占住了多久**。
///
/// ## ★ 指标选择上踩过的坑(2026-09-15,值得记下来)
///
/// 第一版是"超过 40ms 就写一行日志"。压测时把阈值降到 18ms,结果:
///
///   - 同一份代码连跑两轮,掉帧次数 91 和 63 —— **波动 ±45%**;
///   - 关掉全部阴影那组反而"更差"(67 次),而阴影明明是额外开销;
///   - 看分布才发现:**探测点本身的常态间隔就是 20~26ms,不是 16.7ms**。
///
/// 也就是说 18ms 这条线**卡在噪声区里**了 —— 主队列 timer 有 leeway、
/// AppKit 事件循环本身也有抖动,20ms 的间隔大部分是调度抖动,不是真掉帧。
/// 拿它去比"谁掉帧少",比的是随机数。
///
/// 所以现在改成**分桶直方图**:不只看"超没超线",而是看整个分布
/// (p50 / p90 / p99 / max + 各区间计数),每 5 秒吐一行汇总。
/// 分档线选 18 / 25 / 33 / 50 / 100 —— 25ms ≈ 掉 1 帧,33ms ≈ 掉 2 帧,
/// 33 以上才是"人眼能明确看到顿一下"的量级。
///
/// ## 用法
///
///   touch "~/Library/Application Support/LaunchPad/perf.on"   # 打开
///   正常打开启动台、照常滚动/悬停/拖动                       # 复现
///   看 diagnostic.log 里的「卡顿探针汇总」行                   # 定位
///   rm 那个文件                                               # 关掉
///
/// 阈值(LP_STALL_MS)只决定"单条明细"的打印线,统计汇总不受它影响。
enum StallWatch {
    private static var timer: DispatchSourceTimer?

    static func startIfEnabled() {
        let flag = Diag.dir.appendingPathComponent("perf.on")
        guard FileManager.default.fileExists(atPath: flag.path) else { return }

        let itemThreshold = Double(ProcessInfo.processInfo.environment["LP_STALL_MS"] ?? "") ?? 40

        Diag.log(String(format: "卡顿探针已启动(明细阈值 %.0fms;每 5 秒出一行汇总)", itemThreshold))

        var last = DispatchTime.now()
        // ★ 第一次打点必须丢掉。timer 的首次 deadline 是 1 秒后,
        //   而 `last` 是在**启动瞬间**打的 —— 首次算出来的间隔恒等于 ~1000ms,
        //   是纯假的"卡顿"。(2026-09-15 自己踩过,害我以为首屏绘制卡了一秒。)
        var primed = false

        // 分桶:0) <18  1) 18~25  2) 25~33  3) 33~50  4) 50~100  5) >100
        let bounds: [Double] = [18, 25, 33, 50, 100]
        var buckets = [Int](repeating: 0, count: bounds.count + 1)
        var samples: [Double] = []
        var worst: Double = 0
        var lastSummary = DispatchTime.now()

        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 1, repeating: 1.0 / 60.0, leeway: .milliseconds(1))
        t.setEventHandler {
            let now = DispatchTime.now()
            let ms = Double(now.uptimeNanoseconds &- last.uptimeNanoseconds) / 1_000_000
            last = now

            guard primed else { primed = true; return }   // 首个采样只用来对齐基线

            samples.append(ms)
            if ms > worst { worst = ms }
            for (i, b) in bounds.enumerated() where ms < b { buckets[i] += 1; break }
            if ms >= (bounds.last ?? 100) { buckets[bounds.count] += 1 }

            if ms > itemThreshold {
                Diag.log(String(format: "卡顿探针:主线程被打断 %.0fms(正常应 ≈16.7ms)", ms))
            }

            // 每 5 秒吐一行分布汇总 —— 这个才是拿来对比的
            if Double(now.uptimeNanoseconds &- lastSummary.uptimeNanoseconds) / 1_000_000_000 >= 5 {
                lastSummary = now
                let s = samples.sorted()
                func pct(_ p: Double) -> Double {
                    s.isEmpty ? 0 : s[min(s.count - 1, Int(Double(s.count) * p))]
                }
                Diag.log(String(format:
                    "卡顿探针汇总:N=%d p50=%.0f p90=%.0f p99=%.0f max=%.0fms | 分档 <18:%d 18-25:%d 25-33:%d 33-50:%d 50-100:%d >100:%d",
                    s.count, pct(0.5), pct(0.9), pct(0.99), worst,
                    buckets[0], buckets[1], buckets[2], buckets[3], buckets[4], buckets[5]))
                samples.removeAll(keepingCapacity: true)
                buckets = [Int](repeating: 0, count: bounds.count + 1)
            }
        }
        t.resume()
        timer = t
    }
}

/// 真实帧间隔探针 —— 跟着显示器刷新走,能看见 GPU / 合成侧的掉帧。
///
/// ## 为什么光有 `StallWatch` 不够
///
/// `StallWatch` 量的是**主线程被占住的时长**。如果卡是因为 GPU 侧太重
/// (每帧贴图太多、离屏模糊、大图缩放合成),主线程其实很闲 ——
/// 探针会给出"一切正常",而用户眼睛看到的就是在掉帧。
///
/// 这两类问题的解法完全相反:
///   主线程忙   → 把工作挪到后台 / 缓存(IconCache 解决的就是这个)
///   GPU 忙     → 减少每帧的绘制层数、去掉离屏效果、别逐帧重采样
///
/// 所以要一个**直接盯着显示器刷新**的探针:`CADisplayLink` 每一帧回调一次,
/// 两次回调的间隔就是**这台机器实际呈现出来的一帧有多长**。
/// 掉帧、合成卡顿、显示器降速,全都会如实反映在这里。
///
/// ## 分档
///
/// 以 60Hz(16.7ms)为基准:
///   1 帧 16.7 / 2 帧 33.3 / 3 帧 50。所以:
///   - <18ms   正常
///   - 18~25    略超一帧(可能是抖动)
///   - 25~33    丢了 1 帧
///   - 33~50    丢了 2 帧   ← 肉眼开始能看出来
///   - >50      丢了 3 帧以上,明显顿
enum FrameWatch {
    private static var link: AnyObject?
    private static var target: FrameTickTarget?

    static func startIfEnabled(for view: NSView) {
        let flag = Diag.dir.appendingPathComponent("perf.on")
        guard FileManager.default.fileExists(atPath: flag.path) else { return }

        let t = FrameTickTarget()
        t.start()
        target = t

        let l = view.displayLink(target: t, selector: #selector(FrameTickTarget.tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l

        // 注意:`preferredFrameRateRange.maximum` 在 macOS 上返回的是 0
        // (它只对 iOS 有意义)。想要真实刷新率得问 NSScreen。
        // 60Hz → 一帧 16.7ms;120Hz(ProMotion)→ 8.3ms。
        // 这个数决定了"丢帧"的门槛该定在哪,所以必须算对。
        let hz = view.window?.screen?.maximumFramesPerSecond ?? 60
        Diag.log(String(format: "帧探针已启动(显示器 %dHz,一帧 %.1fms)", hz, 1000.0 / Double(hz)))
    }
}

/// `NSView.displayLink` 需要一个 Objective-C 目标对象,所以得有个 NSObject。
final class FrameTickTarget: NSObject {
    private var last = CACurrentMediaTime()
    private var samples: [Double] = []
    private var buckets = [Int](repeating: 0, count: 5)   // <18 / 18-25 / 25-33 / 33-50 / >50
    private var worst: Double = 0
    private var lastSummary = CACurrentMediaTime()
    private var dirty = false

    func start() {
        last = CACurrentMediaTime()
        lastSummary = last
        dirty = true
    }

    @objc func tick(_ link: Any?) {
        let now = CACurrentMediaTime()
        let ms = (now - last) * 1000
        last = now

        guard dirty else { return }   // 第一帧只用来对齐基线

        samples.append(ms)
        if ms > worst { worst = ms }
        if ms < 18 { buckets[0] += 1 }
        else if ms < 25 { buckets[1] += 1 }
        else if ms < 33 { buckets[2] += 1 }
        else if ms < 50 { buckets[3] += 1 }
        else { buckets[4] += 1 }

        guard now - lastSummary >= 5 else { return }
        lastSummary = now

        let s = samples.sorted()
        func pct(_ p: Double) -> Double { s.isEmpty ? 0 : s[min(s.count - 1, Int(Double(s.count) * p))] }
        let dropped = buckets[2] + buckets[3] + buckets[4]   // ≥25ms = 至少丢 1 帧
        Diag.log(String(format:
            "帧探针汇总:N=%d p50=%.1f p90=%.1f p99=%.1f max=%.0fms | 丢帧(≥25ms) %d 帧 %.1f%% | 分档 <18:%d 18-25:%d 25-33:%d 33-50:%d >50:%d",
            s.count, pct(0.5), pct(0.9), pct(0.99), worst,
            dropped, s.isEmpty ? 0 : Double(dropped) * 100 / Double(s.count),
            buckets[0], buckets[1], buckets[2], buckets[3], buckets[4]))

        samples.removeAll(keepingCapacity: true)
        buckets = [Int](repeating: 0, count: 5)
    }
}

/// ★ 无边框窗口的一个经典坑:`.borderless` 窗口的 `canBecomeKey` 默认是 **false**。
///   系统因此不给它键盘焦点 —— 表现就是「搜索框点不进去、文件夹改名打不了字」,
///   点上去毫无反应。必须子类化并手动放行这两个属性。
///   (这也解释了为什么之前改名框的焦点总被吞 —— 不全是延时的问题。)
final class LaunchpadWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    private var escMonitor: Any?
    private var hotKeyRef: EventHotKeyRef?

    /// 截图流程的"宽限期" —— 一旦看到截图相关进程被激活,这段时间内
    /// 不再把失活当成"用户切走了"。
    private var screenshotGraceUntil: Date?

    /// ★ 失活那一瞬间"距上次鼠标按下"过了多久(秒)。
    ///
    /// 为什么必须在失活瞬间采样,而不是 0.8 秒后再采:
    /// 截图时用户**马上就会开始框选**(鼠标按下),等 0.8 秒后再看,
    /// 就完全分不清"这次失活到底是点击造成的还是快捷键造成的"了。
    ///
    /// 这个值是区分"用户主动切走"和"某个 App 自己抢焦点"的关键证据:
    ///   - 点 Dock 图标 / 点别的窗口 → 失活瞬间鼠标刚按下过(≈0)
    ///   - 按快捷键触发截图(⌘⇧A 等) → 失活瞬间鼠标已经很久没动过(好几秒)
    ///
    /// ★ 来源 API 不需要任何权限(实测确认),别再用辅助功能那套。
    private var mouseAgeAtResign: TimeInterval = .greatestFiniteMagnitude

    /// ★ 失活那一瞬间,前台 App 是否有全屏遮罩(截图 UI 特征)。有则记下描述。
    ///
    /// 为什么也必须在这一瞬间采样:2026-09-15 的日志抓到了铁证 ——
    ///   失活瞬间(17:33:37.387): 前台窗口 = `1440x900@L27/a1.00`  ← 微信截图遮罩,在!
    ///   0.85 秒后检查时:         "无全屏遮罩"                  ← 已经关了
    /// 用户框选完遮罩就撤,等到 0.8 秒后再查,黄花菜都凉了。
    /// (顺带确认了微信截图遮罩的真实特征:铺满全屏 1440x900、层级 27、alpha 1.00,
    ///  层级比我们自己的 3 还高,所以截图时它盖在我们上面 —— 这是正常的。)
    private var overlayAtResign: String?

    /// 系统截图的三个 bundle id —— 2026-09-15 在本机实地查出来的,不是凭记忆:
    ///   /System/Library/CoreServices/screencaptureui.app   → com.apple.screencaptureui   (LSUIElement)
    ///   /System/Applications/Utilities/Screenshot.app      → com.apple.screenshot.launcher
    ///   命令行工具 /usr/sbin/screencapture                  → com.apple.screencapture
    /// 用精确集合而不是 contains 模糊匹配,免得用户装个名字带 screenshot 的第三方 app 被误伤。
    private static let screenCaptureBundleIDs: Set<String> = [
        "com.apple.screencaptureui",
        "com.apple.screencapture",
        "com.apple.screenshot.launcher",
    ]

    func applicationDidFinishLaunching(_ notification: Notification) {
        Diag.rotateIfNeeded()
        Diag.markSession()
        // ★ 把开关的**实际取值**写进日志。
        //   为什么必须记:压测脚本用 `open --env` 传 LP_OLDICON,
        //   如果不生效,两条路径会跑出**一模一样**的结果,而日志里看不出来 ——
        //   很容易得出"优化没用"的错误结论。宁可信日志,不信传参成功。
        Diag.log(String(format: "开关: LP_OLDICON=%@ LP_PROBE=%@ 屏幕倍数=%.0f",
                        ProcessInfo.processInfo.environment["LP_OLDICON"] ?? "(未设置)",
                        ProcessInfo.processInfo.environment["LP_PROBE"] ?? "(未设置)",
                        NSScreen.main?.backingScaleFactor ?? 0))
        StallWatch.startIfEnabled()
        setupWorkspaceObservers()
        setupGlobalHotkey()
        prewarmWallpaper()
        openWindow()
    }

    /// ★ v1.12:提前把模糊壁纸算好。
    ///
    /// 为什么要挪到开窗之前:
    ///   窗口现在设成 `isOpaque = true`(不透明)让 WindowServer 走快速合成路径,
    ///   代价是"壁纸还没算好"的那一瞬间会露出窗口底色(黑)。
    ///   冷启动算壁纸实测约 130ms(ImageIO 首次加载 + CIContext 创建)。
    ///   先算完再开窗,就完全看不到那一下黑 —— 而且算完会进 WallpaperBackground
    ///   的缓存,后面 LaunchpadRoot 再要就是 3ms 命中。
    ///
    /// 这段是同步的、会阻塞启动约 0~130ms。可以接受:进程启动本身更久,
    /// 而且 app 常驻内存,这个代价一辈子只付一次。
    private func prewarmWallpaper() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let t0 = Date()
        let img = WallpaperBackground.image(for: screen)
        let ms = Date().timeIntervalSince(t0) * 1000
        Diag.log(String(format: "预热壁纸: %@,耗时 %.0fms",
                        img == nil ? "没找到(将走毛玻璃兜底)" : "完成", ms))
    }

    /// 盯住"哪个 app 被激活了"。用来识别截图进程,以及记录事件流。
    private func setupWorkspaceObservers() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    @objc private func appDidActivate(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else { return }

        if app.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            Diag.log("事件 didActivate ← 自己(启动台)")
            return
        }

        let bid = (app.bundleIdentifier ?? "").lowercased()
        let name = app.localizedName ?? "?"

        if Self.screenCaptureBundleIDs.contains(bid) {
            // ★ 关键:截图进程一旦被激活,就开一段宽限期。
            //   截图结束后系统未必把焦点还给我们,靠"稍后看前台是谁"去猜太不稳,
            //   直接记下"刚刚在截图"这个事实。
            screenshotGraceUntil = Date().addingTimeInterval(1.5)
            Diag.log("事件 didActivate ← 截图进程 \(name)[\(bid)] → 开宽限期 1.5s")
            return
        }

        Diag.log("事件 didActivate ← \(name)[\(bid)]")
    }

    /// 点击 Dock 图标(窗口已关时)重新打开
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Diag.log("事件 shouldHandleReopen(点 Dock 图标)")
        openWindow()
        return false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        Diag.log("事件 becameActive")
    }

    private func ensureEscMonitor() {
        guard escMonitor == nil else { return }
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Esc
                // ★ 例外:正在文本框里输入(改文件夹名)时,Esc 应该由文本框自己处理
                //   (取消编辑),而不是把整个启动台关掉 —— 不然改一半名字全丢了。
                //   NSTextField 的编辑器是 NSTextView,用它来判断"是否正在输入"。
                if let responder = self?.window?.firstResponder, responder is NSTextView {
                    return event
                }
                self?.closeWindow(reason: "按了 Esc")
                return nil
            }
            return event
        }
    }

    /// ★★ 全局快捷键 ⌘⇧L —— 改用 Carbon RegisterEventHotKey
    ///
    /// 之前是这么写的(已废弃,别再改回去):
    ///     AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true])
    ///     NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { ... }
    ///
    /// 那段代码有两个致命问题:
    ///   1. addGlobalMonitorForEvents 是「监听系统里所有键盘事件」,必须拿「辅助功能」权限;
    ///   2. AXTrustedCheckOptionPrompt = true 会在「每次启动且无授权」时弹系统授权窗,
    ///      于是用户每次开启动台都被问一次「想使用辅助功能来控制这台电脑」。
    ///   而且 ad-hoc 签名每次重签 cdhash 都变,TCC 会把 app 当新 app,授权反复被撤销,
    ///   形成「授权→重签→失效→再弹窗」的死循环。
    ///
    /// RegisterEventHotKey 是「向系统注册一个热键」,不读取事件流,
    /// ★ 因此完全不需要辅助功能权限 —— 弹窗从根上消失。
    /// (Alfred / Raycast 这类工具用的就是这套。)
    /// 注意:local monitor(上面的 Esc)不需要权限,保持原样即可。
    private func setupGlobalHotkey() {
        // 1) 装事件处理器(必须是 C 闭包,不能捕获上下文,所以用 NSApp.delegate 拿自己)
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hkID = EventHotKeyID()
            let err = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hkID
            )
            if err == noErr, hkID.signature == kHotKeySignature {
                DispatchQueue.main.async {
                    (NSApp.delegate as? AppDelegate)?.openWindow()
                }
            }
            return noErr
        }, 1, &spec, nil, nil)

        // 2) 注册 ⌘⇧L(kVK_ANSI_L = 0x25 = 37,与旧实现同一个键)
        let hotKeyID = EventHotKeyID(signature: kHotKeySignature, id: 1)
        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_L),
            UInt32(cmdKey | shiftKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if status != noErr {
            // 注册失败也只是热键不可用,Dock 图标照常能唤起,不需要任何权限
            print("启动台:注册全局快捷键 ⌘⇧L 失败(状态码 \(status)),Dock 图标仍可使用。")
        }
    }

    deinit {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref) }
    }

    func openWindow() {
        Diag.log("打开窗口 (已有窗口=\(window != nil), 已有内容=\(window?.contentViewController != nil))")

        // 已有窗口且有内容 → 只前置,不重建内容(保留搜索/编辑模式/文件夹状态)
        if let existing = window, existing.contentViewController != nil {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let content = LaunchpadRoot { [weak self] in
            self?.closeWindow(reason: "点了空白处")
        }
        let hosting = NSHostingController(rootView: content)
        let win: NSWindow
        if let existing = window {
            win = existing
            win.contentViewController = hosting
        } else {
            win = LaunchpadWindow(
                contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                styleMask: [.borderless, .fullSizeContentView],
                backing: .buffered, defer: false
            )
            // ★ v1.12:改成**不透明**。
            //   我们的内容(模糊壁纸)本来就铺满整屏、没有任何透明区域,
            //   标成 transparent 只会让 WindowServer 每帧都得多做一次
            //   "窗口 × 桌面"的混合 —— 全屏窗口下这笔开销不小,直接省掉。
            //   前提:开窗前必须已经算好壁纸,否则会闪一下黑(见 prewarmWallpaper)。
            win.isOpaque = true
            win.backgroundColor = .black
            // ★ 层级保持 .floating(3):要浮在普通窗口之上,但不能盖住系统 UI。
            //   实测原生启动台打开时**菜单栏和 Dock 都是可见的**(看截图确认),
            //   所以绝不能提到 .statusBar(25)/ 菜单栏(24)/ Dock(20) 之上。
            //   (上一版提到 .statusBar 把菜单栏盖没了 —— 那是错的,别再改回去。)
            win.level = .floating
            win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            win.titlebarAppearsTransparent = true
            win.hasShadow = false
            win.contentViewController = hosting
            self.window = win
        }
        if let screen = NSScreen.main {
            win.setFrame(screen.frame, display: true)
            Diag.log("""
            窗口几何: screen.frame=\(screen.frame) visibleFrame=\(screen.visibleFrame)
                      win.frame=\(win.frame) contentLayoutRect=\(win.contentLayoutRect)
                      contentView.frame=\(win.contentView?.frame ?? .zero)
                      safeAreaInsets=\(win.contentView?.safeAreaInsets ?? .init())
            """)
        }
        ensureEscMonitor()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // 帧探针要挂在真实的视图上 —— 用 hosting 的 view,不是 contentView,
        // 这样量和刷新同步的正是"真正在画内容的那个视图"。
        if let v = win.contentViewController?.view {
            FrameWatch.startIfEnabled(for: v)
        }

        if LaunchpadProbe.isActive {
            // 布局完成后再量一次 —— 刚 setFrame 时量到的是我们设的值,
            // 真正可疑的是"被 NSHostingController 改过之后"的值。
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let w = self?.window else { return }
                let hv = w.contentViewController?.view
                Diag.log("""
                探针·延迟几何: win.frame=\(w.frame)
                          screen.frame=\(NSScreen.main?.frame ?? .zero)
                          contentView.frame=\(w.contentView?.frame ?? .zero)
                          hosting.view.frame=\(hv?.frame ?? .zero)
                          preferredContentSize=\(w.contentViewController?.preferredContentSize ?? .zero)
                """)
            }
        }
    }

    func closeWindow(reason: String = "未说明") {
        Diag.log("关窗 (原因: \(reason))")
        window?.orderOut(nil)
    }

    /// ★ 别的 App 抢到前台 → 我们收起
    ///
    /// 起因:点 Dock 里的其他 App,它其实启动了,只是被我们这个全屏浮窗盖在底下,
    ///       看起来像"点了没反应"。
    ///
    /// ⚠️ 但不能"一失活就立刻关" —— 截图会让本 app 失活。
    ///
    /// 这条逻辑改过四版。前三版都在纠结**系统截图**,第四版才想明白:
    /// 真正的坑是**第三方截图工具**(微信等) —— 它们不启动系统的截图进程,
    /// 而是**让主进程自己抢到前台**,然后铺一层全屏遮罩让你框选。
    /// 于是"前台是微信"这个现象,既可能是"用户切到微信",也可能是"微信在截图",
    /// **光看 app 名字根本区分不了**。
    ///
    /// 第四版换了个维度:不看是谁,看**这次失活是怎么发生的**。
    ///   微信截图  → 用户按的是快捷键(⌘⇧A),失活瞬间鼠标已经很久没动 → 不是点击切换
    ///   切到微信  → 用户点了 Dock 图标或微信窗口,失活瞬间鼠标刚按下 → 是点击切换
    ///
    /// 这个判断在 `applicationDidResignActive` 的**第一行**就要采样,
    /// 因为截图一开始用户就会去框选(鼠标按下),晚 0.8 秒再采就废了。
    func applicationDidResignActive(_ notification: Notification) {
        // ★ 调试探针模式(见 LaunchpadProbe)下不要自动收窗 ——
        //   探针是为了"进了文件夹截张图",窗口一收就白跑了。
        guard !LaunchpadProbe.isActive else { return }

        // ★★ 两个关键证据都必须在这里采样,不能放进下面的延迟回调 ——
        //    截图一开始用户就会去框选(鼠标按下)、遮罩也会很快撤掉,
        //    晚 0.8 秒再采,两个证据全废。这一行是整个修复的命门。
        mouseAgeAtResign = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState, eventType: .leftMouseDown
        )
        overlayAtResign = Self.frontAppFullScreenOverlay()

        Diag.log(String(format: "事件 resignActive (front=%@, 距上次鼠标按下=%.3fs, 全屏遮罩=%@)",
                        Self.describe(NSWorkspace.shared.frontmostApplication),
                        mouseAgeAtResign,
                        overlayAtResign ?? "无"))
        Diag.log("  前台 App 的在屏窗口: \(Self.describeFrontAppWindows())")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }
            guard let win = self.window, win.isVisible else {
                Diag.log("  延迟检查: 窗口本来就没显示,无需处理")
                return
            }

            if NSApp.isActive {
                Diag.log("  延迟检查: 已重新激活 → 不动")
                return
            }

            // ── 第一组:系统截图(screencaptureui 那套) ──

            // ① 系统里还有最近启动的截图进程 → 截图流程中
            if let hit = Self.runningScreenCaptureProcess() {
                Diag.log("  延迟检查: 截图进程仍在运行 [\(hit)] → 抢回焦点")
                self.reclaimFocus()
                return
            }

            // ② 刚刚看到过系统截图进程被激活,且还在宽限期内
            if let until = self.screenshotGraceUntil, Date() < until {
                Diag.log(String(format: "  延迟检查: 截图宽限期内(还剩 %.2fs) → 抢回焦点",
                                until.timeIntervalSinceNow))
                self.reclaimFocus()
                return
            }

            // ── 第二组:第三方截图的判据 ──
            //
            // ★ 顺序很重要:先看"有没有全屏遮罩",再看"鼠标点没点过"。
            //   因为遮罩是**更本质**的证据 —— 不管是快捷键还是点菜单触发的截图,
            //   它都得铺一层全屏遮罩让你框选。先判它,能覆盖更多触发方式。

            // ③ ★ 失活**那一瞬间**前台铺着全屏遮罩 → 铁证:它在截图
            //    (必须是失活瞬间采的那个值 —— 0.8 秒后遮罩早撤了,实测过)
            if let overlay = self.overlayAtResign {
                Diag.log("  延迟检查: 失活瞬间有全屏遮罩 [\(overlay)] → 判定为截图,抢回焦点")
                self.screenshotGraceUntil = Date().addingTimeInterval(2.0)
                self.reclaimFocus()
                return
            }

            // ③b 兜底:此刻仍然有遮罩(有些截图工具遮罩停留更久)
            if let overlay = Self.frontAppFullScreenOverlay() {
                Diag.log("  延迟检查: 当前仍有全屏遮罩 [\(overlay)] → 判定为截图,抢回焦点")
                self.screenshotGraceUntil = Date().addingTimeInterval(2.0)
                self.reclaimFocus()
                return
            }

            // ④ 失活那一瞬间鼠标刚按下过 → 这是"点出来的"切换,用户主动的
            if self.mouseAgeAtResign < 0.5 {
                Diag.log(String(format: "  延迟检查: 失活时鼠标刚按下(%.3fs) → 判定用户主动切走,关窗",
                                self.mouseAgeAtResign))
                self.closeWindow(reason: "失活由鼠标点击引起")
                return
            }

            // ── 第三组:兜底 ──

            // ⑤ 前台是系统浮层(截屏/录屏 UI)
            if let front = NSWorkspace.shared.frontmostApplication,
               Self.isTransientSystemUI(front) {
                Diag.log("  延迟检查: 前台是系统浮层 \(Self.describe(front)) → 抢回焦点")
                self.reclaimFocus()
                return
            }

            // ⑥ 没有前台 App
            if NSWorkspace.shared.frontmostApplication == nil {
                Diag.log("  延迟检查: 没有前台 App → 抢回焦点")
                self.reclaimFocus()
                return
            }

            Diag.log(String(format: "  延迟检查: 前台是 %@,鼠标已 %.1fs 未动,也无全屏遮罩 → 判定为用户切走,关窗",
                            Self.describe(NSWorkspace.shared.frontmostApplication),
                            self.mouseAgeAtResign))
            self.closeWindow(reason: "失活后前台变成了普通 App")
        }
    }

    /// 把焦点抢回来。窗口还在、只是系统把前台给了别人时用。
    private func reclaimFocus() {
        guard let win = window, win.isVisible else { return }
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        Diag.log("  → 已重新激活自己并前置窗口")
    }

    // MARK: - 截图特征识别

    /// 前台 App 是否铺了一个**覆盖整块屏幕**的窗口。
    ///
    /// 这是截图工具的通用特征 —— 无论系统还是微信,要让你框选就必须先盖住整个屏幕。
    /// 光看 app 名字区分不了"切到微信"和"微信在截图",但"有没有全屏遮罩"可以。
    ///
    /// 判定条件(两步,缺一不可,避免误伤正常全屏的 App):
    ///   1. 窗口覆盖了某块屏幕的 95% 以上
    ///   2. 且它是个浮层(层级 > 0)**或**半透明(alpha < 0.98)
    ///      —— 这两点把"全屏 Chrome/浏览器"这类 alpha=1、layer=0 的正常窗口排除掉
    private static func frontAppFullScreenOverlay() -> String? {
        guard let front = NSWorkspace.shared.frontmostApplication,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
                as? [[String: Any]]
        else { return nil }

        let pid = front.processIdentifier

        for w in list {
            guard (w[kCGWindowOwnerPID as String] as? Int) == Int(pid) else { continue }
            guard let b = w[kCGWindowBounds as String] as? [String: Any] else { continue }

            let width = b["Width"] as? Double ?? 0
            let height = b["Height"] as? Double ?? 0
            let layer = w[kCGWindowLayer as String] as? Int ?? 0
            let alpha = w[kCGWindowAlpha as String] as? Double ?? 1

            guard coversAnyScreen(width: width, height: height) else { continue }
            guard layer > 0 || alpha < 0.98 else { continue }

            return String(format: "%.0fx%.0f layer=%d alpha=%.2f", width, height, layer, alpha)
        }
        return nil
    }

    /// 这个尺寸是否足以覆盖某块屏幕。只比宽高不比位置 ——
    /// CGWindowList 是左上原点、NSScreen 是左下原点,比位置要换算,比宽高就不用。
    private static func coversAnyScreen(width: Double, height: Double) -> Bool {
        for screen in NSScreen.screens {
            let f = screen.frame
            if width >= f.width * 0.95 && height >= f.height * 0.95 { return true }
        }
        return false
    }

    /// 纯诊断用:把前台 App 所有在屏窗口的尺寸/层级/透明度写进日志。
    /// 万一遮罩特征的假设不成立,这行日志能直接告诉我微信截图窗口长什么样。
    private static func describeFrontAppWindows() -> String {
        guard let front = NSWorkspace.shared.frontmostApplication,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
                as? [[String: Any]]
        else { return "(拿不到)" }

        let pid = front.processIdentifier
        var parts: [String] = []

        for w in list {
            guard (w[kCGWindowOwnerPID as String] as? Int) == Int(pid) else { continue }
            let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
            let width = b["Width"] as? Double ?? 0
            let height = b["Height"] as? Double ?? 0
            let layer = w[kCGWindowLayer as String] as? Int ?? 0
            let alpha = w[kCGWindowAlpha as String] as? Double ?? 1
            parts.append(String(format: "%.0fx%.0f@L%d/a%.2f", width, height, layer, alpha))
        }
        return parts.isEmpty ? "(该 App 无在屏窗口)" : parts.joined(separator: "  ")
    }

    /// 系统里是否有**正在截图**的相关进程。有则返回可读描述,没有返回 nil。
    ///
    /// 用 `NSWorkspace.runningApplications` 而不是 shell 命令:
    /// 它包含 LSUIElement 的 agent 进程(screencaptureui 正是这类),且不 fork 子进程。
    /// (实测 appex 类扩展如 ScreenshotControls **不会**出现在这个列表里,所以不会被误收。)
    ///
    /// ★ `maxAge` 这道过滤是必须的,不是保险起见 ——
    ///   2026-09-15 日志里抓到一次误伤:用户主动切到别的 App 时,因为系统里残留着
    ///   一个截图进程,焦点被硬抢回启动台。人不可能"开着截图工具就一直呆在启动台"。
    ///   所以只认**最近才启动**的截图进程 = 真的在进行一次截图。
    ///   (实测 screencaptureui 是按需启动、用完即退,不是常驻守护进程。)
    private static func runningScreenCaptureProcess(maxAge: TimeInterval = 25) -> String? {
        for app in NSWorkspace.shared.runningApplications {
            let bid = (app.bundleIdentifier ?? "").lowercased()
            guard screenCaptureBundleIDs.contains(bid) else { continue }

            var freshness = "(启动时间未知)"
            if let launched = app.launchDate {
                let age = Date().timeIntervalSince(launched)
                if age > maxAge { continue }   // 启动太久 → 不是"正在截图"
                freshness = String(format: "(%.0f 秒前启动)", age)
            }

            return "\(app.localizedName ?? "?")[\(bid)] pid=\(app.processIdentifier) \(freshness)"
        }
        return nil
    }

    /// 截图 / 录屏这类系统浮层,不算"用户切到了别的 App"。
    private static func isTransientSystemUI(_ app: NSRunningApplication) -> Bool {
        let bundleID = (app.bundleIdentifier ?? "").lowercased()
        let name = (app.localizedName ?? "").lowercased()
        return screenCaptureBundleIDs.contains(bundleID)
            || bundleID.contains("screencapture")
            || bundleID.contains("screenshot")
            || name.contains("截屏")
            || name.contains("截图")
            || name.contains("screenshot")
    }

    /// 给日志用的可读描述
    private static func describe(_ app: NSRunningApplication?) -> String {
        guard let app else { return "nil" }
        return "\(app.localizedName ?? "?")[\(app.bundleIdentifier ?? "?")]"
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
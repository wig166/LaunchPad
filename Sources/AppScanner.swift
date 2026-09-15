import Foundation

enum AppScanner {
    /// 扫描所有 .app,覆盖 4 个位置:
    ///   /Applications                                  用户自己装的
    ///   ~/Applications                                 当前用户装的
    ///   /System/Applications                           ★ 系统自带:Mail / 日历 / 备忘录 /
    ///                                                    Safari / 地图 / 照片 / 音乐 /  …
    ///                                                    (不扫这里会直接少掉三四十个)
    ///   /Library/Apple/usr/share/Managed Applications   Apple 额外投放的内置 App
    /// 关键:用 enumerator + skipsPackageDescendants,绝不钻进 .app 包内部
    /// (Xcode 这种包里有几万个文件,钻进去就是秒级卡顿)
    /// 只列目录,绝不碰 AppKit —— 图标交给格子按需后台加载
    static func scan() -> [AppItem] {
        let fm = FileManager.default
        var dirs: [URL] = []

        for domain in [FileManager.SearchPathDomainMask.localDomainMask, .userDomainMask] {
            if let u = try? fm.url(for: .applicationDirectory, in: domain, appropriateFor: nil, create: false) {
                dirs.append(u)
            }
        }

        let systemApps = URL(fileURLWithPath: "/System/Applications")
        if fm.fileExists(atPath: systemApps.path) { dirs.append(systemApps) }

        let managed = URL(fileURLWithPath: "/Library/Apple/usr/share/Managed Applications")
        if fm.fileExists(atPath: managed.path) { dirs.append(managed) }

        let opts: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
        var seen = Set<String>()
        var items: [AppItem] = []
        for dir in dirs {
            guard let enumr = fm.enumerator(at: dir, includingPropertiesForKeys: nil, options: opts) else { continue }
            for case let url as URL in enumr {
                guard url.path.hasSuffix(".app") else { continue }
                if seen.contains(url.path) { continue }
                seen.insert(url.path)
                let name = displayName(for: url)
                items.append(AppItem(name: name, path: url))
            }
        }
        return items.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// 显示名:优先取本地化名,再取 Info.plist 原始名,最后回退文件名。
    /// 直接用 .app 文件名是错的 —— "WeChat.app" 会永远显示 "WeChat",
    /// "TencentMeeting.app" 永远显示 "TencentMeeting",而不是"微信""腾讯会议"。
    ///
    /// 四级顺序(实测 105 个 app 验证过,65 个被正确本地化):
    ///   1. localizedInfoDictionary["CFBundleDisplayName"]   ← 微信/日历/备忘录 走这条
    ///   2. infoDictionary["CFBundleDisplayName"]
    ///   3. localizedInfoDictionary["CFBundleName"]          ← 邮件(Mail)走这条
    ///   4. infoDictionary["CFBundleName"]
    ///   5. 文件名兜底
    /// 为什么 3 不能省:Mail.app 只有 CFBundleName 没有 CFBundleDisplayName,
    /// 且它的 zh_CN.lproj 里根本没有 InfoPlist.strings,
    /// 中文名"邮件"由 LaunchServices 系统本地化表(LSHasLocalizedDisplayName)提供,
    /// 只能靠 localizedInfoDictionary 拿到。
    ///
    /// ★ 前置条件(极易踩):localizedInfoDictionary 内部用
    ///   Bundle.main.preferredLocalizations 决定语言。主 bundle 若没在 Info.plist
    ///   声明 CFBundleLocalizations,该值会回退到 en,于是所有 app 名都变英文。
    ///   本项目 Info.plist 已显式声明,不要删。
    ///
    /// 性能:105 个 app 约 0.2s,跑在后台线程,不阻塞 UI。
    private static func displayName(for url: URL) -> String {
        let fallback = url.deletingPathExtension().lastPathComponent
        guard let bundle = Bundle(url: url) else { return fallback }
        let loc = bundle.localizedInfoDictionary ?? [:]
        let info = bundle.infoDictionary ?? [:]
        if let s = loc["CFBundleDisplayName"] as? String, !s.isEmpty { return s }
        if let s = info["CFBundleDisplayName"] as? String, !s.isEmpty { return s }
        if let s = loc["CFBundleName"] as? String, !s.isEmpty { return s }
        if let s = info["CFBundleName"] as? String, !s.isEmpty { return s }
        return fallback
    }
}
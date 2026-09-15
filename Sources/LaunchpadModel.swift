import Foundation

// MARK: - AppItem (stable id = path, so folder structure survives rescans)
struct AppItem: Identifiable, Hashable, Codable {
    let name: String
    let pathString: String

    var id: String { pathString }
    var path: URL { URL(fileURLWithPath: pathString) }

    init(name: String, path: URL) {
        self.name = name
        self.pathString = path.path
    }
}

// MARK: - Folder
struct FolderItem: Identifiable, Hashable, Codable {
    var id: String        // UUID 字符串,稳定
    var name: String
    var apps: [AppItem]

    init(id: String = UUID().uuidString, name: String = "文件夹", apps: [AppItem] = []) {
        self.id = id
        self.name = name
        self.apps = apps
    }
}

// MARK: - 顶层条目(enum 关联值,Codable 自动处理)
enum LaunchpadItem: Identifiable, Hashable, Codable {
    case app(AppItem)
    case folder(FolderItem)

    var id: String {
        switch self {
        case .app(let a): return "app:" + a.id
        case .folder(let f): return "folder:" + f.id
        }
    }

    var name: String {
        switch self {
        case .app(let a): return a.name
        case .folder(let f): return f.name
        }
    }
}

// MARK: - 整个启动台结构(可存盘)
struct LaunchpadStructure: Codable {
    var topLevel: [LaunchpadItem] = []

    func allAppPaths() -> Set<String> {
        var set = Set<String>()
        for item in topLevel {
            switch item {
            case .app(let a): set.insert(a.pathString)
            case .folder(let f): for a in f.apps { set.insert(a.pathString) }
            }
        }
        return set
    }

    func findItem(id: String) -> LaunchpadItem? {
        topLevel.first(where: { $0.id == id })
    }

    // 合并:扫描结果 + 已存结构
    // 规则:结构里的 app 保留位置,名称/路径更新;缺失的 app 移除;空文件夹丢弃;
    //      新扫描到的 app 追加到末尾
    mutating func merge(with scanned: [AppItem]) {
        let scannedByPath = Dictionary(uniqueKeysWithValues: scanned.map { ($0.pathString, $0) })
        var seen = Set<String>()
        var newTop: [LaunchpadItem] = []

        for item in topLevel {
            switch item {
            case .app(let a):
                if let updated = scannedByPath[a.pathString] {
                    newTop.append(.app(updated))
                    seen.insert(a.pathString)
                }
                // 扫描不到的 app → 丢弃
            case .folder(var f):
                let kept = f.apps.compactMap { scannedByPath[$0.pathString] }
                if !kept.isEmpty {
                    f.apps = kept
                    newTop.append(.folder(f))
                    for a in kept { seen.insert(a.pathString) }
                }
                // 空文件夹 → 丢弃
            }
        }
        for app in scanned where !seen.contains(app.pathString) {
            newTop.append(.app(app))
        }
        topLevel = newTop
    }

    // MARK: - 拖动排序

    /// 把一个顶层条目移动到指定位置(拖动排序用)。
    ///
    /// `index` 的约定:**基于"已排除被拖动项"的数组**的下标。
    /// 因为 UI 那边算落点位置时,画面上本来就不显示被拖的那个格子
    /// (它跟着鼠标走了),所以算出来的下标天然是"排除后"的。
    /// 两边用同一套约定,这里就**不需要**再做 `if target > from { target -= 1 }`
    /// 那种修正 —— 那种修正用错一次就会偏一位,是排序 bug 的常见来源。
    mutating func moveItem(id: String, to index: Int) {
        guard let from = topLevel.firstIndex(where: { $0.id == id }) else { return }
        let item = topLevel.remove(at: from)
        let target = max(0, min(index, topLevel.count))
        topLevel.insert(item, at: target)
    }

    /// 拖一个 app 到另一个 app → 新建文件夹
    // ★ 文件夹要落在「被拖到的那一方(target)」原来的位置上。
    //   老实现用 topLevel.append(),所以不管拖到哪,新文件夹都跑到列表最末尾
    //   (视觉上 = 最下面)。实测发现过这个问题。
    mutating func createFolder(with dragged: AppItem, containing target: AppItem) {
        let folder = FolderItem(name: "文件夹", apps: [target, dragged])

        // 先移除被拖动的 app —— 这一步会改变数组结构(如果它原本在某个文件夹里,
        // 那个文件夹可能因为只剩 1 个而被拆开),所以 target 的下标
        // 必须在移除之后重新查找,不能提前算好。
        removeApp(dragged)

        if let idx = topLevel.firstIndex(where: {
            if case .app(let a) = $0 { return a.pathString == target.pathString }
            return false
        }) {
            topLevel[idx] = .folder(folder)   // 就地替换 → 文件夹出现在原位置
        } else {
            // 兜底:target 不在顶层(正常流程不会发生),退回追加
            topLevel.append(.folder(folder))
        }
    }

    // 拖一个 app 到已有文件夹 → 加入文件夹
    mutating func addAppToFolder(_ app: AppItem, folderID: String) {
        guard appExists(pathString: app.pathString) else { return }
        removeApp(app)
        guard let idx = topLevel.firstIndex(where: {
            if case .folder(let f) = $0 { return f.id == folderID }
            return false
        }) else { return }
        if case .folder(var folder) = topLevel[idx] {
            // 去重
            if !folder.apps.contains(where: { $0.pathString == app.pathString }) {
                folder.apps.append(app)
            }
            topLevel[idx] = .folder(folder)
        }
    }

    // 从文件夹里移除一个 app(放回顶层)
    mutating func removeApp(_ app: AppItem) {
        for i in 0..<topLevel.count {
            if case .folder(var f) = topLevel[i], f.apps.contains(where: { $0.pathString == app.pathString }) {
                f.apps.removeAll { $0.pathString == app.pathString }
                if f.apps.isEmpty {
                    topLevel.remove(at: i)
                } else if f.apps.count == 1 {
                    // 只剩一个了,自动拆掉文件夹
                    topLevel[i] = .app(f.apps[0])
                } else {
                    topLevel[i] = .folder(f)
                }
                return
            }
        }
        // 顶层就直接删除
        topLevel.removeAll { item in
            if case .app(let a) = item { return a.pathString == app.pathString }
            return false
        }
    }

    /// 把 app 从文件夹里拿出来、放回顶层(文件夹内页把图标拖出去用)。
    ///
    /// ★ 不能复用 `removeApp` —— 那个方法的语义是"把这个 app 从结构里摘掉"
    ///   (给 createFolder / addAppToFolder 用,app 马上会被放进新地方),
    ///   它**不会**把 app 加回 topLevel。文件夹内页的"拖出去"如果走它,
    ///   app 会从启动台上彻底消失,直到下次重启扫描才回来 —— 这是个真 bug。
    ///
    /// 位置:插在文件夹**后面一格**,视觉上就是"从文件夹里拿出来,放在旁边"。
    mutating func moveAppToTopLevel(_ app: AppItem) {
        var folderIndex: Int?
        for i in 0..<topLevel.count {
            if case .folder(var f) = topLevel[i],
               f.apps.contains(where: { $0.pathString == app.pathString }) {
                f.apps.removeAll { $0.pathString == app.pathString }
                folderIndex = i
                // 文件夹只剩这一个 app 被拿走后的三种收尾,和 removeApp 一致
                if f.apps.isEmpty {
                    topLevel.remove(at: i)
                } else if f.apps.count == 1 {
                    topLevel[i] = .app(f.apps[0])
                } else {
                    topLevel[i] = .folder(f)
                }
                break
            }
        }
        guard let idx = folderIndex else { return }
        topLevel.insert(.app(app), at: min(idx + 1, topLevel.count))
    }

    /// 文件夹**内部**的拖动排序。
    ///
    /// `index` 的约定和 `moveItem` 一样:**基于"已排除被拖项"的数组**的下标 ——
    /// UI 算落点时被拖的图标不在网格里,两边必须用同一套约定,否则会错一位。
    mutating func moveAppInFolder(folderID: String, appPath: String, to index: Int) {
        guard let fi = topLevel.firstIndex(where: {
            if case .folder(let f) = $0 { return f.id == folderID }
            return false
        }),
        case .folder(var f) = topLevel[fi],
        let from = f.apps.firstIndex(where: { $0.pathString == appPath }) else { return }

        let app = f.apps.remove(at: from)
        f.apps.insert(app, at: max(0, min(index, f.apps.count)))
        topLevel[fi] = .folder(f)
    }

    // 整个文件夹删除(里面的 app 全部回到顶层)
    mutating func removeFolder(id: String) {        var restored: [AppItem] = []
        topLevel.removeAll { item in
            if case .folder(let f) = item, f.id == id {
                restored = f.apps
                return true
            }
            return false
        }
        topLevel.append(contentsOf: restored.map { LaunchpadItem.app($0) })
    }

    // 重命名文件夹
    mutating func renameFolder(id: String, to newName: String) {
        guard let idx = topLevel.firstIndex(where: {
            if case .folder(let f) = $0 { return f.id == id }
            return false
        }) else { return }
        if case .folder(var f) = topLevel[idx] {
            f.name = newName.isEmpty ? "文件夹" : newName
            topLevel[idx] = .folder(f)
        }
    }

    private func appExists(pathString: String) -> Bool {
        for item in topLevel {
            switch item {
            case .app(let a): if a.pathString == pathString { return true }
            case .folder(let f): if f.apps.contains(where: { $0.pathString == pathString }) { return true }
            }
        }
        return false
    }
}

// MARK: - 持久化
enum LaunchpadStorage {
    static var storageURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("LaunchPad", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("structure.json")
    }

    static func load() -> LaunchpadStructure {
        guard let data = try? Data(contentsOf: storageURL),
              let s = try? JSONDecoder().decode(LaunchpadStructure.self, from: data) else {
            return LaunchpadStructure()
        }
        return s
    }

    static func save(_ structure: LaunchpadStructure) {
        guard let data = try? JSONEncoder().encode(structure) else { return }
        try? data.write(to: storageURL, options: .atomic)
    }
}
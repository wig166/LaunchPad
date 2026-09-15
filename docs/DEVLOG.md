# 开发日志

> 这里按时间顺序记录每个版本解决了什么问题、怎么定位的。
> 有点长,但每个坑都是真踩过的 —— 给同样想写一个启动台的人参考。

---

# 启动台 LaunchPad（自制的 macOS 启动台替代）

自己做的启动台 app，**不挑系统版本**，Sequoia / Tahoe 26 / macOS 27 都能用——等于把"系统给不给启动台"这事儿一脚踢开。

## 怎么用
1. 打开 `LaunchPad.app`（已装好：`/Applications/LaunchPad.app`）。
   - 如果弹出"无法验证开发者"：右键 → 打开；或去 **系统设置 → 隐私与安全性 → 底部"仍要打开"**。
2. 点 **Dock** 里的启动台图标 → 全屏毛玻璃启动台弹出（缩放淡入，不是硬切）。
3. 点任意 app 图标即打开，窗口自动关闭。
4. **搜索**：顶部搜索框过滤；右边 `x` 一键清空。
5. **文件夹**：
   - 点右上角 **编辑** 进入编辑模式（图标会像 iPhone 一样抖起来）。
   - **拖一个 app 到另一个 app** → 创建新文件夹。
   - **拖一个 app 到已有文件夹** → 加进去。
   - **编辑模式下点文件夹** → 弹"删除文件夹？"，删了里面的 app 回到顶层。
   - **进文件夹之后**（v1.11 起精简过，见下文）：
     - **双击文件夹名** → 改名（这是唯一的改名入口）。
     - **点空白处** → 回启动台主页。
     - **拖图标到 grid 外的空白处** → 把 app 移出文件夹（回顶层）。
     - 顶栏不再有「返回」「编辑」按钮，名字旁边那个铅笔图标也删了 ——
       原因见 v1.11 那一章，不是偷懒。
   - 右上角显示当前 app 总数。
6. 按 `Esc` 或点空白处（非编辑模式）关闭窗口；不重置搜索/文件夹状态。
   ★ 在**文件夹里**点空白处是"回主页"，不是关窗。
7. **全局快捷键** `⌘⇧L` 随时唤起。
   ★ v1.7 起**不需要任何辅助功能权限**（改用 Carbon 热键注册，见下文），不用再去系统设置里打勾。

## 文件夹结构存在哪
`~/Library/Application Support/LaunchPad/structure.json`。删掉这个文件 =回到全新平铺。

## 装在哪 / 怎么重建
- **唯一副本**：`/Applications/LaunchPad.app`。
- ★ **绝对不要在别的地方再放一份**。两处同时存在会让 LaunchServices 注册出两条记录，
  TCC 认错 app，表现就是"明明授权了还反复弹窗"（2026-09-01 踩过这个坑）。
- 改完源码跑 `./build.sh`：编译 + 拷 Info.plist + 拷图标 + 重签 + 装到 `/Applications`，一步到位。

### Dock 图标还是旧的？刷新缓存
改了 `.icns` 之后 macOS 不会立刻换，跑这两条：
```
killall Dock
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f -R "/Applications/LaunchPad.app"
```
还不行就把 Dock 上的图标拖掉、重新拖一次（拖掉时"移除"不是"废纸篓"，不会删文件）。

## 技术要点（给你以后想改时参考）
- 扫 4 个位置的所有 `.app` → `Sources/AppScanner.swift`：
  `/Applications`、`~/Applications`、**`/System/Applications`**（系统自带 61 个在这）、
  `/Library/Apple/usr/share/Managed Applications`
- 数据模型 + 文件夹 + JSON 持久化 → `Sources/LaunchpadModel.swift`
- 图标网格 + 文件夹 + 动画 + 搜索 → `Sources/AppGrid.swift`（SwiftUI + NSVisualEffectView）
- 入口：NSApplication + 无边框 floating 窗口，点 Dock 唤起 → `Sources/main.swift`
- 重新编译（改完代码后）：
  ```
  cd LaunchPad
  swiftc -O Sources/AppScanner.swift Sources/LaunchpadModel.swift Sources/AppGrid.swift Sources/main.swift \
    -o LaunchPad.app/Contents/MacOS/LaunchPad -framework AppKit -framework SwiftUI -framework ApplicationServices
  ```
  再签名：
  ```
  codesign --force --deep --sign - LaunchPad.app
  ```

## v1.1 性能修复（之前卡死的根源）
1. **扫描在主线程同步跑 + 每个 app 都同步取图标** → 几百个图标查询堵死主线程。
2. **`subpathsOfDirectory` 钻进 .app 包内部** → Xcode 几万文件，扫描 7.6 秒。

改法：
- 扫描改用 `enumerator` + `skipsPackageDescendants`，**绝不钻进 .app 内部** → 0.03s，纯目录枚举。
- 图标按需后台线程取，配合 `LazyVGrid` 只加载屏幕上能看见的那几十个。
- 窗口秒开先显示"正在载入 App…"loading，后台扫完再填数据。

## v1.2 这版干了啥
1. **文件夹**：可拖拽创建、可改名、可删除；进文件夹用缩放过渡；状态持久化到 `~/Library/Application Support/LaunchPad/structure.json`。
2. **丝滑**：
   - 窗口从中心缩放淡入（spring 0.48s）
   - 单个格子淡入 + 微缩放
   - 鼠标悬停格子放大 1.07，被拖入时放大 1.16 并亮出白色高亮框
     （v1.3 起取消了"按下缩到 0.90"——那个手势会抢走拖拽）
   - 编辑模式所有图标 iOS 那样正弦抖动
   - 文件夹进/出用 scale+opacity 过渡
3. **新图标**：蓝紫渐变背景 + 4 个真彩色"app 块"（红橙绿蓝各自带投影+顶光），不再是蓝底白格。

## v1.3 这版干了啥（7 个问题全修）
1. **漏 app（原来 46 → 现在 107）**：之前只扫 `/Applications` + `~/Applications`，
   **`/System/Applications` 完全没扫**——Mail / 日历 / 备忘录 / Safari / 地图 / 照片 / FaceTime
   全在那儿。补上后实测 **107 个**（其中 61 个是系统自带），扫描耗时 0.041s。
2. **点 Dock 其他 app 没反应**：不是没反应，是那个 app **启动了但被我们的全屏浮窗盖在底下**。
   改法：加 `applicationDidResignActive` —— 别的 app 一抢到前台，我们立刻自己收起来。
3. **拖不动、建不了文件夹**（关键）：
   格子上的 `.simultaneousGesture(DragGesture(minimumDistance: 0))`（按下缩放那个）
   **在跟 `.draggable` 抢手势主动权**，导致拖拽永远起不来。已删掉；
   按下反馈改用 hover / 拖入高亮来做。现在拖 app 到 app 上 = 建文件夹，拖到文件夹 = 加进去。
   顺带把根视图上的 `LongPressGesture` 也删了（同样抢拖拽事件）。
4. **编辑按钮看不清**：原来是"白底 + 白字"，在亮壁纸上等于隐形。
   改成**深底 + 白字 + 白描边 + 图标 + 投影**；编辑态变蓝底，并且左边多了操作提示条。
5. **编辑模式下不能拖**：同上第 3 条，同一个手势冲突，一并修好。
6. **毛玻璃要透出壁纸**：material 从 `.popover` 换成 **`.underWindowBackground`**
   （这个材质才是"把窗口下面的内容模糊透出来"用的），并 `isEmphasized = false` 不额外加深；
   再压一层 14% 的暗底保证白字在亮壁纸上也读得清。
7. **图标没换**：`.icns`（1024×1024）其实早就打进包里了，是 macOS 图标缓存没刷 → 见上面"刷新缓存"。

顺手清掉了两个编译警告（`case .app(let app)` 的未使用变量、macOS 14 废弃的 `onChange`），
现在**零警告编译**。

## v1.4 微调（图标视觉重量 + 编辑模式抖动优化）
1. **图标"太大"**：之前的色块几乎顶到圆角边，跟 Photos/Messages 一比视觉重量过重。
   改成**内部整体缩到 85%**，色块比例/间距全部不变，只是四周多了 7.5% 的视觉留白。
   跟 Apple 其他 app 图标在 Dock 里的视觉重量对齐。
2. **编辑模式抖动**：原来 60fps 计算 `sin(t*5.5)*1.4` 每帧都重算、整个 cell 都参与 rotationEffect。
   改成 30fps——抖动是低振幅旋转，肉眼分不出 60 和 30，**GPU 工作量减半**。

剩下的"还有一点点卡"主要来自 `NSVisualEffectView(.underWindowBackground, .behindWindow)`：
它每一帧都把窗口下面整个桌面实时模糊合成一遍，M1+8GB Air 上不可能跟原生一样丝滑。
原生 Launchpad 是个特权 AppKit 层走 Metal 直通的，SwiftUI 这边要追平很难。
可选方案（你点头我就做）：
- A. **缓存壁纸快照**：窗口弹出时一次性截图桌面 → CIFilter 模糊 → 静态贴图，零实时合成成本。
  代价：你换壁纸过程中开 Launchpad，看到的会是旧的。
- B. **换成 `.regularMaterial`**：不透明模糊，不再透壁纸。代价：看不到桌面。
- C. **维持现状**：透壁纸+一点点卡。

## v1.5 两个 bug（App 名显示 + 滚动到底部被挡）

### 1. 所有 app 名字都是英文 —— 已修（65 个恢复中文）

**根因不是扫描逻辑，是 Info.plist 缺了 `CFBundleLocalizations`。**

`Bundle.localizedInfoDictionary` 内部用 **`Bundle.main.preferredLocalizations`** 决定用哪种语言。
主 bundle（也就是 LaunchPad.app 自己）没在 Info.plist 里声明支持哪些语言时，这个值会**回退到英文**，
于是读任何 app 的本地化名都拿到英文版本——微信变 `WeChat`、日历变 `Calendar`。

修了两处：

- **Info.plist 补 `CFBundleLocalizations`**（41 种语言，中文优先）**+ `CFBundleDevelopmentRegion = en`**。
  这是根治，★ 不要删，删了 bug 立刻复发。
- **`AppScanner.displayName()` 改成四级回退**，实测 105 个 app 验证过：
  ```
  1. localizedInfoDictionary["CFBundleDisplayName"]   ← 微信/日历/备忘录/照片 走这条
  2. infoDictionary["CFBundleDisplayName"]
  3. localizedInfoDictionary["CFBundleName"]          ← 邮件(Mail)走这条
  4. infoDictionary["CFBundleName"]
  5. 文件名兜底
  ```
  第 3 级不能省：`Mail.app` 只有 `CFBundleName`、没有 `CFBundleDisplayName`，而且它的
  `zh_CN.lproj` 里**根本没有 InfoPlist.strings**，中文名"邮件"由 LaunchServices 系统本地化表
  （`LSHasLocalizedDisplayName = 1`）提供，只能靠 `localizedInfoDictionary` 拿到。

效果（部分）：
```
WeChat → 微信        TencentMeeting → 腾讯会议     Mail → 邮件
Calendar → 日历      Notes → 备忘录                Photos → 照片
Maps → 地图          Terminal → 终端               Reminders → 提醒事项
aDrive → 阿里云盘     BaiduNetdisk_mac → 百度网盘    NeteaseMusic → 网易云音乐
rednote → 小红书      Eudic → 欧路词典              Doubao → 豆包
VoiceMemos → 语音备忘录   Freeform → 无边记         Shortcuts → 快捷指令
```

> 已存到 `structure.json` 的文件夹**不会丢**：`merge()` 按 path 匹配，会用新扫描到的
> AppItem 覆盖旧条目，名字自动刷新成中文，文件夹结构和位置保持不变。

### 2. 滑到最底部时最后一行 app 名字看不见 —— 已修

Grid 底部空间不够，最后一行被 Dock 盖住，且松手回弹后又看不见。
在 `ScrollView` 内的 `LazyVGrid` 上补了 `.padding(.bottom, 100)`（顶层页和文件夹内页都加），
滚动到底部时最后一行会停在 Dock 上方，名字正常显示。

### 附：新增 build.sh

```bash
cd /Users/xingxing/WorkBuddy/2026-09-01-13-59-46/LaunchPad && ./build.sh
```
一键完成：编译 → 拷 Info.plist → 拷图标 → 重签名。
（以前是手动四步，容易漏拷 Info.plist，这次的 bug 有一部分就是这么来的。）

> ~~⚠️ 重签名后辅助功能授权会失效，需要重新勾一次~~
> **这条在 v1.7 已经作废** —— app 不再申请辅助功能权限，重签多少次都不会再弹窗。

## v1.6 两个 bug（文件夹改名字 + 把 app 移出文件夹）

### 1. 文件夹内页改不了名字 —— 已修

**根因**：FolderDetailView 顶部右侧用 `Color.clear` 占位，**根本没有"编辑/完成"按钮**。
改名原本依赖顶层传下来的 `isEditMode`，但用户没在顶层开编辑就直接进文件夹 → isEditMode = false → 名字点不动。

**修法**：顶部右侧补一个"完成/编辑"按钮（跟顶层页同款设计、共享同一个 binding），跨页 `isEditMode` 同步。

### 2. 把 app 从文件夹移不出去 —— 已修

**根因**：FolderDetailView 里 AppCell 的 `onDrop: { _ in false }` + 整个 VStack **没有任何 drop 接收区**。
AppCell 的 `.draggable` 是好的（能拖起），但**没地方放**，拖了等于没动。

**修法**：把 ScrollView **之外**的整个区域挂上 `.dropDestination(for: String.self)`：
```swift
.dropDestination(for: String.self) { ids, _ in
    guard let draggedID = ids.first else { return false }
    let path = draggedID.hasPrefix("app:") ? String(draggedID.dropFirst(4)) : draggedID
    guard let app = folder.apps.first(where: { $0.pathString == path }) else { return false }
    onRemoveAppFromFolder(app)
    return true
}
```
SwiftUI drop 事件从内到外匹配（closest wins）：
- 拖到另一个 AppCell 上 → AppCell 自己的 `dropDestination` 接收（目前返回 false，不变）
- 拖到 grid 外的空白区域（topBar 下面 / Dock 上面 / 边缘）→ 这里的 dropDestination 接收 → 移出文件夹

移出后 `LaunchpadModel.removeApp` 自动处理：folder 只剩 1 个时会自动拆文件夹。

## v1.7 ★ 彻底干掉「想使用辅助功能来控制这台电脑」弹窗

### 根因：为了一个全局快捷键，整个 app 被迫要了最敏感的权限

老代码（`Sources/main.swift`）：
```swift
let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
if !AXIsProcessTrustedWithOptions(opts) { ... }          // ← 每次启动都弹授权窗
NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { } // ← 这个 API 才需要辅助功能权限
```

两个问题叠加：
1. `addGlobalMonitorForEvents` 是「监听系统里**所有**键盘事件」，Apple 强制要求辅助功能权限；
2. `AXTrustedCheckOptionPrompt = true` 会在**每次启动且无授权**时弹系统授权窗。

再加上 ad-hoc 签名**每次重签 cdhash 都变**，TCC 把它当新 app，授权反复被撤销，
于是形成死循环：**授权 → 重签 → 失效 → 再弹窗**。上一版给它固定 `--identifier` 只是缓解，没根治。

### 解法：换成 Carbon 的 `RegisterEventHotKey`

`RegisterEventHotKey` 是「**向系统注册一个热键**」，不读取事件流，
**因此完全不需要辅助功能权限** —— 弹窗从根上消失。
（Alfred、Raycast 这类工具用的就是这套。）

```swift
// 1) 装事件处理器(必须是 C 闭包,不能捕获上下文,用 NSApp.delegate 拿自己)
InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
    var hkID = EventHotKeyID()
    if GetEventParameter(event, EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID), nil,
        MemoryLayout<EventHotKeyID>.size, nil, &hkID) == noErr,
       hkID.signature == kHotKeySignature {
        DispatchQueue.main.async { (NSApp.delegate as? AppDelegate)?.openWindow() }
    }
    return noErr
}, 1, &spec, nil, nil)

// 2) 注册 ⌘⇧L
RegisterEventHotKey(UInt32(kVK_ANSI_L), UInt32(cmdKey | shiftKey),
                    hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
```

**验证结果**（`otool` / `nm` 实测）：
- 链接框架：AppKit + SwiftUI + **Carbon**，已无 ApplicationServices
- 二进制里**零个辅助功能 API 引用**
- 已引用 `RegisterEventHotKey` / `UnregisterEventHotKey`

### 附：app 位置也改了

**唯一的 app 副本放 `/Applications/LaunchPad.app`**，工作区只留源码。
`build.sh` 已改成直接输出到那里。

> ★ 绝对不要在多个位置放 app 副本。两处同时存在会让 LaunchServices 注册出两条记录，
> TCC 认错 app，表现同样是「授权过还反复弹窗」。2026-09-01 就因为这个空壳副本折腾了两小时。

> 已授权过的旧记录可以留着不管（app 已经不用它了）；想清爽就去
> 系统设置 → 隐私与安全性 → 辅助功能 里把 LaunchPad 那一项删掉。

## v1.8 五个问题（位置 / 改名 / 点击反馈 / 图标尺寸 / 掉帧）

### 1. 新建文件夹跑到最下面 —— 已修

`LaunchpadModel.createFolder` 原来用 `topLevel.append(.folder(...))`，
不管拖到哪，新文件夹都追加到**列表末尾**（视觉上就是最下面）。

改成**就地替换 target 的位置**：
```swift
removeApp(dragged)          // 先移除被拖的 app(会改变数组结构)
if let idx = topLevel.firstIndex(where: { ... target ... }) {
    topLevel[idx] = .folder(folder)   // 就地替换 → 文件夹出现在原位置
}
```
注意 `removeApp` 会改变数组结构（被拖的 app 若原本在某个文件夹里，
那个文件夹可能因只剩 1 个而被拆开），所以 **target 的下标必须在移除之后再查**，不能提前算。

### 2. 改文件夹名太绕 —— 改成双击直接改

原来必须**先点右上角"编辑"→ 再点名字**。现在跟原生启动台一致：**双击文件夹名字直接进入编辑**，
不再依赖编辑模式。同时加了：
- 铅笔图标常显（提示"这里可以改名"）+ hover 时名字底下浮出淡淡的底
- 输入框有可见的边框和底色，自动抢焦点（延 0.05s，等 TextField 上树后才 focus）
- **Esc 不再关窗**——正在输入时 Esc 交给文本框自己处理，不然改一半名字全丢了
  （`main.swift` 的 Esc monitor 里判断 `firstResponder is NSTextView`）

### 3. 点击 app 没有反馈 —— 已加

按下先缩到 0.9，约 0.11s 后弹回并执行动作。
动作**刻意延后到动画之后**——因为"打开 App"会立刻关窗，不延后反馈根本来不及被看见。
> ⚠️ 这里绝对不能用 `DragGesture(minimumDistance: 0)` / `LongPressGesture` 去捕捉按下状态，
> 它们会跟 `.draggable` 抢手势导致拖不动（v1.3 的教训）。

### 4. Dock 里图标比原生的大一圈 —— 已修（根因和上次不同）

`genicon.swift` 第 40 行原来是：
```swift
let bgRect = CGRect(x: 0, y: 0, width: size, height: size)   // 铺满整个 1024 画布,零边距
```
背景圆角矩形**直接铺满画布**。而 macOS 原生图标的内容只占 1024 画布里的 **约 824px（80.5%）**，
四周是透明边距。少了这圈边距，在 Dock 里就比旁边大一圈。

> v1.4 那次缩的是**内部色块**（85%），压根没动整体尺寸，所以没解决问题。

现在在绘制最开始套一层整体缩放：
```swift
let contentScale: CGFloat = 0.805
cg.translateBy(x: size * (1 - contentScale) / 2, y: size * (1 - contentScale) / 2)
cg.scaleBy(x: contentScale, y: contentScale)
```
**实测验证**：四边各留 99px（9.7%）透明边距，内容占 80.5% ✓

> 另外发现 `Sources/AppIcon.icns` 一直**不存在**，所以 build.sh 里那句
> `cp Sources/AppIcon.icns` 一直在被跳过——图标从来没被自动更新过。
> 新增 **`genicon.sh`** 固化图标生成流程（编译 → 画 1024 PNG → sips 切全套尺寸 → iconutil 打包）。
> 以后改图标：`./genicon.sh && ./build.sh && killall Dock`。

### 5. 卡顿（像 24fps）—— 找到三个真凶

先排除掉两个**不是**原因的：
- `WiggleEffect` 写法是对的（`if active` 包裹，非编辑模式不跑 `TimelineView`）
- 图标加载是异步后台的，不阻塞

**真凶一：入场动画把毛玻璃层一起缩放了**
```swift
}                                    // ZStack 结束(含毛玻璃层)
.scaleEffect(appeared ? 1.0 : 0.85)  // ← 整个 ZStack 一起缩放
.opacity(appeared ? 1.0 : 0.0)
```
`scaleEffect` / `opacity` 挂在 ZStack 整体上，**毛玻璃层也被一起缩放淡入**——
入场动画的每一帧，WindowServer 都要重做一次"缩放后的实时模糊"合成。
现重构为 **`backgroundLayer`（静态，不参与动画）+ `contentLayer`（独立做入场动画）**。

**真凶二：一屏 100+ 个格子每个都做缩放动画**
`CellAppearEffect` 原来是 `.opacity + .scaleEffect(0.6→1.0)`，
105 个格子同时缩放，SwiftUI 要逐个重新光栅化。改成**只做透明度淡入**（纯合成，便宜得多）。
同理，格子上的 `.transition(.scale.combined(with: .opacity))` 也统一简化为 `.transition(.opacity)`。

**真凶三（结构性）：实时模糊本身**
`NSVisualEffectView(.underWindowBackground, .behindWindow)` 每帧都要模糊整个屏幕
（你这台是 1440×900@2x = **2880×1800 = 518 万像素**）。
而且你用的是**动态壁纸**，它本身也在持续吃 GPU，两个叠加，M1 8GB 掉到 24fps 完全说得通。

新增：**跟随系统的「减少透明度」设置**
```swift
reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
```
开了 系统设置 → 辅助功能 → 显示 → **减少透明度**，本 app 就用不透明底色，省掉全部实时模糊，帧率会明显回升。
（并监听 `accessibilityDisplayOptionsDidChangeNotification`，改了立刻生效。）
> 想立刻要流畅就开这个开关；想要透壁纸的观感就保持关闭。

## v1.8.1 ★ 弹窗又出现 —— 真凶是「同 bundle ID 的重复副本」

v1.7 明明已经把辅助功能相关代码删干净了，点击时**还是弹**「想使用辅助功能来控制这台电脑」。

### 排查：先证明「不可能是这个 app 弹的」

```bash
nm -u /Applications/LaunchPad.app/Contents/MacOS/LaunchPad | grep -i "AX\|Accessibility"
# 空
otool -L /Applications/LaunchPad.app/Contents/MacOS/LaunchPad | grep -i ApplicationServices
# 空 —— 根本没链接 AX 所在的框架，物理上就调不了
```
源码、二进制、链接库三处全干净 → **弹窗另有出处**。

> ⚠️ 顺带一个坑：`pgrep -lf "LaunchPad.app"` **匹配不到**。进程名只有 `LaunchPad`，
> 路径不在命令行里，所以这个命令会假阴性、让你误判「app 没在运行」。用 `pgrep -x LaunchPad`。

### 取证：看运行中的进程到底跑的是哪个文件

```bash
pgrep -x LaunchPad                 # 69823 ← 其实一直在跑
lsof -p 69823 | grep MacOS/
# /private/tmp/launchpad-workspace-copy-153949/LaunchPad.app/Contents/MacOS/LaunchPad
```
**不是 /Applications 那份。** 那是个 9/1 留下的调试副本（build 7 = v1.6），
`strings` 一搜，里面赫然躺着 `AXTrustedCheckOptionPrompt` 和
`addGlobalMonitorForEventsMatchingMask:handler:` —— 正是会弹窗的那套旧代码。

### 机制：同 bundle ID = 系统认为它们是同一个 app

```bash
# Dock 里那条 tile 指向哪？
plutil -p ~/Library/Preferences/com.apple.dock.plist | grep -A4 _CFURLString | grep -i launchpad
# "file:///private/tmp/launchpad-workspace-copy-153949/LaunchPad.app/"
```
两条线索合起来就是完整因果链：

```
点 Dock 图标 → LaunchServices 按 bundle id 判重
             → 发现 com.xingxing.launchpad 已有一个在跑（/private/tmp 那份）
             → 不启动新的，直接唤醒旧副本
             → 旧副本调用 AXIsProcessTrustedWithOptions(prompt: true) → 弹窗
```

**结论：更新了 app 但行为还是旧的、或者旧 bug 复现 —— 第一件事就是查有没有第二份副本。**

### 修法（四步）

1. `kill <pid>` —— 结束旧副本进程
2. 副本移入废纸篓（**不要 `rm -rf`**，留个后悔的余地）
3. `lsregister -u <旧路径>` + `lsregister -f /Applications/LaunchPad.app` —— 清掉旧注册
4. 修 Dock plist：把 `_CFURLString` 指回 `/Applications/LaunchPad.app/`，
   并**删掉 `book` 键**（别名记录还指向旧路径，不改的话 Dock 照旧跳过去），然后：
   ```bash
   killall cfprefsd    # 不刷这个，改完的 plist 会被内存缓存覆盖回去
   killall Dock
   ```

> **为什么不能靠 AppleScript 自动往 Dock 加图标**：`System Events` 需要辅助功能权限 ——
> 绕一圈又回到刚爬出来的那个权限地狱。Dock 图标这种事，手动拖一次最干净。

### 防御：build.sh 现在会自己查

构建时扫描 `/private/tmp`、桌面、下载、`~/Applications` 和工作区，
凡 bundle ID 与 `com.xingxing.launchpad` 相同的 `.app` **一律移入废纸篓并打印清单**。
同 bundle ID 的副本在这个场景下没有合理用途，只会劫持启动。

## v1.9 ★ 7 列 + 壁纸模糊背景

你提的两个问题，第二个查下去发现**根因是我上一版埋的**。

### 1. 一屏 10 列太挤 → 固定 7 列

```swift
// 旧：自适应 —— 在 1440 宽的屏幕上会算出 10 列
private let columns = [GridItem(.adaptive(minimum: 100, maximum: 112), spacing: 26)]

// 新：固定 7 列，列宽随屏幕自适应
private let columns = Array(repeating: GridItem(.flexible(), spacing: 20), count: 7)
```

配套调整（**光改列数不够，图标不变大会显得更空**）：
- 图标 64 → **78px**，格子 100×102 → 124×124，行距 26 → 22
- 网格收窄并居中：`.frame(maxWidth: 1080)` + `.frame(maxWidth: .infinity)`
  —— 7 列若铺满 1440，单格会宽到 200px，图标和名字之间空一大截，反而散。
  限制在 1080 以内、左右留白，才是原生那种"聚拢"的观感。

### 2. 背景是死白 → 自己读壁纸做模糊

**根因：不是 bug，是我 v1.8 的错误设计。**

当时为了救卡顿，我让你去开「减少透明度」，代码就写成了这样：

```swift
if reduceTransparency {
    Color(nsColor: .windowBackgroundColor)   // ← 系统窗口底色，就是那片白
} else {
    VisualEffectView(...)                     // 实时毛玻璃
}
```

**这是一个"流畅 or 好看"的二选一 —— 而正确答案是两个都要。**

查了你的系统设置，确实是这个原因：

```bash
defaults read com.apple.universalaccess
    increaseContrast = 1;
    reduceTransparency = 1;
```

「减少透明度」和「增加对比度」**只要开一个**，macOS 就会强制把所有实时毛玻璃
变成不透明纯色。**但原生启动台在同样设置下照样显示壁纸模糊** ——
因为它压根不用系统毛玻璃，而是**自己取壁纸、自己做模糊**。这才是要复刻的做法。

#### 怎么找到你的壁纸（连踩三个坑）

你的壁纸是 **「照片随机播放」**，候选池有 62 张照片，系统定时轮换。于是：

| 坑 | 现象 | 解法 |
|---|---|---|
| 1 | `desktopImageURL` 返回的不是图片，是个目录 | 判断是目录就走另一条路 |
| 2 | 返回的是 `…/Application Support`，**比真正的池子高一级** | 在它下面再探一层 `com.apple.desktop.photos` |
| 3 | 池子里**没有任何字段记录"当前是第几张"** —— 翻遍 `com.apple.wallpaper/Store/Index.plist` 的 Configuration 也没有 | 取 **atime（访问时间）最新**的那张 |

第 3 条的原理：系统每次真正拿某张图去渲染桌面时，会刷新那个文件的 atime。
实测验证 —— atime 最新的文件与 `ls -lut` 排出来的第一张完全一致。

> 这个方案有自反馈性：我们自己读了 A，A 就保持最新，下次仍选 A，稳定；
> 直到系统把壁纸换成 B，B 变最新，我们下次就跟着选 B。

#### 性能：从 711ms 砍到 20ms

第一版跑出来 **711ms** —— 会让启动卡一下。逐段测下来是这样：

| 步骤 | 耗时 |
|---|---|
| `desktopImageURL` | 4.3 ms |
| 目录扫描 + atime 排序（61 个文件） | 0.9 ms |
| HEIC 从 3024px 原图生成缩略图 | **184.5 ms** |
| **HEIC 改用文件内嵌缩略图** | **3.8 ms** ← 快 48 倍 |
| 高斯模糊 CPU 渲染（480px 图） | 10.9 ms |
| 高斯模糊 GPU 渲染（同样 480px 图） | 20.1 ms |

两处关键优化：

**① 优先用文件内嵌的缩略图**。相机/手机拍的照片，文件内部本来就带一张小图，
直接取它，比从 3024px 原图重新缩放快几十倍：

```swift
kCGImageSourceCreateThumbnailFromImageIfAbsent   // 有内嵌就用内嵌（3.8ms）
kCGImageSourceCreateThumbnailFromImageAlways     // 总是从原图生成（184ms）
```

兜底：内嵌缩略图有时只有 160×120，拉到全屏会糊出马赛克
—— 所以低于 320px 宽就回退到从原图生成。

**② 这种尺寸下 CPU 渲染比 GPU 快**。图只有 480px，GPU 那套
上下文创建 + 纹理上传的开销，远大于它的算力优势（10.9ms vs 20.1ms）。

剩下的 130ms 冷启动（ImageIO 框架首次加载 + CIContext 创建）**丢到后台线程**算，
不挡首屏。

### 3. 【已撤销】窗口层级 —— 我搞错了，原生的菜单栏是可见的

v1.9 我一度把层级提到 `.statusBar`，理由写的是"原生启动台全屏接管、不露菜单栏"。
**这个前提是错的** —— 截图打回来才知道：原生启动台打开时，**菜单栏和 Dock 都看得见**。

```swift
win.level = .floating      // 3 —— 浮在普通窗口之上，但不遮菜单栏(24)和 Dock(20) ✓
// win.level = .statusBar  // 25 —— 曾经的错误改动，会把菜单栏整个盖没
```

`.floating` 的位置很讲究：要**高于普通窗口(0)** 才能浮在其他 app 上面，
又要**低于 Dock(20)** 才不会遮挡系统 UI。3 正好卡在中间。

### 4. 三个 bug 修复

#### ① 搜索框点不了 / 改名打不了字 —— 实测出来的真根因

跑了个实验确认，不是猜的：

```
普通带标题栏窗口        canBecomeKey = true
无边框窗口(.borderless)  canBecomeKey = false   ← 根因
子类化 override 之后     canBecomeKey = true
```

**`.borderless` 窗口默认拒绝键盘焦点**，所以里面的输入框点不进去。修法：

```swift
final class LaunchpadWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
```

> ⚠️ **这一条同时意味着 v1.8 的「双击文件夹名改名」一直用不了** ——
> 输入框同样拿不到键盘焦点。之前那个"延 0.05 秒再抢焦点"的修复治标不治本，
> 病根在窗口级别就没有键盘焦点。**改名功能请重新测一次。**

#### ② 截图完成后跳到别的程序

`applicationDidResignActive` 里原本是**一失活就立刻关窗**。
截图会让 app 短暂失活，窗口一关，焦点就落到截图前那个 app 上，回不来了。

改成延迟 0.7 秒后做三重判断，全都不满足才关：

1. 本 app 又激活了 → 刚才只是短暂失活，不关
2. 前台是截图/录屏相关进程 → 不算"用户切走了"，不关
3. 都不是 → 才关

#### ③ 菜单栏 —— 见上面第 3 条（改回 `.floating`）

### 新增文件

- `Sources/WallpaperBackground.swift` —— 壁纸定位 + 模糊，`build.sh` 已加入编译列表
- 版本 **1.9 / build 10**

## macOS 27 升级体检（2026-09-15 实测）

升级到 macOS 27.0 (26A428) 后做的一轮完整核对。结论：**自制启动台照常能用**，但系统那边变了不少，有一条已经顺手修掉。

### 1. 磁盘空间突然变大 → 是本地快照被升级清掉了

| | 升级前 | 升级后 |
|---|---|---|
| 可用空间 | 约 56 GB | **约 109 GB** |

原因不是系统"变瘦了"，而是 **APFS 本地快照（Time Machine 本地快照）在系统升级过程中被清理**：

```
tmutil listlocalsnapshots /     →  升级后返回空
```

快照平时占着空间不显眼，系统升级前会把它清掉腾地方，所以可用空间一下子多出来几十 GB。

> ⚠️ 代价是：那些快照同时也是"能回滚到几小时前"的还原点。**升级后它们没了。**
> 如果还没做过 Time Machine 完整备份，建议现在补一个。

### 2. 系统启动台**没有被删**，是改名重构成了 `Apps.app`

一开始只查了 `Launchpad.app` 发现不存在，差点得出"系统启动台已被移除"的结论 —— **那是错的**，纠正一下：

```
/System/Applications/Apps.app
  CFBundleDisplayName  = Apps
  CFBundleIdentifier   = com.apple.apps.launcher
  CFBundleSignature    = dlet          ← 启动台沿用几十年的老 creator code
  LSMinimumSystemVersion = 27.0
```

在它的二进制里还能搜到 `com.apple.launchpad.toggle` —— 启动台的快捷键通知名。所以它就是启动台，只是换了名字和 bundle id。

含义：Dock 里现在**两个都在**（系统的 `Apps` + 自制的 `LaunchPad`），互不冲突，留哪个都行。

### 3. 自制 v1.9 在 macOS 27 下的验证结果

| 项目 | 结果 |
|---|---|
| 编译（Swift 6.1.2 / macOS 18 SDK / 只要 CLT） | ✅ 零警告通过 |
| 冷启动 | ✅ 进程起得来，窗口 +0.8s 出现，之后稳定保持 |
| 窗口层级 | ✅ `layer=3`（`.floating`），菜单栏是 `layer=24`，**不会被盖** |
| 窗口尺寸 | ✅ 1440×900 全屏贴合 |
| 壁纸模糊管线 | ✅ 仍然有效，热态 **16 ms**（macOS 26 上是 20 ms） |

冷启动耗时曲线上有个细节：**首次约 150–185 ms**，是进程冷启动（加载 CoreImage/ImageIO + 建 CIContext）的一次性开销；之后每次都是 14–16 ms。因为跑在后台线程，不卡首屏。

### 4. ★ 已修：`desktopImageURL` 的返回值跟着系统版本往上漂

这是这次唯一动代码的地方。原来代码写死"照片池在返回目录的**下一层**"，实测这个层级关系会变：

| 系统 | `desktopImageURL` 返回 | 距真实照片池 |
|---|---|---|
| macOS 26 | `~/Library/Application Support` | 低 1 级 |
| **macOS 27** | **`~/Library`** | **低 2 级** |

在 27 上"探一层"已经打不中了，之所以没出问题，是因为后面还写了条硬编码兜底路径接住了。靠兜底活着不踏实 —— 已经改成**从返回值出发广度优先下探，去搜 `com.apple.desktop.photos` 这个名字**，往下几级都能自己找到。

代价实测可忽略：从 `~/Library` 出发**只访问 2 个目录、2.1 ms** 就命中。限了最多 2 层 / 每目录 256 项，防止异常目录结构把主线程拖住。

```
desktopImageURL → /Users/xingxing/Library
BFS 下探 → /Users/xingxing/Library/Application Support/com.apple.desktop.photos   [访问 2 个目录, 2.1 ms]
```

### 5. 记一笔：atime 定位法的两个固有局限

背景：壁纸是「照片随机播放」，池子里 61 张，`Index.plist` 里**没有任何字段记录"当前是第几张"**（只有 `type: imageFolder` 和池子路径）。所以只能靠"系统渲染时刷新的 atime，最新那张就是当前壁纸"。

实测发现两个躲不掉的坑（**都是既有设计就有的，不是 27 引入的**）：

1. **会被自己污染 → 自我锁定**。排序阶段只读元数据、不脏；但最后真正解码图片那一下会把选中那张的 atime 刷成"现在"，于是下次启动它还是最新。选对了就稳定不闪，选错了会一直错。macOS 没有 Linux 的 `O_NOATIME`，躲不掉。
2. **同秒多张无法区分**。系统设壁纸时会一次读好几张（实测 16:57:57 一批 4 个文件 atime 完全相同，疑似预载下一张），`max(by:)` 这时选谁取决于目录遍历顺序，不稳定。

缓解：池子里都是同一批照片，选错也只是换一张，不会变成空白或纯色。要彻底准确只能去解析 `Index.plist` 里按 display UUID 索引的嵌套二进制 blob，还要把 UUID 映射到 `NSScreen`，不划算，没做。

另外注意：壁纸设的是 **`shuffle_every_30_minutes`** —— 每 30 分钟换一张，所以背景偶尔和桌面不完全是同一张属正常。

### 6. 顺带记：不需要装 Xcode

编译这个项目**只要 Command Line Tools**，不用装 Xcode（Xcode 是完整 IDE，十几个 GB）：

```
xcode-select -p  →  /Library/Developer/CommandLineTools
swiftc --version →  Swift 6.1.2, target arm64-apple-macosx18.0
```

升级 macOS 27 之后 CLT 完好，`./build.sh` 照跑不误。

## 「截图后跳走」—— 改了四版，真凶是微信

用户反馈过两次，前三次修法都没根治。**第四版靠诊断日志才抓到真凶。**

| 版本 | 做法 | 为什么没治好 |
|---|---|---|
| v1 | 一失活就关窗 | 截图会让 app 失活 → 截完图直接跳走 |
| v2 | 延迟 0.7s，再看前台是不是截图进程 | 截图进程退得比 0.7s 快，检查时前台已经是别的 App |
| v3 | 查系统里有没有"正在截图"的进程 | 治好了**系统截图**，但**微信截图照样跳** |
| v4 | 换维度：不看是谁抢焦点，看这次失活是"点出来"的还是"快捷键触发"的 | 判据对了，但**采样时机放错了** |
| **v5** | **把遮罩检测挪到失活那一瞬间** | 当前版本 |

### 真凶：微信截图是「主进程自己抢前台」

v3 只盯着苹果自带的截图进程，但用户实际用的是**微信截图**。日志抓到的现场：

```
[17:24:07.418] 事件 didActivate ← 微信[com.tencent.xinwechat]
[17:24:07.434] 事件 resignActive (front=微信[com.tencent.xinWeChat])
[17:24:08.287]   延迟检查: 前台是 微信 → 判定为用户切走,关窗   ← 误判
```

微信截图时，**微信自己成了前台 app**，间隔只有 16 毫秒。

**难点**：`你主动切到微信` 和 `微信在截图`，前台都是微信 —— **按 app 名字根本区分不了**。

### v4 的两个新判据

**判据一：失活那一瞬间，鼠标刚按下过吗？**

```swift
CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .leftMouseDown)
```

| 场景 | 失活瞬间"距上次鼠标按下" | 结论 |
|---|---|---|
| 点 Dock 图标 / 点别的窗口 | ≈ 0 | 点出来的 → 用户主动，关窗 |
| 按快捷键触发截图（⌘⇧A） | 好几秒 | 不是点出来的 → 保留 |

★ 这个 API **不需要任何权限**（实测确认），不是辅助功能那一套。
★ **必须在 `applicationDidResignActive` 第一行采样**，不能放进延迟回调 ——
  截图一开始用户就会去框选（鼠标按下），晚 0.8 秒再采就废了。

**判据二：前台 App 有没有铺一层全屏遮罩？**

截图工具的通用特征：不论系统还是微信，要让你框选就必须先盖住整个屏幕。

实测到的微信截图遮罩特征（2026-09-15 从日志里读出来的**真实值**，不是查文档）：

```
1440x900 @ layer=27 alpha=1.00     ← 铺满整屏；层级 27 比我们自己的 3 还高
```

它比我们的窗口层级高，所以截图时它盖在我们上面 —— 这是正常的。

判定条件（两步缺一不可，避免误伤正常全屏的 App）：
1. 窗口覆盖某块屏幕 95% 以上
2. **且**是浮层（`layer > 0`）**或**半透明（`alpha < 0.98`）
   —— 把"全屏 Chrome"这类 `alpha=1, layer=0` 的正常窗口排除掉

★ 顺序上**判据二在判据一前面**：遮罩是更本质的证据，
  不管截图是快捷键还是点菜单触发的，遮罩都在。

### ★★ v5 的真正教训：采样时机

v4 判据是对的，但还是没修好。因为**遮罩检测被放在了延迟 0.8 秒后**：

```
[17:33:37.387] 前台 App 的在屏窗口: 1440x900@L27/a1.00   ← 遮罩明明在
[17:33:38.240] 延迟检查: ... 也无全屏遮罩 → 关窗          ← 0.85 秒后就没了
```

用户框选完遮罩就撤了。**信号在检查时已经消失**。

修法：和鼠标采样一样，**在 `applicationDidResignActive` 的第一行就采**。

> **可复用的教训**：凡是"某个信号可能很快消失"的判据，
> **采样点必须放在事件发生的那一刻，不能放进延迟回调里。**
> 这个坑我在同一个功能里踩了两遍 —— 先修了鼠标采样，却忘了同步修遮罩采样。

### 完整判断顺序

**第一步：在失活那一瞬间先采两个证据**（关键，绝不能延后）

- `mouseAgeAtResign` —— 距上次鼠标按下过了多久
- `overlayAtResign` —— 前台 App 此刻有没有全屏遮罩

**第二步：0.8 秒后按顺序判断**

1. 窗口不可见 → 不处理
2. `NSApp.isActive` 已恢复 → 不处理
3. 系统截图进程仍在运行（且是最近启动的）→ 抢回焦点
4. 系统截图宽限期内 → 抢回焦点
5. **失活瞬间有全屏遮罩** → 抢回焦点 ← 微信等第三方截图的主判据
5b. 此刻仍有全屏遮罩（兜底，有些工具遮罩停留更久）→ 抢回焦点
6. **失活瞬间鼠标刚按下（<0.5s）** → 用户主动切走，关窗
7. 前台是系统浮层 / 没有前台 App → 抢回焦点
8. 都不是 → 关窗

### 三个"查出来的事实"（不是查文档，是在本机验证的）

**① 系统截图涉及三个 bundle，白名单必须精确：**

```
/System/Library/CoreServices/screencaptureui.app  → com.apple.screencaptureui   (LSUIElement=true)
/System/Applications/Utilities/Screenshot.app     → com.apple.screenshot.launcher
/usr/sbin/screencapture                           → com.apple.screencapture
```

**② `screencaptureui` 是按需启动的，不是常驻守护进程**（实测：用完就退，等 3 秒也不复活）。
这条很关键 —— 如果它常驻，"检测到进程就抢回焦点"会让启动台**永远关不掉**。

**③ `runningApplications` 里常驻的名字带 screen 的只有屏幕时间小组件：**

```
屏幕时间 | com.apple.ScreenTimeWidgetApplication.ScreenTimeWidgetExtension
```

它**不含** "screenshot"/"screencapture"，所以精确白名单不会误伤。
而 `ScreenshotControls.appex` 这类扩展**根本不会**出现在 `runningApplications` 里。
→ 这就是为什么白名单用的是**精确 Set 匹配**而不是 `contains("screenshot")` 模糊匹配：
  一旦用模糊匹配，任何名字带 screenshot 的常驻进程都会让启动台无法关闭。

### ★ 严格性过滤：只认"最近启动"的截图进程

实测抓到过一次误伤：用户主动切到别的 App 时，因为系统里残留着一个截图进程，
焦点被硬抢回启动台。人不可能"开着截图工具就一直呆在启动台"。

所以加了 `maxAge: 25` 秒 —— 只认最近启动的截图进程 = 真的在进行一次截图。

### 诊断日志（以后再有怪问题，先看它）

```
~/Library/Application Support/LaunchPad/diagnostic.log
```

超过 200KB 自动清空。记录内容包括：启动/开关窗（含原因）、`becameActive`/`resignActive`
（含失活那一刻的前台 App **和距上次鼠标按下的秒数**）、延迟检查的**完整决策链**、
每一次 `didActivate` 事件、以及**前台 App 每个在屏窗口的尺寸/层级/透明度**。

最后那条是刻意加的：万一对"全屏遮罩"特征的假设不成立，
这行日志会直接显示微信截图窗口到底长什么样，不用再猜。

设计要点：不使用 `DateFormatter`（Swift 6 严格并发下不算 Sendable），
直接拆 `DateComponents` 拼时间戳；写盘走独立串行队列，不阻塞主线程。

## 拖动排序（复刻原生启动台交互）

用户反馈：「拖动 app 或文件夹到某一处时，无法让另一个 app 移动位置」。

### 为什么之前做不到（这是结构性问题，不是没做好）

- `LaunchpadModel` 里只有 createFolder / addAppToFolder / removeApp / removeFolder / renameFolder，
  **没有任何排序方法**
- 拖拽靠每个 `AppCell` 自己的 `.dropDestination` —— 内层先拦截事件，外层永远收不到；
  而且 `dropDestination` **拿不到鼠标坐标**，根本算不出"插到第几格"

### 现在的交互（跟原生一致）

| 操作 | 结果 |
|---|---|
| 拖动图标 | 其他图标**实时让位**，能看见会插到哪一格 |
| 停在某个 App 上约 0.9 秒 | 格子放大 + 高亮 → 松手建文件夹 |
| 停在文件夹上约 0.9 秒 | 松手加入该文件夹 |
| 其他情况松手 | 按落点排序 |

### 实现要点

**① 模型层 `moveItem(id:to:)`**

index 的约定是**基于"已排除被拖项"的数组** —— 因为画面上被拖的格子本来就不显示。
两边用同一套约定，就**不需要** `if target > from { target -= 1 }` 那种修正
（那种修正用错一次就偏一位，是排序 bug 的常见来源）。

自动化测试 7 个用例全过：拖到中间 / 最前 / 最后 / 原位不动 / 越界 / 负数 / id 不存在。

**② 让位 = 插一个透明占位格**

渲染的不是 `filtered`，而是 `displaySlots`：去掉被拖项 + 在落点插一个 `Color.clear`。
LazyVGrid 把它当正常格子排布，后面的项自然往后挪 —— **不需要自己算位移**。

**③ 整个网格是唯一的放置目标**

`.onDrop(of:delegate:)` 挂在网格上（只有 `DropDelegate` 才拿得到 `info.location` 坐标）。
格子上原来的 `dropDestination` 全部撤掉 —— 留着的话内层会拦截，外层收不到。

**④ 三个必须注意的坑（都踩过）**

- **坐标系统**：`.onDrop` 必须挂在 `.frame(maxWidth: 1080)` 和 `.frame(maxWidth: .infinity)`
  **中间**。挂最外面的话 `info.location.x` 是相对全宽(1440)的，而列距是按 1080 算的，
  落点会整体偏一大截。
- **初始落点**：`beginDrag` 里必须把 `dropIndex` 设成它**自己原来的下标**。
  否则占位符先插到末尾，一开拖所有图标就往左挤一格，画面"跳"一下。
- **拖动取消没有回调**：SwiftUI 不告诉你"用户放弃了拖动"。只能靠 `dropExited` 后
  延迟 0.5 秒判定 —— 期间回到网格就取消清理。立刻清的话，
  "从边缘划出去再划回来"这种常见操作会让让位失效。

**⑤ `.draggable` → `.onDrag`**

`.draggable` 没有"拖动开始"的回调，外层永远不知道被拖的是谁，而让位必须要知道。
`.onDrag` 的闭包正好在拖动开始时执行。代价是失去自定义预览（用系统快照，反而更接近原生）。

**⑥ 搜索状态下禁止排序**

搜索时画面里只是子集，落点下标跟真实数组对不上，执行了就会打乱顺序。

**⑦ 建文件夹从"拖上去就建"改成"停留 1 秒"**

原来"拖到 app 上"这**一个手势**被建文件夹独占了，没法同时用来排序。
区分方式是停留时长 —— 这也是原生启动台的做法。
顶部提示文案已同步改成「拖动排序 · 停在某个 App 上约 1 秒 → 建文件夹」。

## v1.10 ★ 顶栏点不到（进了文件夹回不去）—— 根因是壁纸把根视图撑大了

用户反馈：「创建了一个文件夹，进入文件夹之后**无法修改文件名、似乎被挡住了、也不能返回主页面**」。

现象很怪：文件夹里两个图标正常显示，但**整个顶栏（返回 / 文件夹名 / 编辑）都不见了**，
只剩「文件夹」三个字孤零零地飘在屏幕最上方。

### 结论先说

**顶栏没丢，是被菜单栏盖住了 —— 而整个内容区被上移了 31.5pt。**

根因链条：

```
壁纸源图是 3:2（缩略图 480×321），屏幕是 16:10（1440×900）
  ↓
背景层 .resizable().aspectRatio(contentMode: .fill) 按**像素比**算 → 把自己撑成 1440×963
  ↓
ZStack 取子视图最大值 → 根内容区变成 1440×963（比窗口高 63pt）
  ↓
窗口只有 900pt → 内容被垂直居中 → 整体上移 31.5pt
  ↓
顶栏（padding.top 28 + 高 30）正好落进菜单栏那 31pt 里
  ↓
看得见一点点、**点击全被菜单栏吃掉** = 用户说的"似乎被挡住了"
```

### 怎么定位的（这套方法以后还能用）

本机**没有辅助功能权限**，`CGEvent.post` 全部无效，所以没法"用程序点开文件夹再截图"。
绕法是：给 app 加一个**环境变量触发的调试探针**（`LP_PROBE`，见下），
让 app 自己进文件夹，然后 `screencapture` 抓屏。全程无人值守、不用点鼠标。

探针日志实测（**修复前**）：

```
探针·frame [根内容区]   = (0.0, -31.5, 1440.0, 963.0)   ← 比窗口高 63、上移 31.5
探针·frame [背景层]     = (0.0, -31.5, 1440.0, 963.0)   ← 就是它撑大的
探针·frame [文件夹topBar] = (0.0, -31.5, 1440.0, 59.0)   ← 顶栏在负坐标 → 被菜单栏吃掉
```

修复后：

```
探针·frame [根内容区]   = (0.0, 0.0, 1440.0, 900.0)   ← 精确等于窗口
探针·frame [背景层]     = (0.0, 0.0, 1440.0, 900.0)
探针·frame [文件夹topBar] = (0.0, 0.0, 1440.0, 74.0)   ← 74 = 43 上边距 + 内容
```

顺带把数字对上了一次：`1440 ÷ 1.4953(480/321) = 963.0` —— 和第 2 行实测的 963 完全吻合，
这条计算反过来印证了"是像素比在起作用，不是逻辑尺寸"。

> ⚠️ 排查中一度以为是 `.transition` 动画残留或 `ScrollView` 吞掉了顶栏。
> **两个都不是。** 教训：**先量尺寸，再猜原因**。一个 `GeometryReader` 打日志，
> 比读十遍布局代码有用。

### 修了两处（防御 ×2，因为它们是两个独立问题）

**① `WallpaperBackground.render`：按屏幕比例居中裁切（cover 语义）**

源图 3:2 → 裁成 16:10。这样位图的**像素比例 == 逻辑尺寸**,不再自相矛盾。
实测：修复前像素 480×321（比例 1.4953，但 `size` 却写 1440×900，撒谎）；
修复后 480×300（比例 1.6000 == 屏幕 1.6000）。

**② `LaunchpadRoot.backgroundLayer`：背景层不许参与尺寸计算**

```swift
Color.clear                      // 尺寸基准：只吃 proposal，绝不长大
    .overlay { Image(...).resizable().aspectRatio(contentMode: .fill) }
    .clipped()                   // 超出部分裁掉
```

注意**不能**写成 `Image(...).fill.clipped()` —— `clipped()` 只裁绘制、不改尺寸，
容器照样被撑大。必须让 `Color.clear` 定尺寸。

这条是"无论壁纸是什么比例都不会再犯"的硬保证。
实际上只要修了 ①,②就不会被触发；但①依赖源图比例、②不依赖任何东西，所以两条都留着。

### 顺带修的：顶栏按菜单栏高度动态避让

窗口是 `.borderless` + `setFrame(screen.frame)`，**铺满整屏、连菜单栏那块也盖住**
（模糊壁纸才能铺到最上沿）。代价是窗口不知道菜单栏在哪，顶栏贴 y=0 放就会被吃掉。

菜单栏高度不是常数（普通外接屏 ~24pt，本机缩放屏 31pt，刘海屏可到 37pt），所以现算：

```swift
enum ScreenMetrics {
    static var menuBarHeight: CGFloat {          // frame.maxY - visibleFrame.maxY
        guard let s = NSScreen.main ?? NSScreen.screens.first else { return 24 }
        return max(0, s.frame.maxY - s.visibleFrame.maxY)
    }
    static var topBarTopPadding: CGFloat { menuBarHeight + 12 }
}
```

原来两处都写死 `.padding(.top, 28)` → 现在都用 `ScreenMetrics.topBarTopPadding`
（本机 = 31 + 12 = 43）。那 12pt 留白不是审美，是**手滑点到菜单栏的缓冲区**。

### 新增：调试探针 `LP_PROBE`（平时完全不影响）

```bash
# 进第一个非空文件夹（排查文件夹内页）
LP_PROBE=folder /Applications/LaunchPad.app/Contents/MacOS/LaunchPad

# 进指定 id 的文件夹
LP_PROBE=<folder-id> /Applications/LaunchPad.app/Contents/MacOS/LaunchPad

# 停在顶层（当对照组）
LP_PROBE=top /Applications/LaunchPad.app/Contents/MacOS/LaunchPad
```

- 只读，不写盘、不改 `structure.json`
- 会**跳过"失活自动关窗"**，不然截图那一瞬间窗口自己就收了
- 配合 `probeFrame("标签")` 把任意视图在窗口坐标系里的 frame 写进 `diagnostic.log`

用法：截图后看日志里的 `探针·frame [...]`，就能立刻判断
「是整体被顶飞了」还是「只有某个视图自己跑偏」。

### 留下的证据截图（`诊断截图/` 目录）

| 文件 | 说明 |
|---|---|
| `修复前-文件夹页整屏.png` | 顶栏整体消失，只剩「文件夹」三字飘在最上方 |
| `修复前-文件夹页顶栏被菜单栏吃掉.png` | 放大左上角：返回按钮的胶囊压在菜单栏底下 |
| `修复后-文件夹页顶栏恢复.png` | 返回 / 文件名 / 编辑 三件套回到菜单栏下方 |
| `修复后-顶层页.png` | 顶层页对照：搜索框居中、`91 个 / 编辑` 避开菜单栏 |

## v1.11 ★ 文件夹里"点一下就跳到别的 app"—— 两个反馈，一个根因

v1.10 修完顶栏被菜单栏吃掉之后，用户实测：**双击文件夹名能改名了，也能回主页**。
但发现两个新问题：

1. 点文件夹名旁边那个**铅笔图标** → "跳到另外一个 app"
2. 点文件夹里的**空白处** → "跳到另外一个 app"

### 这两个是同一件事

**单击掉进了根视图的"点空白关窗"。** `LaunchpadRoot` 最外层有：

```swift
.onTapGesture { if !isEditMode { onEscape() } }   // onEscape = closeWindow()
```

任何没被下层控件吃掉的单击都会走到这里 → **窗口被关掉** → 后面的 app 露出来。
在用户眼里，这就是"跳到另外一个 app"。

- 铅笔图标**根本没有绑任何动作**，它只是"这里能改名"的提示图示。
  用户以为它是按钮，点了发现没反应、反而掉进关窗 → 现象就是"点了修改按钮跳走了"。
- 空白处同理。
- 这也解释了为什么**双击名字是好的**：双击手势会把第一下按住等第二下，
  不会漏给上层的单击手势。（所以修的时候**千万不要**给名字条再加单击手势，
  会把改名一起搞坏。）

### 解法

**① 顶栏那一条豁免**（这是真正治根的一步）

```swift
.onTapGesture(coordinateSpace: .local) { location in
    if location.y <= Self.topBarExclusionHeight { return }   // 顶栏 → 什么都不做
    if activeFolderID != nil { closeFolder() }               // 文件夹里 → 回主页
    else if !isEditMode { onEscape() }                       // 主页 → 关窗（保持原行为）
}
```

- 用**带坐标**的 `onTapGesture` 才可能排除"顶栏那一条"。
  光删按钮治不了根 —— 掉下来的单击还在。
- 这一条顺带把**顶层页「编辑」按钮万一漏下来的单击**也挡住了。
- `topBarExclusionHeight = 顶栏上边距 + 38`。顶部这一条本来也没有"点空白"的语义，
  豁免它不会有任何损失。

**② 文件夹内页顶栏精简到只剩文件夹名**

用户明确要求，全删：

| 删掉的 | 为什么 |
|---|---|
| 「返回」胶囊按钮 | 改为**点空白处回主页**，也更接近原生（点文件夹外面就退出文件夹） |
| 「编辑」胶囊按钮 | 文件夹内不需要。要移出某个 app，把图标拖到空白区即可 |
| 名字旁的铅笔图标 | 没绑动作、纯误导，用户以为它是"修改按钮" |

现在文件夹内页的顶栏 = **一个居中的文件夹名**，双击它改名。

### 顺带说明：为什么没有用"给名字条加单击手势"的办法

试过这个思路，放弃了。给同一个视图同时挂 `onTapGesture(count: 2)` 和单击手势，
两者的优先级完全依赖 SwiftUI 内部实现 —— 而**双击改名是用户明确要保住的功能**，
不能拿它冒险。改成"在根视图按坐标豁免"就没这个风险：名字条上的手势一个没动。

### ⚠️ 一个已知的小代价

顶栏那一条（屏幕最上面约 81pt）点下去**什么都不发生**了。
好处是这里再也没有"误关窗"；代价是这一条不再能用来"点空白关窗"。
启动台这么大面积，不缺这一条。

## v1.12 ★ 滚动卡顿 + 文件夹 3×3

用户反馈（v1.11 实测后）：

1. **"用起来还是能感受到卡顿，和 mac 原生的启动台手感差异十分明显"**
2. **"文件夹现在显示的是 4 个应用…还是要修改成 3×3 的"**

### 结论先说（压测数字）

滚动压测（预热后每组跑 2 遍，阈值 18ms，脚本见下）：

| 配置 | 主线程 ≥25ms | 实际丢帧 ≥25ms | 最差单帧 |
|---|---|---|---|
| ① 基线 v1.11（同步取图 + 每帧高质量重采样） | 2.7% / 2.6% | 3.3% / 4.5% | 106 / 124ms |
| ② **v1.12（图标缓存 + 圆角阴影烤进位图）** | **1.5% / 1.0%** | **2.2% / 1.7%** | 125ms |
| ③ 探针：在 ② 上再去掉所有阴影 | 0.8% / 0.9% | 1.4% / 1.3% | 125ms |

- ①→②：**主线程拖慢减半、丢帧减半**。
- ②→③ 只剩 ~30% 的差距 —— 说明阴影的开销已经被"烤进位图"吃掉了，
  剩下的（1.9% 丢帧）不再来自阴影，所以**不要再往阴影上想办法**。

### 卡在哪：三个真凶

**① 滚动时在主线程同步取图标（最主要）**

`LazyVGrid` 是**滚到哪儿才建哪儿**的。原来 `AppCell.onAppear` 里直接同步调
`NSWorkspace.shared.icon(forFile:)` —— 单个 1~6ms，走的是 IconServices（查库、读缓存文件）。
一屏七八个格子同时冒出来 = 主线程被占几十毫秒 = 一次掉好几帧。

**② 每帧高质量重采样**

`Image(nsImage:).resizable()` 显示在 78pt 的框里，而 NSImage 自身 `size` 是 32pt，
再挂 `.interpolation(.high)` —— 尺寸不符 + 高质量插值 = **每帧**做一次缩放。

**③ SwiftUI 的 `.shadow` 每帧离屏模糊**

一屏 ~30 个格子，图标一处、文字一处 = 60 次离屏高斯模糊/帧。
（③ 探针证明：全去掉能再降 30%，但圆角阴影是观感的一部分，不能删 ——
所以正确做法是**把它烤进位图**，而不是删掉。）

### 做法

**`Sources/IconCache.swift`（新增）**

- App 列表一扫完就在**后台并发**把所有图标缩好、连圆角带投影一起烤成"卡片"位图；
- 滚动时**一次 `icon(forFile:)` 都不发生**，也没有任何离屏模糊；
- 缓存里的图 **逻辑尺寸 = 显示尺寸** → 绘制是 1:1 贴图，零重采样；
- 预热必须 `DispatchQueue.concurrentPerform` 铺开：
  写成"一个 async 块里 for 一遍"是**串行**的，实测 91 个要 1716ms（18.9ms/个），
  期间满屏灰占位块，图标一个一个往外蹦。铺开后 ~130ms。

**`CardStyle` —— 把圆角 + 投影烤进位图**

```swift
卡片边长 = 图标边长 + 2 × 留白
留白     = 模糊半径 × 1.5 + |纵向偏移| + 2        // 78pt 图标 → 98pt 卡片
```

渲染**分两步**，不能合并：先在图标大小的画布里 clip 圆角、画图标；
再把这张图**带 setShadow** 画进大画布。因为 clip 会把阴影一起裁掉（阴影画在裁剪区外）。

**顺带删掉的：每个格子各自的淡入动画**

原来 `onAppear` 里 opacity 0→1 淡入 0.22s。`LazyVGrid` 会反复销毁/重建滚出屏幕的格子，
于是每次滚动都有新格子从透明淡进来 —— 看起来就是"没跟上手"。
整个内容层本来就有一入场动画，每个格子再淡一遍是重复的，而且 91 个同时跑。

### 压测怎么做的（避坑清单）

脚本：`/tmp/lp_ab.sh`（压测）+ `/tmp/lp_scroll.swift`（滚轮驱动器）。
代码里两个探针：`StallWatch`（主线程卡顿，按档位分桶）+ `FrameWatch`（`NSView.displayLink` 测真实帧间隔）。

踩过的坑，全记在这了：

1. `open -n -a xxx.app --env VAR=val` **不可靠** —— 同一台机器上有时传得进去有时传不进去，
   表现为 A/B 两轮跑出一模一样的数字而日志里毫无异常。
   → 必须**直接执行可执行文件**（`LP_OLDICON=1 /Applications/.../MacOS/LaunchPad`）。
2. 必须**断言前台是谁**。第一版没做，前台是 WorkBuddy，测的是 WorkBuddy 在滚 ——
   五路构造全绿，全是假的。
3. 必须**断言画面真的动了**（截图像素对比），否则"0 次卡顿"可能只是"根本没滚起来"。
4. 探针第一次打点必丢（timer 首帧 deadline 是 1 秒后），否则每次都记一条恒等于 1000ms 的假卡顿。
5. **重建之后必须热身**：构建完 Spotlight/LaunchServices 会重新索引 bundle，
   紧接着第一次启动被系统拖慢 —— 同一个基线一次量出 13.2% 丢帧、另一次 2.4%，差 5 倍，代码一个字没改。
6. 关阴影要用"不挂 modifier"，不能用 `.shadow(color: .clear)` —— 后者照样开离屏层。

### ★★ 两个差点翻车的坑（最重要，别重犯）

**坑一：`cgImage(forProposedRect:)` 的 rect 绝不能传 nil**

`NSWorkspace.icon(forFile:)` 返回的 NSImage：

- `image.size` 是 **32×32 pt**（不是 512/1024）；
- 里面塞了 **32 档** representation（16px 一路到 2048px）；
- 类型是 **`NSISIconImageRep`，不是 `NSBitmapImageRep`** —— 所以"遍历 representations 挑一档"
  这条路**根本走不通**，`as? NSBitmapImageRep` 永远匹配不到。

于是：

```swift
img.cgImage(forProposedRect: nil, ...)                  // → 64×64   ❌ 糊
var r = NSRect(x: 0, y: 0, width: 78, height: 78)
img.cgImage(forProposedRect: &r, ...)                   // → 256×256 ✅ 清晰
```

传 `nil` 时 AppKit 只能拿 `image.size`(32pt) 去算，给你 64px ——
**里面有多少档高分辨率都拿不到**。必须明确告诉它"我要多大"。

**坑二：macOS 图标位图自带透明边 —— 但千万别去"裁"它**

实测（`/tmp/lp_alphabounds`）：

```
请求 78pt → 位图 256×256，不透明内容只有 218×218（85.2%）
请求 20pt → 位图  48×48， 内容 46×46（95.8%）
```

看到"图标按 78pt 画的，屏幕上量出来只有 64pt"，很自然会想"那把透明边裁掉"。
**这是错的** —— 因为 `Image(nsImage:).resizable().frame(78)` 本来就是把
**整张位图（含透明边）缩进 78pt**，留白一样占位置。v1.11 的可见内容**一直**就是 64pt，
不存在"有个 bug 让它小了 15%"。

硬证据 —— v1.11 真机截图逐图标量（连通域工具 `/tmp/lpblobs`）：

```
v1.11 : 63.0×61.5pt / 63.5×61.5pt / 64.0×64.0pt   ← 78pt 的框
裁边后 : 74.0×72.0pt / 74.5×72.5pt                 ← 同一个图标，大了 18%
```

**我这次就是顺着这个错误结论改的，把图标撑大了一圈，最后又改回来。**

更根本的教训：**A/B 的对照组必须和真机一一对齐过，才能信。**
我那版对照组（LP_OLDICON 路径）把图标画进了 98pt 的框（可见 80pt），
真机 v1.11 是 78pt 的框（64pt）—— 对照组虚胖 16pt，
量出来"新版比旧版小 5pt"，于是我去修一个根本不存在的问题。
现在对照组里补了 `.frame(width: iconPointSize)`，三路（旧/素/卡片）可见尺寸都是 64pt，才是公平的。

相关代码：`IconCache.fillsBox`（默认 `false` = 保留透明边、和 v1.11 一致；
改成 `true` 就是"让图标撑满 78pt"，属于**外观变更**，不是优化）。

### 文件夹改成 3×3

用户要的，而且原生启动台本来就是 3×3（最多 9 个），2×2 是我们当初图省事。

尺寸是算出来的，不是拍脑袋：外层格子 78×78，
`小图标 20 × 3 + 间距 3 × 2 + 内边距 6 × 2 = 78` 正好填满不溢出。

**顺带修的：文件夹卡片被放大了 25%。**
`FolderIcon` 原来靠 ZStack 撑满外层，而外层从 v1.11 的 78pt 变成了卡片的 98pt，
于是文件夹卡片跟着长到 98pt —— 比应用图标（可见 64pt）大出一半，一屏看过去很突兀。
加一句 `.frame(width: 78, height: 78)` 钉死。
（验证：改动前后整屏逐像素对比，只有那一个格子的上下边缘变了，0.88%，其他 100 多个图标零变化。）

### 视觉保真度的验证方法

性能优化最怕"数字好看了、画面悄悄变了"。这次用的取证链：

| 工具 | 干什么 |
|---|---|
| `/tmp/lpblobs` | 连通域，把截图里每个图标单独框出来量尺寸 |
| `/tmp/lpdiff` | 两张截图逐像素比，给出差异像素数 + 差异图 |
| `/tmp/lpmeter` | 按饱和度抠单个图标的包围盒 |
| `/tmp/lpbright` | 按亮度抠浅色块（文件夹那种灰卡片，饱和度为 0 用不了 lpmeter） |
| `/tmp/lpregion` | 裁一块出来，好让 lpdiff 只比一个局部 |
| `/tmp/lpcrop` | 两张同区域放大并排，肉眼判读 |

结论：图标尺寸、位置、标签文字，v1.11 和 v1.12 全部对齐
（`诊断截图/v1.12-图标尺寸 左v1.11 右修正后.png`）；
图标边缘平均通道差 5/255（约 2%），来自 CG 和 SwiftUI 的降采样滤波器不同，肉眼不可见。

### 留下的开关（都在 `IconCache.PerfFlags`，环境变量控制，平时零开销）

| 变量 | 作用 |
|---|---|
| `LP_OLDICON=1` | 退回 v1.11 的取图方式，当压测基线 |
| `LP_NOSHADOW=1` | 去掉所有阴影，量阴影占多少 |
| `LP_DUMPCARD=1` | 把卡片位图画一圈洋红描边导出 + **显示到界面上**，用来判断"是位图画小了还是布局压小了" |
| `LP_PROBE=top / folder` | 停在顶层 / 进第一个非空文件夹，方便截图 |

## 计划中（想做还没做）
- ✅ 全局快捷键随处唤起（`⌘⇧L`）
- ✅ 文件夹分组
- **多页**：现在还是单页平铺，所有 app + 文件夹一屏装不下要滚动。
- **开机自启**：系统设置 → 通用 → 登录项，把 LaunchPad 加进去。
- **拖入文件夹可改名**：已实现（在编辑模式下点文件夹名字）。

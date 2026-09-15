# LaunchPad —— 把 macOS 启动台的手感找回来

从 macOS 26 开始,系统的启动台被换成了新的「App」浏览页,交互逻辑全变了。
这个项目就是把原来那个熟悉的启动台做回来:文件夹、拖动排序等。

![顶层页](assets/screenshot-top.png)

## 系统要求

- macOS 15.0 或更高(在 macOS 27 上开发实测)
- Apple Silicon(M1 起测试通过)

## 安装

### 方式一:下载现成的

到 [Releases](../../releases) 页面下载最新的 `LaunchPad.app`,拖进「应用程序」即可。

> app 是 ad-hoc 签名的,没有走苹果公证。首次打开如果提示"无法验证开发者":
> 在「应用程序」里**右键 → 打开**,再点一次"打开"就好了;不想这样可以在本地自己构建(见下)。

### 方式二:自己构建

不需要装完整的 Xcode,只装 [Command Line Tools](xcode-select --install) 就够:

```bash
git clone https://github.com/<你的用户名>/LaunchPad.git
cd LaunchPad
./build.sh
```

`build.sh` 会直接把 app 构建并签名(ad-hoc)安装到 `/Applications/LaunchPad.app`。

## 使用技巧

| 操作 | 怎么做 |
|---|---|
| 打开 app | 单击 |
| 新建文件夹 | 把一个 app 拖到另一个上,停留约 1 秒 |
| 移动 app 进文件夹 | 拖到文件夹图标上停一下 |
| 给文件夹改名 | 打开文件夹,双击顶部文件夹名 |
| 调整 app 顺序 | 直接拖(主页和文件夹里都行),其他图标会让位 |
| 把 app 移出文件夹 | 在文件夹里把图标拖到网格外的空白处或顶部提示条 |
| 关闭启动台 | 点空白处|

## 项目结构

```
Sources/
  main.swift               App 生命周期、全局快捷键、诊断日志与性能探针
  AppScanner.swift         扫描 /Applications 里的 app
  LaunchpadModel.swift     数据模型:网格结构、文件夹、排序,存取 structure.json
  IconCache.swift          图标缓存:后台并发预取,圆角+投影烘焙进位图
  AppGrid.swift            界面:网格、文件夹、拖动排序的落点计算
  WallpaperBackground.swift 壁纸读取与模糊
build.sh                   一键构建 + 签名 + 安装到 /Applications
docs/DEVLOG.md             开发日志:每个版本踩过的坑
```

## 开发

想改图标尺寸、列数、快捷键这些常量,都在对应文件顶部,有注释说明。
改动之后跑一遍 `./build.sh` 就能看效果。

诊断工具(压测、截图对比、探针)的用法写在开发日志里,排查显示问题时会用得上:

```bash
LP_PROBE=top /Applications/LaunchPad.app/Contents/MacOS/LaunchPad   # 启动后停在顶层
```

---

**创作者-星之所向-阿星陪你走过丝绸之路**
一个骑行的人,顺手写的 Mac 小工具。

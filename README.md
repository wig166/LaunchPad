# LaunchPad —— 把 macOS 启动台的手感找回来

从 macOS 26 开始,系统的启动台被换成了新的「App」浏览页,交互逻辑全变了。
这个项目就是把原来那个熟悉的启动台做回来:7 列大图标、文件夹、拖动排序、
模糊壁纸背景,而且滚动是顺的。

> 创作者-星之所向-阿星陪你走过丝绸之路

![顶层页](assets/screenshot-top.png)

## 特性

- **7 列大图标网格** —— 和原生启动台一样的密度与留白,不是"塞满一屏"
- **文件夹** —— 拖一个 app 到另一个上停一下就合成;文件夹缩略图 3×3,最多 9 个
- **拖动排序** —— 随时拖,其他图标实时让位;拖出文件夹的 app 会回到主页
- **搜索** —— 顶部输入即过滤,回车打开第一个结果
- **模糊壁纸背景** —— 取当前桌面壁纸,后台预先模糊好,滚动零开销
- **全局快捷键 `⌘⇧L`** —— 随时唤起/收起
- **滚动不卡** —— 图标在后台预先缩放 + 圆角投影一次烘焙成位图,滚动时纯贴图(见开发日志 v1.12)

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
| 删除文件夹 | 右键文件夹图标 → 删除文件夹(app 会回到主页);把 app 全部拖空也会自动拆掉 |
| 关闭启动台 | 点空白处,或再按一次 `⌘⇧L` |

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

## 许可证

[MIT](LICENSE) —— 随便用、随便改,留个署名就行。

---

**创作者-星之所向-阿星陪你走过丝绸之路**
一个骑行的人,顺手写的 Mac 小工具。

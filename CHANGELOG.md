# 更新日志

这里记的是我每次改了什么、为什么改、踩了什么坑。不是 changelog 模板,是给自己留的迭代笔记。

---

## v1.13 (build 16) —— 2026-09-16

### 我修了什么

**发布包"文件已损坏"** —— 有人下载后打不开,右键打开、隐私与安全性全都没用。查下来是我自己的锅。

### 我踩的坑

`codesign -vv --strict` 报了这么一句:

```
a sealed resource is missing or invalid
file missing: Contents/MacOS/LaunchPad.cstemp
```

翻译过来:签名清单里封了一个根本不存在的文件。

原因是我用 `codesign --force --deep` 反复重签,但**签名前没清掉上一轮的 `_CodeSignature`**。
codesign 会把包内文件清单写进 `CodeResources`,旧清单还在,它就把上次签名留下的临时文件
`LaunchPad.cstemp` 当成"包内资源"一起封进了新签名。签名从此无效,macOS 对签名损坏的 app
一律判"文件已损坏",不给你任何绕过的机会。

本机一直没暴露,是因为本地装的 app 没有隔离标记,Gatekeeper 压根不查它。只有别人下载才会中招。

### 改法

1. 签名前 `rm -rf "$APP/Contents/_CodeSignature"` 并清掉 `*.cstemp`
2. 去掉 `--deep`(包内没有嵌套的 framework,不需要它)
3. build.sh 加了**签名自检**:`codesign -vv --strict` 不过就直接构建失败

### 现在的效果

- `codesign -vv` → valid on disk ✅
- `spctl` → rejected(ad-hoc 签名没有苹果开发者证书,这个改不掉,除非交 99 美元/年)
- 用户那边从"**文件已损坏**"(死路一条)变成"**来自身份不明的开发者**"(右键→打开 就能用)

---

## v1.12 (build 15) —— 2026-09-15

开源首发版。

- 文件夹里的 app 可以拖出来了,拖动时会显示"松手:移回主页"的提示条
- 文件夹内部可以拖动排序了
- 删掉了没用的"编辑"按钮,想删文件夹改成右键菜单
- 滚动性能优化:主线程 ≥25ms 的卡顿从 2.65% 降到 1.25%,实际掉帧从 3.9% 降到 1.95%
- 文件夹图标从 2×2 换成 3×3

---

**创作者-星之所向-阿星陪你走过丝绸之路**
一个骑行的人,顺手写的 Mac 小工具。

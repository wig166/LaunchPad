import Cocoa
import CoreGraphics

// 启动台图标生成器:
// - Apple 风格圆角(22%)
// - 蓝紫渐变背景 + 顶部柔光
// - 2x2 多彩"app 块",各自带投影+顶光,看起来真的像 4 个 app 摆在那
// - 输出 1024x1024 PNG,然后用 iconutil 转 icns

@discardableResult
func makeIcon(to outPath: String) -> Bool {
    let size: CGFloat = 1024

    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(size),
        pixelsHigh: Int(size),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 32
    )!

    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    let cg = ctx.cgContext

    cg.setAllowsAntialiasing(true)
    cg.setShouldAntialias(true)
    cg.interpolationQuality = .high

    let space = CGColorSpaceCreateDeviceRGB()

    // === ★ 整体缩放到 Apple 标准图标占比 ===
    // macOS 的 app 图标在 1024 画布里,实际内容只占约 824px(≈80.5%),四周留透明边距,
    // 这样在 Dock 里和系统原生图标视觉重量才一致。
    // 之前背景圆角矩形直接铺满 0..1024(一点边距都没有),所以在 Dock 里
    // 比旁边的原生图标"大了一圈" —— 这就是问题根因。
    // (v1.4 那次缩的是内部色块,没动整体尺寸,所以没解决问题。)
    let contentScale: CGFloat = 0.805
    cg.saveGState()
    cg.translateBy(x: size * (1 - contentScale) / 2, y: size * (1 - contentScale) / 2)
    cg.scaleBy(x: contentScale, y: contentScale)

    // === 背景:圆角矩形 + 渐变 ===
    let cornerRadius = size * 0.225
    let bgRect = CGRect(x: 0, y: 0, width: size, height: size)
    let bgPath = CGPath(roundedRect: bgRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    cg.saveGState()
    cg.addPath(bgPath)
    cg.clip()

    // 蓝→深蓝紫 渐变
    let bgColors = [
        NSColor(red: 0.42, green: 0.58, blue: 0.98, alpha: 1.0).cgColor,  // 顶:亮
        NSColor(red: 0.18, green: 0.22, blue: 0.60, alpha: 1.0).cgColor   // 底:深
    ] as CFArray
    let bgGradient = CGGradient(colorsSpace: space, colors: bgColors, locations: [0, 1])!
    cg.drawLinearGradient(bgGradient, start: CGPoint(x: size/2, y: size), end: CGPoint(x: size/2, y: 0), options: [])

    // 顶部柔光(径向)
    cg.setBlendMode(.softLight)
    let radialColors = [
        NSColor(white: 1, alpha: 0.30).cgColor,
        NSColor(white: 1, alpha: 0).cgColor
    ] as CFArray
    let radialGrad = CGGradient(colorsSpace: space, colors: radialColors, locations: [0, 1])!
    cg.drawRadialGradient(
        radialGrad,
        startCenter: CGPoint(x: size/2, y: size * 0.85),
        startRadius: 0,
        endCenter: CGPoint(x: size/2, y: size * 0.85),
        endRadius: size * 0.75,
        options: []
    )
    cg.setBlendMode(.normal)

    cg.restoreGState()

    // === 2x2 app 块 ===
    // 整体缩到 85%,给图标四周加视觉留白,跟 Apple 其他 app 的视觉重量对齐
    // (色块比例/形状/间距全部不变,只是看起来更"瘦",不再顶到圆角边)
    let innerScale: CGFloat = 0.85
    cg.saveGState()
    cg.translateBy(x: size * (1 - innerScale) / 2, y: size * (1 - innerScale) / 2)
    cg.scaleBy(x: innerScale, y: innerScale)
    let gridSize: CGFloat = 600
    let gridX = (size - gridSize) / 2
    let gridY = (size - gridSize) / 2
    let cellSize: CGFloat = 280
    let cellGap: CGFloat = 40
    let cellRadius: CGFloat = 64

    // 顺序:左下 / 右下 / 左上 / 右上(对应 row 0/1, col 0/1,row=0 在底部)
    // 配色:红 / 橙 / 绿 / 蓝(经典 mac 风的四色)
    let palettes: [(NSColor, NSColor)] = [
        (NSColor(red: 1.00, green: 0.45, blue: 0.48, alpha: 1.0),
         NSColor(red: 0.86, green: 0.20, blue: 0.30, alpha: 1.0)),   // 红
        (NSColor(red: 1.00, green: 0.72, blue: 0.32, alpha: 1.0),
         NSColor(red: 0.95, green: 0.50, blue: 0.10, alpha: 1.0)),   // 橙
        (NSColor(red: 0.45, green: 0.88, blue: 0.55, alpha: 1.0),
         NSColor(red: 0.18, green: 0.70, blue: 0.32, alpha: 1.0)),   // 绿
        (NSColor(red: 0.50, green: 0.78, blue: 0.98, alpha: 1.0),
         NSColor(red: 0.25, green: 0.55, blue: 0.92, alpha: 1.0))    // 蓝
    ]

    // (col, row):row=0 在底部;idx 是 palettes 的索引(顺序:左下=红, 右下=橙, 左上=绿, 右上=蓝)
    let cells: [(Int, Int, Int)] = [(0, 0, 0), (1, 0, 1), (0, 1, 2), (1, 1, 3)]

    for (col, row, idx) in cells {
        let x = gridX + CGFloat(col) * (cellSize + cellGap)
        let y = gridY + CGFloat(row) * (cellSize + cellGap)
        let cellRect = CGRect(x: x, y: y, width: cellSize, height: cellSize)
        let cellPath = CGPath(roundedRect: cellRect, cornerWidth: cellRadius, cornerHeight: cellRadius, transform: nil)

        // 投影
        cg.saveGState()
        cg.setShadow(offset: CGSize(width: 0, height: cellSize * 0.07), blur: cellSize * 0.18, color: NSColor(white: 0, alpha: 0.32).cgColor)
        cg.addPath(cellPath)
        cg.setFillColor(NSColor.white.cgColor)
        cg.fillPath()
        cg.restoreGState()

        // 块内渐变填充
        cg.saveGState()
        cg.addPath(cellPath)
        cg.clip()

        let (c1, c2) = palettes[idx]
        let cellGrad = CGGradient(colorsSpace: space, colors: [c1.cgColor, c2.cgColor] as CFArray, locations: [0, 1])!
        cg.drawLinearGradient(cellGrad, start: CGPoint(x: x, y: y), end: CGPoint(x: x, y: y + cellSize), options: [])

        // 顶部高光
        cg.setBlendMode(.overlay)
        NSColor(white: 1, alpha: 0.42).setFill()
        cg.fill(CGRect(x: x, y: y + cellSize * 0.50, width: cellSize, height: cellSize * 0.50))
        cg.setBlendMode(.normal)

        // 极细的内描边(让边缘不那么糊)
        cg.setStrokeColor(NSColor(white: 1, alpha: 0.25).cgColor)
        cg.setLineWidth(2)
        cg.addPath(cellPath)
        cg.strokePath()

        cg.restoreGState()
    }

    cg.restoreGState()

    cg.restoreGState()  // 收尾:撤销最外层的整体缩放(contentScale)

    NSGraphicsContext.restoreGraphicsState()

    guard let png = rep.representation(using: .png, properties: [:]) else {
        print("PNG 生成失败")
        return false
    }
    let url = URL(fileURLWithPath: outPath)
    do {
        try png.write(to: url)
        print("图标已写入: \(url.path)")
        return true
    } catch {
        print("写入失败: \(error)")
        return false
    }
}

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"
exit(makeIcon(to: outPath) ? 0 : 1)
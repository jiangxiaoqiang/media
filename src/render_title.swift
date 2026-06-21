#!/usr/bin/swift
import AppKit
import CoreText

guard CommandLine.arguments.count >= 5 else {
    fputs("用法: render_title.swift <font.ttf> <text> <output.png> <fontSize> [<font2.ttf> <text2> <fontSize2>]\n", stderr)
    exit(1)
}

let fontPath = CommandLine.arguments[1]
let text = CommandLine.arguments[2]
let outputPath = CommandLine.arguments[3]
let fontSize = CGFloat(Double(CommandLine.arguments[4]) ?? 72)

// 双语支持：第二行文字（英文）
let hasSecondary = CommandLine.arguments.count >= 8
var fontPath2: String? = nil
var text2: String? = nil
var fontSize2: CGFloat? = nil
if hasSecondary {
    fontPath2 = CommandLine.arguments[5]
    text2 = CommandLine.arguments[6]
    fontSize2 = CGFloat(Double(CommandLine.arguments[7]) ?? 48)
}

guard let fontData = NSData(contentsOfFile: fontPath) as Data?,
      let provider = CGDataProvider(data: fontData as CFData),
      let cgFont = CGFont(provider) else {
    fputs("无法加载字体: \(fontPath)\n", stderr)
    exit(1)
}

var error: Unmanaged<CFError>?
CTFontManagerRegisterGraphicsFont(cgFont, &error)
let ctFont = CTFontCreateWithGraphicsFont(cgFont, fontSize, nil, nil)

// 主标题（中文）
let attributes: [NSAttributedString.Key: Any] = [
    .font: ctFont,
    .foregroundColor: NSColor.white,
]
let attrString = NSAttributedString(string: text, attributes: attributes)
let line = CTLineCreateWithAttributedString(attrString)
let bounds = CTLineGetBoundsWithOptions(line, [])

// 副标题（英文）
var line2: CTLine? = nil
var bounds2: CGRect = .zero
if let fontPath2 = fontPath2, let text2 = text2, let fontSize2 = fontSize2 {
    if let fontData2 = NSData(contentsOfFile: fontPath2) as Data?,
       let provider2 = CGDataProvider(data: fontData2 as CFData),
       let cgFont2 = CGFont(provider2) {
        CTFontManagerRegisterGraphicsFont(cgFont2, nil)
        let ctFont2 = CTFontCreateWithGraphicsFont(cgFont2, fontSize2, nil, nil)
        let attributes2: [NSAttributedString.Key: Any] = [
            .font: ctFont2,
            .foregroundColor: NSColor.white,
        ]
        let attrString2 = NSAttributedString(string: text2, attributes: attributes2)
        line2 = CTLineCreateWithAttributedString(attrString2)
        bounds2 = CTLineGetBoundsWithOptions(line2!, [])
    }
}

let padding: CGFloat = 24
let lineSpacing: CGFloat = hasSecondary ? 16 : 0
let width = ceil(max(bounds.width, bounds2.width) + padding * 2)
let height = ceil(bounds.height + bounds2.height + lineSpacing + padding * 2)

let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let context = CGContext(
    data: nil,
    width: Int(width),
    height: Int(height),
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fputs("无法创建绘图上下文\n", stderr)
    exit(1)
}

context.clear(CGRect(x: 0, y: 0, width: width, height: height))

// 绘制主标题（居中偏上）
let totalTextHeight = bounds.height + (hasSecondary ? bounds2.height + lineSpacing : 0)
let startY = (CGFloat(height) - totalTextHeight) / 2
let x1 = (CGFloat(width) - bounds.width) / 2 - bounds.minX
let y1 = startY - bounds.minY
context.textPosition = CGPoint(x: x1, y: y1)
CTLineDraw(line, context)

// 绘制副标题（居中偏下）
if let line2 = line2 {
    let x2 = (CGFloat(width) - bounds2.width) / 2 - bounds2.minX
    let y2 = startY + bounds.height + lineSpacing - bounds2.minY
    context.textPosition = CGPoint(x: x2, y: y2)
    CTLineDraw(line2, context)
}

guard let cgImage = context.makeImage() else {
    fputs("无法生成图像\n", stderr)
    exit(1)
}

let image = NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fputs("无法导出 PNG\n", stderr)
    exit(1)
}

do {
    try png.write(to: URL(fileURLWithPath: outputPath))
} catch {
    fputs("写入失败: \(outputPath)\n", stderr)
    exit(1)
}

#!/usr/bin/swift
import AppKit
import CoreText

guard CommandLine.arguments.count >= 5 else {
    fputs("用法: render_title.swift <font.ttf> <text> <output.png> <fontSize> [<font2.ttf> <text2> <fontSize2>] [<maxWidth>]\n", stderr)
    exit(1)
}

let fontPath = CommandLine.arguments[1]
let text = CommandLine.arguments[2]
let outputPath = CommandLine.arguments[3]
let fontSize = CGFloat(Double(CommandLine.arguments[4]) ?? 72)

// 双语支持：第二行文字（英文）；可选 maxWidth 为最后一项
let hasSecondary = CommandLine.arguments.count >= 8
var fontPath2: String? = nil
var text2: String? = nil
var fontSize2: CGFloat? = nil
var maxWidth: CGFloat? = nil

if hasSecondary {
    fontPath2 = CommandLine.arguments[5]
    text2 = CommandLine.arguments[6]
    fontSize2 = CGFloat(Double(CommandLine.arguments[7]) ?? 48)
    if CommandLine.arguments.count >= 9,
       let w = Double(CommandLine.arguments[8]), w > 0 {
        maxWidth = CGFloat(w)
    }
} else if CommandLine.arguments.count >= 6,
          let w = Double(CommandLine.arguments[5]), w > 0 {
    maxWidth = CGFloat(w)
}

let innerLineSpacing: CGFloat = 8

guard let fontData = NSData(contentsOfFile: fontPath) as Data?,
      let provider = CGDataProvider(data: fontData as CFData),
      let cgFont = CGFont(provider) else {
    fputs("无法加载字体: \(fontPath)\n", stderr)
    exit(1)
}

var error: Unmanaged<CFError>?
CTFontManagerRegisterGraphicsFont(cgFont, &error)
let ctFont = CTFontCreateWithGraphicsFont(cgFont, fontSize, nil, nil)

func wrapLines(text: String, font: CTFont, maxWidth: CGFloat?) -> [CTLine] {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor.white,
    ]
    let attrString = NSAttributedString(string: text, attributes: attributes)
    let singleLine = CTLineCreateWithAttributedString(attrString)
    let naturalWidth = CTLineGetBoundsWithOptions(singleLine, []).width

    guard let maxWidth = maxWidth, naturalWidth > maxWidth else {
        return [singleLine]
    }

    var lines: [CTLine] = []
    let typesetter = CTTypesetterCreateWithAttributedString(attrString)
    var start = 0
    let length = attrString.length

    while start < length {
        var count = CTTypesetterSuggestLineBreak(typesetter, start, Double(maxWidth))
        if count == 0 { count = 1 }
        let line = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count))
        lines.append(line)
        start += count
    }
    return lines
}

func blockSize(lines: [CTLine], lineSpacing: CGFloat) -> (width: CGFloat, height: CGFloat) {
    var maxW: CGFloat = 0
    var totalH: CGFloat = 0
    for (index, line) in lines.enumerated() {
        let bounds = CTLineGetBoundsWithOptions(line, [])
        maxW = max(maxW, bounds.width)
        totalH += bounds.height
        if index < lines.count - 1 {
            totalH += lineSpacing
        }
    }
    return (maxW, totalH)
}

// firstLineTopY：首行视觉顶边 Y（CG 坐标系 Y 向上，值越大越靠画面顶部）
func drawLines(_ lines: [CTLine], in context: CGContext, canvasWidth: CGFloat, firstLineTopY: CGFloat, lineSpacing: CGFloat) {
    var lineTopY = firstLineTopY
    for (index, line) in lines.enumerated() {
        let bounds = CTLineGetBoundsWithOptions(line, [])
        let x = (canvasWidth - bounds.width) / 2 - bounds.minX
        context.textPosition = CGPoint(x: x, y: lineTopY - bounds.maxY)
        CTLineDraw(line, context)
        if index < lines.count - 1 {
            lineTopY -= bounds.height + lineSpacing
        }
    }
}

// 主标题（中文）
let primaryLines = wrapLines(text: text, font: ctFont, maxWidth: maxWidth)
let primarySize = blockSize(lines: primaryLines, lineSpacing: innerLineSpacing)

// 副标题（英文）
var secondaryLines: [CTLine] = []
var secondarySize: (width: CGFloat, height: CGFloat) = (0, 0)
if let fontPath2 = fontPath2, let text2 = text2, let fontSize2 = fontSize2 {
    if let fontData2 = NSData(contentsOfFile: fontPath2) as Data?,
       let provider2 = CGDataProvider(data: fontData2 as CFData),
       let cgFont2 = CGFont(provider2) {
        CTFontManagerRegisterGraphicsFont(cgFont2, nil)
        let ctFont2 = CTFontCreateWithGraphicsFont(cgFont2, fontSize2, nil, nil)
        secondaryLines = wrapLines(text: text2, font: ctFont2, maxWidth: maxWidth)
        secondarySize = blockSize(lines: secondaryLines, lineSpacing: innerLineSpacing)
    }
}

let padding: CGFloat = 24
let blockSpacing: CGFloat = hasSecondary && !secondaryLines.isEmpty ? 16 : 0
let width = ceil(max(primarySize.width, secondarySize.width) + padding * 2)
let height = ceil(primarySize.height + secondarySize.height + blockSpacing + padding * 2)

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

// 绘制主标题与副标题（各块内多行居中，从上往下）
let totalTextHeight = primarySize.height + (secondaryLines.isEmpty ? 0 : secondarySize.height + blockSpacing)
let firstLineTopY = (CGFloat(height) + totalTextHeight) / 2
drawLines(primaryLines, in: context, canvasWidth: CGFloat(width), firstLineTopY: firstLineTopY, lineSpacing: innerLineSpacing)

if !secondaryLines.isEmpty {
    let secondaryFirstLineTopY = firstLineTopY - primarySize.height - blockSpacing
    drawLines(secondaryLines, in: context, canvasWidth: CGFloat(width), firstLineTopY: secondaryFirstLineTopY, lineSpacing: innerLineSpacing)
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

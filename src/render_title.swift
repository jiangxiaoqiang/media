#!/usr/bin/swift
import AppKit
import CoreText

guard CommandLine.arguments.count >= 5 else {
    fputs("用法: render_title.swift <font.ttf> <text> <output.png> <fontSize>\n", stderr)
    exit(1)
}

let fontPath = CommandLine.arguments[1]
let text = CommandLine.arguments[2]
let outputPath = CommandLine.arguments[3]
let fontSize = CGFloat(Double(CommandLine.arguments[4]) ?? 72)

guard let fontData = NSData(contentsOfFile: fontPath) as Data?,
      let provider = CGDataProvider(data: fontData as CFData),
      let cgFont = CGFont(provider) else {
    fputs("无法加载字体: \(fontPath)\n", stderr)
    exit(1)
}

var error: Unmanaged<CFError>?
CTFontManagerRegisterGraphicsFont(cgFont, &error)
let ctFont = CTFontCreateWithGraphicsFont(cgFont, fontSize, nil, nil)

let attributes: [NSAttributedString.Key: Any] = [
    .font: ctFont,
    .foregroundColor: NSColor.white,
    .strokeColor: NSColor.black,
    .strokeWidth: -3.0,
]
let attrString = NSAttributedString(string: text, attributes: attributes)
let line = CTLineCreateWithAttributedString(attrString)

let bounds = CTLineGetBoundsWithOptions(line, [])
let padding: CGFloat = 24
let width = ceil(bounds.width + padding * 2)
let height = ceil(bounds.height + padding * 2)

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
context.textPosition = CGPoint(x: padding - bounds.minX, y: padding - bounds.minY)
CTLineDraw(line, context)

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

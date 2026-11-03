import AppKit
let src = NSImage(contentsOfFile: CommandLine.arguments[1])!
let size = src.size
let out = NSImage(size: size, flipped: false) { rect in
    NSColor.white.setFill(); rect.fill()
    src.draw(in: rect)
    return true
}
let rep = NSBitmapImageRep(data: out.tiffRepresentation!)!
try! rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])!.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))

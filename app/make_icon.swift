// 앱 아이콘 1024px PNG 생성: swift make_icon.swift out.png
// "물길": 위의 두 대화에서 아래 대화로 맥락(주황 선)이 흘러 들어가고, 받는 쪽 입구 점이 채워져 있다.
import AppKit

let px = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> NSColor {
    NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

let ink = rgb(18, 20, 26)
let amber = rgb(242, 178, 79)

// 몸체 (macOS 아이콘 그리드: 824px 사각형, 모서리 185) — 캔버스 바닥색
let body = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
NSGradient(starting: rgb(34, 38, 50), ending: ink)!.draw(in: body, angle: -90)

// 점 격자 (캔버스와 같은 결, 아주 옅게)
body.addClip()
rgb(255, 255, 255, 0.05).setFill()
for gx in stride(from: 148, through: 900, by: 48) {
    for gy in stride(from: 148, through: 900, by: 48) {
        NSBezierPath(ovalIn: NSRect(x: gx - 4, y: gy - 4, width: 8, height: 8)).fill()
    }
}

// 카드: 위 둘(보내는 쪽), 아래 하나(받는 쪽). 좌표는 아래가 0
let cardW: CGFloat = 236, cardH: CGFloat = 140
let up1 = NSPoint(x: 318, y: 668), up2 = NSPoint(x: 706, y: 668), down = NSPoint(x: 512, y: 344)
func cardRect(_ c: NSPoint) -> NSRect { NSRect(x: c.x - cardW / 2, y: c.y - cardH / 2, width: cardW, height: cardH) }

// 받는 카드 위쪽 테두리의 두 입구
let inlet1 = NSPoint(x: down.x - 62, y: down.y + cardH / 2)
let inlet2 = NSPoint(x: down.x + 62, y: down.y + cardH / 2)

// 흐름 선 (카드 아래에서 입구까지)
let flow = NSBezierPath()
flow.lineWidth = 26
flow.lineCapStyle = .round
flow.move(to: NSPoint(x: up1.x, y: up1.y - cardH / 2)); flow.line(to: inlet1)
flow.move(to: NSPoint(x: up2.x, y: up2.y - cardH / 2)); flow.line(to: inlet2)
amber.setStroke()
flow.stroke()

// 카드 (제목 줄 + 흐린 둘째 줄)
for c in [up1, up2, down] {
    let r = cardRect(c)
    rgb(236, 238, 243).setFill()
    NSBezierPath(roundedRect: r, xRadius: 30, yRadius: 30).fill()
    rgb(18, 20, 26, 0.88).setFill()
    NSBezierPath(roundedRect: NSRect(x: r.minX + 32, y: r.midY + 8, width: 132, height: 24), xRadius: 12, yRadius: 12).fill()
    rgb(18, 20, 26, 0.30).setFill()
    NSBezierPath(roundedRect: NSRect(x: r.minX + 32, y: r.midY - 34, width: 88, height: 22), xRadius: 11, yRadius: 11).fill()
}

// 입구 점: 채워짐 = 받음 (바닥색 고리로 카드 테두리와 떼어 놓음)
for p in [inlet1, inlet2] {
    ink.setFill()
    NSBezierPath(ovalIn: NSRect(x: p.x - 34, y: p.y - 34, width: 68, height: 68)).fill()
    amber.setFill()
    NSBezierPath(ovalIn: NSRect(x: p.x - 24, y: p.y - 24, width: 48, height: 48)).fill()
}

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))

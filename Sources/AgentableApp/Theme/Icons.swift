import AppKit
import SwiftUI

/// The design's icon set: 24-point line drawings with a 1.75 stroke and round ends, drawn from the
/// same SVG path data the canvas uses, so every screen shares one icon language.
enum Icon: String, CaseIterable {
    case database, views, history, agents, agent, access, settings, review
    case chevronDown, chevronRight, chevronLeft, plus, close, check, minus
    case filter, search, key, reference, hidden, you, lock, send, arrowRight
    case warning, download, file, link, info
    case edit, more, upDown, pointer, braces, server, layers, undo, play

    fileprivate var drawing: [Part] {
        switch self {
        case .database: [.ellipse(12, 5, 8, 3), .path("M4 5v14c0 1.7 3.6 3 8 3s8-1.3 8-3V5"), .path("M4 12c0 1.7 3.6 3 8 3s8-1.3 8-3")]
        case .views: [.rect(3, 4, 18, 16, 2), .path("M3 10h18M9 4v16")]
        case .history: [.circle(12, 12, 9), .path("M12 7v5l3 2")]
        case .agents: [.rect(3, 4, 18, 16, 2), .path("m7 9 3 3-3 3M13 15h4")]
        case .agent: [.path("m7 9 3 3-3 3M13 15h4")]
        case .access: [.path("M12 3 4 6v6c0 5 3.5 8 8 9 4.5-1 8-4 8-9V6z")]
        case .settings: [.path("M4 6h10M18 6h2M4 12h4M12 12h8M4 18h12"), .circle(16, 6, 2), .circle(10, 12, 2), .circle(18, 18, 2)]
        case .review: [.path("M12 4v8M8 8h8M8 18h8")]
        case .chevronDown: [.path("m6 9 6 6 6-6")]
        case .chevronRight: [.path("m9 6 6 6-6 6")]
        case .chevronLeft: [.path("m15 6-6 6 6 6")]
        case .plus: [.path("M12 5v14M5 12h14")]
        case .close: [.path("M6 6l12 12M18 6 6 18")]
        case .check: [.path("m5 12 5 5 9-10")]
        case .minus: [.path("M5 12h14")]
        case .filter: [.path("M4 5h16l-6 8v5l-4 2v-7z")]
        case .search: [.circle(11, 11, 7), .path("m20 20-3.5-3.5")]
        case .key: [.circle(8, 15, 4), .path("m11 12 9-9M17 6l3 3")]
        case .reference: [.path("M7 17 17 7M8 7h9v9")]
        case .hidden: [.path("M3 3l18 18"), .path("M10.6 6.1A9.7 9.7 0 0 1 12 6c5 0 9 6 9 6a17 17 0 0 1-2.6 3.2M6.6 7.6C4.4 9.1 3 12 3 12s4 6 9 6a9 9 0 0 0 4.4-1.2")]
        case .you: [.circle(12, 8, 4), .path("M4 21c1.5-4 4.5-6 8-6s6.5 2 8 6")]
        case .lock: [.rect(5, 11, 14, 10, 2), .path("M8 11V7a4 4 0 0 1 8 0v4")]
        case .send: [.path("M12 19V5M6 11l6-6 6 6")]
        case .arrowRight: [.path("M5 12h14M13 6l6 6-6 6")]
        case .warning: [.path("M12 3 2 20h20z"), .path("M12 10v4M12 17v.5")]
        case .download: [.path("M12 4v11M7 10l5 5 5-5M5 20h14")]
        case .file: [.path("M14 3H6a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V9z"), .path("M14 3v6h6")]
        case .link: [.path("M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1"), .path("M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1")]
        case .info: [.circle(12, 12, 9), .path("M12 8v4M12 16v.5")]
        case .edit: [.path("M12 20h9"), .path("M16.5 3.5a2.1 2.1 0 0 1 3 3L7 19l-4 1 1-4z")]
        case .more: [.path("M5 12h.01M12 12h.01M19 12h.01")]
        case .upDown: [.path("m8 15 4 4 4-4M8 9l4-4 4 4")]
        case .pointer: [.path("M5 3l13 7.5-6 1.4-3 6.6z")]
        case .braces: [.path("M8 4H7a2 2 0 0 0-2 2v3a2 2 0 0 1-2 2 2 2 0 0 1 2 2v3a2 2 0 0 0 2 2h1M16 4h1a2 2 0 0 1 2 2v3a2 2 0 0 0 2 2 2 2 0 0 0-2 2v3a2 2 0 0 1-2 2h-1")]
        case .server: [.rect(3, 4, 18, 7, 2), .rect(3, 13, 18, 7, 2), .path("M7 7.5h.01M7 16.5h.01")]
        case .layers: [.path("M12 3 3 8l9 5 9-5z"), .path("m3 13 9 5 9-5")]
        case .undo: [.path("M9 14 4 9l5-5"), .path("M4 9h11a5 5 0 0 1 0 10h-3")]
        case .play: [.path("M7 5v14l12-7z")]
        }
    }

    /// The icon as a path in a 24 × 24 box.
    var path: Path {
        var result = Path()
        for part in drawing { part.add(to: &result) }
        return result
    }
}

private enum Part {
    case path(String)
    case circle(CGFloat, CGFloat, CGFloat)
    case ellipse(CGFloat, CGFloat, CGFloat, CGFloat)
    case rect(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)

    func add(to path: inout Path) {
        switch self {
        case .path(let data): SVGPath.add(data, to: &path)
        case .circle(let x, let y, let r): path.addEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
        case .ellipse(let x, let y, let rx, let ry): path.addEllipse(in: CGRect(x: x - rx, y: y - ry, width: rx * 2, height: ry * 2))
        case .rect(let x, let y, let w, let h, let r): path.addRoundedRect(in: CGRect(x: x, y: y, width: w, height: h), cornerSize: CGSize(width: r, height: r))
        }
    }
}

extension Icon {
    /// Strokes the icon into the current AppKit context, for views that draw themselves. The view
    /// must be flipped, like the SVG it comes from.
    @MainActor func draw(in rect: NSRect, color: NSColor, weight: CGFloat = 1.75) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.minY)
        context.scaleBy(x: rect.width / 24, y: rect.height / 24)
        context.addPath(path.cgPath)
        context.setLineWidth(weight * 24 / rect.width)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setStrokeColor(color.cgColor)
        context.strokePath()
        context.restoreGState()
    }
}

/// Draws an `Icon` at a size, in the current foreground style.
struct IconView: View {
    let icon: Icon
    var size: CGFloat = 16
    var weight: CGFloat = 1.75
    /// Filled instead of drawn as a line, as the design's play triangle.
    var filled = false

    init(_ icon: Icon, size: CGFloat = 16, weight: CGFloat = 1.75, filled: Bool = false) {
        self.icon = icon
        self.size = size
        self.weight = weight
        self.filled = filled
    }

    var body: some View {
        Group {
            if filled {
                IconShape(icon: icon).fill()
            } else {
                IconShape(icon: icon)
                    .stroke(style: StrokeStyle(lineWidth: weight * 24 / size, lineCap: .round, lineJoin: .round))
            }
        }
        .frame(width: 24, height: 24)
        .scaleEffect(size / 24)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct IconShape: Shape {
    let icon: Icon

    func path(in rect: CGRect) -> Path { icon.path }
}

/// A small SVG path reader: M L H V C S A Z and their relative forms, enough for the design's icons.
enum SVGPath {
    static func add(_ data: String, to path: inout Path) {
        var scanner = Tokens(data)
        var current = CGPoint.zero
        var start = CGPoint.zero
        var lastControl: CGPoint?
        var command: Character = "M"

        while let next = scanner.command() ?? (scanner.hasNumber ? command : nil) {
            command = next
            let relative = command.isLowercase
            func point() -> CGPoint? {
                guard let x = scanner.number(), let y = scanner.number() else { return nil }
                return relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
            }
            switch command.uppercased().first! {
            case "M":
                guard let p = point() else { return }
                path.move(to: p)
                current = p
                start = p
                lastControl = nil
                command = relative ? "l" : "L"
            case "L":
                guard let p = point() else { return }
                path.addLine(to: p)
                current = p
                lastControl = nil
            case "H":
                guard let x = scanner.number() else { return }
                current = CGPoint(x: relative ? current.x + x : x, y: current.y)
                path.addLine(to: current)
                lastControl = nil
            case "V":
                guard let y = scanner.number() else { return }
                current = CGPoint(x: current.x, y: relative ? current.y + y : y)
                path.addLine(to: current)
                lastControl = nil
            case "C":
                guard let c1 = point(), let c2 = point(), let p = point() else { return }
                path.addCurve(to: p, control1: c1, control2: c2)
                lastControl = c2
                current = p
            case "S":
                let c1 = lastControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                guard let c2 = point(), let p = point() else { return }
                path.addCurve(to: p, control1: c1, control2: c2)
                lastControl = c2
                current = p
            case "A":
                guard let rx = scanner.number(), let ry = scanner.number(), let rotation = scanner.number(),
                      let large = scanner.number(), let sweep = scanner.number(), let p = point() else { return }
                arc(&path, from: current, to: p, rx: rx, ry: ry, rotation: rotation, large: large != 0, sweep: sweep != 0)
                current = p
                lastControl = nil
            case "Z":
                path.closeSubpath()
                current = start
                lastControl = nil
            default:
                return
            }
        }
    }

    /// SVG's endpoint arc, as cubic curves (W3C SVG implementation notes, F.6).
    private static func arc(_ path: inout Path, from p0: CGPoint, to p1: CGPoint, rx: CGFloat, ry: CGFloat, rotation: CGFloat, large: Bool, sweep: Bool) {
        var rx = abs(rx), ry = abs(ry)
        guard rx > 0, ry > 0, p0 != p1 else { path.addLine(to: p1); return }
        let phi = rotation * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1 = cosPhi * dx + sinPhi * dy
        let y1 = -sinPhi * dx + cosPhi * dy
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 { rx *= sqrt(lambda); ry *= sqrt(lambda) }
        let numerator = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let denominator = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var factor = sqrt(max(0, numerator / denominator))
        if large == sweep { factor = -factor }
        let cx1 = factor * rx * y1 / ry
        let cy1 = -factor * ry * x1 / rx
        let cx = cosPhi * cx1 - sinPhi * cy1 + (p0.x + p1.x) / 2
        let cy = sinPhi * cx1 + cosPhi * cy1 + (p0.y + p1.y) / 2
        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let sign: CGFloat = ux * vy - uy * vx < 0 ? -1 : 1
            let dot = (ux * vx + uy * vy) / (sqrt(ux * ux + uy * uy) * sqrt(vx * vx + vy * vy))
            return sign * acos(min(1, max(-1, dot)))
        }
        let theta1 = angle(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
        var delta = angle((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry)
        if !sweep && delta > 0 { delta -= 2 * .pi }
        if sweep && delta < 0 { delta += 2 * .pi }
        let segments = max(1, Int(ceil(abs(delta) / (.pi / 2))))
        let step = delta / CGFloat(segments)
        let t = 4 / 3 * tan(step / 4)
        var theta = theta1
        func point(_ angle: CGFloat) -> (CGPoint, CGPoint) {
            let x = rx * cos(angle), y = ry * sin(angle)
            let position = CGPoint(x: cosPhi * x - sinPhi * y + cx, y: sinPhi * x + cosPhi * y + cy)
            let dxv = -rx * sin(angle), dyv = ry * cos(angle)
            return (position, CGPoint(x: cosPhi * dxv - sinPhi * dyv, y: sinPhi * dxv + cosPhi * dyv))
        }
        for _ in 0..<segments {
            let (a, da) = point(theta)
            let (b, db) = point(theta + step)
            path.addCurve(to: b, control1: CGPoint(x: a.x + t * da.x, y: a.y + t * da.y), control2: CGPoint(x: b.x - t * db.x, y: b.y - t * db.y))
            theta += step
        }
    }

    private struct Tokens {
        let characters: [Character]
        var index = 0

        init(_ text: String) { characters = Array(text) }

        mutating func skipSeparators() {
            while index < characters.count, characters[index] == " " || characters[index] == "," { index += 1 }
        }

        mutating func command() -> Character? {
            skipSeparators()
            guard index < characters.count, characters[index].isLetter else { return nil }
            defer { index += 1 }
            return characters[index]
        }

        var hasNumber: Bool {
            var probe = index
            while probe < characters.count, characters[probe] == " " || characters[probe] == "," { probe += 1 }
            return probe < characters.count && (characters[probe].isNumber || characters[probe] == "-" || characters[probe] == ".")
        }

        mutating func number() -> CGFloat? {
            skipSeparators()
            var text = ""
            var sawDot = false
            if index < characters.count, characters[index] == "-" || characters[index] == "+" {
                text.append(characters[index]); index += 1
            }
            while index < characters.count {
                let c = characters[index]
                if c.isNumber { text.append(c) } else if c == ".", !sawDot { sawDot = true; text.append(c) } else { break }
                index += 1
            }
            return Double(text).map { CGFloat($0) }
        }
    }
}

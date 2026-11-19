import AppKit
import AgentableCore

/// Text attributes the grid draws with.
@MainActor
enum GridStyle {
    static let rowHeight: CGFloat = 34
    static let headerHeight: CGFloat = 36
    static let gutterWidth: CGFloat = 34
    static let padding: CGFloat = 10
    static let cellFont = Fonts.nsMono(12)
    static let cellBold = Fonts.nsMono(12, .semibold)
    static let headerFont = Fonts.ns(12, .semibold)
    static let headerHint = Fonts.nsMono(11)
    static let flagFont = Fonts.ns(11, .semibold)

    static func attributes(_ font: NSFont, _ color: NSColor, alignment: NSTextAlignment = .left, strike: Bool = false) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.alignment = alignment
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
        if strike {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            attributes[.strikethroughColor] = color
        }
        return attributes
    }

    /// One line of text for a cell: newlines and tabs become spaces, very long values are cut,
    /// decimals get the column's scale.
    static func display(_ value: CellValue, scale: Int? = nil) -> String {
        if let scale, let formatted = fixed(value, scale: scale) { return formatted }
        var text = value.displayText
        if text.count > 300 { text = String(text.prefix(300)) + "…" }
        if text.contains(where: { $0 == "\n" || $0 == "\t" || $0 == "\r" }) {
            text = text.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ")
        }
        return text
    }

    /// Timestamps read short, as in the design: "11-18 09:42" this year, "2025-03-04 10:22" before.
    /// Values with a zone (`…Z`) show in local time.
    static func shortDate(_ value: CellValue) -> String? {
        guard case .text(let text) = value, text.count >= 16 else { return nil }
        let chars = Array(text)
        guard chars[4] == "-", chars[7] == "-", chars[10] == " " || chars[10] == "T", chars[13] == ":" else { return nil }
        var date = String(text.prefix(16)).replacingOccurrences(of: "T", with: " ")
        if text.hasSuffix("Z"), let parsed = isoFormatter.date(from: text) {
            date = localFormatter.string(from: parsed)
        }
        let year = String(date.prefix(4))
        return year == currentYear ? String(date.dropFirst(5)) : date
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let localFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    private static let currentYear = String(Calendar.current.component(.year, from: .now))

    /// The color a status-like value reads in: done green, waiting amber, moving blue, failed red,
    /// closed gray; anything else stays plain.
    static func statusColor(_ text: String) -> NSColor? {
        let word = text.lowercased()
        let groups: [(NSColor, [String])] = [
            (.tmOK, ["paid", "active", "succeeded", "success", "completed", "complete", "done", "approved", "published", "enabled", "settled"]),
            (.tmWarn, ["pending", "waiting", "processing", "queued", "draft", "in_review", "review", "trial", "on_hold", "hold"]),
            (.tmYou, ["shipped", "sent", "running", "scheduled", "in_transit", "open", "new"]),
            (.tmBad, ["failed", "error", "rejected", "overdue", "blocked", "declined", "disputed"]),
            (.tmMuted, ["refunded", "cancelled", "canceled", "archived", "deleted", "closed", "expired", "inactive", "disabled", "void"]),
        ]
        return groups.first { $0.1.contains(word) }?.0
    }

    private static func fixed(_ value: CellValue, scale: Int) -> String? {
        let decimal: Decimal?
        switch value {
        case .real(let number): decimal = Decimal(number)
        case .integer(let number): decimal = Decimal(number)
        case .text(let text): decimal = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))
        default: decimal = nil
        }
        guard var decimal else { return nil }
        var rounded = Decimal()
        NSDecimalRound(&rounded, &decimal, scale, .plain)
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = scale
        formatter.maximumFractionDigits = scale
        return formatter.string(from: rounded as NSDecimalNumber)
    }
}

/// One data cell, drawn directly for speed.
final class GridCellView: NSView {
    var value: CellValue = .null
    var numeric = false
    var scale: Int?
    var dateTime = false
    var status = false
    var mark: CellMark = .none
    var struck = false
    /// Shown instead of the value in an empty cell of a new row: "required", "default", "NULL".
    var placeholder: String?
    /// A small arrow that follows the cell's foreign key.
    var link = false
    var onFollow: (() -> Void)?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    func configure(value: CellValue, numeric: Bool, scale: Int? = nil, dateTime: Bool = false, status: Bool = false, mark: CellMark, struck: Bool,
                   placeholder: String? = nil, link: Bool = false) {
        self.value = value
        self.numeric = numeric
        self.scale = scale
        self.dateTime = dateTime
        self.status = status
        self.mark = mark
        self.struck = struck
        self.placeholder = placeholder
        self.link = link
        toolTip = link ? String(localized: "Open the row it points to") : nil
        needsDisplay = true
    }

    private var linkRect: NSRect {
        NSRect(x: bounds.maxX - 30, y: (bounds.height - 22) / 2, width: 22, height: 22)
    }

    /// Whether a click lands on the foreign key arrow.
    func takesClick(_ event: NSEvent) -> Bool {
        link && linkRect.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        if takesClick(event) {
            onFollow?()
        } else {
            super.mouseDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        var inset = bounds.insetBy(dx: GridStyle.padding, dy: 0)
        if link {
            inset.size.width -= 26
            let box = NSBezierPath(roundedRect: linkRect.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
            NSColor.tmWindow.setFill()
            box.fill()
            NSColor.tmLine.setStroke()
            box.stroke()
            Icon.reference.draw(in: linkRect.insetBy(dx: 5, dy: 5), color: .tmYou, weight: 1.9)
        }
        if let placeholder {
            drawLine(placeholder, attributes: GridStyle.attributes(GridStyle.cellFont, .tmMuted, alignment: numeric ? .right : .left), in: inset)
            return
        }
        switch mark {
        case .none:
            drawValue(value, in: inset, strike: struck)
        case .edited(let was, let now):
            NSColor.tmYouTint.setFill()
            bounds.fill()
            NSColor.tmYou.setFill()
            NSRect(x: 0, y: 0, width: 2, height: bounds.height).fill()
            drawChange(was: was, now: GridStyle.display(now, scale: scale), nowIsNull: now.isNull, ghost: false, in: inset)
        case .proposed(let was, let now):
            drawChange(was: was, now: now.map { GridStyle.display(.text($0), scale: scale) } ?? "NULL", nowIsNull: now == nil, ghost: true, in: inset)
        }
    }

    private func drawValue(_ value: CellValue, in rect: NSRect, strike: Bool) {
        var color: NSColor = value.isNull ? .tmMuted : (strike ? .tmMuted : .tmText)
        let text = (dateTime ? GridStyle.shortDate(value) : nil) ?? GridStyle.display(value, scale: scale)
        var rect = rect
        if status, !strike, case .text(let word) = value, let tint = GridStyle.statusColor(word) {
            color = tint
            tint.setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.minX, y: (bounds.height - 7) / 2, width: 7, height: 7)).fill()
            rect.origin.x += 14
            rect.size.width -= 14
        }
        let attributes = GridStyle.attributes(GridStyle.cellFont, color, alignment: numeric ? .right : .left, strike: strike)
        drawLine(text, attributes: attributes, in: rect)
    }

    /// "was" struck through, then the new value: plain for your edits, in a dashed orange box for an agent's.
    private func drawChange(was: CellValue, now: String, nowIsNull: Bool, ghost: Bool, in rect: NSRect) {
        let wasText = GridStyle.display(was, scale: scale)
        let wasAttributes = GridStyle.attributes(GridStyle.cellFont, .tmMuted, strike: true)
        let nowFont = ghost ? Fonts.nsMono(12, .medium) : GridStyle.cellFont
        let nowColor: NSColor = ghost ? .tmAgentText : (nowIsNull ? .tmMuted : .tmText)
        let nowAttributes = GridStyle.attributes(nowFont, nowColor)
        let wasWidth = min((wasText as NSString).size(withAttributes: wasAttributes).width, rect.width * 0.45)
        let nowWidth = (now as NSString).size(withAttributes: nowAttributes).width
        let boxPadding: CGFloat = ghost ? 7 : 0
        let total = wasWidth + 6 + nowWidth + boxPadding * 2
        var x = numeric ? max(rect.minX, rect.maxX - total) : rect.minX
        drawLine(wasText, attributes: wasAttributes, in: NSRect(x: x, y: rect.minY, width: wasWidth, height: rect.height))
        x += wasWidth + 6
        let available = max(0, rect.maxX - x)
        if ghost {
            let boxWidth = min(nowWidth + boxPadding * 2, available)
            let box = NSRect(x: x, y: (bounds.height - 20) / 2, width: boxWidth, height: 20).insetBy(dx: 0.5, dy: 0.5)
            let path = NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6)
            path.setLineDash([3, 2], count: 2, phase: 0)
            path.lineWidth = 1
            NSColor.tmAgent.setStroke()
            path.stroke()
            drawLine(now, attributes: nowAttributes, in: NSRect(x: x + boxPadding, y: rect.minY, width: max(0, boxWidth - boxPadding * 2), height: rect.height))
        } else {
            drawLine(now, attributes: nowAttributes, in: NSRect(x: x, y: rect.minY, width: available, height: rect.height))
        }
    }

    private func drawLine(_ text: String, attributes: [NSAttributedString.Key: Any], in rect: NSRect) {
        guard rect.width > 2 else { return }
        let font = attributes[.font] as? NSFont ?? GridStyle.cellFont
        let height = ceil(font.ascender - font.descender)
        let line = NSRect(x: rect.minX, y: floor((bounds.height - height) / 2), width: rect.width, height: height)
        (text as NSString).draw(with: line, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
    }
}

/// The narrow first column: a blue dot on rows you edited, an orange tick on rows an agent wants to change.
final class GutterCellView: NSView {
    var marks = RowMarks()
    var onOpenProposal: ((String) -> Void)?

    override var isFlipped: Bool { true }

    func configure(_ marks: RowMarks) {
        self.marks = marks
        toolTip = marks.proposal != nil ? String(localized: "Waiting for your review. Click to open it.")
            : marks.isNew ? String(localized: "New row, not saved yet") : (marks.editedByYou || marks.deletedByYou ? String(localized: "Edited by you") : nil)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if marks.proposal != nil {
            let box = NSRect(x: (bounds.width - 22) / 2 + 2, y: (bounds.height - 22) / 2, width: 22, height: 22).insetBy(dx: 0.5, dy: 0.5)
            let path = NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6)
            NSColor.tmWindow.setFill()
            path.fill()
            NSColor.tmLine.setStroke()
            path.stroke()
            let check = NSBezierPath()
            check.move(to: NSPoint(x: box.minX + 6.5, y: box.midY + 0.5))
            check.line(to: NSPoint(x: box.minX + 9.5, y: box.midY + 3.5))
            check.line(to: NSPoint(x: box.maxX - 6, y: box.midY - 3.5))
            check.lineWidth = 1.6
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            NSColor.tmText2.setStroke()
            check.stroke()
        } else if marks.isNew {
            Icon.plus.draw(in: NSRect(x: bounds.midX - 4, y: bounds.midY - 6, width: 12, height: 12), color: .tmYou, weight: 2.2)
        } else if marks.editedByYou || marks.deletedByYou {
            NSColor.tmYou.setFill()
            NSBezierPath(ovalIn: NSRect(x: bounds.midX - 1.5, y: bounds.midY - 3.5, width: 7, height: 7)).fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        if let proposal = marks.proposal { onOpenProposal?(proposal) } else { super.mouseDown(with: event) }
    }
}

/// Row background: agent rows tinted orange with a bar on the left; separators; selection.
/// Selection is drawn here too: AppKit does not always call `drawSelection(in:)` for custom row
/// views, so relying on it left selected rows unmarked.
final class GridRowView: NSTableRowView {
    var marks = RowMarks()

    override var isSelected: Bool {
        didSet { if isSelected != oldValue { needsDisplay = true } }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        if marks.proposal != nil {
            NSColor.tmAgentTint.setFill()
            bounds.fill()
        } else if marks.deletedByYou {
            NSColor.tmYouTint.withAlphaComponent(0.6).setFill()
            bounds.fill()
        }
        if isSelected {
            NSColor.tmYouTint.withAlphaComponent(marks.proposal != nil ? 0.5 : 0.9).setFill()
            bounds.fill()
        }
        if marks.proposal != nil {
            NSColor.tmAgent.setFill()
            NSRect(x: 0, y: 0, width: 3, height: bounds.height).fill()
        } else if marks.isNew {
            NSColor.tmYou.setFill()
            NSRect(x: 0, y: 0, width: 3, height: bounds.height).fill()
        }
        NSColor.tmLine2.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {}

    override var isEmphasized: Bool {
        get { false }
        set {}
    }
}

/// A column header: name, an arrow to the table a foreign key points to, a funnel when filtered,
/// sort direction, and an orange underline where an agent is looking.
final class GridHeaderCell: NSTableHeaderCell {
    var name = ""
    var foreignTable: String?
    var filtered = false
    var agent = false
    var ascending: Bool?
    /// Position among several sort keys, shown next to the arrow.
    var sortRank: Int?
    var numeric = false

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        NSColor.tmWindow.setFill()
        cellFrame.fill()
        NSColor.tmLine.setFill()
        NSRect(x: cellFrame.minX, y: cellFrame.maxY - 1, width: cellFrame.width, height: 1).fill()
        // AppKit fills the space after the last column with a copy of a header cell. The copy
        // carries this cell's name, so draw only for the cells that really head a column.
        guard let table = (controlView as? NSTableHeaderView)?.tableView,
              table.tableColumns.contains(where: { $0.headerCell === self }) else { return }
        if agent {
            NSColor.tmAgent.setFill()
            NSRect(x: cellFrame.minX, y: cellFrame.maxY - 2, width: cellFrame.width, height: 2).fill()
        }

        var rect = cellFrame.insetBy(dx: GridStyle.padding, dy: 0)
        let titleAttributes = GridStyle.attributes(GridStyle.headerFont, agent ? .tmAgentText : .tmText2)
        let hintAttributes = GridStyle.attributes(GridStyle.headerHint, .tmMuted)
        let hint = foreignTable.map { "→ \($0)" }
        let titleWidth = (name as NSString).size(withAttributes: titleAttributes).width
        let hintWidth = hint.map { ($0 as NSString).size(withAttributes: hintAttributes).width + 6 } ?? 0
        let iconsWidth: CGFloat = (filtered ? 19 : 0) + (ascending != nil ? (sortRank == nil ? 14 : 24) : 0)
        let contentWidth = min(rect.width, titleWidth + hintWidth + iconsWidth)
        if numeric { rect.origin.x = rect.maxX - contentWidth; rect.size.width = contentWidth }

        let titleRect = NSRect(x: rect.minX, y: cellFrame.minY, width: min(titleWidth, rect.width - iconsWidth), height: cellFrame.height)
        draw(name, titleAttributes, titleRect, in: cellFrame)
        var x = titleRect.maxX
        if let hint, x + 6 < rect.maxX - iconsWidth {
            draw(hint, hintAttributes, NSRect(x: x + 6, y: cellFrame.minY, width: rect.maxX - iconsWidth - x - 6, height: cellFrame.height), in: cellFrame)
            x += hintWidth
        }
        if filtered {
            drawFunnel(at: NSPoint(x: x + 6, y: cellFrame.midY - 6.5))
            x += 19
        }
        if let ascending {
            drawChevron(at: NSPoint(x: x + 4, y: cellFrame.midY), up: ascending)
            if let sortRank {
                ("\(sortRank)" as NSString).draw(at: NSPoint(x: x + 14, y: cellFrame.midY - 7), withAttributes: GridStyle.attributes(GridStyle.headerHint, .tmMuted))
            }
        }
    }

    private func draw(_ text: String, _ attributes: [NSAttributedString.Key: Any], _ rect: NSRect, in frame: NSRect) {
        let font = attributes[.font] as? NSFont ?? GridStyle.headerFont
        let height = ceil(font.ascender - font.descender)
        let line = NSRect(x: rect.minX, y: frame.minY + floor((frame.height - height) / 2), width: max(0, rect.width), height: height)
        (text as NSString).draw(with: line, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
    }

    private func drawFunnel(at origin: NSPoint) {
        let path = NSBezierPath()
        let s: CGFloat = 13 / 24
        func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: origin.x + x * s, y: origin.y + y * s) }
        path.move(to: p(4, 5)); path.line(to: p(20, 5)); path.line(to: p(14, 13)); path.line(to: p(14, 18))
        path.line(to: p(10, 20)); path.line(to: p(10, 13)); path.close()
        path.lineWidth = 1.4
        path.lineJoinStyle = .round
        NSColor.tmYou.setStroke()
        path.stroke()
    }

    private func drawChevron(at origin: NSPoint, up: Bool) {
        let path = NSBezierPath()
        let dy: CGFloat = up ? -2 : 2
        path.move(to: NSPoint(x: origin.x, y: origin.y - dy))
        path.line(to: NSPoint(x: origin.x + 4, y: origin.y + dy))
        path.line(to: NSPoint(x: origin.x + 8, y: origin.y - dy))
        path.lineWidth = 1.5
        path.lineCapStyle = .round
        NSColor.tmMuted.setStroke()
        path.stroke()
    }
}

final class GridHeaderView: NSTableHeaderView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.tmWindow.setFill()
        bounds.fill()
        NSColor.tmLine.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        super.draw(dirtyRect)
    }
}

/// The agent's live cursor: an orange pointer with its name on a flag.
final class AgentCursorView: NSView {
    var name = "" {
        didSet { invalidateIntrinsicContentSize(); needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        let width = (name as NSString).size(withAttributes: [.font: GridStyle.flagFont]).width
        return NSSize(width: 14 + width + 16 + 4, height: 36)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let pointer = NSBezierPath()
        pointer.move(to: NSPoint(x: 1.5, y: 1.5))
        pointer.line(to: NSPoint(x: 14, y: 9.2))
        pointer.line(to: NSPoint(x: 8.2, y: 10.4))
        pointer.line(to: NSPoint(x: 5.4, y: 16.8))
        pointer.close()
        NSColor.tmAgent.setFill()
        pointer.fill()
        NSColor.tmWindow.setStroke()
        pointer.lineWidth = 1.5
        pointer.lineJoinStyle = .round
        pointer.stroke()

        let attributes: [NSAttributedString.Key: Any] = [.font: GridStyle.flagFont, .foregroundColor: NSColor.tmAgentFlagText]
        let size = (name as NSString).size(withAttributes: attributes)
        let flag = NSRect(x: 12, y: 13, width: ceil(size.width) + 16, height: ceil(size.height) + 6)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.shadowOffset = NSSize(width: 0, height: -4)
        shadow.shadowBlurRadius = 8
        shadow.set()
        NSColor.tmAgentFlag.setFill()
        NSBezierPath(roundedRect: flag, xRadius: 6, yRadius: 6).fill()
        NSGraphicsContext.restoreGraphicsState()
        (name as NSString).draw(at: NSPoint(x: flag.minX + 8, y: flag.minY + 3), withAttributes: attributes)
    }
}

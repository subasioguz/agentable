import AppKit
import SwiftUI
import AgentableCore

/// The SQL editor: an `NSTextView` with colored SQL, line numbers and completion of table names,
/// columns and keywords as you type.
struct SQLEditorView: NSViewRepresentable {
    let document: SQLDocument
    let dialect: SQLDialect

    func makeCoordinator() -> SQLEditorCoordinator {
        SQLEditorCoordinator(document: document, dialect: dialect)
    }

    func makeNSView(context: Context) -> SQLEditorContainer {
        let container = SQLEditorContainer()
        context.coordinator.attach(container)
        return container
    }

    func updateNSView(_ container: SQLEditorContainer, context: Context) {
        let coordinator = context.coordinator
        coordinator.document = document
        coordinator.dialect = dialect
        document.editor = coordinator
        // Reading these registers them with Observation, so outside changes (open, format, an
        // agent's suggestion arriving or settling) land here.
        coordinator.update(text: document.text, suggestion: document.suggestion, stale: document.suggestionIsStale)
    }
}

/// Holds the scrolling editor and, above it, the completion list.
final class SQLEditorContainer: NSView {
    let scrollView = NSScrollView()
    let textView = SQLTextView(frame: .zero)
    let completions = CompletionListView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .tmWindow

        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.drawsBackground = true
        textView.backgroundColor = .tmWindow
        textView.insertionPointColor = .tmText
        textView.textContainerInset = NSSize(width: 6, height: 12)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.selectedTextAttributes = [.backgroundColor: NSColor.tmYouTint]
        scrollView.documentView = textView

        let ruler = LineNumberRuler(textView: textView, scrollView: scrollView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        addSubview(scrollView)
        completions.isHidden = true
        addSubview(completions)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    weak var coordinator: SQLEditorCoordinator?

    override func layout() {
        super.layout()
        coordinator?.layoutCard()
    }
}

final class SQLTextView: NSTextView {
    weak var coordinator: SQLEditorCoordinator?

    /// While an agent's suggestion shows, Tab takes it and Esc dismisses it.
    override func keyDown(with event: NSEvent) {
        if let coordinator, coordinator.isPreviewing {
            switch event.keyCode {
            case 48: coordinator.document.acceptSuggestion()
            case 53: coordinator.document.dismissSuggestion()
            default: super.keyDown(with: event)
            }
            return
        }
        super.keyDown(with: event)
    }

    /// Suggested lines: the agent's tint with its color down the left edge.
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let lines = coordinator?.addedLineRects() else { return }
        for line in lines where line.intersects(rect) {
            NSColor.tmAgentTint.setFill()
            line.fill()
            NSColor.tmAgent.setFill()
            NSRect(x: line.minX, y: line.minY, width: 2, height: line.height).fill()
        }
    }

    override func doCommand(by selector: Selector) {
        if coordinator?.handleCompletionCommand(selector) == true { return }
        super.doCommand(by: selector)
    }

    override func resignFirstResponder() -> Bool {
        coordinator?.hideCompletions()
        return super.resignFirstResponder()
    }

    override func mouseDown(with event: NSEvent) {
        coordinator?.hideCompletions()
        super.mouseDown(with: event)
    }
}

@MainActor
final class SQLEditorCoordinator: NSObject, NSTextViewDelegate {
    var document: SQLDocument
    var dialect: SQLDialect
    weak var container: SQLEditorContainer?
    private var wordRange: NSRange?
    private var suppressCompletion = false

    static let font = Fonts.nsMono(13)
    static let lineHeight: CGFloat = 24

    init(document: SQLDocument, dialect: SQLDialect) {
        self.document = document
        self.dialect = dialect
    }

    var textView: SQLTextView? { container?.textView }

    func attach(_ container: SQLEditorContainer) {
        self.container = container
        container.coordinator = self
        document.editor = self
        let textView = container.textView
        textView.coordinator = self
        textView.delegate = self
        textView.typingAttributes = Self.baseAttributes
        container.completions.onPick = { [weak self] index in self?.accept(index) }
        replaceText(document.text)
        let selection = document.selection
        if NSMaxRange(selection) <= (textView.string as NSString).length { textView.setSelectedRange(selection) }
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: container.scrollView.contentView)
        container.scrollView.contentView.postsBoundsChangedNotifications = true
        DispatchQueue.main.async { [weak textView] in textView?.window?.makeFirstResponder(textView) }
    }

    // MARK: Agents' suggestions

    private var preview: SQLSuggestion?
    private var previewBase = ""
    private var previewStale = false
    private var lineChanges: [LineChange] = []
    private var card: NSHostingView<AnyView>?
    /// The line the card sits under: the end of the first changed block.
    private var cardLine = 0
    /// The card height the text last made room for.
    private var decoratedHeight: CGFloat?

    var isPreviewing: Bool { preview != nil }

    /// Shows the document's text, or an agent's suggestion over it until the person decides.
    func update(text: String, suggestion: SQLSuggestion?, stale: Bool) {
        guard let textView else { return }
        if let suggestion {
            if preview?.id != suggestion.id || previewBase != text || previewStale != stale {
                showPreview(suggestion, over: text, stale: stale)
            }
        } else {
            if preview != nil { endPreview() }
            if textView.string != text { replaceText(text) }
        }
    }

    /// The document's lines and the suggested ones in one read-only text: added lines tinted,
    /// removed ones struck through, and the agent's note under the first change.
    private func showPreview(_ suggestion: SQLSuggestion, over text: String, stale: Bool) {
        guard let textView else { return }
        preview = suggestion
        previewBase = text
        previewStale = stale
        lineChanges = LineDiff.lines(from: text, to: suggestion.sql)
        let firstChange = lineChanges.firstIndex { if case .same = $0 { false } else { true } }
        if let firstChange {
            var end = firstChange
            while end + 1 < lineChanges.count, lineChanges[end + 1] != .same(lineChanges[end + 1].text) { end += 1 }
            cardLine = end
        } else {
            cardLine = max(lineChanges.count - 1, 0)
        }
        hideCompletions()
        textView.isEditable = false
        textView.string = lineChanges.map(\.text).joined(separator: "\n") + "\n"
        highlight()
        decoratedHeight = nil
        card?.removeFromSuperview()
        let card = NSHostingView(rootView: AnyView(EmptyView()))
        textView.addSubview(card)
        self.card = card
        layoutCard()
        var old = 0
        ruler?.labels = lineChanges.map { change in
            switch change {
            case .same: old += 1; return "\(old)"
            case .removed: old += 1; return "−"
            case .added: return "+"
            }
        }
        ruler?.needsDisplay = true
        textView.window?.makeFirstResponder(textView)
    }

    private func endPreview() {
        preview = nil
        lineChanges = []
        card?.removeFromSuperview()
        card = nil
        ruler?.labels = nil
        textView?.isEditable = true
    }

    private var ruler: LineNumberRuler? { container?.scrollView.verticalRulerView as? LineNumberRuler }

    /// Colors added and removed lines and leaves room under the card's line.
    private func decoratePreview(cardHeight: CGFloat) {
        guard let storage = textView?.textStorage else { return }
        storage.beginEditing()
        var location = 0
        for (index, change) in lineChanges.enumerated() {
            let length = (change.text as NSString).length
            let range = NSRange(location: location, length: length)
            switch change {
            case .added: storage.addAttribute(.foregroundColor, value: NSColor.tmAgentText, range: range)
            case .removed: storage.addAttributes([.foregroundColor: NSColor.tmMuted, .strikethroughStyle: NSUnderlineStyle.single.rawValue], range: range)
            case .same: break
            }
            if index == cardLine, location + length + 1 <= storage.length {
                let paragraph = (Self.baseAttributes[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
                paragraph.paragraphSpacing = cardHeight + 12
                storage.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: location, length: length + 1))
            }
            location += length + 1
        }
        storage.endEditing()
    }

    /// Sizes the card to the visible width and puts it under its line.
    func layoutCard() {
        guard let textView, let card, let preview, let layout = textView.layoutManager else { return }
        let origin = textView.textContainerOrigin
        // The visible part starts left of zero, under the line numbers.
        let visible = textView.visibleRect
        let left = max(visible.minX, 0) + origin.x + 4
        let width = max(visible.maxX - left - 14, 320)
        card.rootView = AnyView(SuggestionCard(
            client: preview.client, note: preview.note, stale: previewStale,
            accept: { [weak self] in self?.document.acceptSuggestion() },
            dismiss: { [weak self] in self?.document.dismissSuggestion() }
        ).frame(width: width))
        let height = ceil(card.fittingSize.height)
        if decoratedHeight != height {
            decoratedHeight = height
            decoratePreview(cardHeight: height)
        }
        // The card's line, by character offset.
        let offset = lineChanges.prefix(cardLine).reduce(0) { $0 + ($1.text as NSString).length + 1 }
        let glyph = layout.glyphIndexForCharacter(at: min(offset, max((textView.string as NSString).length - 1, 0)))
        layout.ensureLayout(for: textView.textContainer!)
        let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        card.frame = NSRect(x: left, y: origin.y + line.minY + Self.lineHeight + 4, width: width, height: height)
        textView.needsDisplay = true
    }

    /// Rows of suggested lines, for the text view to tint.
    func addedLineRects() -> [NSRect]? {
        guard preview != nil, let textView, let layout = textView.layoutManager else { return nil }
        var rects: [NSRect] = []
        var location = 0
        for change in lineChanges {
            let length = (change.text as NSString).length
            if case .added = change {
                let glyph = layout.glyphIndexForCharacter(at: min(location, max((textView.string as NSString).length - 1, 0)))
                let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                rects.append(NSRect(x: 0, y: line.minY + textView.textContainerOrigin.y, width: textView.bounds.width, height: Self.lineHeight))
            }
            location += length + 1
        }
        return rects
    }

    /// Replaces everything as one undoable edit; false when the editor can't take it now.
    func replaceAllUndoably(_ text: String) -> Bool {
        guard let textView else { return false }
        if preview != nil { endPreview() }
        if textView.string != document.text { replaceText(document.text) }
        let all = NSRange(location: 0, length: (textView.string as NSString).length)
        guard textView.shouldChangeText(in: all, replacementString: text) else { return false }
        textView.replaceCharacters(in: all, with: text)
        textView.didChangeText()
        textView.undoManager?.setActionName(String(localized: "Accept Suggestion"))
        return true
    }

    func replaceText(_ text: String) {
        guard let textView else { return }
        suppressCompletion = true
        textView.string = text
        highlight()
        suppressCompletion = false
        hideCompletions()
    }

    @objc private func scrolled() {
        container?.scrollView.verticalRulerView?.needsDisplay = true
        hideCompletions()
    }

    // MARK: Coloring

    static var baseAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        let glyphHeight = font.ascender - font.descender
        return [.font: font, .foregroundColor: NSColor.tmText, .paragraphStyle: paragraph, .baselineOffset: floor((lineHeight - glyphHeight) / 2)]
    }

    func highlight() {
        guard let textView, let storage = textView.textStorage else { return }
        let text = storage.string
        let map = Self.utf16Offsets(text)
        storage.beginEditing()
        storage.setAttributes(Self.baseAttributes, range: NSRange(location: 0, length: storage.length))
        for span in SQLAnalyzer.spans(in: text, dialect: dialect) {
            guard span.range.upperBound < map.count else { continue }
            let range = NSRange(location: map[span.range.lowerBound], length: map[span.range.upperBound] - map[span.range.lowerBound])
            switch span.kind {
            case .keyword, .function: storage.addAttribute(.foregroundColor, value: NSColor.tmSQLKeyword, range: range)
            case .string: storage.addAttribute(.foregroundColor, value: NSColor.tmSQLString, range: range)
            case .number: storage.addAttribute(.foregroundColor, value: NSColor.tmSQLNumber, range: range)
            case .comment:
                storage.addAttribute(.foregroundColor, value: NSColor.tmMuted, range: range)
                storage.addAttribute(.obliqueness, value: 0.14, range: range)
            case .identifier, .quoted, .symbol, .parameter: break
            }
        }
        storage.endEditing()
        textView.typingAttributes = Self.baseAttributes
        container?.scrollView.verticalRulerView?.needsDisplay = true
    }

    /// For each UTF-8 offset, the UTF-16 offset of the same place.
    static func utf16Offsets(_ text: String) -> [Int] {
        var map: [Int] = []
        map.reserveCapacity(text.utf8.count + 1)
        var utf16 = 0
        for scalar in text.unicodeScalars {
            let value = scalar.value
            let bytes = value < 0x80 ? 1 : value < 0x800 ? 2 : value < 0x10000 ? 3 : 4
            for _ in 0..<bytes { map.append(utf16) }
            utf16 += value >= 0x10000 ? 2 : 1
        }
        map.append(utf16)
        return map
    }

    // MARK: Text view delegate

    func textDidChange(_ notification: Notification) {
        guard let textView else { return }
        highlight()
        if document.text != textView.string { document.text = textView.string }
        document.selection = textView.selectedRange()
        if suppressCompletion {
            suppressCompletion = false
            hideCompletions()
        } else {
            updateCompletions()
        }
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard let textView else { return }
        document.selection = textView.selectedRange()
        if let wordRange, !NSLocationInRange(textView.selectedRange().location, NSRange(location: wordRange.location, length: wordRange.length + 1)) {
            hideCompletions()
        }
    }

    // MARK: Completion

    private func isWordCharacter(_ unit: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return CharacterSet.alphanumerics.contains(scalar) || unit == 0x5F
    }

    private func updateCompletions() {
        guard let textView, let container, textView.selectedRange().length == 0 else { return hideCompletions() }
        let ns = textView.string as NSString
        let cursor = textView.selectedRange().location
        var start = cursor
        while start > 0, isWordCharacter(ns.character(at: start - 1)) { start -= 1 }
        let prefix = ns.substring(with: NSRange(location: start, length: cursor - start))
        var qualifier: String?
        if start > 0, ns.character(at: start - 1) == 0x2E {
            var from = start - 1
            while from > 0, isWordCharacter(ns.character(at: from - 1)) { from -= 1 }
            if from < start - 1 { qualifier = ns.substring(with: NSRange(location: from, length: start - 1 - from)) }
        }
        guard !prefix.isEmpty || qualifier != nil, !insideStringOrComment(cursor) else { return hideCompletions() }
        if let first = prefix.unicodeScalars.first, CharacterSet.decimalDigits.contains(first) { return hideCompletions() }
        let items = document.completions(prefix: prefix, qualifier: qualifier)
        guard !items.isEmpty, !(items.count == 1 && items[0].text.caseInsensitiveCompare(prefix) == .orderedSame) else {
            return hideCompletions()
        }
        wordRange = NSRange(location: start, length: cursor - start)
        let list = container.completions
        list.items = items
        list.selected = 0
        list.scroll = 0
        let size = list.preferredSize
        var caret = textView.firstRect(forCharacterRange: NSRange(location: start, length: 0), actualRange: nil)
        if let window = textView.window {
            caret = container.convert(window.convertFromScreen(caret), from: nil)
        }
        var origin = NSPoint(x: max(4, caret.minX - 8), y: caret.maxY + 4)
        if origin.y + size.height > container.bounds.height - 4 { origin.y = max(4, caret.minY - size.height - 4) }
        origin.x = min(origin.x, max(4, container.bounds.width - size.width - 4))
        list.frame = NSRect(origin: origin, size: size)
        list.isHidden = false
        list.needsDisplay = true
    }

    private func insideStringOrComment(_ utf16Location: Int) -> Bool {
        guard let textView else { return false }
        let text = textView.string
        let index = String.Index(utf16Offset: utf16Location, in: text)
        let offset = text.utf8.distance(from: text.startIndex, to: index)
        return SQLAnalyzer.spans(in: text, dialect: dialect).contains {
            ($0.kind == .string || $0.kind == .comment || $0.kind == .quoted) && $0.range.lowerBound < offset && offset <= $0.range.upperBound
                && !($0.kind != .comment && offset == $0.range.upperBound)
        }
    }

    func hideCompletions() {
        wordRange = nil
        container?.completions.isHidden = true
    }

    /// Up, down, return, tab and escape steer the list while it is open.
    func handleCompletionCommand(_ selector: Selector) -> Bool {
        guard let list = container?.completions, !list.isHidden else { return false }
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            list.move(by: 1)
        case #selector(NSResponder.moveUp(_:)):
            list.move(by: -1)
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
            accept(list.selected)
        case #selector(NSResponder.cancelOperation(_:)):
            hideCompletions()
        default:
            return false
        }
        return true
    }

    private func accept(_ index: Int) {
        guard let textView, let wordRange, let list = container?.completions, list.items.indices.contains(index) else { return }
        let item = list.items[index]
        hideCompletions()
        suppressCompletion = true
        textView.insertText(item.insertion, replacementRange: wordRange)
    }
}

/// Line numbers to the left of the editor, muted, as drawn.
final class LineNumberRuler: NSRulerView {
    private weak var textView: NSTextView?
    /// While a suggestion shows: each line's number, "+" or "−" in place of counting.
    var labels: [String]?

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 44
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.tmWindow.setFill()
        bounds.fill()
        drawHashMarksAndLabels(in: dirtyRect)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layout = textView.layoutManager, let container = textView.textContainer else { return }
        let text = textView.string as NSString
        let attributes = GridStyle.attributes(Fonts.nsMono(12), NSColor.tmMuted.withAlphaComponent(0.75), alignment: .right)
        let visible = textView.visibleRect
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var line = 1
        text.enumerateSubstrings(in: NSRange(location: 0, length: characters.location), options: [.byLines, .substringNotRequired]) { _, _, _, _ in line += 1 }
        if characters.location > 0, text.character(at: characters.location - 1) != 0x0A { line -= 1 }

        let marked = GridStyle.attributes(Fonts.nsMono(12), NSColor.tmAgentText, alignment: .right)
        func draw(_ number: Int, top: CGFloat, height: CGFloat) {
            // A line with room for a card under it is taller than its text.
            let height = min(height, SQLEditorCoordinator.lineHeight)
            let y = convert(NSPoint(x: 0, y: top + textView.textContainerOrigin.y), from: textView).y
            let font = Fonts.nsMono(12)
            let glyph = ceil(font.ascender - font.descender)
            let box = NSRect(x: 0, y: y + floor((height - glyph) / 2) + 1, width: ruleThickness - 14, height: glyph)
            var label = "\(number)"
            if let labels {
                guard number - 1 < labels.count else { return }
                label = labels[number - 1]
            }
            (label as NSString).draw(with: box, options: [.usesLineFragmentOrigin], attributes: label == "+" || label == "−" ? marked : attributes)
        }

        var index = characters.location
        while index < NSMaxRange(characters) {
            let lineRange = text.lineRange(for: NSRange(location: index, length: 0))
            let glyphRange = layout.glyphRange(forCharacterRange: NSRange(location: lineRange.location, length: max(lineRange.length, 1)), actualCharacterRange: nil)
            let fragment = layout.lineFragmentRect(forGlyphAt: min(glyphRange.location, max(layout.numberOfGlyphs - 1, 0)), effectiveRange: nil)
            draw(line, top: fragment.minY, height: fragment.height)
            line += 1
            index = NSMaxRange(lineRange)
        }
        // The empty line after a final newline, or the only line of an empty editor.
        if text.length == 0 || (NSMaxRange(characters) == text.length && text.character(at: text.length - 1) == 0x0A) {
            let extra = layout.extraLineFragmentRect
            if extra.height > 0 { draw(line, top: extra.minY, height: extra.height) }
            else if text.length == 0 { draw(1, top: 0, height: SQLEditorCoordinator.lineHeight) }
        }
    }
}

/// The completion list: a small card of names with what they are, drawn in the design's style.
final class CompletionListView: NSView {
    var items: [Completion] = []
    var selected = 0
    var scroll = 0
    var onPick: ((Int) -> Void)?

    static let rowHeight: CGFloat = 26
    static let visibleRows = 8

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.18
        layer?.shadowRadius = 12
        layer?.shadowOffset = NSSize(width: 0, height: -6)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var preferredSize: NSSize {
        let label = GridStyle.attributes(Fonts.nsMono(12.5), .tmText)
        let detail = GridStyle.attributes(Fonts.ns(11.5), .tmMuted)
        let widest = items.prefix(50).map {
            ($0.text as NSString).size(withAttributes: label).width + ($0.detail as NSString).size(withAttributes: detail).width
        }.max() ?? 120
        let rows = min(items.count, Self.visibleRows)
        return NSSize(width: min(max(widest + 48, 220), 380), height: CGFloat(rows) * Self.rowHeight + 10)
    }

    func move(by step: Int) {
        guard !items.isEmpty else { return }
        selected = (selected + step + items.count) % items.count
        if selected < scroll { scroll = selected }
        if selected >= scroll + Self.visibleRows { scroll = selected - Self.visibleRows + 1 }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let card = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        NSColor.tmWindow.setFill()
        card.fill()
        NSColor.tmLine.setStroke()
        card.stroke()
        let label = GridStyle.attributes(Fonts.nsMono(12.5), .tmText)
        let detail = GridStyle.attributes(Fonts.ns(11.5), .tmMuted, alignment: .right)
        for (row, index) in (scroll..<min(items.count, scroll + Self.visibleRows)).enumerated() {
            let rect = NSRect(x: 5, y: 5 + CGFloat(row) * Self.rowHeight, width: bounds.width - 10, height: Self.rowHeight)
            if index == selected {
                NSColor.tmYouTint.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
            }
            let item = items[index]
            let textHeight: CGFloat = 16
            let y = rect.minY + (rect.height - textHeight) / 2
            (item.detail as NSString).draw(with: NSRect(x: rect.minX + 8, y: y, width: rect.width - 16, height: textHeight), options: [.usesLineFragmentOrigin], attributes: detail)
            (item.text as NSString).draw(with: NSRect(x: rect.minX + 8, y: y, width: rect.width - 90, height: textHeight), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: label)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = Int((point.y - 5) / Self.rowHeight) + scroll
        if items.indices.contains(row) { onPick?(row) }
    }

    override func scrollWheel(with event: NSEvent) {
        let step = event.scrollingDeltaY < 0 ? 1 : -1
        scroll = min(max(0, scroll + step), max(0, items.count - Self.visibleRows))
        needsDisplay = true
    }
}

/// An agent's note under its suggested lines, with Accept (Tab) and Dismiss (Esc), as drawn.
struct SuggestionCard: View {
    let client: String
    let note: String?
    let stale: Bool
    let accept: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(client).font(.ui(12.5, .semibold)).foregroundStyle(Color.tmAgentText)
            VStack(alignment: .leading, spacing: 2) {
                Text(note ?? String(localized: "Suggested a new version of this query."))
                    .font(.ui(12.5)).foregroundStyle(Color.tmText2)
                    .fixedSize(horizontal: false, vertical: true)
                if stale {
                    Text("Made for an earlier version of this query.").font(.ui(12)).foregroundStyle(Color.tmMuted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                Button(action: accept) {
                    HStack(spacing: 6) {
                        Text("Accept").font(.ui(12))
                        KeyCap(text: "⇥")
                    }
                }
                .buttonStyle(.secondary(height: 26))
                Button(action: dismiss) {
                    HStack(spacing: 6) {
                        Text("Dismiss").font(.ui(12))
                        KeyCap(text: "esc")
                    }
                }
                .buttonStyle(.secondary(height: 26))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(Color.tmWindow)
                .shadow(color: Color.tmShadow.opacity(0.45), radius: 12, y: 8)
        )
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.tmLine))
    }
}

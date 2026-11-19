import Foundation

public enum SQLDialect: Sendable {
    case postgres
    case sqlite
}

struct SQLToken: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// Keyword or bare identifier.
        case word
        /// Quoted identifier; `text` holds the name without quotes.
        case quoted
        /// String literal in any quoting style, including dollar-quoted bodies.
        case string
        case number
        /// `$1`, `?` and similar placeholders.
        case parameter
        /// A single punctuation or operator character.
        case symbol
        case semicolon
    }

    let kind: Kind
    let text: String
    /// Byte offsets into the UTF-8 source.
    let start: Int
    let end: Int

    var upper: String { text.uppercased() }
}

/// Splits SQL into tokens, skipping whitespace and comments. It understands every quoting style
/// that can hide a semicolon: strings, quoted identifiers, Postgres `E''` and `$tag$` bodies.
enum SQLLexer {
    static func tokenize(_ sql: String, dialect: SQLDialect) -> [SQLToken] {
        let bytes = Array(sql.utf8)
        let n = bytes.count
        var tokens: [SQLToken] = []
        var i = 0

        func slice(_ start: Int, _ end: Int) -> String {
            String(decoding: bytes[start..<min(end, n)], as: UTF8.self)
        }

        while i < n {
            let b = bytes[i]

            if b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D || b == 0x0C {
                i += 1
                continue
            }

            // -- line comment
            if b == 0x2D, i + 1 < n, bytes[i + 1] == 0x2D {
                while i < n, bytes[i] != 0x0A { i += 1 }
                continue
            }

            // /* block comment */ (Postgres allows nesting)
            if b == 0x2F, i + 1 < n, bytes[i + 1] == 0x2A {
                var depth = 1
                i += 2
                while i < n, depth > 0 {
                    if bytes[i] == 0x2A, i + 1 < n, bytes[i + 1] == 0x2F {
                        depth -= 1
                        i += 2
                    } else if dialect == .postgres, bytes[i] == 0x2F, i + 1 < n, bytes[i + 1] == 0x2A {
                        depth += 1
                        i += 2
                    } else {
                        i += 1
                    }
                }
                continue
            }

            let start = i

            switch b {
            case 0x27: // '
                i = scanQuoted(bytes, from: i, quote: 0x27, backslashEscapes: false)
                tokens.append(SQLToken(kind: .string, text: slice(start, i), start: start, end: i))
                continue
            case 0x22: // "
                i = scanQuoted(bytes, from: i, quote: 0x22, backslashEscapes: false)
                tokens.append(SQLToken(kind: .quoted, text: unquote(slice(start, i), quote: "\""), start: start, end: i))
                continue
            case 0x60 where dialect == .sqlite: // `
                i = scanQuoted(bytes, from: i, quote: 0x60, backslashEscapes: false)
                tokens.append(SQLToken(kind: .quoted, text: unquote(slice(start, i), quote: "`"), start: start, end: i))
                continue
            case 0x5B where dialect == .sqlite: // [identifier]
                i += 1
                while i < n, bytes[i] != 0x5D { i += 1 }
                let nameEnd = i
                if i < n { i += 1 }
                tokens.append(SQLToken(kind: .quoted, text: slice(start + 1, nameEnd), start: start, end: i))
                continue
            case 0x3B: // ;
                i += 1
                tokens.append(SQLToken(kind: .semicolon, text: ";", start: start, end: i))
                continue
            case 0x3F: // ?
                i += 1
                while i < n, isDigit(bytes[i]) { i += 1 }
                tokens.append(SQLToken(kind: .parameter, text: slice(start, i), start: start, end: i))
                continue
            case 0x24: // $
                if i + 1 < n, isDigit(bytes[i + 1]) {
                    i += 1
                    while i < n, isDigit(bytes[i]) { i += 1 }
                    tokens.append(SQLToken(kind: .parameter, text: slice(start, i), start: start, end: i))
                    continue
                }
                if dialect == .postgres, let tagEnd = dollarTagEnd(bytes, from: i) {
                    let tag = Array(bytes[i..<tagEnd])
                    i = tagEnd
                    var closed = false
                    while i + tag.count <= n {
                        if bytes[i] == 0x24, Array(bytes[i..<(i + tag.count)]) == tag {
                            i += tag.count
                            closed = true
                            break
                        }
                        i += 1
                    }
                    if !closed { i = n }
                    tokens.append(SQLToken(kind: .string, text: slice(start, i), start: start, end: i))
                    continue
                }
            default:
                break
            }

            if isWordStart(b) {
                while i < n, isWordChar(bytes[i]) { i += 1 }
                let word = slice(start, i)
                // Prefixed literals: E'...' (backslash escapes), X'...', B'...', N'...'
                if i < n, bytes[i] == 0x27, word.count == 1, "EeXxBbNn".contains(word) {
                    let escapes = dialect == .postgres && (word == "E" || word == "e")
                    i = scanQuoted(bytes, from: i, quote: 0x27, backslashEscapes: escapes)
                    tokens.append(SQLToken(kind: .string, text: slice(start, i), start: start, end: i))
                    continue
                }
                tokens.append(SQLToken(kind: .word, text: word, start: start, end: i))
                continue
            }

            if isDigit(b) || (b == 0x2E && i + 1 < n && isDigit(bytes[i + 1])) {
                i += 1
                while i < n, isDigit(bytes[i]) || bytes[i] == 0x2E || isWordStart(bytes[i]) { i += 1 }
                tokens.append(SQLToken(kind: .number, text: slice(start, i), start: start, end: i))
                continue
            }

            // Named parameters (:name, @name) in SQLite.
            if dialect == .sqlite, b == 0x3A || b == 0x40, i + 1 < n, isWordStart(bytes[i + 1]) {
                i += 1
                while i < n, isWordChar(bytes[i]) { i += 1 }
                tokens.append(SQLToken(kind: .parameter, text: slice(start, i), start: start, end: i))
                continue
            }

            i += 1
            tokens.append(SQLToken(kind: .symbol, text: slice(start, i), start: start, end: i))
        }
        return tokens
    }

    /// Returns the index just past the closing quote. A doubled quote is an escaped quote.
    static func scanQuoted(_ bytes: [UInt8], from start: Int, quote: UInt8, backslashEscapes: Bool) -> Int {
        var i = start + 1
        let n = bytes.count
        while i < n {
            let c = bytes[i]
            if backslashEscapes, c == 0x5C {
                i += 2
                continue
            }
            if c == quote {
                if i + 1 < n, bytes[i + 1] == quote {
                    i += 2
                    continue
                }
                return i + 1
            }
            i += 1
        }
        return n
    }

    /// For a `$tag$` opener at `start`, the index just past its second `$`; `nil` if it is not one.
    static func dollarTagEnd(_ bytes: [UInt8], from start: Int) -> Int? {
        let n = bytes.count
        var i = start + 1
        guard i < n else { return nil }
        if bytes[i] == 0x24 { return i + 1 }
        guard isWordStart(bytes[i]) else { return nil }
        while i < n, isWordStart(bytes[i]) || isDigit(bytes[i]) { i += 1 }
        guard i < n, bytes[i] == 0x24 else { return nil }
        return i + 1
    }

    static func unquote(_ text: String, quote: Character) -> String {
        var inner = Substring(text)
        if inner.first == quote { inner.removeFirst() }
        if inner.last == quote { inner.removeLast() }
        return inner.replacingOccurrences(of: String(repeating: quote, count: 2), with: String(quote))
    }

    static func isDigit(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x39 }

    static func isWordStart(_ b: UInt8) -> Bool {
        (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || b == 0x5F || b >= 0x80
    }

    static func isWordChar(_ b: UInt8) -> Bool {
        isWordStart(b) || isDigit(b) || b == 0x24
    }
}

/// Converts source bytes into tokens. Lexical errors are recorded and the
/// offending input skipped, so a single run reports every bad token.
public struct Lexer {
    private let bytes: [UInt8]
    private var position = 0
    public private(set) var diagnostics: [Diagnostic] = []

    public init(source: SourceFile) {
        self.bytes = source.bytes
    }

    public mutating func tokenize() -> [Token] {
        var tokens: [Token] = []
        while true {
            skipWhitespaceAndComments()
            guard let byte = peek() else {
                tokens.append(Token(kind: .endOfFile, span: Span(start: position, end: position)))
                return tokens
            }
            let start = position
            if let kind = lexToken(startingWith: byte) {
                tokens.append(Token(kind: kind, span: Span(start: start, end: position)))
            }
        }
    }

    private mutating func lexToken(startingWith byte: UInt8) -> TokenKind? {
        if byte.isDigit { return lexNumber() }
        if byte.isIdentifierStart { return lexIdentifier() }
        if byte == UInt8(ascii: "\"") { return lexString() }
        if let symbol = lexSymbol() { return .symbol(symbol) }

        let start = position
        advance()
        while let next = peek(), next & 0b1100_0000 == 0b1000_0000 { advance() }  // UTF-8 continuation bytes
        let character = String(decoding: bytes[start..<position], as: UTF8.self)
        diagnostics.append(.error("unexpected character '\(character)'", at: Span(start: start, end: position)))
        return nil
    }

    private mutating func lexNumber() -> TokenKind {
        let start = position
        while peek()?.isDigit == true { advance() }
        var isFloat = false
        // `1..10` is a range, so a dot only starts a fraction when a digit follows it.
        if peek() == UInt8(ascii: "."), peek(offset: 1)?.isDigit == true {
            isFloat = true
            advance()
            while peek()?.isDigit == true { advance() }
        }
        if peek() == UInt8(ascii: "e") || peek() == UInt8(ascii: "E") {
            let sign = peek(offset: 1) == UInt8(ascii: "+") || peek(offset: 1) == UInt8(ascii: "-") ? 1 : 0
            if peek(offset: 1 + sign)?.isDigit == true {
                isFloat = true
                position += 1 + sign
                while peek()?.isDigit == true { advance() }
            }
        }
        let text = String(decoding: bytes[start..<position], as: UTF8.self)
        if isFloat { return .float(Double(text)!) }
        guard let value = UInt64(text) else {
            diagnostics.append(.error("integer literal '\(text)' is too large", at: Span(start: start, end: position)))
            return .integer(0)
        }
        return .integer(value)
    }

    private mutating func lexIdentifier() -> TokenKind {
        let start = position
        while peek()?.isIdentifierContinue == true { advance() }
        let text = String(decoding: bytes[start..<position], as: UTF8.self)
        return Keyword(rawValue: text).map(TokenKind.keyword) ?? .identifier(text)
    }

    private mutating func lexString() -> TokenKind {
        let start = position
        advance()
        var content: [UInt8] = []
        while let byte = peek(), byte != UInt8(ascii: "\n") {
            advance()
            if byte == UInt8(ascii: "\"") { return .string(String(decoding: content, as: UTF8.self)) }
            guard byte == UInt8(ascii: "\\") else {
                content.append(byte)
                continue
            }
            let escapeStart = position - 1
            guard let escaped = peek() else { break }
            advance()
            switch escaped {
            case UInt8(ascii: "n"): content.append(UInt8(ascii: "\n"))
            case UInt8(ascii: "t"): content.append(UInt8(ascii: "\t"))
            case UInt8(ascii: "r"): content.append(UInt8(ascii: "\r"))
            case UInt8(ascii: "0"): content.append(0)
            case UInt8(ascii: "\\"), UInt8(ascii: "\""): content.append(escaped)
            default:
                let text = String(decoding: [escaped], as: UTF8.self)
                diagnostics.append(.error("unknown escape sequence '\\\(text)'", at: Span(start: escapeStart, end: position)))
            }
        }
        diagnostics.append(.error("unterminated string literal", at: Span(start: start, end: position)))
        return .string(String(decoding: content, as: UTF8.self))
    }

    private mutating func lexSymbol() -> Symbol? {
        for length in [2, 1] where position + length <= bytes.count {
            let text = String(decoding: bytes[position..<position + length], as: UTF8.self)
            if let symbol = Symbol(rawValue: text) {
                position += length
                return symbol
            }
        }
        return nil
    }

    private mutating func skipWhitespaceAndComments() {
        while let byte = peek() {
            if byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t") || byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r") {
                advance()
            } else if byte == UInt8(ascii: "/"), peek(offset: 1) == UInt8(ascii: "/") {
                while let next = peek(), next != UInt8(ascii: "\n") { advance() }
            } else {
                return
            }
        }
    }

    private func peek(offset: Int = 0) -> UInt8? {
        position + offset < bytes.count ? bytes[position + offset] : nil
    }

    private mutating func advance() {
        position += 1
    }
}

extension UInt8 {
    fileprivate var isDigit: Bool { self >= UInt8(ascii: "0") && self <= UInt8(ascii: "9") }

    fileprivate var isIdentifierStart: Bool {
        (self >= UInt8(ascii: "a") && self <= UInt8(ascii: "z"))
            || (self >= UInt8(ascii: "A") && self <= UInt8(ascii: "Z"))
            || self == UInt8(ascii: "_")
    }

    fileprivate var isIdentifierContinue: Bool { isIdentifierStart || isDigit }
}

public enum Keyword: String, Sendable {
    case `fn`, export, `let`, `var`, `if`, `else`, `while`, `for`, `in`
    case `return`, `break`, `continue`, `true`, `false`, `as`
}

/// Punctuation and operators. Raw values are the exact source spelling, which
/// lets the lexer do longest-match lookup with `Symbol(rawValue:)`.
public enum Symbol: String, Sendable {
    case leftParen = "(", rightParen = ")"
    case leftBrace = "{", rightBrace = "}"
    case leftBracket = "[", rightBracket = "]"
    case comma = ",", semicolon = ";", colon = ":", arrow = "->", dotDot = ".."
    case plus = "+", minus = "-", star = "*", slash = "/", percent = "%"
    case ampersand = "&", pipe = "|", caret = "^", shiftLeft = "<<", shiftRight = ">>"
    case andAnd = "&&", pipePipe = "||", bang = "!"
    case equal = "=", equalEqual = "==", bangEqual = "!="
    case less = "<", lessEqual = "<=", greater = ">", greaterEqual = ">="
    case plusEqual = "+=", minusEqual = "-=", starEqual = "*=", slashEqual = "/=", percentEqual = "%="
}

public enum TokenKind: Hashable, Sendable {
    case identifier(String)
    case integer(UInt64)
    case float(Double)
    case string(String)
    case keyword(Keyword)
    case symbol(Symbol)
    case endOfFile
}

public struct Token: Hashable, Sendable {
    public let kind: TokenKind
    public let span: Span
}

extension TokenKind: CustomStringConvertible {
    public var description: String {
        switch self {
        case .identifier(let name): "identifier '\(name)'"
        case .integer: "integer literal"
        case .float: "float literal"
        case .string: "string literal"
        case .keyword(let keyword): "'\(keyword.rawValue)'"
        case .symbol(let symbol): "'\(symbol.rawValue)'"
        case .endOfFile: "end of file"
        }
    }
}

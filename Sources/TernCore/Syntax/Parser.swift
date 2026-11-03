/// Recursive-descent parser with Pratt-style binary expressions.
///
/// Errors unwind (via `throws`) to the nearest statement or item boundary,
/// where the parser resynchronizes and keeps going so one run reports many errors.
public struct Parser {
    private struct ParseError: Error {}

    private let tokens: [Token]
    private var index = 0
    public private(set) var diagnostics: [Diagnostic] = []

    public init(tokens: [Token]) {
        self.tokens = tokens
    }

    public mutating func parseProgram() -> Program {
        var functions: [FunctionDecl] = []
        while current.kind != .endOfFile {
            let start = index
            do {
                functions.append(try parseFunction())
            } catch {
                if index == start { advance() }
                while !isAtItemStart { advance() }
            }
        }
        return Program(functions: functions)
    }

    // MARK: - Items

    private mutating func parseFunction() throws -> FunctionDecl {
        let isExported = consume(.keyword(.export))
        try expect(.keyword(.fn))
        let (name, nameSpan) = try expectIdentifier()
        try expect(.symbol(.leftParen))
        var parameters: [Parameter] = []
        while !check(.symbol(.rightParen)) {
            let (parameterName, parameterSpan) = try expectIdentifier()
            try expect(.symbol(.colon))
            parameters.append(Parameter(name: parameterName, nameSpan: parameterSpan, type: try parseType()))
            if !consume(.symbol(.comma)) { break }
        }
        try expect(.symbol(.rightParen))
        let returnType = consume(.symbol(.arrow)) ? try parseType() : nil
        let body = try parseBlock()
        return FunctionDecl(
            name: name, nameSpan: nameSpan, parameters: parameters,
            returnType: returnType, body: body, isExported: isExported
        )
    }

    private mutating func parseType() throws -> TypeExpr {
        if case .identifier(let name) = current.kind {
            return .named(name, advance().span)
        }
        let open = try expect(.symbol(.leftBracket), what: "type")
        let element = try parseType()
        try expect(.symbol(.semicolon))
        guard case .integer(let count) = current.kind else {
            throw error("expected array length, found \(current.kind)", at: current.span)
        }
        advance()
        let close = try expect(.symbol(.rightBracket))
        return .array(element: element, count: Int(clamping: count), open.through(close))
    }

    // MARK: - Statements

    private enum BlockItem {
        case statement(Stmt)
        case tail(Expr)
    }

    private mutating func parseBlock() throws -> Block {
        let open = try expect(.symbol(.leftBrace))
        var statements: [Stmt] = []
        var tail: Expr?
        while !check(.symbol(.rightBrace)) {
            if isAtItemStart {
                throw error("expected '}', found \(current.kind)", at: current.span)
            }
            let start = index
            do {
                switch try parseBlockItem() {
                case .statement(let statement): statements.append(statement)
                case .tail(let expr): tail = expr
                }
            } catch {
                synchronizeToStatement()
                if index == start { advance() }
            }
        }
        let close = advance()
        return Block(statements: statements, tail: tail, span: open.through(close.span))
    }

    private mutating func parseBlockItem() throws -> BlockItem {
        switch current.kind {
        case .keyword(.let), .keyword(.var):
            return .statement(.binding(try parseBinding()))
        case .keyword(.while):
            let start = advance().span
            let condition = try parseExpression()
            let body = try parseBlock()
            return .statement(.whileLoop(condition: condition, body: body, span: start.through(body.span)))
        case .keyword(.for):
            let start = advance().span
            let (variable, variableSpan) = try expectIdentifier()
            try expect(.keyword(.in))
            let lower = try parseExpression()
            try expect(.symbol(.dotDot))
            let upper = try parseExpression()
            let body = try parseBlock()
            return .statement(.forLoop(
                variable: variable, variableSpan: variableSpan,
                start: lower, end: upper, body: body, span: start.through(body.span)
            ))
        case .keyword(.return):
            let start = advance().span
            let value = check(.symbol(.semicolon)) || check(.symbol(.rightBrace)) ? nil : try parseExpression()
            let end = try expectSemicolon()
            return .statement(.returnStmt(value, span: start.through(end)))
        case .keyword(.break):
            let start = advance().span
            return .statement(.breakStmt(span: start.through(try expectSemicolon())))
        case .keyword(.continue):
            let start = advance().span
            return .statement(.continueStmt(span: start.through(try expectSemicolon())))
        default:
            return try parseExpressionItem()
        }
    }

    private mutating func parseBinding() throws -> Binding {
        let start = current.span
        let isMutable = advance().kind == .keyword(.var)
        let (name, nameSpan) = try expectIdentifier()
        let type = consume(.symbol(.colon)) ? try parseType() : nil
        try expect(.symbol(.equal))
        let value = try parseExpression()
        let end = try expectSemicolon()
        return Binding(isMutable: isMutable, name: name, nameSpan: nameSpan, type: type, value: value, span: start.through(end))
    }

    private mutating func parseExpressionItem() throws -> BlockItem {
        let expr = try parseExpression()
        if case .symbol(let symbol) = current.kind, let op = Self.assignmentOperators[symbol] {
            advance()
            let value = try parseExpression()
            let end = try expectSemicolon()
            return .statement(.assign(target: expr, op: op, value: value, span: expr.span.through(end)))
        }
        if consume(.symbol(.semicolon)) { return .statement(.expr(expr)) }
        if check(.symbol(.rightBrace)) { return .tail(expr) }
        switch expr.kind {
        case .ifElse, .block: return .statement(.expr(expr))
        default:
            try expectSemicolon()
            return .statement(.expr(expr))
        }
    }

    /// Maps assignment tokens to their compound operator; plain `=` maps to `nil`.
    private static let assignmentOperators: [Symbol: BinaryOp?] = [
        .equal: nil, .plusEqual: .add, .minusEqual: .subtract,
        .starEqual: .multiply, .slashEqual: .divide, .percentEqual: .remainder,
    ]

    // MARK: - Expressions

    private static let castPrecedence = 10

    private static func binaryOperator(for symbol: Symbol) -> (op: BinaryOp, precedence: Int)? {
        switch symbol {
        case .pipePipe: (.or, 1)
        case .andAnd: (.and, 2)
        case .equalEqual: (.equal, 3)
        case .bangEqual: (.notEqual, 3)
        case .less: (.less, 3)
        case .lessEqual: (.lessEqual, 3)
        case .greater: (.greater, 3)
        case .greaterEqual: (.greaterEqual, 3)
        case .pipe: (.bitOr, 4)
        case .caret: (.bitXor, 5)
        case .ampersand: (.bitAnd, 6)
        case .shiftLeft: (.shiftLeft, 7)
        case .shiftRight: (.shiftRight, 7)
        case .plus: (.add, 8)
        case .minus: (.subtract, 8)
        case .star: (.multiply, 9)
        case .slash: (.divide, 9)
        case .percent: (.remainder, 9)
        default: nil
        }
    }

    private mutating func parseExpression(minimumPrecedence: Int = 1) throws -> Expr {
        var lhs = try parseUnary()
        while true {
            if check(.keyword(.as)), Self.castPrecedence >= minimumPrecedence {
                advance()
                let type = try parseType()
                lhs = Expr(kind: .cast(lhs, type), span: lhs.span.through(type.span))
            } else if case .symbol(let symbol) = current.kind,
                      let binary = Self.binaryOperator(for: symbol),
                      binary.precedence >= minimumPrecedence {
                advance()
                let rhs = try parseExpression(minimumPrecedence: binary.precedence + 1)
                lhs = Expr(kind: .binary(binary.op, lhs, rhs), span: lhs.span.through(rhs.span))
            } else {
                return lhs
            }
        }
    }

    private mutating func parseUnary() throws -> Expr {
        let op: UnaryOp? = switch current.kind {
        case .symbol(.minus): .negate
        case .symbol(.bang): .not
        default: nil
        }
        guard let op else { return try parsePostfix() }
        let start = advance().span
        let operand = try parseUnary()
        return Expr(kind: .unary(op, operand), span: start.through(operand.span))
    }

    private mutating func parsePostfix() throws -> Expr {
        var expr = try parsePrimary()
        while consume(.symbol(.leftBracket)) {
            let index = try parseExpression()
            let close = try expect(.symbol(.rightBracket))
            expr = Expr(kind: .index(expr, index), span: expr.span.through(close))
        }
        return expr
    }

    private mutating func parsePrimary() throws -> Expr {
        let token = current
        switch token.kind {
        case .integer(let value):
            advance()
            return Expr(kind: .integer(value), span: token.span)
        case .float(let value):
            advance()
            return Expr(kind: .float(value), span: token.span)
        case .string(let value):
            advance()
            return Expr(kind: .string(value), span: token.span)
        case .keyword(.true), .keyword(.false):
            advance()
            return Expr(kind: .bool(token.kind == .keyword(.true)), span: token.span)
        case .identifier(let name):
            advance()
            guard consume(.symbol(.leftParen)) else {
                return Expr(kind: .identifier(name), span: token.span)
            }
            var arguments: [Expr] = []
            while !check(.symbol(.rightParen)) {
                arguments.append(try parseExpression())
                if !consume(.symbol(.comma)) { break }
            }
            let close = try expect(.symbol(.rightParen))
            return Expr(kind: .call(callee: name, calleeSpan: token.span, arguments: arguments), span: token.span.through(close))
        case .symbol(.leftParen):
            advance()
            let inner = try parseExpression()
            let close = try expect(.symbol(.rightParen))
            return Expr(kind: inner.kind, span: token.span.through(close))
        case .symbol(.leftBracket):
            return try parseArrayLiteral()
        case .symbol(.leftBrace):
            let block = try parseBlock()
            return Expr(kind: .block(block), span: block.span)
        case .keyword(.if):
            return try parseIf()
        default:
            throw error("expected expression, found \(token.kind)", at: token.span)
        }
    }

    private mutating func parseArrayLiteral() throws -> Expr {
        let open = advance().span
        if check(.symbol(.rightBracket)) {
            throw error("array literals must have at least one element", at: open.through(current.span))
        }
        let first = try parseExpression()
        if consume(.symbol(.semicolon)) {
            guard case .integer(let count) = current.kind else {
                throw error("expected array length, found \(current.kind)", at: current.span)
            }
            advance()
            let close = try expect(.symbol(.rightBracket))
            return Expr(kind: .arrayRepeat(first, count: Int(clamping: count)), span: open.through(close))
        }
        var elements = [first]
        while consume(.symbol(.comma)), !check(.symbol(.rightBracket)) {
            elements.append(try parseExpression())
        }
        let close = try expect(.symbol(.rightBracket))
        return Expr(kind: .arrayList(elements), span: open.through(close))
    }

    private mutating func parseIf() throws -> Expr {
        let start = advance().span
        let condition = try parseExpression()
        let then = try parseBlock()
        var elseBranch: Expr?
        if consume(.keyword(.else)) {
            if check(.keyword(.if)) {
                elseBranch = try parseIf()
            } else {
                let block = try parseBlock()
                elseBranch = Expr(kind: .block(block), span: block.span)
            }
        }
        let end = elseBranch?.span ?? then.span
        return Expr(kind: .ifElse(condition: condition, then: then, else: elseBranch), span: start.through(end))
    }

    // MARK: - Token helpers

    private var current: Token { tokens[index] }

    private var isAtItemStart: Bool {
        check(.keyword(.fn)) || check(.keyword(.export)) || check(.endOfFile)
    }

    @discardableResult
    private mutating func advance() -> Token {
        let token = tokens[index]
        if index < tokens.count - 1 { index += 1 }
        return token
    }

    private func check(_ kind: TokenKind) -> Bool {
        current.kind == kind
    }

    private mutating func consume(_ kind: TokenKind) -> Bool {
        guard check(kind) else { return false }
        advance()
        return true
    }

    @discardableResult
    private mutating func expect(_ kind: TokenKind, what: String? = nil) throws -> Span {
        guard check(kind) else {
            throw error("expected \(what ?? kind.description), found \(current.kind)", at: current.span)
        }
        return advance().span
    }

    /// A missing `;` is reported just after the previous token, which is where
    /// the reader expects it, rather than at whatever starts the next line.
    @discardableResult
    private mutating func expectSemicolon() throws -> Span {
        guard check(.symbol(.semicolon)) else {
            let end = tokens[max(index - 1, 0)].span.end
            throw error("expected ';', found \(current.kind)", at: Span(start: end, end: end))
        }
        return advance().span
    }

    private mutating func expectIdentifier() throws -> (String, Span) {
        guard case .identifier(let name) = current.kind else {
            throw error("expected identifier, found \(current.kind)", at: current.span)
        }
        return (name, advance().span)
    }

    private mutating func error(_ message: String, at span: Span) -> ParseError {
        diagnostics.append(.error(message, at: span))
        return ParseError()
    }

    private mutating func synchronizeToStatement() {
        var depth = 0
        while !isAtItemStart {
            switch current.kind {
            case .symbol(.semicolon) where depth == 0:
                advance()
                return
            case .symbol(.leftBrace):
                depth += 1
            case .symbol(.rightBrace):
                if depth == 0 { return }
                depth -= 1
            case .keyword(.let), .keyword(.var), .keyword(.while), .keyword(.for),
                 .keyword(.return), .keyword(.break), .keyword(.continue):
                if depth == 0 { return }
            default:
                break
            }
            advance()
        }
    }
}

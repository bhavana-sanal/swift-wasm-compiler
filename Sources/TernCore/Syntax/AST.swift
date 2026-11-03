/// The untyped syntax tree produced by the ``Parser``.
public struct Program: Sendable {
    public var functions: [FunctionDecl]
}

public struct FunctionDecl: Sendable {
    public var name: String
    public var nameSpan: Span
    public var parameters: [Parameter]
    public var returnType: TypeExpr?
    public var body: Block
    public var isExported: Bool
}

public struct Parameter: Sendable {
    public var name: String
    public var nameSpan: Span
    public var type: TypeExpr
}

public indirect enum TypeExpr: Sendable {
    case named(String, Span)
    case array(element: TypeExpr, count: Int, Span)

    public var span: Span {
        switch self {
        case .named(_, let span), .array(_, _, let span): span
        }
    }
}

public struct Block: Sendable {
    public var statements: [Stmt]
    /// The trailing expression without a semicolon, which becomes the block's value.
    public var tail: Expr?
    public var span: Span
}

public struct Binding: Sendable {
    public var isMutable: Bool
    public var name: String
    public var nameSpan: Span
    public var type: TypeExpr?
    public var value: Expr
    public var span: Span
}

public enum Stmt: Sendable {
    case binding(Binding)
    /// `target = value`, or a compound assignment such as `target += value` when `op` is set.
    case assign(target: Expr, op: BinaryOp?, value: Expr, span: Span)
    case expr(Expr)
    case whileLoop(condition: Expr, body: Block, span: Span)
    case forLoop(variable: String, variableSpan: Span, start: Expr, end: Expr, body: Block, span: Span)
    case returnStmt(Expr?, span: Span)
    case breakStmt(span: Span)
    case continueStmt(span: Span)

    public var span: Span {
        switch self {
        case .binding(let binding): binding.span
        case .expr(let expr): expr.span
        case .assign(_, _, _, let span), .whileLoop(_, _, let span), .forLoop(_, _, _, _, _, let span),
             .returnStmt(_, let span), .breakStmt(let span), .continueStmt(let span):
            span
        }
    }
}

public struct Expr: Sendable {
    public var kind: ExprKind
    public var span: Span
}

public indirect enum ExprKind: Sendable {
    case integer(UInt64)
    case float(Double)
    case bool(Bool)
    case string(String)
    case identifier(String)
    case unary(UnaryOp, Expr)
    case binary(BinaryOp, Expr, Expr)
    case call(callee: String, calleeSpan: Span, arguments: [Expr])
    case index(Expr, Expr)
    case cast(Expr, TypeExpr)
    /// `else` holds either a block expression or another `if` for `else if` chains.
    case ifElse(condition: Expr, then: Block, else: Expr?)
    case block(Block)
    case arrayList([Expr])
    case arrayRepeat(Expr, count: Int)
}

public enum UnaryOp: String, Sendable {
    case negate = "-"
    case not = "!"
}

public enum BinaryOp: String, Sendable {
    case add = "+", subtract = "-", multiply = "*", divide = "/", remainder = "%"
    case bitAnd = "&", bitOr = "|", bitXor = "^", shiftLeft = "<<", shiftRight = ">>"
    case equal = "==", notEqual = "!=", less = "<", lessEqual = "<=", greater = ">", greaterEqual = ">="
    case and = "&&", or = "||"

    var isComparison: Bool {
        switch self {
        case .equal, .notEqual, .less, .lessEqual, .greater, .greaterEqual: true
        default: false
        }
    }

    var isLogical: Bool { self == .and || self == .or }

    /// Operators defined only on integers (`%` too, since Wasm has no `f64.rem`).
    var isIntegerOnly: Bool {
        switch self {
        case .remainder, .bitAnd, .bitOr, .bitXor, .shiftLeft, .shiftRight: true
        default: false
        }
    }
}

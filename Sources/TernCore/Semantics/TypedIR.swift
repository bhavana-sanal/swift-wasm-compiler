/// The checked program: every name is resolved to a local slot or function
/// index and every expression carries its type. The optimizer and the Wasm
/// lowering both work on this form.
public struct TypedProgram: Sendable {
    public var functions: [TypedFunction]
    /// Host functions the program calls, in import order.
    public var imports: [Builtin]
}

public struct TypedFunction: Sendable {
    public var name: String
    public var isExported: Bool
    /// Parameters occupy the first `parameterCount` entries of `locals`.
    public var parameterCount: Int
    public var result: TernType
    public var locals: [Local]
    public var body: TypedBlock
}

public struct Local: Sendable {
    public var name: String
    public var type: TernType
}

public enum Builtin: String, CaseIterable, Sendable {
    case printI32 = "print_i32"
    case printI64 = "print_i64"
    case printF64 = "print_f64"
    case printStr = "print_str"

    var parameter: TernType {
        switch self {
        case .printI32: .i32
        case .printI64: .i64
        case .printF64: .f64
        case .printStr: .str
        }
    }
}

public enum Callee: Sendable {
    case function(Int)
    case builtin(Builtin)
}

public struct TypedBlock: Sendable {
    public var statements: [TypedStmt]
    public var tail: TypedExpr?
    public var type: TernType
}

public indirect enum TypedStmt: Sendable {
    /// Also initializes array locals, in which case the value is an array literal.
    case assign(local: Int, op: BinaryOp?, value: TypedExpr)
    case assignElement(local: Int, index: TypedExpr, op: BinaryOp?, value: TypedExpr)
    case expr(TypedExpr)
    case whileLoop(condition: TypedExpr, body: TypedBlock)
    case forLoop(local: Int, start: TypedExpr, end: TypedExpr, body: TypedBlock)
    case returnValue(TypedExpr?)
    case breakLoop
    case continueLoop

    /// True when control never reaches the next statement.
    var diverges: Bool {
        switch self {
        case .returnValue, .breakLoop, .continueLoop: true
        case .expr(let expr), .assign(_, _, let expr): expr.type == .never
        case .assignElement(_, let index, _, let value): index.type == .never || value.type == .never
        case .whileLoop, .forLoop: false
        }
    }
}

public struct TypedExpr: Sendable {
    public var kind: TypedExprKind
    public var type: TernType
}

public indirect enum TypedExprKind: Sendable {
    /// `i32` constants are stored sign-extended.
    case int(Int64)
    case float(Double)
    case bool(Bool)
    case string(String)
    case local(Int)
    case unary(UnaryOp, TypedExpr)
    case binary(BinaryOp, TypedExpr, TypedExpr)
    case call(Callee, [TypedExpr])
    case element(local: Int, index: TypedExpr)
    /// Converts the operand to the expression's type.
    case cast(TypedExpr)
    case ifElse(condition: TypedExpr, then: TypedBlock, else: TypedBlock?)
    case block(TypedBlock)
    case arrayList([TypedExpr])
    /// Fills every element (the count comes from the array type).
    case arrayRepeat(TypedExpr)
}

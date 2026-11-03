/// Constant folding and dead-code elimination over the typed IR.
///
/// - Unary, binary, comparison, logical and cast operations on constants are
///   evaluated with the same semantics as the Wasm instructions they replace:
///   integers wrap, shifts mask their count, float-to-int casts saturate.
/// - Integer division is folded only when it cannot trap, so `1 / 0` still
///   traps at run time instead of being rejected or silently changed.
/// - `true && x` becomes `x`, `false && x` becomes `false` (and likewise for `||`).
/// - `if` with a constant condition is replaced by the branch it takes;
///   `while false` loops and branches that fold to nothing are removed.
/// - Statements after `return`, `break` or `continue` are dropped.
enum Optimizer {
    static func optimize(_ program: TypedProgram) -> TypedProgram {
        var program = program
        for index in program.functions.indices {
            program.functions[index].body = fold(program.functions[index].body)
        }
        return program
    }

    static func fold(_ block: TypedBlock) -> TypedBlock {
        var statements: [TypedStmt] = []
        for statement in block.statements {
            guard let folded = fold(statement) else { continue }
            statements.append(folded)
            if folded.diverges {
                return TypedBlock(statements: statements, tail: nil, type: block.type)
            }
        }
        return TypedBlock(statements: statements, tail: block.tail.map(fold), type: block.type)
    }

    private static func fold(_ statement: TypedStmt) -> TypedStmt? {
        switch statement {
        case .assign(let local, let op, let value):
            return .assign(local: local, op: op, value: fold(value))
        case .assignElement(let local, let index, let op, let value):
            return .assignElement(local: local, index: fold(index), op: op, value: fold(value))
        case .expr(let expr):
            let folded = fold(expr)
            if case .block(let block) = folded.kind, block.statements.isEmpty, block.tail == nil { return nil }
            return .expr(folded)
        case .whileLoop(let condition, let body):
            let condition = fold(condition)
            if case .bool(false) = condition.kind { return nil }
            return .whileLoop(condition: condition, body: fold(body))
        case .forLoop(let local, let start, let end, let body):
            return .forLoop(local: local, start: fold(start), end: fold(end), body: fold(body))
        case .returnValue(let value):
            return .returnValue(value.map(fold))
        case .breakLoop, .continueLoop:
            return statement
        }
    }

    static func fold(_ expr: TypedExpr) -> TypedExpr {
        let type = expr.type
        switch expr.kind {
        case .int, .float, .bool, .string, .local:
            return expr
        case .unary(let op, let operand):
            let operand = fold(operand)
            let folded = foldUnary(op, operand.kind, type: type)
            return TypedExpr(kind: folded ?? .unary(op, operand), type: type)
        case .binary(let op, let lhs, let rhs):
            let lhs = fold(lhs), rhs = fold(rhs)
            if op.isLogical, case .bool(let value) = lhs.kind {
                return (op == .and) == value ? rhs : lhs
            }
            return TypedExpr(kind: foldBinary(op, lhs, rhs) ?? .binary(op, lhs, rhs), type: type)
        case .call(let callee, let arguments):
            return TypedExpr(kind: .call(callee, arguments.map(fold)), type: type)
        case .element(let local, let index):
            return TypedExpr(kind: .element(local: local, index: fold(index)), type: type)
        case .cast(let operand):
            let operand = fold(operand)
            return TypedExpr(kind: foldCast(operand.kind, to: type) ?? .cast(operand), type: type)
        case .ifElse(let condition, let then, let elseBranch):
            let condition = fold(condition)
            guard case .bool(let value) = condition.kind else {
                return TypedExpr(kind: .ifElse(condition: condition, then: fold(then), else: elseBranch.map(fold)), type: type)
            }
            let taken = value ? then : elseBranch ?? TypedBlock(statements: [], tail: nil, type: .unit)
            return flatten(fold(taken), type: type)
        case .block(let block):
            return flatten(fold(block), type: type)
        case .arrayList(let elements):
            return TypedExpr(kind: .arrayList(elements.map(fold)), type: type)
        case .arrayRepeat(let element):
            return TypedExpr(kind: .arrayRepeat(fold(element)), type: type)
        }
    }

    /// A block holding nothing but a value is just that value.
    private static func flatten(_ block: TypedBlock, type: TernType) -> TypedExpr {
        if block.statements.isEmpty, let tail = block.tail { return tail }
        return TypedExpr(kind: .block(block), type: type)
    }

    private static func foldUnary(_ op: UnaryOp, _ operand: TypedExprKind, type: TernType) -> TypedExprKind? {
        switch (op, operand) {
        case (.negate, .int(let value)):
            type == .i32 ? .int(Int64(0 &- Int32(truncatingIfNeeded: value))) : .int(0 &- value)
        case (.negate, .float(let value)):
            .float(-value)
        case (.not, .bool(let value)):
            .bool(!value)
        default:
            nil
        }
    }

    private static func foldBinary(_ op: BinaryOp, _ lhs: TypedExpr, _ rhs: TypedExpr) -> TypedExprKind? {
        switch (lhs.kind, rhs.kind) {
        case (.int(let a), .int(let b)):
            lhs.type == .i32
                ? foldInteger(op, Int32(truncatingIfNeeded: a), Int32(truncatingIfNeeded: b))
                : foldInteger(op, a, b)
        case (.float(let a), .float(let b)):
            foldFloat(op, a, b)
        case (.bool(let a), .bool(let b)):
            op == .equal ? .bool(a == b) : op == .notEqual ? .bool(a != b) : nil
        default:
            nil
        }
    }

    private static func foldInteger<T: FixedWidthInteger & SignedInteger>(_ op: BinaryOp, _ a: T, _ b: T) -> TypedExprKind? {
        let value: T
        switch op {
        case .add: value = a &+ b
        case .subtract: value = a &- b
        case .multiply: value = a &* b
        case .divide:
            // Overflow here means a zero divisor or `min / -1`, both of which trap in Wasm.
            let (quotient, overflow) = a.dividedReportingOverflow(by: b)
            if overflow { return nil }
            value = quotient
        case .remainder:
            // `min % -1` is 0 in Wasm, which is what `partialValue` holds.
            if b == 0 { return nil }
            value = a.remainderReportingOverflow(dividingBy: b).partialValue
        case .bitAnd: value = a & b
        case .bitOr: value = a | b
        case .bitXor: value = a ^ b
        case .shiftLeft: value = a &<< b
        case .shiftRight: value = a &>> b
        case .equal: return .bool(a == b)
        case .notEqual: return .bool(a != b)
        case .less: return .bool(a < b)
        case .lessEqual: return .bool(a <= b)
        case .greater: return .bool(a > b)
        case .greaterEqual: return .bool(a >= b)
        case .and, .or: return nil
        }
        return .int(Int64(value))
    }

    private static func foldFloat(_ op: BinaryOp, _ a: Double, _ b: Double) -> TypedExprKind? {
        switch op {
        case .add: .float(a + b)
        case .subtract: .float(a - b)
        case .multiply: .float(a * b)
        case .divide: .float(a / b)
        case .equal: .bool(a == b)
        case .notEqual: .bool(a != b)
        case .less: .bool(a < b)
        case .lessEqual: .bool(a <= b)
        case .greater: .bool(a > b)
        case .greaterEqual: .bool(a >= b)
        default: nil
        }
    }

    private static func foldCast(_ operand: TypedExprKind, to target: TernType) -> TypedExprKind? {
        switch (operand, target) {
        case (.int(let value), .i32): .int(Int64(Int32(truncatingIfNeeded: value)))
        case (.int(let value), .i64): .int(value)
        case (.int(let value), .f64): .float(Double(value))
        case (.float(let value), .i32): .int(Int64(saturatingTruncation(value, as: Int32.self)))
        case (.float(let value), .i64): .int(saturatingTruncation(value, as: Int64.self))
        case (.bool(let value), .i32), (.bool(let value), .i64): .int(value ? 1 : 0)
        default: nil
        }
    }

    /// Mirrors `trunc_sat_f64_s`: NaN becomes 0 and out-of-range values clamp.
    static func saturatingTruncation<T: FixedWidthInteger>(_ value: Double, as type: T.Type) -> T {
        if value.isNaN { return 0 }
        if value <= Double(T.min) { return T.min }
        if value >= Double(T.max) { return T.max }
        return T(value)
    }
}

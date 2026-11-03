/// Resolves names and checks types, producing a ``TypedProgram``.
///
/// Type information flows both ways: an `expected` type is passed down as a
/// hint (so `let x: i64 = 5` types the literal as `i64`) and the synthesized
/// type flows back up, where callers report mismatches with ``coerce(_:to:at:)``.
public struct Checker {
    private struct Signature {
        var parameters: [TernType]
        var result: TernType
    }

    private struct Variable {
        var local: Int
        var isMutable: Bool
    }

    public private(set) var diagnostics: [Diagnostic] = []
    private var signatures: [Signature] = []
    private var functionIndices: [String: Int] = [:]
    private var usedBuiltins: Set<Builtin> = []

    // State for the function currently being checked.
    private var locals: [Local] = []
    private var scopes: [[String: Variable]] = []
    private var loopDepth = 0
    private var returnType: TernType = .unit

    public init() {}

    public mutating func check(_ program: Program) -> TypedProgram {
        declareFunctions(program.functions)
        var functions: [TypedFunction] = []
        for (declaration, signature) in zip(program.functions, signatures) {
            functions.append(checkFunction(declaration, signature: signature))
        }
        return TypedProgram(functions: functions, imports: Builtin.allCases.filter(usedBuiltins.contains))
    }

    // MARK: - Declarations

    private mutating func declareFunctions(_ declarations: [FunctionDecl]) {
        for (index, declaration) in declarations.enumerated() {
            let parameters = declaration.parameters.map { resolveSignatureType($0.type) }
            let result = declaration.returnType.map { resolveSignatureType($0) } ?? .unit
            if Builtin(rawValue: declaration.name) != nil {
                report("'\(declaration.name)' is a builtin function and cannot be redefined", at: declaration.nameSpan)
            } else if functionIndices[declaration.name] != nil {
                report("function '\(declaration.name)' is already defined", at: declaration.nameSpan)
            } else {
                functionIndices[declaration.name] = index
            }
            signatures.append(Signature(parameters: parameters, result: result))
        }
    }

    private mutating func checkFunction(_ declaration: FunctionDecl, signature: Signature) -> TypedFunction {
        locals = []
        scopes = [[:]]
        loopDepth = 0
        returnType = signature.result

        for (parameter, type) in zip(declaration.parameters, signature.parameters) {
            if scopes[0][parameter.name] != nil {
                report("duplicate parameter '\(parameter.name)'", at: parameter.nameSpan)
            }
            declare(parameter.name, type: type, isMutable: false)
        }

        let body = checkBlock(declaration.body, expected: signature.result)
        if !body.type.conforms(to: signature.result) {
            if let tail = declaration.body.tail {
                report(mismatch: signature.result, found: body.type, at: tail.span)
            } else {
                let close = Span(start: declaration.body.span.end - 1, end: declaration.body.span.end)
                report("function '\(declaration.name)' must return a value of type '\(signature.result)'", at: close)
            }
        }

        return TypedFunction(
            name: declaration.name, isExported: declaration.isExported,
            parameterCount: declaration.parameters.count, result: signature.result,
            locals: locals, body: body
        )
    }

    // MARK: - Types

    private mutating func resolveType(_ type: TypeExpr) -> TernType {
        switch type {
        case .named(let name, let span):
            if let resolved = TernType.named[name] { return resolved }
            report("unknown type '\(name)'", at: span, suggestingFrom: TernType.named.keys, for: name)
            return .error
        case .array(let element, let count, let span):
            return arrayType(element: resolveType(element), count: count, at: span)
        }
    }

    private mutating func resolveSignatureType(_ type: TypeExpr) -> TernType {
        let resolved = resolveType(type)
        if case .array = resolved {
            report("arrays cannot be passed to or returned from functions", at: type.span)
            return .error
        }
        return resolved
    }

    private mutating func arrayType(element: TernType, count: Int, at span: Span) -> TernType {
        guard element != .error else { return .error }
        guard element.isScalar else {
            report("array elements must be of type i32, i64, f64, bool or str, found '\(element)'", at: span)
            return .error
        }
        guard count >= 1 else {
            report("array length must be at least 1", at: span)
            return .error
        }
        let (bytes, overflow) = count.multipliedReportingOverflow(by: element.byteSize)
        guard !overflow, bytes <= LinearMemory.stackSize else {
            report("array '[\(element); \(count)]' does not fit in the \(LinearMemory.stackSize)-byte stack", at: span)
            return .error
        }
        return .array(element: element, count: count)
    }

    // MARK: - Statements

    private mutating func checkBlock(_ block: Block, expected: TernType?) -> TypedBlock {
        scopes.append([:])
        defer { scopes.removeLast() }

        var statements: [TypedStmt] = []
        var diverges = false
        var firstUnreachable: Span?
        for statement in block.statements {
            if diverges, firstUnreachable == nil { firstUnreachable = statement.span }
            if let typed = checkStatement(statement) {
                statements.append(typed)
                diverges = diverges || typed.diverges
            }
        }
        var tail: TypedExpr?
        if let expr = block.tail {
            if diverges, firstUnreachable == nil { firstUnreachable = expr.span }
            tail = checkExpression(expr, expected: expected)
        }
        if let firstUnreachable {
            diagnostics.append(.warning("unreachable code", at: firstUnreachable))
        }
        return TypedBlock(statements: statements, tail: tail, type: diverges ? .never : tail?.type ?? .unit)
    }

    private mutating func checkStatement(_ statement: Stmt) -> TypedStmt? {
        switch statement {
        case .binding(let binding):
            return checkBinding(binding)
        case .assign(let target, let op, let value, _):
            return checkAssignment(target: target, op: op, value: value)
        case .expr(let expr):
            return .expr(checkExpression(expr, expected: nil))
        case .whileLoop(let condition, let body, _):
            let typedCondition = checkExpression(condition, expected: .bool)
            coerce(typedCondition, to: .bool, at: condition.span)
            return .whileLoop(condition: typedCondition, body: checkLoopBody(body))
        case .forLoop(let variable, _, let start, let end, let body, _):
            let (lower, upper) = checkOperands(start, end, hint: nil)
            var type = lower.type
            if type != .error, !type.isInteger {
                report("range bounds must be 'i32' or 'i64', found '\(type)'", at: start.span)
                type = .error
            } else {
                coerce(upper, to: type, at: end.span)
            }
            scopes.append([:])
            defer { scopes.removeLast() }
            let local = declare(variable, type: type, isMutable: false)
            return .forLoop(local: local, start: lower, end: upper, body: checkLoopBody(body))
        case .returnStmt(let value, let span):
            guard let value else {
                if returnType != .unit, returnType != .error {
                    report("missing return value; function returns '\(returnType)'", at: span)
                }
                return .returnValue(nil)
            }
            let typed = checkExpression(value, expected: returnType)
            coerce(typed, to: returnType, at: value.span)
            return .returnValue(typed)
        case .breakStmt(let span):
            if loopDepth == 0 { report("'break' outside of a loop", at: span) }
            return .breakLoop
        case .continueStmt(let span):
            if loopDepth == 0 { report("'continue' outside of a loop", at: span) }
            return .continueLoop
        }
    }

    private mutating func checkLoopBody(_ body: Block) -> TypedBlock {
        loopDepth += 1
        defer { loopDepth -= 1 }
        let typed = checkBlock(body, expected: nil)
        if let tail = body.tail, !typed.type.conforms(to: .unit) {
            report(mismatch: .unit, found: typed.type, at: tail.span)
        }
        return typed
    }

    private mutating func checkBinding(_ binding: Binding) -> TypedStmt? {
        let declared = binding.type.map { resolveType($0) }
        let value = switch binding.value.kind {
        case .arrayList, .arrayRepeat: checkArrayLiteral(binding.value, expected: declared)
        default: checkExpression(binding.value, expected: declared)
        }
        if let declared { coerce(value, to: declared, at: binding.value.span) }

        var type = declared ?? value.type
        if value.type == .never {
            // The initializer always exits (e.g. both branches return), so there
            // is nothing to store. The name is still declared so later references
            // aren't reported as unknown; the optimizer removes them as dead code.
            declare(binding.name, type: .never, isMutable: binding.isMutable)
            return .expr(value)
        }
        if type == .unit {
            report("cannot bind '\(binding.name)' to a value of type '()'", at: binding.value.span)
            type = .error
        }
        let local = declare(binding.name, type: type, isMutable: binding.isMutable)
        return .assign(local: local, op: nil, value: value)
    }

    private mutating func checkArrayLiteral(_ expr: Expr, expected: TernType?) -> TypedExpr {
        var hint: TernType?
        if case .array(let element, _) = expected { hint = element }

        switch expr.kind {
        case .arrayList(let elements):
            var typed: [TypedExpr] = []
            var elementType = hint
            for element in elements {
                let value = checkExpression(element, expected: elementType)
                if let elementType {
                    coerce(value, to: elementType, at: element.span)
                } else {
                    elementType = value.type
                }
                typed.append(value)
            }
            let type = arrayType(element: elementType ?? .error, count: elements.count, at: expr.span)
            return TypedExpr(kind: .arrayList(typed), type: type)
        case .arrayRepeat(let element, let count):
            let value = checkExpression(element, expected: hint)
            if let hint { coerce(value, to: hint, at: element.span) }
            let type = arrayType(element: hint ?? value.type, count: count, at: expr.span)
            return TypedExpr(kind: .arrayRepeat(value), type: type)
        default:
            preconditionFailure("checkArrayLiteral called on a non-array expression")
        }
    }

    private mutating func checkAssignment(target: Expr, op: BinaryOp?, value: Expr) -> TypedStmt? {
        let operatorName = op.map { "\($0.rawValue)=" } ?? "="
        switch target.kind {
        case .identifier(let name):
            guard let variable = lookup(name, at: target.span) else {
                _ = checkExpression(value, expected: nil)
                return nil
            }
            let type = locals[variable.local].type
            if case .array = type {
                report("cannot assign to array '\(name)' as a whole", at: target.span,
                       help: "assign to individual elements, like '\(name)[0] = ...'")
                return nil
            }
            if !variable.isMutable {
                report("cannot assign to immutable variable '\(name)'", at: target.span,
                       help: "declare it with 'var' to make it mutable")
            }
            let typed = checkAssignedValue(value, type: type, op: op, operatorName: operatorName)
            return .assign(local: variable.local, op: op, value: typed)

        case .index(let base, let index):
            guard let array = resolveArray(base) else {
                _ = checkExpression(index, expected: .i32)
                _ = checkExpression(value, expected: nil)
                return nil
            }
            if !array.isMutable, case .identifier(let name) = base.kind {
                report("cannot assign to an element of immutable array '\(name)'", at: target.span,
                       help: "declare it with 'var' to make it mutable")
            }
            let typedIndex = checkIndex(index)
            let typed = checkAssignedValue(value, type: array.element, op: op, operatorName: operatorName)
            return .assignElement(local: array.local, index: typedIndex, op: op, value: typed)

        default:
            report("invalid assignment target", at: target.span)
            _ = checkExpression(value, expected: nil)
            return nil
        }
    }

    private mutating func checkAssignedValue(_ value: Expr, type: TernType, op: BinaryOp?, operatorName: String) -> TypedExpr {
        let typed = checkExpression(value, expected: type)
        if let op, type != .error, !Self.supports(op, type) {
            report("operator '\(operatorName)' cannot be applied to '\(type)'", at: value.span)
        } else {
            coerce(typed, to: type, at: value.span)
        }
        return typed
    }

    // MARK: - Expressions

    private mutating func checkExpression(_ expr: Expr, expected: TernType?) -> TypedExpr {
        switch expr.kind {
        case .integer(let value):
            return integerLiteral(value, negated: false, expected: expected, at: expr.span)
        case .float(let value):
            return TypedExpr(kind: .float(value), type: .f64)
        case .bool(let value):
            return TypedExpr(kind: .bool(value), type: .bool)
        case .string(let value):
            return TypedExpr(kind: .string(value), type: .str)

        case .identifier(let name):
            guard let variable = lookup(name, at: expr.span) else { return .invalid }
            let type = locals[variable.local].type
            if case .array = type {
                report("array '\(name)' cannot be used as a value", at: expr.span, help: "index into it, like '\(name)[0]'")
                return .invalid
            }
            return TypedExpr(kind: .local(variable.local), type: type)

        case .unary(let op, let operand):
            if op == .negate, case .integer(let value) = operand.kind {
                return integerLiteral(value, negated: true, expected: expected, at: expr.span)
            }
            let typed = checkExpression(operand, expected: op == .not ? .bool : expected)
            guard typed.type != .error else { return .invalid }
            guard op == .not ? typed.type == .bool : typed.type.isNumeric else {
                report("unary operator '\(op.rawValue)' cannot be applied to '\(typed.type)'", at: expr.span)
                return .invalid
            }
            return TypedExpr(kind: .unary(op, typed), type: typed.type)

        case .binary(let op, let lhs, let rhs):
            return checkBinary(op, lhs, rhs, expected: expected, at: expr.span)

        case .call(let callee, let calleeSpan, let arguments):
            return checkCall(callee, calleeSpan: calleeSpan, arguments: arguments, at: expr.span)

        case .index(let base, let index):
            guard let array = resolveArray(base) else {
                _ = checkExpression(index, expected: .i32)
                return .invalid
            }
            return TypedExpr(kind: .element(local: array.local, index: checkIndex(index)), type: array.element)

        case .cast(let operand, let typeExpr):
            let target = resolveType(typeExpr)
            let typed = checkExpression(operand, expected: Self.isIntegerLiteral(operand) && target.isInteger ? target : nil)
            guard typed.type != .error, target != .error else { return .invalid }
            guard (typed.type.isNumeric && target.isNumeric) || (typed.type == .bool && target.isInteger) else {
                report("cannot cast '\(typed.type)' to '\(target)'", at: expr.span)
                return .invalid
            }
            return typed.type == target ? typed : TypedExpr(kind: .cast(typed), type: target)

        case .ifElse(let condition, let then, let elseBranch):
            return checkIf(condition: condition, then: then, else: elseBranch, expected: expected)

        case .block(let block):
            let typed = checkBlock(block, expected: expected)
            return TypedExpr(kind: .block(typed), type: typed.type)

        case .arrayList, .arrayRepeat:
            report("array literals can only initialize a 'let' or 'var' binding", at: expr.span)
            return .invalid
        }
    }

    private mutating func integerLiteral(_ magnitude: UInt64, negated: Bool, expected: TernType?, at span: Span) -> TypedExpr {
        let type: TernType = expected == .i64 ? .i64 : .i32
        let limit = type == .i64 ? UInt64(Int64.max) : UInt64(Int32.max)
        guard magnitude <= (negated ? limit + 1 : limit) else {
            report("integer literal '\(negated ? "-" : "")\(magnitude)' does not fit in '\(type)'", at: span,
                   help: type == .i32 ? "annotate the expected type as 'i64' for larger values" : nil)
            return .invalid
        }
        let value = negated ? Int64(bitPattern: 0 &- magnitude) : Int64(magnitude)
        return TypedExpr(kind: .int(value), type: type)
    }

    private mutating func checkBinary(_ op: BinaryOp, _ lhs: Expr, _ rhs: Expr, expected: TernType?, at span: Span) -> TypedExpr {
        if op.isLogical {
            let left = checkExpression(lhs, expected: .bool)
            coerce(left, to: .bool, at: lhs.span)
            let right = checkExpression(rhs, expected: .bool)
            coerce(right, to: .bool, at: rhs.span)
            return TypedExpr(kind: .binary(op, left, right), type: .bool)
        }

        let (left, right) = checkOperands(lhs, rhs, hint: op.isComparison ? nil : expected)
        guard left.type != .error, right.type != .error else { return .invalid }
        guard left.type == right.type, Self.supports(op, left.type) else {
            let bothNumeric = left.type.isNumeric && right.type.isNumeric
            report("binary operator '\(op.rawValue)' cannot be applied to '\(left.type)' and '\(right.type)'", at: span,
                   help: bothNumeric && left.type != right.type ? "convert one operand with 'as', like 'x as \(left.type)'" : nil)
            return .invalid
        }
        return TypedExpr(kind: .binary(op, left, right), type: op.isComparison ? .bool : left.type)
    }

    /// Checks two operands that must share a type. An integer literal on the
    /// left takes its type from the right (`1 + x` where `x: i64`).
    private mutating func checkOperands(_ lhs: Expr, _ rhs: Expr, hint: TernType?) -> (TypedExpr, TypedExpr) {
        if Self.isIntegerLiteral(lhs), !Self.isIntegerLiteral(rhs) {
            let right = checkExpression(rhs, expected: hint)
            let left = checkExpression(lhs, expected: right.type.isInteger ? right.type : hint)
            return (left, right)
        }
        let left = checkExpression(lhs, expected: hint)
        let right = checkExpression(rhs, expected: left.type.isInteger ? left.type : hint)
        return (left, right)
    }

    private mutating func checkCall(_ callee: String, calleeSpan: Span, arguments: [Expr], at span: Span) -> TypedExpr {
        let target: Callee
        let parameters: [TernType]
        let result: TernType
        if let builtin = Builtin(rawValue: callee) {
            usedBuiltins.insert(builtin)
            (target, parameters, result) = (.builtin(builtin), [builtin.parameter], .unit)
        } else if let index = functionIndices[callee] {
            (target, parameters, result) = (.function(index), signatures[index].parameters, signatures[index].result)
        } else {
            let candidates = Array(functionIndices.keys) + Builtin.allCases.map(\.rawValue)
            report("cannot find function '\(callee)' in scope", at: calleeSpan, suggestingFrom: candidates, for: callee)
            for argument in arguments { _ = checkExpression(argument, expected: nil) }
            return .invalid
        }

        if arguments.count != parameters.count {
            let noun = parameters.count == 1 ? "argument" : "arguments"
            let verb = arguments.count == 1 ? "was" : "were"
            report("function '\(callee)' takes \(parameters.count) \(noun) but \(arguments.count) \(verb) given", at: span)
        }
        var typedArguments: [TypedExpr] = []
        for (position, argument) in arguments.enumerated() {
            let expected = position < parameters.count ? parameters[position] : nil
            let typed = checkExpression(argument, expected: expected)
            if let expected { coerce(typed, to: expected, at: argument.span) }
            typedArguments.append(typed)
        }
        return TypedExpr(kind: .call(target, typedArguments), type: result)
    }

    private mutating func checkIf(condition: Expr, then: Block, else elseBranch: Expr?, expected: TernType?) -> TypedExpr {
        let typedCondition = checkExpression(condition, expected: .bool)
        coerce(typedCondition, to: .bool, at: condition.span)
        let typedThen = checkBlock(then, expected: expected)

        guard let elseBranch else {
            if !typedThen.type.conforms(to: .unit) {
                report("'if' without 'else' cannot produce a value", at: then.tail?.span ?? then.span,
                       help: "add an 'else' branch, or end the expression with ';'")
                return .invalid
            }
            return TypedExpr(kind: .ifElse(condition: typedCondition, then: typedThen, else: nil), type: .unit)
        }

        let typedElse: TypedBlock
        if case .block(let block) = elseBranch.kind {
            typedElse = checkBlock(block, expected: expected)
        } else {
            let chained = checkExpression(elseBranch, expected: expected)
            typedElse = TypedBlock(statements: [], tail: chained, type: chained.type)
        }

        let type: TernType
        switch (typedThen.type, typedElse.type) {
        case (.never, let other), (let other, .never):
            type = other
        case (.error, _), (_, .error):
            type = .error
        case let (thenType, elseType) where thenType == elseType:
            type = thenType
        case let (thenType, elseType):
            report("'if' and 'else' have incompatible types '\(thenType)' and '\(elseType)'", at: elseBranch.span)
            type = .error
        }
        return TypedExpr(kind: .ifElse(condition: typedCondition, then: typedThen, else: typedElse), type: type)
    }

    // MARK: - Names

    @discardableResult
    private mutating func declare(_ name: String, type: TernType, isMutable: Bool) -> Int {
        locals.append(Local(name: name, type: type))
        scopes[scopes.count - 1][name] = Variable(local: locals.count - 1, isMutable: isMutable)
        return locals.count - 1
    }

    private mutating func lookup(_ name: String, at span: Span) -> Variable? {
        for scope in scopes.reversed() {
            if let variable = scope[name] { return variable }
        }
        report("cannot find '\(name)' in scope", at: span, suggestingFrom: scopes.flatMap(\.keys), for: name)
        return nil
    }

    private mutating func resolveArray(_ base: Expr) -> (local: Int, element: TernType, isMutable: Bool)? {
        guard case .identifier(let name) = base.kind else {
            report("only array variables can be indexed", at: base.span)
            return nil
        }
        guard let variable = lookup(name, at: base.span) else { return nil }
        switch locals[variable.local].type {
        case .array(let element, _):
            return (variable.local, element, variable.isMutable)
        case .error:
            return nil
        case let type:
            report("cannot index into a value of type '\(type)'", at: base.span)
            return nil
        }
    }

    private mutating func checkIndex(_ index: Expr) -> TypedExpr {
        let typed = checkExpression(index, expected: .i32)
        coerce(typed, to: .i32, at: index.span)
        return typed
    }

    // MARK: - Helpers

    private static func isIntegerLiteral(_ expr: Expr) -> Bool {
        switch expr.kind {
        case .integer: true
        case .unary(.negate, let operand): isIntegerLiteral(operand)
        default: false
        }
    }

    static func supports(_ op: BinaryOp, _ type: TernType) -> Bool {
        if op.isLogical { return type == .bool }
        if op == .equal || op == .notEqual { return type.isNumeric || type == .bool }
        if op.isIntegerOnly { return type.isInteger }
        return type.isNumeric
    }

    private mutating func coerce(_ expr: TypedExpr, to expected: TernType, at span: Span) {
        if !expr.type.conforms(to: expected) {
            report(mismatch: expected, found: expr.type, at: span)
        }
    }

    private mutating func report(mismatch expected: TernType, found: TernType, at span: Span) {
        report("mismatched types: expected '\(expected)', found '\(found)'", at: span)
    }

    private mutating func report(_ message: String, at span: Span, help: String? = nil) {
        diagnostics.append(.error(message, at: span, help: help))
    }

    private mutating func report(_ message: String, at span: Span, suggestingFrom candidates: some Sequence<String>, for name: String) {
        let suggestion = Self.closestMatch(to: name, in: candidates)
        report(message, at: span, help: suggestion.map { "did you mean '\($0)'?" })
    }

    /// The candidate with the smallest edit distance, if it's close enough to be a plausible typo.
    static func closestMatch(to name: String, in candidates: some Sequence<String>) -> String? {
        let threshold = max(1, name.count / 3)
        return Set(candidates)
            .filter { $0 != name }
            .map { (candidate: $0, distance: editDistance(name, $0)) }
            .filter { $0.distance <= threshold }
            .min { ($0.distance, $0.candidate) < ($1.distance, $1.candidate) }?
            .candidate
    }

    /// Optimal string alignment distance: Levenshtein plus adjacent
    /// transpositions, so the common `cuont` → `count` typo costs 1.
    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty, !b.isEmpty else { return max(a.count, b.count) }
        var d = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { d[i][0] = i }
        for j in 0...b.count { d[0][j] = j }
        for i in 1...a.count {
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1)
                }
            }
        }
        return d[a.count][b.count]
    }
}

extension TypedExpr {
    /// Placeholder for an expression that failed to check.
    fileprivate static let invalid = TypedExpr(kind: .int(0), type: .error)
}

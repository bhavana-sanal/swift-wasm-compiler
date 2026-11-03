/// Lowers one function body to a flat Wasm instruction sequence.
///
/// Loops become a `block`/`loop` pair; `break` branches to the block and
/// `continue` to the loop (or, in `for` loops, to an inner block so the
/// increment still runs). Branch depths are relative, so the lowering tracks
/// how many structured blocks are open.
struct FunctionLowering {
    private enum Slot {
        case wasm(UInt32)
        case frame(offset: Int, element: TernType, count: Int)
        /// A binding whose initializer never completes, so nothing ever reads it.
        case unused
    }

    private let function: TypedFunction
    private let importCount: Int
    private let builtinIndices: [Builtin: UInt32]
    var strings: StringTable
    private(set) var extraLocals: [ValueType] = []

    private var slots: [Slot] = []
    private var code: [Instruction] = []
    private var framePointer: UInt32?
    private var frameSize = 0
    private var depth = 0
    private var loops: [(breakLabel: Int, continueLabel: Int)] = []

    /// Index of `$sp`, the only global a module ever has.
    private static let stackPointer: UInt32 = 0

    init(function: TypedFunction, importCount: Int, builtinIndices: [Builtin: UInt32], strings: StringTable) {
        self.function = function
        self.importCount = importCount
        self.builtinIndices = builtinIndices
        self.strings = strings

        for (index, local) in function.locals.enumerated() {
            if index < function.parameterCount {
                slots.append(.wasm(UInt32(index)))
            } else if case .array(let element, let count) = local.type {
                frameSize = Self.align(frameSize)
                slots.append(.frame(offset: frameSize, element: element, count: count))
                frameSize += element.byteSize * count
            } else if local.type == .never {
                slots.append(.unused)
            } else {
                slots.append(.wasm(newLocal(local.type.valueType)))
            }
        }
        if frameSize > 0 {
            frameSize = Self.align(frameSize)
            framePointer = newLocal(.i32)
        }
    }

    mutating func lower() -> [Instruction] {
        if let framePointer {
            code += [
                .globalGet(Self.stackPointer), .i32Const(Int32(frameSize)), .numeric(.i32Sub),
                .localTee(framePointer), .globalSet(Self.stackPointer),
            ]
        }
        emit(function.body)
        if function.body.type != .never { emitEpilogue() }
        return code
    }

    // MARK: - Statements

    private mutating func emit(_ block: TypedBlock) {
        for statement in block.statements { emit(statement) }
        if let tail = block.tail { emit(tail) }
    }

    private mutating func emit(_ statement: TypedStmt) {
        switch statement {
        case .assign(let local, let op, let value):
            switch slots[local] {
            case .frame(let offset, let element, _):
                emitArrayInitializer(value, offset: offset, element: element)
            case .unused:
                preconditionFailure("assignment to a binding that is never initialized")
            case .wasm(let index):
                if op != nil { code.append(.localGet(index)) }
                emit(value)
                if let op { code.append(.numeric(Self.numericOp(op, value.type))) }
                code.append(.localSet(index))
            }

        case .assignElement(let local, let index, let op, let value):
            let (offset, access) = emitElementAddress(local: local, index: index)
            if op != nil {
                let address = newLocal(.i32)
                code += [.localTee(address), .localGet(address), .load(access, offset: offset)]
            }
            emit(value)
            if let op { code.append(.numeric(Self.numericOp(op, value.type))) }
            code.append(.store(access, offset: offset))

        case .expr(let expr):
            emit(expr)
            if expr.type != .unit, expr.type != .never { code.append(.drop) }

        case .whileLoop(let condition, let body):
            let exit = open(.block(.empty))
            let top = open(.loop(.empty))
            if !Self.isConstantTrue(condition) {
                emit(condition)
                code += [.numeric(.i32Eqz), .brIf(relativeDepth(to: exit))]
            }
            loops.append((exit, top))
            emit(body)
            loops.removeLast()
            code.append(.br(relativeDepth(to: top)))
            close()
            close()

        case .forLoop(let local, let start, let end, let body):
            guard case .wasm(let counter) = slots[local] else { preconditionFailure("loop counter must be a scalar local") }
            let is64 = start.type == .i64
            emit(start)
            code.append(.localSet(counter))
            let bound: Instruction
            if case .int(let value) = end.kind {
                bound = is64 ? .i64Const(value) : .i32Const(Int32(truncatingIfNeeded: value))
            } else {
                emit(end)
                let limit = newLocal(end.type.valueType)
                code.append(.localSet(limit))
                bound = .localGet(limit)
            }

            let exit = open(.block(.empty))
            let top = open(.loop(.empty))
            code += [.localGet(counter), bound, .numeric(is64 ? .i64GeS : .i32GeS), .brIf(relativeDepth(to: exit))]
            let next = open(.block(.empty))
            loops.append((exit, next))
            emit(body)
            loops.removeLast()
            close()
            code += [
                .localGet(counter), is64 ? .i64Const(1) : .i32Const(1), .numeric(is64 ? .i64Add : .i32Add),
                .localSet(counter), .br(relativeDepth(to: top)),
            ]
            close()
            close()

        case .returnValue(let value):
            if let value { emit(value) }
            emitEpilogue()
            code.append(.return)

        case .breakLoop:
            code.append(.br(relativeDepth(to: loops[loops.count - 1].breakLabel)))

        case .continueLoop:
            code.append(.br(relativeDepth(to: loops[loops.count - 1].continueLabel)))
        }
    }

    // MARK: - Expressions

    private mutating func emit(_ expr: TypedExpr) {
        switch expr.kind {
        case .int(let value):
            code.append(expr.type == .i64 ? .i64Const(value) : .i32Const(Int32(truncatingIfNeeded: value)))
        case .float(let value):
            code.append(.f64Const(value))
        case .bool(let value):
            code.append(.i32Const(value ? 1 : 0))
        case .string(let value):
            code.append(.i32Const(Int32(strings.offset(of: value))))
        case .local(let local):
            guard case .wasm(let index) = slots[local] else { preconditionFailure("only scalar locals can be read directly") }
            code.append(.localGet(index))

        case .unary(.negate, let operand) where operand.type == .f64:
            emit(operand)
            code.append(.numeric(.f64Neg))
        case .unary(.negate, let operand):
            code.append(operand.type == .i64 ? .i64Const(0) : .i32Const(0))
            emit(operand)
            code.append(.numeric(operand.type == .i64 ? .i64Sub : .i32Sub))
        case .unary(.not, let operand):
            emit(operand)
            code.append(.numeric(.i32Eqz))

        case .binary(.and, let lhs, let rhs):
            emit(lhs)
            open(.if(.value(.i32)))
            emit(rhs)
            code += [.else, .i32Const(0)]
            close()
        case .binary(.or, let lhs, let rhs):
            emit(lhs)
            open(.if(.value(.i32)))
            code += [.i32Const(1), .else]
            emit(rhs)
            close()
        case .binary(let op, let lhs, let rhs):
            emit(lhs)
            emit(rhs)
            code.append(.numeric(Self.numericOp(op, lhs.type)))

        case .call(let callee, let arguments):
            for argument in arguments { emit(argument) }
            switch callee {
            case .function(let index): code.append(.call(UInt32(importCount + index)))
            case .builtin(let builtin): code.append(.call(builtinIndices[builtin]!))
            }

        case .element(let local, let index):
            let (offset, access) = emitElementAddress(local: local, index: index)
            code.append(.load(access, offset: offset))

        case .cast(let operand):
            emit(operand)
            if let conversion = Self.conversion(from: operand.type, to: expr.type) { code.append(conversion) }

        case .ifElse(let condition, let then, let elseBranch):
            emit(condition)
            let isValue = expr.type != .unit && expr.type != .never
            open(.if(isValue ? .value(expr.type.valueType) : .empty))
            emit(then)
            if let elseBranch {
                code.append(.else)
                emit(elseBranch)
            }
            close()
            // Both branches exit, but the validator can't see that through `if`.
            if expr.type == .never { code.append(.unreachable) }

        case .block(let block):
            emit(block)

        case .arrayList, .arrayRepeat:
            preconditionFailure("array literals are lowered by the binding that owns them")
        }
    }

    private mutating func emitArrayInitializer(_ value: TypedExpr, offset: Int, element: TernType) {
        let framePointer = framePointer!
        let access = element.memoryAccess
        switch value.kind {
        case .arrayList(let elements):
            for (position, item) in elements.enumerated() {
                code.append(.localGet(framePointer))
                emit(item)
                code.append(.store(access, offset: UInt32(offset + position * element.byteSize)))
            }
        case .arrayRepeat(let fill):
            guard case .array(_, let count) = value.type else { preconditionFailure("array literal without array type") }
            let fillValue = newLocal(element.valueType)
            let position = newLocal(.i32)
            emit(fill)
            code += [.localSet(fillValue), .i32Const(0), .localSet(position)]
            code += [
                .block(.empty), .loop(.empty),
                .localGet(position), .i32Const(Int32(count)), .numeric(.i32GeU), .brIf(1),
                .localGet(framePointer), .localGet(position),
            ]
            code += Self.scale(by: element.byteSize)
            code += [
                .numeric(.i32Add), .localGet(fillValue), .store(access, offset: UInt32(offset)),
                .localGet(position), .i32Const(1), .numeric(.i32Add), .localSet(position),
                .br(0), .end, .end,
            ]
        default:
            preconditionFailure("arrays are initialized only from array literals")
        }
    }

    /// Pushes `frame + index * size` after trapping on an out-of-bounds index,
    /// and returns the static offset and access width for the load or store.
    private mutating func emitElementAddress(local: Int, index: TypedExpr) -> (UInt32, MemoryAccess) {
        guard case .frame(let offset, let element, let count) = slots[local] else {
            preconditionFailure("indexing a non-array local")
        }
        let position = newLocal(.i32)
        emit(index)
        // A single unsigned comparison also rejects negative indices.
        code += [
            .localTee(position), .i32Const(Int32(count)), .numeric(.i32GeU),
            .if(.empty), .unreachable, .end,
            .localGet(framePointer!), .localGet(position),
        ]
        code += Self.scale(by: element.byteSize)
        code.append(.numeric(.i32Add))
        return (UInt32(offset), element.memoryAccess)
    }

    private mutating func emitEpilogue() {
        guard let framePointer else { return }
        code += [.localGet(framePointer), .i32Const(Int32(frameSize)), .numeric(.i32Add), .globalSet(Self.stackPointer)]
    }

    // MARK: - Helpers

    private mutating func newLocal(_ type: ValueType) -> UInt32 {
        extraLocals.append(type)
        return UInt32(function.parameterCount + extraLocals.count - 1)
    }

    @discardableResult
    private mutating func open(_ instruction: Instruction) -> Int {
        code.append(instruction)
        depth += 1
        return depth - 1
    }

    private mutating func close() {
        code.append(.end)
        depth -= 1
    }

    private func relativeDepth(to label: Int) -> UInt32 {
        UInt32(depth - 1 - label)
    }

    private static func isConstantTrue(_ expr: TypedExpr) -> Bool {
        if case .bool(true) = expr.kind { return true }
        return false
    }

    private static func align(_ offset: Int) -> Int {
        (offset + 7) & ~7
    }

    private static func scale(by size: Int) -> [Instruction] {
        size == 1 ? [] : [.i32Const(Int32(size)), .numeric(.i32Mul)]
    }

    private static func numericOp(_ op: BinaryOp, _ operand: TernType) -> NumericOp {
        switch (op, operand) {
        case (.add, .i32): .i32Add
        case (.subtract, .i32): .i32Sub
        case (.multiply, .i32): .i32Mul
        case (.divide, .i32): .i32DivS
        case (.remainder, .i32): .i32RemS
        case (.bitAnd, .i32): .i32And
        case (.bitOr, .i32): .i32Or
        case (.bitXor, .i32): .i32Xor
        case (.shiftLeft, .i32): .i32Shl
        case (.shiftRight, .i32): .i32ShrS
        case (.equal, .i32), (.equal, .bool): .i32Eq
        case (.notEqual, .i32), (.notEqual, .bool): .i32Ne
        case (.less, .i32): .i32LtS
        case (.lessEqual, .i32): .i32LeS
        case (.greater, .i32): .i32GtS
        case (.greaterEqual, .i32): .i32GeS

        case (.add, .i64): .i64Add
        case (.subtract, .i64): .i64Sub
        case (.multiply, .i64): .i64Mul
        case (.divide, .i64): .i64DivS
        case (.remainder, .i64): .i64RemS
        case (.bitAnd, .i64): .i64And
        case (.bitOr, .i64): .i64Or
        case (.bitXor, .i64): .i64Xor
        case (.shiftLeft, .i64): .i64Shl
        case (.shiftRight, .i64): .i64ShrS
        case (.equal, .i64): .i64Eq
        case (.notEqual, .i64): .i64Ne
        case (.less, .i64): .i64LtS
        case (.lessEqual, .i64): .i64LeS
        case (.greater, .i64): .i64GtS
        case (.greaterEqual, .i64): .i64GeS

        case (.add, .f64): .f64Add
        case (.subtract, .f64): .f64Sub
        case (.multiply, .f64): .f64Mul
        case (.divide, .f64): .f64Div
        case (.equal, .f64): .f64Eq
        case (.notEqual, .f64): .f64Ne
        case (.less, .f64): .f64Lt
        case (.lessEqual, .f64): .f64Le
        case (.greater, .f64): .f64Gt
        case (.greaterEqual, .f64): .f64Ge

        default: preconditionFailure("no instruction for '\(op.rawValue)' on '\(operand)'")
        }
    }

    /// `nil` when the representation is unchanged (`bool` to `i32`).
    private static func conversion(from source: TernType, to target: TernType) -> Instruction? {
        switch (source, target) {
        case (.i32, .i64), (.bool, .i64): .numeric(.i64ExtendI32S)
        case (.i64, .i32): .numeric(.i32WrapI64)
        case (.i32, .f64): .numeric(.f64ConvertI32S)
        case (.i64, .f64): .numeric(.f64ConvertI64S)
        case (.f64, .i32): .i32TruncSatF64S
        case (.f64, .i64): .i64TruncSatF64S
        case (.bool, .i32): nil
        default: preconditionFailure("no conversion from '\(source)' to '\(target)'")
        }
    }
}

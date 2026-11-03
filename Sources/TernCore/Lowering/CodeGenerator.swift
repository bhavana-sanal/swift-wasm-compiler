/// Linear memory layout. Programs that use arrays get a 64 KiB stack at the
/// bottom of memory, growing down from `stackSize`; string data sits above it.
/// A frame that grows past address 0 wraps to a huge unsigned address, so its
/// first access traps as out of bounds without an explicit overflow check.
enum LinearMemory {
    static let pageSize = 65536
    static let stackSize = 65536
}

/// Lowers a ``TypedProgram`` to a ``WasmModule``.
struct CodeGenerator {
    private let program: TypedProgram
    private var module = WasmModule()
    private var strings: StringTable
    private let usesStack: Bool

    static func generate(_ program: TypedProgram) -> WasmModule {
        var generator = CodeGenerator(program: program)
        return generator.run()
    }

    private init(program: TypedProgram) {
        self.program = program
        self.usesStack = program.functions.contains { function in
            function.locals.contains { if case .array = $0.type { true } else { false } }
        }
        self.strings = StringTable(base: usesStack ? LinearMemory.stackSize : 0)
    }

    private mutating func run() -> WasmModule {
        var builtinIndices: [Builtin: UInt32] = [:]
        for builtin in program.imports {
            let type = module.typeIndex(for: FunctionType(parameters: [builtin.parameter.valueType], results: []))
            builtinIndices[builtin] = UInt32(module.imports.count)
            module.imports.append(.init(module: "env", name: builtin.rawValue, typeIndex: type))
        }
        if usesStack {
            module.globals.append(.init(name: "sp", type: .i32, isMutable: true, initializer: .i32Const(Int32(LinearMemory.stackSize))))
        }

        let importCount = module.imports.count
        for (index, function) in program.functions.enumerated() {
            let parameters = function.locals[..<function.parameterCount].map(\.type.valueType)
            let results = function.result == .unit ? [] : [function.result.valueType]
            let typeIndex = module.typeIndex(for: FunctionType(parameters: parameters, results: results))

            var lowering = FunctionLowering(function: function, importCount: importCount, builtinIndices: builtinIndices, strings: strings)
            let body = lowering.lower()
            strings = lowering.strings
            module.functions.append(.init(name: function.name, typeIndex: typeIndex, locals: lowering.extraLocals, body: body))
            if function.isExported {
                module.exports.append(.init(name: function.name, kind: .function, index: UInt32(importCount + index)))
            }
        }

        if usesStack || !strings.bytes.isEmpty {
            let size = strings.base + strings.bytes.count
            module.memoryPages = UInt32(max(1, (size + LinearMemory.pageSize - 1) / LinearMemory.pageSize))
            module.exports.append(.init(name: "memory", kind: .memory, index: 0))
        }
        if !strings.bytes.isEmpty {
            module.data.append(.init(offset: UInt32(strings.base), bytes: strings.bytes))
        }
        return module
    }
}

/// Interns string literals as a little-endian `u32` length followed by UTF-8 bytes.
struct StringTable {
    let base: Int
    private(set) var bytes: [UInt8] = []
    private var offsets: [String: UInt32] = [:]

    init(base: Int) {
        self.base = base
    }

    mutating func offset(of string: String) -> UInt32 {
        if let offset = offsets[string] { return offset }
        let offset = UInt32(base + bytes.count)
        let utf8 = Array(string.utf8)
        withUnsafeBytes(of: UInt32(utf8.count).littleEndian) { bytes.append(contentsOf: $0) }
        bytes.append(contentsOf: utf8)
        while bytes.count % 4 != 0 { bytes.append(0) }  // keep each length prefix aligned
        offsets[string] = offset
        return offset
    }
}

extension TernType {
    var valueType: ValueType {
        switch self {
        case .i32, .bool, .str: .i32
        case .i64: .i64
        case .f64: .f64
        default: preconditionFailure("'\(self)' has no Wasm value type")
        }
    }

    var memoryAccess: MemoryAccess {
        switch self {
        case .i64: .i64
        case .f64: .f64
        case .bool: .byte
        default: .i32
        }
    }
}

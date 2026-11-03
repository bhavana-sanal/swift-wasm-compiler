/// An in-memory Wasm module, limited to the features the compiler emits.
/// ``encode()`` turns it into a binary and ``wat()`` into text.
public struct WasmModule: Sendable {
    public struct Import: Sendable {
        public var module: String
        public var name: String
        public var typeIndex: UInt32
    }

    public struct Function: Sendable {
        /// Used only for the text format; the binary carries no names.
        public var name: String
        public var typeIndex: UInt32
        /// Locals beyond the parameters.
        public var locals: [ValueType]
        /// The instruction sequence, without the final `end`.
        public var body: [Instruction]
    }

    public struct Global: Sendable {
        public var name: String
        public var type: ValueType
        public var isMutable: Bool
        public var initializer: Instruction
    }

    public enum ExportKind: UInt8, Sendable {
        case function = 0x00
        case memory = 0x02
    }

    public struct Export: Sendable {
        public var name: String
        public var kind: ExportKind
        public var index: UInt32
    }

    public struct DataSegment: Sendable {
        public var offset: UInt32
        public var bytes: [UInt8]
    }

    public var types: [FunctionType] = []
    public var imports: [Import] = []
    public var functions: [Function] = []
    /// Minimum size of the single linear memory, or `nil` for no memory.
    public var memoryPages: UInt32?
    public var globals: [Global] = []
    public var exports: [Export] = []
    public var data: [DataSegment] = []

    public init() {}

    /// Returns the index of `type`, adding it to the type section if needed.
    mutating func typeIndex(for type: FunctionType) -> UInt32 {
        if let index = types.firstIndex(of: type) { return UInt32(index) }
        types.append(type)
        return UInt32(types.count - 1)
    }
}

public enum ValueType: UInt8, Sendable {
    case i32 = 0x7F
    case i64 = 0x7E
    case f64 = 0x7C

    var name: String {
        switch self {
        case .i32: "i32"
        case .i64: "i64"
        case .f64: "f64"
        }
    }
}

public struct FunctionType: Hashable, Sendable {
    public var parameters: [ValueType]
    public var results: [ValueType]
}

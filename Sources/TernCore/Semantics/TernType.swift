public indirect enum TernType: Hashable, Sendable {
    case i32, i64, f64, bool
    /// A pointer to a length-prefixed UTF-8 string in the data segment.
    case str
    case unit
    /// The type of code that never completes, such as a block ending in `return`.
    case never
    /// Assigned after a type error so the mistake isn't reported again downstream.
    case error
    case array(element: TernType, count: Int)

    static let named: [String: TernType] = ["i32": .i32, "i64": .i64, "f64": .f64, "bool": .bool, "str": .str]

    var isInteger: Bool { self == .i32 || self == .i64 }
    var isNumeric: Bool { isInteger || self == .f64 }

    /// Types that can live in a local, a parameter, or an array element.
    var isScalar: Bool {
        switch self {
        case .i32, .i64, .f64, .bool, .str: true
        default: false
        }
    }

    /// Whether a value of this type can stand where `expected` is required.
    func conforms(to expected: TernType) -> Bool {
        self == expected || self == .never || self == .error || expected == .error
    }

    /// Size in linear memory when stored as an array element.
    var byteSize: Int {
        switch self {
        case .i64, .f64: 8
        case .bool: 1
        default: 4
        }
    }
}

extension TernType: CustomStringConvertible {
    public var description: String {
        switch self {
        case .i32: "i32"
        case .i64: "i64"
        case .f64: "f64"
        case .bool: "bool"
        case .str: "str"
        case .unit: "()"
        case .never: "!"
        case .error: "{error}"
        case .array(let element, let count): "[\(element); \(count)]"
        }
    }
}

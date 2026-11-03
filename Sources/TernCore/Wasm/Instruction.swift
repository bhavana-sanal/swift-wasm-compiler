public enum Instruction: Equatable, Sendable {
    case unreachable
    case block(BlockType)
    case loop(BlockType)
    case `if`(BlockType)
    case `else`
    case end
    case br(UInt32)
    case brIf(UInt32)
    case `return`
    case call(UInt32)
    case drop
    case localGet(UInt32)
    case localSet(UInt32)
    case localTee(UInt32)
    case globalGet(UInt32)
    case globalSet(UInt32)
    case load(MemoryAccess, offset: UInt32)
    case store(MemoryAccess, offset: UInt32)
    case i32Const(Int32)
    case i64Const(Int64)
    case f64Const(Double)
    case numeric(NumericOp)
    case i32TruncSatF64S
    case i64TruncSatF64S
}

public enum BlockType: Equatable, Sendable {
    case empty
    case value(ValueType)
}

/// The width of a load or store. Booleans are stored as single bytes.
public enum MemoryAccess: Sendable {
    case i32, i64, f64, byte

    var loadOpcode: UInt8 {
        switch self {
        case .i32: 0x28
        case .i64: 0x29
        case .f64: 0x2B
        case .byte: 0x2D  // i32.load8_u
        }
    }

    var storeOpcode: UInt8 {
        switch self {
        case .i32: 0x36
        case .i64: 0x37
        case .f64: 0x39
        case .byte: 0x3A  // i32.store8
        }
    }

    /// log2 of the natural alignment, as encoded in the memarg.
    var alignment: UInt32 {
        switch self {
        case .i32: 2
        case .i64, .f64: 3
        case .byte: 0
        }
    }

    var loadName: String {
        switch self {
        case .i32: "i32.load"
        case .i64: "i64.load"
        case .f64: "f64.load"
        case .byte: "i32.load8_u"
        }
    }

    var storeName: String {
        switch self {
        case .i32: "i32.store"
        case .i64: "i64.store"
        case .f64: "f64.store"
        case .byte: "i32.store8"
        }
    }
}

/// Single-byte numeric instructions without immediates. The raw value is the
/// text-format name; ``opcode`` is the binary encoding.
public enum NumericOp: String, Sendable {
    case i32Eqz = "i32.eqz", i32Eq = "i32.eq", i32Ne = "i32.ne"
    case i32LtS = "i32.lt_s", i32GtS = "i32.gt_s", i32LeS = "i32.le_s", i32GeS = "i32.ge_s", i32GeU = "i32.ge_u"
    case i64Eq = "i64.eq", i64Ne = "i64.ne"
    case i64LtS = "i64.lt_s", i64GtS = "i64.gt_s", i64LeS = "i64.le_s", i64GeS = "i64.ge_s"
    case f64Eq = "f64.eq", f64Ne = "f64.ne", f64Lt = "f64.lt", f64Gt = "f64.gt", f64Le = "f64.le", f64Ge = "f64.ge"
    case i32Add = "i32.add", i32Sub = "i32.sub", i32Mul = "i32.mul", i32DivS = "i32.div_s", i32RemS = "i32.rem_s"
    case i32And = "i32.and", i32Or = "i32.or", i32Xor = "i32.xor", i32Shl = "i32.shl", i32ShrS = "i32.shr_s"
    case i64Add = "i64.add", i64Sub = "i64.sub", i64Mul = "i64.mul", i64DivS = "i64.div_s", i64RemS = "i64.rem_s"
    case i64And = "i64.and", i64Or = "i64.or", i64Xor = "i64.xor", i64Shl = "i64.shl", i64ShrS = "i64.shr_s"
    case f64Neg = "f64.neg", f64Add = "f64.add", f64Sub = "f64.sub", f64Mul = "f64.mul", f64Div = "f64.div"
    case i32WrapI64 = "i32.wrap_i64", i64ExtendI32S = "i64.extend_i32_s"
    case f64ConvertI32S = "f64.convert_i32_s", f64ConvertI64S = "f64.convert_i64_s"

    var opcode: UInt8 {
        switch self {
        case .i32Eqz: 0x45
        case .i32Eq: 0x46
        case .i32Ne: 0x47
        case .i32LtS: 0x48
        case .i32GtS: 0x4A
        case .i32LeS: 0x4C
        case .i32GeS: 0x4E
        case .i32GeU: 0x4F
        case .i64Eq: 0x51
        case .i64Ne: 0x52
        case .i64LtS: 0x53
        case .i64GtS: 0x55
        case .i64LeS: 0x57
        case .i64GeS: 0x59
        case .f64Eq: 0x61
        case .f64Ne: 0x62
        case .f64Lt: 0x63
        case .f64Gt: 0x64
        case .f64Le: 0x65
        case .f64Ge: 0x66
        case .i32Add: 0x6A
        case .i32Sub: 0x6B
        case .i32Mul: 0x6C
        case .i32DivS: 0x6D
        case .i32RemS: 0x6F
        case .i32And: 0x71
        case .i32Or: 0x72
        case .i32Xor: 0x73
        case .i32Shl: 0x74
        case .i32ShrS: 0x75
        case .i64Add: 0x7C
        case .i64Sub: 0x7D
        case .i64Mul: 0x7E
        case .i64DivS: 0x7F
        case .i64RemS: 0x81
        case .i64And: 0x83
        case .i64Or: 0x84
        case .i64Xor: 0x85
        case .i64Shl: 0x86
        case .i64ShrS: 0x87
        case .f64Neg: 0x9A
        case .f64Add: 0xA0
        case .f64Sub: 0xA1
        case .f64Mul: 0xA2
        case .f64Div: 0xA3
        case .i32WrapI64: 0xA7
        case .i64ExtendI32S: 0xAC
        case .f64ConvertI32S: 0xB7
        case .f64ConvertI64S: 0xB9
        }
    }
}

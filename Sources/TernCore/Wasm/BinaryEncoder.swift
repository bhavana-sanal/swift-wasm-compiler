/// Section ids from the core spec, in the order they must appear.
enum SectionID: UInt8 {
    case type = 1
    case `import` = 2
    case function = 3
    case memory = 5
    case global = 6
    case export = 7
    case code = 10
    case data = 11
}

extension WasmModule {
    public static let magic: [UInt8] = [0x00, 0x61, 0x73, 0x6D]  // "\0asm"
    public static let version: [UInt8] = [0x01, 0x00, 0x00, 0x00]

    public func encode() -> [UInt8] {
        var bytes = Self.magic + Self.version

        appendSection(.type, count: types.count, to: &bytes) { out in
            for type in types {
                out.append(0x60)
                out.appendVector(type.parameters) { $0.append($1.rawValue) }
                out.appendVector(type.results) { $0.append($1.rawValue) }
            }
        }
        appendSection(.import, count: imports.count, to: &bytes) { out in
            for entry in imports {
                out.appendName(entry.module)
                out.appendName(entry.name)
                out.append(0x00)  // function import
                out.appendUnsignedLEB128(entry.typeIndex)
            }
        }
        appendSection(.function, count: functions.count, to: &bytes) { out in
            for function in functions { out.appendUnsignedLEB128(function.typeIndex) }
        }
        if let memoryPages {
            appendSection(.memory, count: 1, to: &bytes) { out in
                out.append(0x00)  // limits with a minimum only
                out.appendUnsignedLEB128(memoryPages)
            }
        }
        appendSection(.global, count: globals.count, to: &bytes) { out in
            for global in globals {
                out.append(global.type.rawValue)
                out.append(global.isMutable ? 0x01 : 0x00)
                global.initializer.encode(into: &out)
                out.append(0x0B)
            }
        }
        appendSection(.export, count: exports.count, to: &bytes) { out in
            for export in exports {
                out.appendName(export.name)
                out.append(export.kind.rawValue)
                out.appendUnsignedLEB128(export.index)
            }
        }
        appendSection(.code, count: functions.count, to: &bytes) { out in
            for function in functions {
                let body = function.encodedBody()
                out.appendUnsignedLEB128(UInt32(body.count))
                out.append(contentsOf: body)
            }
        }
        appendSection(.data, count: data.count, to: &bytes) { out in
            for segment in data {
                out.append(0x00)  // active segment for memory 0
                Instruction.i32Const(Int32(bitPattern: segment.offset)).encode(into: &out)
                out.append(0x0B)
                out.appendVector(segment.bytes) { $0.append($1) }
            }
        }
        return bytes
    }

    /// Writes `id`, the byte length, the entry count and the entries. Empty
    /// sections are omitted entirely.
    private func appendSection(_ id: SectionID, count: Int, to bytes: inout [UInt8], entries: (inout [UInt8]) -> Void) {
        guard count > 0 else { return }
        var contents: [UInt8] = []
        contents.appendUnsignedLEB128(UInt32(count))
        entries(&contents)
        bytes.append(id.rawValue)
        bytes.appendUnsignedLEB128(UInt32(contents.count))
        bytes.append(contentsOf: contents)
    }
}

extension WasmModule.Function {
    func encodedBody() -> [UInt8] {
        // Locals are declared as runs of (count, type).
        var runs: [(count: UInt32, type: ValueType)] = []
        for local in locals {
            if let last = runs.last, last.type == local {
                runs[runs.count - 1].count += 1
            } else {
                runs.append((1, local))
            }
        }
        var bytes: [UInt8] = []
        bytes.appendVector(runs) { out, run in
            out.appendUnsignedLEB128(run.count)
            out.append(run.type.rawValue)
        }
        for instruction in body { instruction.encode(into: &bytes) }
        bytes.append(0x0B)
        return bytes
    }
}

extension Instruction {
    func encode(into bytes: inout [UInt8]) {
        switch self {
        case .unreachable: bytes.append(0x00)
        case .block(let type): bytes.append(0x02); type.encode(into: &bytes)
        case .loop(let type): bytes.append(0x03); type.encode(into: &bytes)
        case .if(let type): bytes.append(0x04); type.encode(into: &bytes)
        case .else: bytes.append(0x05)
        case .end: bytes.append(0x0B)
        case .br(let depth): bytes.append(0x0C); bytes.appendUnsignedLEB128(depth)
        case .brIf(let depth): bytes.append(0x0D); bytes.appendUnsignedLEB128(depth)
        case .return: bytes.append(0x0F)
        case .call(let index): bytes.append(0x10); bytes.appendUnsignedLEB128(index)
        case .drop: bytes.append(0x1A)
        case .localGet(let index): bytes.append(0x20); bytes.appendUnsignedLEB128(index)
        case .localSet(let index): bytes.append(0x21); bytes.appendUnsignedLEB128(index)
        case .localTee(let index): bytes.append(0x22); bytes.appendUnsignedLEB128(index)
        case .globalGet(let index): bytes.append(0x23); bytes.appendUnsignedLEB128(index)
        case .globalSet(let index): bytes.append(0x24); bytes.appendUnsignedLEB128(index)
        case .load(let access, let offset):
            bytes.append(access.loadOpcode)
            bytes.appendUnsignedLEB128(access.alignment)
            bytes.appendUnsignedLEB128(offset)
        case .store(let access, let offset):
            bytes.append(access.storeOpcode)
            bytes.appendUnsignedLEB128(access.alignment)
            bytes.appendUnsignedLEB128(offset)
        case .i32Const(let value): bytes.append(0x41); bytes.appendSignedLEB128(Int64(value))
        case .i64Const(let value): bytes.append(0x42); bytes.appendSignedLEB128(value)
        case .f64Const(let value):
            bytes.append(0x44)
            withUnsafeBytes(of: value.bitPattern.littleEndian) { bytes.append(contentsOf: $0) }
        case .numeric(let op): bytes.append(op.opcode)
        case .i32TruncSatF64S: bytes.append(contentsOf: [0xFC, 0x02])
        case .i64TruncSatF64S: bytes.append(contentsOf: [0xFC, 0x06])
        }
    }
}

extension BlockType {
    func encode(into bytes: inout [UInt8]) {
        switch self {
        case .empty: bytes.append(0x40)
        case .value(let type): bytes.append(type.rawValue)
        }
    }
}

extension Array where Element == UInt8 {
    mutating func appendName(_ name: String) {
        appendVector(Array(name.utf8)) { $0.append($1) }
    }

    mutating func appendVector<T>(_ items: [T], _ encode: (inout [UInt8], T) -> Void) {
        appendUnsignedLEB128(UInt32(items.count))
        for item in items { encode(&self, item) }
    }
}

extension WasmModule {
    /// Renders the module in the WebAssembly text format, for debugging.
    public func wat() -> String {
        let functionNames = imports.map(\.name) + functions.map(\.name)
        let globalNames = globals.map(\.name)
        var lines = ["(module"]

        for (index, type) in types.enumerated() {
            lines.append("  (type (;\(index);) (func\(Self.signature(type))))")
        }
        for entry in imports {
            lines.append("  (import \"\(entry.module)\" \"\(entry.name)\" (func $\(entry.name) (type \(entry.typeIndex))))")
        }
        if let memoryPages {
            lines.append("  (memory (;0;) \(memoryPages))")
        }
        for global in globals {
            let type = global.isMutable ? "(mut \(global.type.name))" : global.type.name
            lines.append("  (global $\(global.name) \(type) (\(global.initializer.text(functionNames: [], globalNames: []))))")
        }
        for export in exports {
            switch export.kind {
            case .function: lines.append("  (export \"\(export.name)\" (func $\(functionNames[Int(export.index)])))")
            case .memory: lines.append("  (export \"\(export.name)\" (memory \(export.index)))")
            }
        }
        for function in functions {
            lines.append("  (func $\(function.name) (type \(function.typeIndex))\(Self.signature(types[Int(function.typeIndex)]))")
            if !function.locals.isEmpty {
                lines.append("    (local \(function.locals.map(\.name).joined(separator: " ")))")
            }
            var depth = 2
            for instruction in function.body {
                if instruction == .end || instruction == .else { depth -= 1 }
                lines.append(String(repeating: "  ", count: depth) + instruction.text(functionNames: functionNames, globalNames: globalNames))
                switch instruction {
                case .block, .loop, .if, .else: depth += 1
                default: break
                }
            }
            lines.append("  )")
        }
        for segment in data {
            lines.append("  (data (i32.const \(segment.offset)) \"\(Self.escape(segment.bytes))\")")
        }
        lines.append(")")
        return lines.joined(separator: "\n") + "\n"
    }

    private static func signature(_ type: FunctionType) -> String {
        var text = ""
        if !type.parameters.isEmpty { text += " (param \(type.parameters.map(\.name).joined(separator: " ")))" }
        if !type.results.isEmpty { text += " (result \(type.results.map(\.name).joined(separator: " ")))" }
        return text
    }

    private static func escape(_ bytes: [UInt8]) -> String {
        let hex = Array("0123456789abcdef")
        var text = ""
        for byte in bytes {
            if byte >= 0x20, byte < 0x7F, byte != UInt8(ascii: "\""), byte != UInt8(ascii: "\\") {
                text.append(Character(UnicodeScalar(byte)))
            } else {
                text += "\\\(hex[Int(byte >> 4)])\(hex[Int(byte & 0xF)])"
            }
        }
        return text
    }
}

extension Instruction {
    func text(functionNames: [String], globalNames: [String]) -> String {
        switch self {
        case .unreachable: "unreachable"
        case .block(let type): "block" + type.text
        case .loop(let type): "loop" + type.text
        case .if(let type): "if" + type.text
        case .else: "else"
        case .end: "end"
        case .br(let depth): "br \(depth)"
        case .brIf(let depth): "br_if \(depth)"
        case .return: "return"
        case .call(let index): "call $\(functionNames[Int(index)])"
        case .drop: "drop"
        case .localGet(let index): "local.get \(index)"
        case .localSet(let index): "local.set \(index)"
        case .localTee(let index): "local.tee \(index)"
        case .globalGet(let index): "global.get $\(globalNames[Int(index)])"
        case .globalSet(let index): "global.set $\(globalNames[Int(index)])"
        case .load(let access, let offset): access.loadName + (offset == 0 ? "" : " offset=\(offset)")
        case .store(let access, let offset): access.storeName + (offset == 0 ? "" : " offset=\(offset)")
        case .i32Const(let value): "i32.const \(value)"
        case .i64Const(let value): "i64.const \(value)"
        case .f64Const(let value): "f64.const \(value)"
        case .numeric(let op): op.rawValue
        case .i32TruncSatF64S: "i32.trunc_sat_f64_s"
        case .i64TruncSatF64S: "i64.trunc_sat_f64_s"
        }
    }
}

extension BlockType {
    fileprivate var text: String {
        switch self {
        case .empty: ""
        case .value(let type): " (result \(type.name))"
        }
    }
}

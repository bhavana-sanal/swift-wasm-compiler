import Testing
@testable import TernCore

@Suite struct WasmEncoderTests {
    @Test func emptyModuleIsJustTheHeader() {
        #expect(WasmModule().encode() == [0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00])
    }

    @Test func smallestUsefulModuleByteForByte() {
        var module = WasmModule()
        let type = module.typeIndex(for: FunctionType(parameters: [], results: [.i32]))
        module.functions = [.init(name: "f", typeIndex: type, locals: [], body: [.i32Const(42)])]
        module.exports = [.init(name: "f", kind: .function, index: 0)]

        #expect(module.encode() == [
            0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00,
            0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7F,  // type: () -> i32
            0x03, 0x02, 0x01, 0x00,  // function 0 uses type 0
            0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x00,  // export "f" = func 0
            0x0A, 0x06, 0x01, 0x04, 0x00, 0x41, 0x2A, 0x0B,  // body: i32.const 42, end
        ])
    }

    @Test func functionTypesAreDeduplicated() {
        var module = WasmModule()
        let a = module.typeIndex(for: FunctionType(parameters: [.i32], results: []))
        let b = module.typeIndex(for: FunctionType(parameters: [.f64], results: []))
        let c = module.typeIndex(for: FunctionType(parameters: [.i32], results: []))
        #expect([a, b, c] == [0, 1, 0])
        #expect(module.types.count == 2)
    }

    @Test func localsAreRunLengthEncoded() {
        let function = WasmModule.Function(name: "f", typeIndex: 0, locals: [.i32, .i32, .f64, .i32], body: [])
        #expect(function.encodedBody() == [0x03, 0x02, 0x7F, 0x01, 0x7C, 0x01, 0x7F, 0x0B])
    }

    @Test(arguments: [
        (Instruction.f64Const(1.5), [0x44, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF8, 0x3F] as [UInt8]),
        (.i32Const(-1), [0x41, 0x7F]),
        (.i64Const(64), [0x42, 0xC0, 0x00]),
        (.load(.f64, offset: 16), [0x2B, 0x03, 0x10]),
        (.store(.byte, offset: 300), [0x3A, 0x00, 0xAC, 0x02]),
        (.if(.value(.i32)), [0x04, 0x7F]),
        (.block(.empty), [0x02, 0x40]),
        (.brIf(2), [0x0D, 0x02]),
        (.numeric(.i64RemS), [0x81]),
        (.i32TruncSatF64S, [0xFC, 0x02]),
        (.i64TruncSatF64S, [0xFC, 0x06]),
    ])
    func instructionEncoding(instruction: Instruction, expected: [UInt8]) {
        var bytes: [UInt8] = []
        instruction.encode(into: &bytes)
        #expect(bytes == expected)
    }

    @Test func compiledProgramHasWellFormedSectionsInOrder() throws {
        let module = try #require(Compiler.compile(SourceFile(name: "t", text: """
            export fn main() {
                var squares = [0; 4];
                for i in 0..4 { squares[i] = i * i; }
                print_str("last: ");
                print_i32(squares[3]);
            }
            """)).module)
        let bytes = module.encode()
        #expect(Array(bytes.prefix(8)) == WasmModule.magic + WasmModule.version)

        // Walk the section headers: ids must increase and sizes must tile the file exactly.
        var offset = 8
        var ids: [UInt8] = []
        while offset < bytes.count {
            ids.append(bytes[offset])
            let (size, width) = decodeUnsigned(bytes, at: offset + 1)
            offset += 1 + width + size
        }
        #expect(offset == bytes.count)
        let expected: [SectionID] = [.type, .import, .function, .memory, .global, .export, .code, .data]
        #expect(ids == expected.map(\.rawValue))

        #expect(module.imports.map(\.name) == ["print_i32", "print_str"])
        #expect(module.exports.map(\.name) == ["main", "memory"])
        #expect(module.memoryPages == 2)  // 64 KiB stack + string data
        #expect(module.data.first?.offset == UInt32(LinearMemory.stackSize))
        #expect(module.data.first?.bytes == [6, 0, 0, 0] + Array("last: ".utf8) + [0, 0])
    }

    @Test func modulesWithoutStringsOrArraysHaveNoMemory() throws {
        let module = try #require(Compiler.compile(SourceFile(name: "t", text: "export fn main() { print_i32(6 * 7); }")).module)
        #expect(module.memoryPages == nil)
        #expect(module.globals.isEmpty)
        #expect(module.functions[0].body == [.i32Const(42), .call(0)])
    }

    @Test func textFormat() throws {
        let module = try #require(Compiler.compile(SourceFile(name: "t", text: """
            fn twice(x: i32) -> i32 { x * 2 }
            export fn main() { if twice(3) > 5 { print_str("big"); } }
            """)).module)
        #expect(module.wat() == """
            (module
              (type (;0;) (func (param i32)))
              (type (;1;) (func (param i32) (result i32)))
              (type (;2;) (func))
              (import "env" "print_str" (func $print_str (type 0)))
              (memory (;0;) 1)
              (export "main" (func $main))
              (export "memory" (memory 0))
              (func $twice (type 1) (param i32) (result i32)
                local.get 0
                i32.const 2
                i32.mul
              )
              (func $main (type 2)
                i32.const 3
                call $twice
                i32.const 5
                i32.gt_s
                if
                  i32.const 0
                  call $print_str
                end
              )
              (data (i32.const 0) "\\03\\00\\00\\00big\\00")
            )

            """)
    }

    private func decodeUnsigned(_ bytes: [UInt8], at start: Int) -> (value: Int, width: Int) {
        var value = 0
        var shift = 0
        var index = start
        while true {
            let byte = bytes[index]
            value |= Int(byte & 0x7F) << shift
            index += 1
            if byte & 0x80 == 0 { return (value, index - start) }
            shift += 7
        }
    }
}

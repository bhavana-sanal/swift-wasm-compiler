import Foundation
import Testing
@testable import TernCore

private let examplesDirectory = packageRoot.appendingPathComponent("examples")

private let examples: [String] = {
    let files = (try? FileManager.default.contentsOfDirectory(atPath: examplesDirectory.path)) ?? []
    return files.filter { $0.hasSuffix(".tern") }.map { String($0.dropLast(5)) }.sorted()
}()

@Test func everyExampleHasAGoldenFile() {
    #expect(!examples.isEmpty)
    for name in examples {
        let golden = examplesDirectory.appendingPathComponent("\(name).expected")
        #expect(FileManager.default.fileExists(atPath: golden.path), "missing \(name).expected")
    }
}

/// Compiles programs, runs them under Node.js and compares their output.
@Suite(.enabled(if: nodeIsAvailable, "Node.js was not found on PATH; skipping end-to-end tests"))
struct EndToEndTests {
    @Test(arguments: examples)
    func exampleMatchesGoldenOutput(name: String) throws {
        let directory = examplesDirectory
        let source = try String(contentsOf: directory.appendingPathComponent("\(name).tern"), encoding: .utf8)
        let expected = try String(contentsOf: directory.appendingPathComponent("\(name).expected"), encoding: .utf8)

        let result = try run(source)
        #expect(result.stderr == "")
        #expect(result.status == 0)
        #expect(result.stdout == expected)
    }

    @Test(arguments: [
        ("integer overflow wraps", """
            export fn main() {
                let max = 2147483647;
                print_i32(max + 1);
                print_str(" ");
                let big: i64 = 9223372036854775807;
                print_i64(big + 1);
            }
            """, "-2147483648 -9223372036854775808"),
        ("short circuit skips the right operand", """
            fn loud(value: bool) -> bool { print_str("evaluated "); value }
            export fn main() {
                let no = false;
                if no && loud(true) { print_str("unreachable"); }
                if !no || loud(true) { print_str("done"); }
            }
            """, "done"),
        ("break and continue in nested loops", """
            export fn main() {
                var total = 0;
                for i in 0..10 {
                    if i % 2 == 0 { continue; }
                    var j = 0;
                    while true {
                        j += 1;
                        if j > i { break; }
                        total += j;
                    }
                }
                print_i32(total);
            }
            """, "95"),
        ("casts truncate toward zero and saturate", """
            export fn main() {
                let x = -3.99;
                let huge = 1e20;
                print_i32(x as i32); print_str(" ");
                print_i32(huge as i32); print_str(" ");
                print_i64(huge as i64); print_str(" ");
                print_f64(7 as f64 / 2.0); print_str(" ");
                print_i32(3000000000 as i64 as i32);
            }
            """, "-3 2147483647 9223372036854775807 3.5 -1294967296"),
        ("block and if expressions", """
            fn sign(n: i32) -> i32 { if n > 0 { 1 } else if n < 0 { -1 } else { 0 } }
            export fn main() {
                let squared = { let t = 7; t * t };
                print_i32(squared + sign(-5) + sign(0) * 100);
            }
            """, "48"),
        ("arrays of every element type", """
            export fn main() {
                var ints = [1, 2, 3];
                var longs: [i64; 2] = [0; 2];
                var floats = [0.5, 1.5];
                var flags = [false; 3];
                let words = ["zero", "one"];
                ints[2] *= 10;
                longs[1] = 5000000000;
                floats[0] += floats[1];
                flags[1] = true;
                print_i32(ints[0] + ints[2]); print_str(" ");
                print_i64(longs[0] + longs[1]); print_str(" ");
                print_f64(floats[0]); print_str(" ");
                print_i32(flags[1] as i32 + flags[2] as i32); print_str(" ");
                print_str(words[1]);
            }
            """, "31 5000000000 2 1 one"),
        ("early returns release the stack frame", """
            fn find(target: i32) -> i32 {
                var values = [0; 512];
                for i in 0..512 {
                    values[i] = i * 3;
                    if values[i] >= target { return i; }
                }
                -1
            }
            export fn main() {
                var sum = 0;
                for _ in 0..1000 { sum += find(30); }
                print_i32(sum);
            }
            """, "10000"),
        ("a binding whose initializer always returns", """
            fn pick(first: bool) -> i32 {
                let unused = if first { return 1; } else { return 2; };
                unused
            }
            export fn main() { print_i32(pick(true) * 10 + pick(false)); }
            """, "12"),
        ("recursion and shadowing", """
            fn factorial(n: i64) -> i64 { if n <= 1 { 1 } else { n * factorial(n - 1) } }
            export fn main() {
                let n = 20;
                let n = factorial(n as i64);
                print_i64(n);
            }
            """, "2432902008176640000"),
        ("string escapes", #"""
            export fn main() { print_str("tab\there \"quoted\" back\\slash\n"); }
            """#, "tab\there \"quoted\" back\\slash\n"),
        ("bitwise operators", """
            export fn main() {
                let a = 12;
                let shift = 33;
                print_i32(a & 10); print_str(" ");
                print_i32(a | 3); print_str(" ");
                print_i32(a ^ 5); print_str(" ");
                print_i32(1 << shift); print_str(" ");
                print_i32(-a >> 2);
            }
            """, "8 15 9 2 -3"),
    ])
    func programOutput(description: String, source: String, expected: String) throws {
        let result = try run(source)
        #expect(result.status == 0, "\(description): \(result.stderr)")
        #expect(result.stdout == expected, "\(description)")
    }

    @Test(arguments: [
        ("out-of-bounds index", """
            export fn main() {
                var a = [1, 2, 3];
                let i = 3;
                print_str("before ");
                print_i32(a[i]);
            }
            """, "unreachable"),
        ("negative index", "export fn main() { let a = [1, 2, 3]; let i = -1; print_i32(a[i]); }", "unreachable"),
        ("integer division by zero", "export fn main() { let zero = 0; print_i32(1 / zero); }", "divide by zero"),
        ("stack exhaustion", """
            fn deep(n: i32) -> i32 {
                let pad = [n; 1000];
                if n == 0 { pad[0] } else { deep(n - 1) + pad[999] }
            }
            export fn main() { print_i32(deep(100)); }
            """, "out of bounds"),
    ])
    func trapsAreReported(description: String, source: String, message: String) throws {
        let result = try run(source)
        #expect(result.status == 1, "\(description)")
        #expect(result.stderr.hasPrefix("trap: "), "\(description)")
        #expect(result.stderr.contains(message), "\(description): \(result.stderr)")
    }

    @Test func outputPrintedBeforeATrapIsKept() throws {
        let result = try run("export fn main() { print_str(\"partial\"); let z = 0; print_i32(5 % z); }")
        #expect(result.stdout == "partial")
        #expect(result.status == 1)
    }

    @Test func runnerRejectsInvalidModules() throws {
        let result = try NodeRunner.run(WasmModule.magic + [0x02, 0x00, 0x00, 0x00], node: NodeRunner.locateNode()!)
        #expect(result.status == 2)
        #expect(result.stderr == "error: not a valid WebAssembly module\n")
    }

    @Test func runnerRequiresAMainExport() throws {
        let module = try #require(Compiler.compile(SourceFile(name: "t", text: "export fn helper() {}")).module)
        let result = try NodeRunner.run(module.encode(), node: NodeRunner.locateNode()!)
        #expect(result.status == 2)
        #expect(result.stderr == "error: module does not export a 'main' function\n")
    }
}

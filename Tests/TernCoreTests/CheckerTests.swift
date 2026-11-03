import Testing
@testable import TernCore

@Suite struct CheckerTests {
    // MARK: Accepted programs

    @Test(arguments: [
        "fn f() -> i64 { let x: i64 = 3000000000; x + 1 }",
        "fn f(x: i64) -> i64 { 1 + x * 2 }",
        "fn f() -> i32 { -2147483648 }",
        "fn f() -> i64 { -9223372036854775808 }",
        "fn f() -> f64 { let n = 3; n as f64 / 2.0 }",
        "fn f() -> i32 { true as i32 + (2.9 as i32) }",
        "fn f(n: i32) -> i32 { if n < 0 { return 0; } n }",
        "fn f(n: i32) -> i32 { if n < 0 { return 0; } else { return n; } }",
        "fn f(n: i32) -> str { if n == 0 { \"zero\" } else if n > 0 { \"positive\" } else { \"negative\" } }",
        "fn f() -> i32 { let x = 1; let x = x + 1; { let x = 10; x } + x }",
        "fn f() -> i32 { var a = [1, 2, 3]; a[0] += a[2]; a[0] }",
        "fn f() { var flags = [false; 8]; flags[3] = !flags[2] && 1 < 2; }",
        "fn f() { for i in 0..10 { if i == 5 { break; } else { continue; } } }",
        "fn even(n: i32) -> bool { if n == 0 { true } else { odd(n - 1) } } fn odd(n: i32) -> bool { if n == 0 { false } else { even(n - 1) } }",
    ])
    func acceptsWellTypedPrograms(source: String) {
        #expect(messages(source) == [])
    }

    @Test func literalTypeFlowsFromTheOtherOperand() throws {
        let program = try #require(optimizedProgram("fn f(x: i64) -> bool { 3 * x > 10 }"))
        guard case .binary(.greater, let lhs, let rhs) = program.functions[0].body.tail?.kind else {
            Issue.record("expected a comparison")
            return
        }
        #expect(lhs.type == .i64)
        #expect(rhs.type == .i64)
    }

    // MARK: Exact diagnostics

    @Test func unknownIdentifierSuggestsTheClosestName() {
        #expect(renderedDiagnostics("""
            fn main() {
                var count = 0;
                cuont += 1;
            }
            """) == [
            """
            error: cannot find 'cuont' in scope
             --> test.tern:3:5
              |
            3 |     cuont += 1;
              |     ^^^^^
              = help: did you mean 'count'?
            """,
        ])
    }

    @Test func assignmentToImmutableVariable() {
        #expect(renderedDiagnostics("fn main() {\n\tlet x = 1;\n\tx = 2;\n}") == [
            """
            error: cannot assign to immutable variable 'x'
             --> test.tern:3:2
              |
            3 | \tx = 2;
              | \t^
              = help: declare it with 'var' to make it mutable
            """,
        ])
    }

    @Test func missingReturnValuePointsAtTheClosingBrace() {
        #expect(renderedDiagnostics("fn answer() -> i32 {\n    let x = 42;\n}") == [
            """
            error: function 'answer' must return a value of type 'i32'
             --> test.tern:3:1
              |
            3 | }
              | ^
            """,
        ])
    }

    @Test func mixedIntegerWidthsSuggestACast() {
        #expect(renderedDiagnostics("fn f(a: i32, b: i64) -> i64 { a + b }") == [
            """
            error: binary operator '+' cannot be applied to 'i32' and 'i64'
             --> test.tern:1:31
              |
            1 | fn f(a: i32, b: i64) -> i64 { a + b }
              |                               ^^^^^
              = help: convert one operand with 'as', like 'x as i32'
            """,
        ])
    }

    @Test(arguments: [
        ("fn f() { let x: bool = 1; }", ["mismatched types: expected 'bool', found 'i32'"]),
        ("fn f() -> f64 { 1 }", ["mismatched types: expected 'f64', found 'i32'"]),
        ("fn f() { let x = 2147483648; }", ["integer literal '2147483648' does not fit in 'i32'"]),
        ("fn f() { let x = -2147483649; }", ["integer literal '-2147483649' does not fit in 'i32'"]),
        ("fn f() { let x: i46 = 1; }", ["unknown type 'i46'"]),
        ("fn f() { prnt(1); }", ["cannot find function 'prnt' in scope"]),
        ("fn f(a: i32) {} fn g() { f(1, 2); }", ["function 'f' takes 1 argument but 2 were given"]),
        ("fn f(a: i32, b: i32) {} fn g() { f(1); }", ["function 'f' takes 2 arguments but 1 was given"]),
        ("fn f() { print_i32(1.5); }", ["mismatched types: expected 'i32', found 'f64'"]),
        ("fn f() { break; }", ["'break' outside of a loop"]),
        ("fn f() { continue; }", ["'continue' outside of a loop"]),
        ("fn f() -> i32 { return; }", ["missing return value; function returns 'i32'"]),
        ("fn f() { return 1; }", ["mismatched types: expected '()', found 'i32'"]),
        ("fn f(c: bool) -> i32 { if c { 1 } }", ["'if' without 'else' cannot produce a value"]),
        ("fn f(c: bool) { let x = if c { 1 } else { true }; }", ["'if' and 'else' have incompatible types 'i32' and 'bool'"]),
        ("fn f() { if 1 { } }", ["mismatched types: expected 'bool', found 'i32'"]),
        ("fn f() { while 0 { } }", ["mismatched types: expected 'bool', found 'i32'"]),
        ("fn f() { for i in 0.0..1.0 { } }", ["range bounds must be 'i32' or 'i64', found 'f64'"]),
        ("fn f() { let b = true + false; }", ["binary operator '+' cannot be applied to 'bool' and 'bool'"]),
        ("fn f() { let r = 5.0 % 2.0; }", ["binary operator '%' cannot be applied to 'f64' and 'f64'"]),
        ("fn f() { let s = \"a\" == \"a\"; }", ["binary operator '==' cannot be applied to 'str' and 'str'"]),
        ("fn f() { let n = -true; }", ["unary operator '-' cannot be applied to 'bool'"]),
        ("fn f() { let n = !1; }", ["unary operator '!' cannot be applied to 'i32'"]),
        ("fn f() { let x = true as f64; }", ["cannot cast 'bool' to 'f64'"]),
        ("fn f() { var b = true; b += true; }", ["operator '+=' cannot be applied to 'bool'"]),
        ("fn f() { let u = print_i32(1); }", ["cannot bind 'u' to a value of type '()'"]),
        ("fn f() {} fn f() {}", ["function 'f' is already defined"]),
        ("fn print_i32(x: i32) {}", ["'print_i32' is a builtin function and cannot be redefined"]),
        ("fn f(a: i32, a: i32) {}", ["duplicate parameter 'a'"]),
        ("fn f() { 1 = 2; }", ["invalid assignment target"]),
    ])
    func rejectsIllTypedPrograms(source: String, expected: [String]) {
        #expect(messages(source) == expected)
    }

    @Test(arguments: [
        ("fn f() { let a = [1, 2]; let b = a; }", ["array 'a' cannot be used as a value"]),
        ("fn f() { let a = [1, 2]; a[0] = 5; }", ["cannot assign to an element of immutable array 'a'"]),
        ("fn f() { var a = [1, 2]; a = 5; }", ["cannot assign to array 'a' as a whole"]),
        ("fn f() { let a = [1, true]; }", ["mismatched types: expected 'i32', found 'bool'"]),
        ("fn f() { let a = [1, 2]; let x = a[1.0]; }", ["mismatched types: expected 'i32', found 'f64'"]),
        ("fn f() { let x = 3; let y = x[0]; }", ["cannot index into a value of type 'i32'"]),
        ("fn f() { let a: [[i32; 2]; 2] = [0; 2]; }", ["array elements must be of type i32, i64, f64, bool or str, found '[i32; 2]'"]),
        ("fn f() { let a = [0; 0]; }", ["array length must be at least 1"]),
        ("fn f() { let a = [0; 20000]; }", ["array '[i32; 20000]' does not fit in the 65536-byte stack"]),
        ("fn f(a: [i32; 4]) {}", ["arrays cannot be passed to or returned from functions"]),
        ("fn f() { print_i32([1, 2][0]); }", ["only array variables can be indexed"]),
        ("fn f() { print_i32([1, 2]); }", ["array literals can only initialize a 'let' or 'var' binding"]),
    ])
    func rejectsArrayMisuse(source: String, expected: [String]) {
        #expect(messages(source) == expected)
    }

    @Test func reportsEveryErrorInSourceOrder() {
        #expect(messages("""
            fn average(values: i32, count: i32) -> f64 {
                values / count
            }
            export fn main() {
                let limit = 10;
                limit = 5;
                print_i32(averag(1, 2));
                print_i32(true);
            }
            """) == [
            "mismatched types: expected 'f64', found 'i32'",
            "cannot assign to immutable variable 'limit'",
            "cannot find function 'averag' in scope",
            "mismatched types: expected 'i32', found 'bool'",
        ])
    }

    @Test func errorTypesDoNotCascade() {
        // One typo, one diagnostic: uses of the broken value stay quiet.
        #expect(messages("fn f() -> i32 { let x = undefined + 1; let y = x * 2; y }") == [
            "cannot find 'undefined' in scope",
        ])
    }

    @Test func warnsOnceAboutUnreachableCode() {
        let source = "fn f() -> i32 { return 1; let x = 2; x }"
        #expect(Compiler.analyze(SourceFile(name: "t", text: source)).program != nil)
        #expect(renderedDiagnostics(source) == [
            """
            warning: unreachable code
             --> test.tern:1:27
              |
            1 | fn f() -> i32 { return 1; let x = 2; x }
              |                           ^^^^^^^^^^
            """,
        ])
    }

    @Test func suggestionsNeedToBeClose() {
        #expect(Checker.closestMatch(to: "cuont", in: ["count", "limit"]) == "count")
        #expect(Checker.closestMatch(to: "lenght", in: ["length", "height"]) == "length")
        #expect(Checker.closestMatch(to: "total", in: ["count", "limit"]) == nil)
        #expect(Checker.editDistance("kitten", "sitting") == 3)
        #expect(Checker.editDistance("", "abc") == 3)
    }
}

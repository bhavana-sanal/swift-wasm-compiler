import Testing
@testable import TernCore

@Suite struct ParserTests {
    @Test(arguments: [
        ("1 + 2 * 3", "(+ 1 (* 2 3))"),
        ("1 * 2 + 3", "(+ (* 1 2) 3)"),
        ("1 - 2 - 3", "(- (- 1 2) 3)"),
        ("8 / 4 % 3", "(% (/ 8 4) 3)"),
        ("(1 + 2) * 3", "(* (+ 1 2) 3)"),
        ("a || b && c", "(|| a (&& b c))"),
        ("a && b == c", "(&& a (== b c))"),
        ("a < b + 1", "(< a (+ b 1))"),
        ("a & b == c", "(== (& a b) c)"),
        ("a | b ^ c & d", "(| a (^ b (& c d)))"),
        ("1 + 2 << 3", "(<< (+ 1 2) 3)"),
        ("-x * y", "(* (- x) y)"),
        ("!a && b", "(&& (! a) b)"),
        ("--x", "(- (- x))"),
        ("x as f64 * 2.0", "(* (as x f64) 2.0)"),
        ("-x as i64", "(as (- x) i64)"),
        ("a + b as i64", "(+ a (as b i64))"),
        ("f(1, g(2)) + a[i + 1]", "(+ (f 1 (g 2)) (index a (+ i 1)))"),
        ("if a { 1 } else if b { 2 } else { 3 }", "(if a {0 stmts 1} (if b {0 stmts 2} {0 stmts 3}))"),
        ("[1, 2, 3,]", "[1, 2, 3]"),
        ("[0.5; 8]", "[0.5; 8]"),
    ])
    func precedenceAndAssociativity(source: String, expected: String) {
        #expect(parseExpression(source)?.sexpr == expected)
    }

    @Test func statementsAndTailExpression() throws {
        let (program, diagnostics) = parse("""
            fn f(n: i32) -> i32 {
                var total: i64 = 0;
                for i in 0..n { total += i as i64; }
                while total > 10 { total -= 1; break; }
                if n > 0 { continue; }
                return 1;
                total as i32
            }
            """)
        #expect(diagnostics.isEmpty)
        let function = try #require(program.functions.first)
        #expect(function.parameters.map(\.name) == ["n"])
        #expect(function.returnType?.sexpr == "i32")
        let kinds = function.body.statements.map { statement in
            switch statement {
            case .binding(let binding): "\(binding.isMutable ? "var" : "let") \(binding.name)"
            case .assign: "assign"
            case .expr: "expr"
            case .whileLoop: "while"
            case .forLoop(let variable, _, _, _, _, _): "for \(variable)"
            case .returnStmt: "return"
            case .breakStmt: "break"
            case .continueStmt: "continue"
            }
        }
        #expect(kinds == ["var total", "for i", "while", "expr", "return"])
        #expect(function.body.tail?.sexpr == "(as total i32)")
    }

    @Test func compoundAssignmentKeepsItsOperator() throws {
        let statement = try #require(parse("fn f() { a[i] *= 2; }").program.functions.first?.body.statements.first)
        guard case .assign(let target, let op, let value, _) = statement else {
            Issue.record("expected an assignment, got \(statement)")
            return
        }
        #expect(target.sexpr == "(index a i)")
        #expect(op == .multiply)
        #expect(value.sexpr == "2")
    }

    @Test func arrayTypes() throws {
        let function = try #require(parse("fn f() { let a: [bool; 16] = [false; 16]; }").program.functions.first)
        guard case .binding(let binding) = function.body.statements.first else {
            Issue.record("expected a binding")
            return
        }
        #expect(binding.type?.sexpr == "[bool; 16]")
    }

    @Test func spansCoverTheWholeExpression() throws {
        let expr = try #require(parseExpression("foo(1) + bar[2]"))
        // The function body starts after "fn f() { ".
        #expect(expr.span == Span(start: 9, end: 24))
    }

    @Test func recoversAtStatementBoundaries() {
        let (program, diagnostics) = parse("""
            fn main() {
                let x = 5
                let y = (x + ;
                print_i32(x y);
                let z = 1;
            }
            fn after() -> i32 { 1 }
            """)
        #expect(diagnostics.map(\.message) == [
            "expected ';', found 'let'",
            "expected expression, found ';'",
            "expected ')', found identifier 'y'",
        ])
        #expect(program.functions.map(\.name) == ["main", "after"])
    }

    @Test func recoversAtItemBoundaries() {
        let (program, diagnostics) = parse("""
            fn broken( -> i32 { 1 }
            fn fine() {}
            let stray = 3;
            fn last() {}
            """)
        #expect(diagnostics.map(\.message) == [
            "expected identifier, found '->'",
            "expected 'fn', found 'let'",
        ])
        #expect(program.functions.map(\.name) == ["fine", "last"])
    }

    @Test func missingSemicolonPointsAfterThePreviousToken() {
        #expect(renderedDiagnostics("fn f() {\n    let x = 1\n    x\n}") == [
            """
            error: expected ';', found identifier 'x'
             --> test.tern:2:14
              |
            2 |     let x = 1
              |              ^
            """,
        ])
    }

    @Test func unclosedBlockAtEndOfFile() {
        #expect(parse("fn f() { let x = 1;").diagnostics.map(\.message) == ["expected '}', found end of file"])
    }

    @Test func emptyArrayLiteralIsRejected() {
        #expect(parse("fn f() { let a = []; }").diagnostics.map(\.message) == ["array literals must have at least one element"])
    }
}

import Testing
@testable import TernCore

@Suite struct OptimizerTests {
    /// The optimized trailing expression of `fn f() -> <type> { <body> }`.
    private func fold(_ body: String, returning type: String = "i32") throws -> TypedExpr {
        let program = try #require(optimizedProgram("fn f(x: i32, b: bool) -> \(type) { \(body) }"))
        return try #require(program.functions[0].body.tail)
    }

    private func foldedInteger(_ body: String, returning type: String = "i32") throws -> Int64? {
        if case .int(let value) = try fold(body, returning: type).kind { return value }
        return nil
    }

    @Test(arguments: [
        ("2 * 3 + 1", Int64(7)),
        ("(10 - 4) / 4", 1),
        ("-7 % 3", -1),
        ("2147483647 + 1", Int64(Int32.min)),
        ("-2147483648 - 1", Int64(Int32.max)),
        ("65536 * 65536", 0),
        ("-2147483648 % -1", 0),
        ("1 << 33", 2),
        ("-16 >> 2", -4),
        ("6 & 3 | 8 ^ 1", 11),
        ("if 1 < 2 { 10 } else { 20 }", 10),
        ("{ 3 * 3 }", 9),
        ("3.99 as i32", 3),
        ("-3.99 as i32", -3),
        ("1e20 as i32", Int64(Int32.max)),
        ("-1e20 as i32", Int64(Int32.min)),
        ("(0.0 / 0.0) as i32", 0),
        ("true as i32 + false as i32", 1),
        ("3000000000 as i64 as i32", -1294967296),
    ])
    func foldsI32Constants(body: String, expected: Int64) throws {
        #expect(try foldedInteger(body) == expected)
    }

    @Test func foldsI64ConstantsWithWrapping() throws {
        #expect(try foldedInteger("9223372036854775807 + 1", returning: "i64") == Int64.min)
        #expect(try foldedInteger("(1 as i64) << 40", returning: "i64") == 1 << 40)
    }

    @Test func foldsFloatsAndComparisons() throws {
        guard case .float(let value) = try fold("7 as f64 / 2.0 - 0.5", returning: "f64").kind else {
            Issue.record("expected a folded float")
            return
        }
        #expect(value == 3.0)
        guard case .bool(true) = try fold("1 < 2 && 2.5 >= 2.5 && !(3 == 4)", returning: "bool").kind else {
            Issue.record("expected a folded 'true'")
            return
        }
    }

    @Test(arguments: ["1 / 0", "-2147483648 / -1", "5 % 0"])
    func leavesTrappingDivisionForRunTime(body: String) throws {
        guard case .binary = try fold(body).kind else {
            Issue.record("'\(body)' must not be folded")
            return
        }
    }

    @Test func shortCircuitsConstantLogicalOperands() throws {
        guard case .local(1) = try fold("true && b", returning: "bool").kind else {
            Issue.record("'true && b' should fold to 'b'")
            return
        }
        guard case .bool(false) = try fold("false && b", returning: "bool").kind else {
            Issue.record("'false && b' should fold to 'false'")
            return
        }
        guard case .bool(true) = try fold("true || b", returning: "bool").kind else {
            Issue.record("'true || b' should fold to 'true'")
            return
        }
    }

    @Test func doesNotFoldThroughVariables() throws {
        guard case .binary(.add, _, _) = try fold("x + 1").kind else {
            Issue.record("'x + 1' must stay a runtime addition")
            return
        }
    }

    @Test func dropsCodeAfterReturn() throws {
        let program = try #require(optimizedProgram("fn f() -> i32 { return 1; print_i32(2); 3 }"))
        let body = program.functions[0].body
        #expect(body.statements.count == 1)
        #expect(body.tail == nil)
    }

    @Test func dropsCodeAfterBreakInsideLoops() throws {
        let program = try #require(optimizedProgram("fn f() { while true { break; print_i32(1); } }"))
        guard case .whileLoop(_, let loopBody) = program.functions[0].body.statements.first else {
            Issue.record("expected the loop to survive")
            return
        }
        #expect(loopBody.statements.count == 1)
    }

    @Test func removesDeadBranchesAndLoops() throws {
        let program = try #require(optimizedProgram("""
            fn f() {
                while false { print_i32(1); }
                if 2 > 3 { print_i32(2); }
                print_i32(3);
            }
            """))
        let statements = program.functions[0].body.statements
        #expect(statements.count == 1)
        guard case .expr(let call) = statements.last, case .call(.builtin(.printI32), _) = call.kind else {
            Issue.record("expected the final print to remain")
            return
        }
    }

    @Test func saturatingTruncationMatchesWasm() {
        #expect(Optimizer.saturatingTruncation(.nan, as: Int32.self) == 0)
        #expect(Optimizer.saturatingTruncation(.infinity, as: Int64.self) == .max)
        #expect(Optimizer.saturatingTruncation(-.infinity, as: Int64.self) == .min)
        #expect(Optimizer.saturatingTruncation(2147483647.9, as: Int32.self) == .max)
        #expect(Optimizer.saturatingTruncation(-0.9, as: Int32.self) == 0)
    }
}

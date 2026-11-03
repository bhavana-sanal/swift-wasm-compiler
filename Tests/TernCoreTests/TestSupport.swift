import Foundation
@testable import TernCore

func tokenize(_ text: String) -> (kinds: [TokenKind], diagnostics: [Diagnostic]) {
    var lexer = Lexer(source: SourceFile(name: "test.tern", text: text))
    let tokens = lexer.tokenize()
    return (tokens.map(\.kind), lexer.diagnostics)
}

func parse(_ text: String) -> (program: Program, diagnostics: [Diagnostic]) {
    var lexer = Lexer(source: SourceFile(name: "test.tern", text: text))
    var parser = Parser(tokens: lexer.tokenize())
    let program = parser.parseProgram()
    return (program, lexer.diagnostics + parser.diagnostics)
}

/// Parses `text` as the trailing expression of a function body.
func parseExpression(_ text: String) -> Expr? {
    parse("fn f() { \(text) }").program.functions.first?.body.tail
}

/// Every diagnostic for `text`, rendered exactly as the CLI prints it.
func renderedDiagnostics(_ text: String) -> [String] {
    let source = SourceFile(name: "test.tern", text: text)
    return Compiler.analyze(source).diagnostics.map { $0.render(in: source) }
}

func messages(_ text: String) -> [String] {
    Compiler.analyze(SourceFile(name: "test.tern", text: text)).diagnostics.map(\.message)
}

/// Checks and optimizes `text`, which must be free of errors.
func optimizedProgram(_ text: String) -> TypedProgram? {
    Compiler.analyze(SourceFile(name: "test.tern", text: text)).program.map(Optimizer.optimize)
}

let packageRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

let nodeIsAvailable = NodeRunner.locateNode() != nil

/// Compiles and runs `text` under Node, returning the runner's result.
func run(_ text: String) throws -> NodeRunner.Result {
    let output = Compiler.compile(SourceFile(name: "test.tern", text: text))
    guard let module = output.module else {
        let source = SourceFile(name: "test.tern", text: text)
        throw CompileFailure(diagnostics: output.diagnostics.map { $0.render(in: source) })
    }
    return try NodeRunner.run(module.encode(), node: NodeRunner.locateNode()!)
}

struct CompileFailure: Error, CustomStringConvertible {
    let diagnostics: [String]
    var description: String { diagnostics.joined(separator: "\n\n") }
}

/// A compact S-expression rendering of the syntax tree, for precedence tests.
extension Expr {
    var sexpr: String {
        switch kind {
        case .integer(let value): "\(value)"
        case .float(let value): "\(value)"
        case .bool(let value): "\(value)"
        case .string(let value): "\"\(value)\""
        case .identifier(let name): name
        case .unary(let op, let operand): "(\(op.rawValue) \(operand.sexpr))"
        case .binary(let op, let lhs, let rhs): "(\(op.rawValue) \(lhs.sexpr) \(rhs.sexpr))"
        case .call(let callee, _, let arguments): "(\(([callee] + arguments.map(\.sexpr)).joined(separator: " ")))"
        case .index(let base, let index): "(index \(base.sexpr) \(index.sexpr))"
        case .cast(let operand, let type): "(as \(operand.sexpr) \(type.sexpr))"
        case .ifElse(let condition, let then, let elseBranch):
            "(if \(condition.sexpr) \(then.sexpr)\(elseBranch.map { " " + $0.sexpr } ?? ""))"
        case .block(let block): block.sexpr
        case .arrayList(let elements): "[\(elements.map(\.sexpr).joined(separator: ", "))]"
        case .arrayRepeat(let element, let count): "[\(element.sexpr); \(count)]"
        }
    }
}

extension Block {
    var sexpr: String {
        "{\(statements.count) stmts\(tail.map { " " + $0.sexpr } ?? "")}"
    }
}

extension TypeExpr {
    var sexpr: String {
        switch self {
        case .named(let name, _): name
        case .array(let element, let count, _): "[\(element.sexpr); \(count)]"
        }
    }
}

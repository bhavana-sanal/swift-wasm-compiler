/// The compiler pipeline: lex → parse → check → optimize → lower → encode.
public enum Compiler {
    public struct Analysis: Sendable {
        /// `nil` when any error was reported.
        public let program: TypedProgram?
        /// Errors and warnings, ordered by source position.
        public let diagnostics: [Diagnostic]
    }

    public struct Output: Sendable {
        /// `nil` when any error was reported.
        public let module: WasmModule?
        public let diagnostics: [Diagnostic]
    }

    /// Runs the front end. Type checking is skipped after syntax errors, since
    /// a partially parsed program mostly produces follow-on noise.
    public static func analyze(_ source: SourceFile) -> Analysis {
        var lexer = Lexer(source: source)
        var parser = Parser(tokens: lexer.tokenize())
        let syntax = parser.parseProgram()
        var diagnostics = lexer.diagnostics + parser.diagnostics
        guard !diagnostics.hasErrors else {
            return Analysis(program: nil, diagnostics: sorted(diagnostics))
        }

        var checker = Checker()
        let program = checker.check(syntax)
        diagnostics += checker.diagnostics
        return Analysis(program: diagnostics.hasErrors ? nil : program, diagnostics: sorted(diagnostics))
    }

    public static func compile(_ source: SourceFile) -> Output {
        let analysis = analyze(source)
        let module = analysis.program.map { CodeGenerator.generate(Optimizer.optimize($0)) }
        return Output(module: module, diagnostics: analysis.diagnostics)
    }

    private static func sorted(_ diagnostics: [Diagnostic]) -> [Diagnostic] {
        diagnostics.enumerated()
            .sorted { ($0.element.span.start, $0.offset) < ($1.element.span.start, $1.offset) }
            .map(\.element)
    }
}

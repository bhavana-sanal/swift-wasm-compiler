import Testing
@testable import TernCore

@Suite struct LexerTests {
    @Test func keywordsIdentifiersAndSymbols() {
        let (kinds, diagnostics) = tokenize("export fn add_1(x: i32) -> i32 { x += 1; }")
        #expect(diagnostics.isEmpty)
        #expect(kinds == [
            .keyword(.export), .keyword(.fn), .identifier("add_1"), .symbol(.leftParen),
            .identifier("x"), .symbol(.colon), .identifier("i32"), .symbol(.rightParen),
            .symbol(.arrow), .identifier("i32"), .symbol(.leftBrace), .identifier("x"),
            .symbol(.plusEqual), .integer(1), .symbol(.semicolon), .symbol(.rightBrace), .endOfFile,
        ])
    }

    @Test func twoCharacterOperatorsWinOverOneCharacterPrefixes() {
        let (kinds, _) = tokenize("<= << < >= >> > == = != ! && & || | ..")
        #expect(kinds == [
            .symbol(.lessEqual), .symbol(.shiftLeft), .symbol(.less),
            .symbol(.greaterEqual), .symbol(.shiftRight), .symbol(.greater),
            .symbol(.equalEqual), .symbol(.equal), .symbol(.bangEqual), .symbol(.bang),
            .symbol(.andAnd), .symbol(.ampersand), .symbol(.pipePipe), .symbol(.pipe),
            .symbol(.dotDot), .endOfFile,
        ])
    }

    @Test func rangeIsNotMistakenForAFloat() {
        #expect(tokenize("0..10").kinds == [.integer(0), .symbol(.dotDot), .integer(10), .endOfFile])
    }

    @Test func numbers() {
        let (kinds, diagnostics) = tokenize("42 3.25 1e3 2.5E-2 18446744073709551615")
        #expect(diagnostics.isEmpty)
        #expect(kinds == [.integer(42), .float(3.25), .float(1000), .float(0.025), .integer(UInt64.max), .endOfFile])
    }

    @Test func integerTooLargeForAnyType() {
        let (_, diagnostics) = tokenize("18446744073709551616")
        #expect(diagnostics.map(\.message) == ["integer literal '18446744073709551616' is too large"])
    }

    @Test func stringEscapes() {
        let (kinds, diagnostics) = tokenize(#""a\tb\n\"q\" \\ \0""#)
        #expect(diagnostics.isEmpty)
        #expect(kinds == [.string("a\tb\n\"q\" \\ \0"), .endOfFile])
    }

    @Test func commentsAreSkipped() {
        #expect(tokenize("a // the rest is ignored\nb").kinds == [.identifier("a"), .identifier("b"), .endOfFile])
    }

    @Test func spansAreByteOffsets() {
        var lexer = Lexer(source: SourceFile(name: "t", text: "let  name = 10;"))
        let spans = lexer.tokenize().map { [$0.span.start, $0.span.end] }
        #expect(spans == [[0, 3], [5, 9], [10, 11], [12, 14], [14, 15], [15, 15]])
    }

    @Test func errorsAreReportedAndLexingContinues() {
        let (kinds, diagnostics) = tokenize("a $ b \"\\q\" é \"open")
        #expect(diagnostics.map(\.message) == [
            "unexpected character '$'",
            "unknown escape sequence '\\q'",
            "unexpected character 'é'",
            "unterminated string literal",
        ])
        #expect(kinds == [.identifier("a"), .identifier("b"), .string(""), .string("open"), .endOfFile])
    }

    @Test func sourceLocations() {
        let file = SourceFile(name: "t", text: "ab\ncd\n\nef")
        #expect(file.location(of: 0) == SourceLocation(line: 1, column: 1))
        #expect(file.location(of: 4) == SourceLocation(line: 2, column: 2))
        #expect(file.location(of: 6) == SourceLocation(line: 3, column: 1))
        #expect(file.location(of: 8) == SourceLocation(line: 4, column: 2))
        #expect(file.lineText(2) == "cd")
    }
}

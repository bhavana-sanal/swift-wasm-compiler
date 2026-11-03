public struct Diagnostic: Hashable, Sendable {
    public enum Severity: String, Sendable {
        case error
        case warning
    }

    public let severity: Severity
    public let message: String
    public let span: Span
    public let help: String?

    public init(_ severity: Severity, _ message: String, at span: Span, help: String? = nil) {
        self.severity = severity
        self.message = message
        self.span = span
        self.help = help
    }

    public static func error(_ message: String, at span: Span, help: String? = nil) -> Diagnostic {
        Diagnostic(.error, message, at: span, help: help)
    }

    public static func warning(_ message: String, at span: Span, help: String? = nil) -> Diagnostic {
        Diagnostic(.warning, message, at: span, help: help)
    }

    /// Renders the diagnostic rustc-style:
    ///
    ///     error: cannot find 'cuont' in scope
    ///      --> main.tern:3:5
    ///       |
    ///     3 |     cuont = 1;
    ///       |     ^^^^^
    ///       = help: did you mean 'count'?
    public func render(in file: SourceFile) -> String {
        let location = file.location(of: span.start)
        let line = file.lineText(location.line)
        let gutter = String(repeating: " ", count: String(location.line).count)

        // Reuse the line's own tabs in the padding so the carets stay aligned.
        let prefix = Array(line.utf8.prefix(location.column - 1))
        let padding = String(decoding: prefix.map { $0 == UInt8(ascii: "\t") ? $0 : UInt8(ascii: " ") }, as: UTF8.self)
        let width = max(1, min(span.end - span.start, line.utf8.count - (location.column - 1)))

        var lines = [
            "\(severity.rawValue): \(message)",
            "\(gutter)--> \(file.name):\(location.line):\(location.column)",
            "\(gutter) |",
            "\(location.line) | \(line)",
            "\(gutter) | \(padding)\(String(repeating: "^", count: width))",
        ]
        if let help {
            lines.append("\(gutter) = help: \(help)")
        }
        return lines.joined(separator: "\n")
    }
}

extension [Diagnostic] {
    public var hasErrors: Bool { contains { $0.severity == .error } }
}

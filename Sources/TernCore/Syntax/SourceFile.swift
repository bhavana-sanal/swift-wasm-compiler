/// A half-open range of UTF-8 byte offsets into a ``SourceFile``.
public struct Span: Hashable, Sendable {
    public var start: Int
    public var end: Int

    public init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }

    /// The smallest span covering both `self` and `other`.
    public func through(_ other: Span) -> Span {
        Span(start: min(start, other.start), end: max(end, other.end))
    }
}

/// A 1-based line and column. Columns count UTF-8 bytes.
public struct SourceLocation: Hashable, Sendable {
    public let line: Int
    public let column: Int
}

public struct SourceFile: Sendable {
    public let name: String
    let bytes: [UInt8]
    private let lineStarts: [Int]

    public init(name: String, text: String) {
        self.name = name
        self.bytes = Array(text.utf8)
        var starts = [0]
        for (offset, byte) in bytes.enumerated() where byte == UInt8(ascii: "\n") {
            starts.append(offset + 1)
        }
        self.lineStarts = starts
    }

    public func location(of offset: Int) -> SourceLocation {
        let line = lineIndex(containing: offset)
        return SourceLocation(line: line + 1, column: offset - lineStarts[line] + 1)
    }

    /// The text of the given 1-based line, without its terminating newline.
    func lineText(_ line: Int) -> String {
        let start = lineStarts[line - 1]
        var end = line < lineStarts.count ? lineStarts[line] - 1 : bytes.count
        if end > start, bytes[end - 1] == UInt8(ascii: "\r") { end -= 1 }
        return String(decoding: bytes[start..<max(start, end)], as: UTF8.self)
    }

    private func lineIndex(containing offset: Int) -> Int {
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low
    }
}

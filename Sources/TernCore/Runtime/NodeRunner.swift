import Foundation

/// Runs compiled modules under Node.js using the bundled `run.mjs` host,
/// which validates the module, provides the print imports and calls `main`.
public enum NodeRunner {
    public struct Result: Sendable {
        public let status: Int32
        public let stdout: String
        public let stderr: String
    }

    /// Searches `PATH` for a `node` executable.
    public static func locateNode() -> URL? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        return path.split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent("node") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    public static func run(_ wasm: [UInt8], node: URL) throws -> Result {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent("ternc-\(UUID().uuidString)")
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let module = directory.appendingPathComponent("program.wasm")
        try Data(wasm).write(to: module)

        // Output goes to files rather than pipes so a chatty program can't
        // fill a pipe buffer and deadlock against `waitUntilExit`.
        let stdoutURL = directory.appendingPathComponent("stdout")
        let stderrURL = directory.appendingPathComponent("stderr")
        try Data().write(to: stdoutURL)
        try Data().write(to: stderrURL)
        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)

        let process = Process()
        process.executableURL = node
        process.arguments = [scriptURL.path, module.path]
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        try stdout.close()
        try stderr.close()

        return Result(
            status: process.terminationStatus,
            stdout: try String(contentsOf: stdoutURL, encoding: .utf8),
            stderr: try String(contentsOf: stderrURL, encoding: .utf8)
        )
    }

    static var scriptURL: URL {
        guard let url = Bundle.module.url(forResource: "run", withExtension: "mjs") else {
            preconditionFailure("run.mjs is missing from the TernCore resource bundle")
        }
        return url
    }
}

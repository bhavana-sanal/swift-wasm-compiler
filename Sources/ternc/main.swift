import Foundation
import TernCore

let usage = """
    usage: ternc <command> <file.tern> [options]

    commands:
      build <file> [-o <path>] [--emit wasm|wat]   compile to a Wasm binary (or text)
      check <file>                                 type-check and report diagnostics
      run <file>                                   compile and run main() under Node.js

    """

struct UsageError: Error {
    let message: String
}

struct Options {
    enum Command: String {
        case build, check, run
    }

    enum Emit: String {
        case wasm, wat
    }

    var command: Command
    var input: String
    var output: String?
    var emit = Emit.wasm

    init(arguments: [String]) throws(UsageError) {
        guard let name = arguments.first else { throw UsageError(message: "missing command") }
        guard let command = Command(rawValue: name) else { throw UsageError(message: "unknown command '\(name)'") }
        self.command = command

        var input: String?
        var remaining = arguments.dropFirst()
        while let argument = remaining.popFirst() {
            switch argument {
            case "-o":
                guard command == .build, let value = remaining.popFirst() else {
                    throw UsageError(message: "'-o' expects a path and is only valid with 'build'")
                }
                output = value
            case "--emit":
                guard command == .build, let value = remaining.popFirst().flatMap(Emit.init(rawValue:)) else {
                    throw UsageError(message: "'--emit' expects 'wasm' or 'wat' and is only valid with 'build'")
                }
                emit = value
            case _ where argument.hasPrefix("-"):
                throw UsageError(message: "unknown option '\(argument)'")
            default:
                guard input == nil else { throw UsageError(message: "expected a single input file") }
                input = argument
            }
        }
        guard let input else { throw UsageError(message: "missing input file") }
        self.input = input
    }

    var outputPath: String {
        if let output { return output }
        let base = input.hasSuffix(".tern") ? String(input.dropLast(5)) : input
        return "\(base).\(emit.rawValue)"
    }
}

func printError(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

/// Prints diagnostics and returns whether any of them is an error.
func report(_ diagnostics: [Diagnostic], in source: SourceFile) -> Bool {
    for diagnostic in diagnostics {
        printError(diagnostic.render(in: source) + "\n")
    }
    let errors = diagnostics.filter { $0.severity == .error }.count
    if errors > 0 {
        printError("error: could not compile '\(source.name)' due to \(errors) \(errors == 1 ? "error" : "errors")")
    }
    return errors > 0
}

func runCommandLine() -> Int32 {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if let first = arguments.first, ["-h", "--help", "help"].contains(first) {
        print(usage, terminator: "")
        return 0
    }

    let options: Options
    do {
        options = try Options(arguments: arguments)
    } catch {
        printError("error: \(error.message)\n\n\(usage)")
        return 2
    }

    let text: String
    do {
        text = try String(contentsOfFile: options.input, encoding: .utf8)
    } catch {
        printError("error: cannot read '\(options.input)': \(error.localizedDescription)")
        return 1
    }
    let source = SourceFile(name: options.input, text: text)

    switch options.command {
    case .check:
        return report(Compiler.analyze(source).diagnostics, in: source) ? 1 : 0

    case .build:
        guard let module = compile(source) else { return 1 }
        let contents = options.emit == .wat ? Data(module.wat().utf8) : Data(module.encode())
        do {
            try contents.write(to: URL(fileURLWithPath: options.outputPath))
        } catch {
            printError("error: cannot write '\(options.outputPath)': \(error.localizedDescription)")
            return 1
        }
        return 0

    case .run:
        guard let module = compile(source) else { return 1 }
        guard let node = NodeRunner.locateNode() else {
            printError("error: 'node' was not found on PATH; install Node.js to use 'ternc run'")
            return 1
        }
        do {
            let result = try NodeRunner.run(module.encode(), node: node)
            FileHandle.standardOutput.write(Data(result.stdout.utf8))
            FileHandle.standardError.write(Data(result.stderr.utf8))
            return result.status
        } catch {
            printError("error: failed to run node: \(error.localizedDescription)")
            return 1
        }
    }
}

func compile(_ source: SourceFile) -> WasmModule? {
    let output = Compiler.compile(source)
    return report(output.diagnostics, in: source) ? nil : output.module
}

exit(runCommandLine())

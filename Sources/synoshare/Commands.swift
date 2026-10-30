import Foundation
import SynoShareKit

/// The network commands share one shape: parse link, ask password, run the engine.
enum Commands {
    static func run(_ arguments: Arguments) async throws {
        switch arguments.command {
        case "probe":
            try arguments.requirePositionals(1)
            let link = try ShareLink(parsing: arguments.positionals[0])
            let destination = try arguments.destination()
            try await Probe(link: link, destination: destination, password: try askPassword()).run()
            print("\nProbe finished.")
        case "list", "download", "retry-failed", "speedtest":
            try await runEngine(arguments)
        case "status":
            try arguments.requirePositionals(0)
            print(try DownloadEngine.report(destination: try arguments.destination()).text)
        case "verify":
            try arguments.requirePositionals(0)
            try verify(destination: try arguments.destination())
        case "resolve":
            try resolve(arguments)
        default:
            throw ArgumentError(usage)
        }
    }

    private static func runEngine(_ arguments: Arguments) async throws {
        try arguments.requirePositionals(1)
        var configuration = EngineConfiguration(link: try ShareLink(parsing: arguments.positionals[0]),
                                                destination: try arguments.destination())
        configuration.maxConcurrency = try arguments.positiveInt("--concurrency", default: 3)
        configuration.preventSleep = !arguments.flags.contains("--allow-sleep")
        let mebibytes = try arguments.positiveInt("--mib", default: 32)
        let password = try askPassword()
        let engine = try DownloadEngine(configuration: configuration, passwordProvider: { password })
        let printer = Task {
            var printer = ProgressPrinter()
            for await event in engine.events { printer.handle(event) }
        }
        let interrupts = InterruptHandler()
        interrupts.install { Task { await engine.stop() } }

        do {
            switch arguments.command {
            case "list": print(try await engine.list(refresh: true).text)
            case "download": print(try await engine.run().text)
            case "retry-failed": print(try await engine.retryFailed().text)
            default:
                let result = try await engine.speedTest(byteCount: Int64(mebibytes) * 1024 * 1024)
                print(String(format: "speed test: %@ in %.1f s = %.2f MB/s",
                             formatBytes(result.bytes), result.seconds, result.megabytesPerSecond))
            }
        } catch {
            await engine.shutdown()
            await printer.value
            throw error
        }
        await engine.shutdown()
        await printer.value
    }

    private static func verify(destination: URL) throws {
        let result = try DownloadEngine.verify(destination: destination)
        print("verified \(result.checked) completed file(s): \(result.ok) OK, \(result.problems.count) problem(s)")
        for problem in result.problems.prefix(50) { print("  \(problem.relPath): \(problem.message)") }
        print(Report.integrityNote)
    }

    private static func resolve(_ arguments: Arguments) throws {
        try arguments.requirePositionals(2)
        guard let resolution = ConflictResolution(rawValue: arguments.positionals[1]) else {
            throw ArgumentError("resolution must be replace or keep-both")
        }
        let store = try StateStore.open(destination: try arguments.destination(), create: false)
        try store.resolveConflict(arguments.positionals[0], resolution)
        print("queued (\(resolution.rawValue)); run download to apply")
    }

    private static func askPassword() throws -> String {
        guard let password = readPassword(prompt: "Share password: "), !password.isEmpty else {
            throw ArgumentError("no password entered (a terminal is required)")
        }
        return password
    }
}

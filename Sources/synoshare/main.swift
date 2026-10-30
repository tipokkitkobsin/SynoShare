import Foundation

do {
    try await Commands.run(Arguments(Array(CommandLine.arguments.dropFirst())))
} catch {
    fail(error.localizedDescription)
}

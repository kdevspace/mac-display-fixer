import Foundation

// Entry point: with CLI arguments the tool runs as a command line utility,
// otherwise it launches the menu bar app.
let arguments = CommandLine.arguments
if arguments.count > 1 {
    CLI.run(args: arguments)
} else {
    MacDisplayFixerApp.main()
}

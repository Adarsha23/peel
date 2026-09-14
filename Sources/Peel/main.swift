import AppKit
import PeelKit

/// One binary, three personalities:
///   peel <command>   → CLI, operates on the note files directly
///   peel / peel open → hands off to LaunchServices so the terminal isn't blocked
///   launched by macOS (or `peel gui`) → the actual app

private func ownAppBundleURL() -> URL? {
    // Bundle.main.executableURL survives being invoked as a bare "peel" from
    // PATH, where argv[0] has no directory to resolve against.
    let exec = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
    var url = exec.resolvingSymlinksInPath()
    while url.path != "/" {
        if url.pathExtension == "app" { return url }
        url.deleteLastPathComponent()
    }
    return nil
}

let arguments = Array(CommandLine.arguments.dropFirst())

if let command = arguments.first, !["open", "gui"].contains(command) {
    exit(CLI.run(arguments))
}

let fromTerminal = isatty(fileno(stdin)) == 1
if fromTerminal, arguments.first != "gui", let appURL = ownAppBundleURL() {
    // Running instance gets a reopen event (shows the latest sticky); otherwise launches.
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = [appURL.path]
    try? process.run()
    process.waitUntilExit()
    exit(process.terminationStatus)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // menu-bar only, no Dock icon
if let mode = ProcessInfo.processInfo.environment["PEEL_APPEARANCE"] {
    app.appearance = NSAppearance(named: mode == "light" ? .aqua : .darkAqua)
}
app.run()

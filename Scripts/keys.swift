// Presses keys as a person would, for Scripts/preflight.sh.
// usage: keys hold <keycode> <opt,ctrl,cmd,shift|none> <seconds>   |   keys tap <keycode> <modifiers>
// The program that runs this needs Accessibility permission.
import CoreGraphics
import Foundation

let args = CommandLine.arguments
guard args.count >= 4, let code = UInt16(args[2]) else { print("usage: keys hold|tap <keycode> <modifiers> [seconds]"); exit(2) }
var flags: CGEventFlags = []
for name in args[3].split(separator: ",") {
    switch name {
    case "opt": flags.insert(.maskAlternate)
    case "ctrl": flags.insert(.maskControl)
    case "cmd": flags.insert(.maskCommand)
    case "shift": flags.insert(.maskShift)
    case "none": break
    // A mistyped name would press the bare key into whatever app is in front.
    default: print("unknown modifier \(name): use opt, ctrl, cmd, shift or none"); exit(2)
    }
}
let source = CGEventSource(stateID: .hidSystemState)
/// Sends the key going down or coming up, with the modifiers set on the event itself.
func post(_ down: Bool) {
    let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
    event?.flags = flags
    event?.post(tap: .cghidEventTap)
}
post(true)
Thread.sleep(forTimeInterval: args[1] == "hold" ? Double(args.count > 4 ? args[4] : "1") ?? 1 : 0.05)
post(false)

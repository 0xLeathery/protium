// Shows or changes the main display's mode, to try Protium on a HiDPI mode of a display that is
// normally run at one pixel to a point:
//
//   display_mode                     prints "<points w> <points h> <pixels w> <pixels h> <Hz>"
//   display_mode hidpi               changes to the mode with the panel's own pixels and half as
//                                    many points each way, at the highest refresh rate it has
//   display_mode <w> <h> <pw> <ph> <Hz>   changes to that mode (what the first form printed)
//
// The change stays after this tool has ended, for the login session: put the old mode back with
// the third form. It rearranges every window on the display, so run it only while nobody is
// using the Mac.
import CoreGraphics
import Foundation

let display = CGMainDisplayID()
func describe(_ m: CGDisplayMode) -> String { "\(m.width) \(m.height) \(m.pixelWidth) \(m.pixelHeight) \(Int(m.refreshRate.rounded()))" }
guard let current = CGDisplayCopyDisplayMode(display) else { print("no display mode"); exit(1) }
let args = CommandLine.arguments
if args.count == 1 { print(describe(current)); exit(0) }
let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
let modes = (CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode] ?? []).filter { $0.isUsableForDesktopGUI() }
var wanted: CGDisplayMode?
if args[1] == "hidpi" {
    let panelW = modes.map { $0.pixelWidth }.filter { w in modes.contains { $0.width == w && $0.pixelWidth == w } }.max() ?? current.pixelWidth
    wanted = modes.filter { $0.pixelWidth == panelW && $0.width * 2 == panelW && $0.pixelHeight == $0.height * 2 }
                  .max { $0.refreshRate < $1.refreshRate }
} else if args.count == 6 {
    wanted = modes.first { describe($0) == args[1...5].joined(separator: " ") }
}
guard let mode = wanted else { print("no such mode"); exit(1) }
var config: CGDisplayConfigRef?
guard CGBeginDisplayConfiguration(&config) == .success,
      CGConfigureDisplayWithDisplayMode(config, display, mode, nil) == .success,
      CGCompleteDisplayConfiguration(config, .forSession) == .success else { print("the mode was not set"); exit(1) }
print(describe(mode))

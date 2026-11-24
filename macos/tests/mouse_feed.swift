// Moves the mouse for macos/tests/mouse_look_test.c, as a hand would, but by a known amount:
//
//   swift mouse_feed.swift look <counts per event> <seconds each way> [events per second, default 1000]
//       to the right at that speed, a pause of half a second, then back to the left
//   swift mouse_feed.swift clicks <x,y> [<x,y> ...]
//       in points from the top left of the main display: goes to each place and clicks there
//   swift mouse_feed.swift nudgeclick <events> <counts per event> [<events> <counts> ...]
//       moves right by that much (left when negative), then clicks without moving, for each pair
//
// It posts mouse events to the system (the terminal needs the Accessibility permission), each
// with the pointer's movement and the mouse's own, unaccelerated movement set alike. Prints what
// it sent, as "sent <counts right> <counts left> in <events> events".

import ApplicationServices
import Foundation

func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }
let unacceleratedX = CGEventField(rawValue: 170)!, unacceleratedY = CGEventField(rawValue: 171)!
let bounds = CGDisplayBounds(CGMainDisplayID())

func move(by dx: Int) {
    var at = CGEvent(source: nil)!.location
    at.x = min(max(at.x + CGFloat(dx), bounds.minX), bounds.maxX - 1)
    let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: at, mouseButton: .left)!
    event.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx))
    event.setIntegerValueField(.mouseEventDeltaY, value: 0)
    event.setDoubleValueField(unacceleratedX, value: Double(dx))
    event.setDoubleValueField(unacceleratedY, value: 0)
    event.post(tap: .cghidEventTap)
}

let args = CommandLine.arguments
guard args.count >= 3, CGPreflightPostEventAccess() else {
    FileHandle.standardError.write("usage: mouse_feed.swift look <counts> <seconds> [rate] | clicks <x,y>...; needs the Accessibility permission\n".data(using: .utf8)!)
    exit(64)
}
if args[1] == "look" {
    let counts = Int(args[2])!, seconds = Double(args.count > 3 ? args[3] : "2")!, rate = Double(args.count > 4 ? args[4] : "1000")!
    var sent = [0, 0], events = 0
    for (leg, sign) in [1, -1].enumerated() {
        let start = now()
        var n = 0
        while true {
            let due = start + Double(n) / rate
            if due - start >= seconds { break }
            while now() < due {}
            move(by: sign * counts)
            sent[leg] += counts
            events += 1
            n += 1
        }
        if leg == 0 { usleep(500_000) }
    }
    print("sent \(sent[0]) \(sent[1]) in \(events) events")
} else if args[1] == "nudgeclick" {
    var i = 2
    while i + 1 < args.count {
        let events = Int(args[i])!, counts = Int(args[i + 1])!
        for _ in 0..<events { move(by: counts); usleep(1000) }
        usleep(300_000)
        let at = CGEvent(source: nil)!.location
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: at, mouseButton: .left)!.post(tap: .cghidEventTap)
        usleep(50_000)
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: at, mouseButton: .left)!.post(tap: .cghidEventTap)
        usleep(300_000)
        print("nudged \(events * counts) clicked")
        i += 2
    }
} else if args[1] == "clicks" {
    for arg in args[2...] {
        let parts = arg.split(separator: ",").compactMap { Double($0) }
        let at = CGPoint(x: parts[0], y: parts[1])
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: at, mouseButton: .left)!.post(tap: .cghidEventTap)
        usleep(200_000)
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: at, mouseButton: .left)!.post(tap: .cghidEventTap)
        usleep(50_000)
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: at, mouseButton: .left)!.post(tap: .cghidEventTap)
        usleep(300_000)
        print("clicked \(Int(at.x)) \(Int(at.y))")
    }
}

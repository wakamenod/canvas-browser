// canvas-browser-display -- a display nobody sees, for chromium on macOS.
//
// Usage: canvas-browser-display [WIDTH HEIGHT]
//
// Makes a virtual display of WIDTH by HEIGHT points, 1920 by 1200 by
// default, and puts it past the bottom right corner of the main display,
// where the two touch at a corner alone.  It prints the display's place
// and size as one line, "LEFT TOP WIDTH HEIGHT", in the coordinates
// chromium takes for a window: the top left of the main display is 0,0.
//
// The display lasts as long as this program.  The program ends when its
// standard input closes, so that it does not outlive Emacs, and the
// display goes with it, even after a kill -9.

import CoreGraphics
import Foundation

func fail(_ message: String) -> Never {
  FileHandle.standardError.write("canvas-browser-display: \(message)\n".data(using: .utf8)!)
  exit(1)
}

let arguments = CommandLine.arguments.dropFirst().map { UInt32($0) }
if arguments.contains(nil) || ![0, 2].contains(arguments.count) {
  fail("usage: canvas-browser-display [WIDTH HEIGHT]")
}
let width = arguments.first.flatMap { $0 } ?? 1920
let height = arguments.last.flatMap { $0 } ?? 1200

let descriptor = CGVirtualDisplayDescriptor()
descriptor.queue = DispatchQueue.main
descriptor.name = "canvas-browser"
descriptor.maxPixelsWide = width
descriptor.maxPixelsHigh = height
// About a hundred dots to the inch, as an ordinary display has.
descriptor.sizeInMillimeters = CGSize(width: Double(width) * 0.254,
                                      height: Double(height) * 0.254)
descriptor.vendorID = 0x3456
descriptor.productID = 0x1234
descriptor.serialNum = 1
descriptor.terminationHandler = { _, _ in exit(0) }

guard let display = CGVirtualDisplay(descriptor: descriptor) else {
  fail("macOS made no virtual display")
}
let settings = CGVirtualDisplaySettings()
settings.hiDPI = 0
guard let mode = CGVirtualDisplayMode(width: width, height: height, refreshRate: 60) else {
  fail("no mode of \(width) by \(height)")
}
settings.modes = [mode]
guard display.apply(settings) else { fail("the virtual display took no mode") }
let id = display.displayID

// The other displays, which the new one must not overlap.
var count: UInt32 = 0
CGGetActiveDisplayList(0, nil, &count)
var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
CGGetActiveDisplayList(count, &ids, &count)
let others = ids.filter { $0 != id }.map { CGDisplayBounds($0) }

// Touching the main display at its corner alone, the display is no
// neighbour the pointer walks into.  A display already there pushes it
// past the corner of them all.
let size = CGSize(width: Double(width), height: Double(height))
let main = CGDisplayBounds(CGMainDisplayID())
var origin = CGPoint(x: main.maxX, y: main.maxY)
if others.contains(where: { $0.intersects(CGRect(origin: origin, size: size)) }) {
  let all = others.reduce(CGRect.null) { $0.union($1) }
  origin = CGPoint(x: all.maxX, y: all.maxY)
}
var config: CGDisplayConfigRef?
CGBeginDisplayConfiguration(&config)
CGConfigureDisplayOrigin(config, id, Int32(origin.x), Int32(origin.y))
if CGCompleteDisplayConfiguration(config, .forSession) != .success {
  fail("the virtual display could not be moved past the corner")
}

signal(SIGTERM) { _ in exit(0) }
signal(SIGHUP) { _ in exit(0) }
signal(SIGINT) { _ in exit(0) }

// macOS moves the display a moment after it is asked to; the place
// printed is where it ended up.
func report(tries: Int) {
  let bounds = CGDisplayBounds(id)
  if bounds.origin != origin && tries > 0 {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { report(tries: tries - 1) }
    return
  }
  print(Int(bounds.minX), Int(bounds.minY), Int(bounds.width), Int(bounds.height))
  fflush(stdout)
  DispatchQueue.global().async {
    while readLine() != nil {}
    exit(0)
  }
}
report(tries: 40)
dispatchMain()

// fpsprobe: animating window that logs frames/s. Never activates itself.
// usage: fpsprobe --x X --y Y [--seconds 10]   (global top-left coordinates, like CGDisplayBounds)
import AppKit
import QuartzCore

var opts: [String: Double] = [:]
var it = CommandLine.arguments.dropFirst().makeIterator()
while let k = it.next(), let v = it.next() { opts[String(k.dropFirst(2))] = Double(v) }

final class Probe: NSView {
    var frames = 0, draws = 0, t0 = CACurrentMediaTime(), angle = 0.0
    let box = CALayer()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        box.frame = CGRect(x: 150, y: 100, width: 100, height: 100)
        box.backgroundColor = NSColor.systemOrange.cgColor
        layer?.addSublayer(box)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc func tick(_ link: CADisplayLink) {
        frames += 1
        angle += 0.05
        CATransaction.begin(); CATransaction.setDisableActions(true)
        box.setAffineTransform(CGAffineTransform(rotationAngle: angle))
        CATransaction.commit()
        let now = CACurrentMediaTime()
        if now - t0 >= 1 {
            let occl = window?.occlusionState.contains(.visible) == true ? "visible" : "occluded"
            print(String(format: "fps=%.1f occlusion=%@ screen=%@", Double(frames) / (now - t0), occl,
                         window?.screen?.localizedName ?? "?"))
            fflush(stdout)
            frames = 0; t0 = now
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let x = opts["x"] ?? 0, y = opts["y"] ?? 0
// Convert global top-left (CG) to AppKit bottom-left coordinates.
let mainH = NSScreen.screens.first?.frame.height ?? 0
let rect = NSRect(x: x + 40, y: mainH - (y + 40) - 300, width: 400, height: 300)
let win = NSWindow(contentRect: rect, styleMask: [.titled], backing: .buffered, defer: false)
win.title = "fpsprobe"
let view = Probe(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
win.contentView = view
win.setFrame(rect, display: false)
win.orderFrontRegardless()
let link = view.displayLink(target: view, selector: #selector(Probe.tick(_:)))
link.add(to: .main, forMode: .common)
DispatchQueue.main.asyncAfter(deadline: .now() + (opts["seconds"] ?? 10)) { exit(0) }
app.run()

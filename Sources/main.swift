// vscreen: an invisible virtual display for agent tests and screenshots.
// Uses the private CGVirtualDisplay API (see CGVirtualDisplay.h).
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ImageIO

// MARK: - helpers

func fail(_ msg: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(("vscreen: " + msg + "\n").data(using: .utf8)!)
    exit(code)
}

func printJSON(_ obj: Any) {
    let data = try! JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write("\n".data(using: .utf8)!)
}

struct Args {
    var cmd = ""
    var opts: [String: String] = [:]
    var flags: Set<String> = []
    var rest: [String] = []
    init(_ argv: [String]) {
        var i = 1
        if argv.count > 1 { cmd = argv[1]; i = 2 }
        while i < argv.count {
            let a = argv[i]
            if a == "--" { rest = Array(argv[(i + 1)...]); break }
            guard a.hasPrefix("--") else { fail("unexpected argument \(a)") }
            let key = String(a.dropFirst(2))
            if i + 1 < argv.count, !argv[i + 1].hasPrefix("--") {
                opts[key] = argv[i + 1]; i += 2
            } else {
                flags.insert(key); i += 1
            }
        }
    }
    func int(_ k: String, _ d: Int) -> Int {
        guard let s = opts[k] else { return d }
        guard let v = Int(s) else { fail("--\(k) needs a number") }
        return v
    }
}

func activeDisplays() -> [CGDirectDisplayID] {
    var n: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &n)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(n))
    CGGetActiveDisplayList(n, &ids, &n)
    return Array(ids.prefix(Int(n)))
}

func rectJSON(_ r: CGRect) -> [String: Any] {
    ["x": r.origin.x, "y": r.origin.y, "width": r.size.width, "height": r.size.height]
}

func displayJSON(_ id: CGDirectDisplayID) -> [String: Any] {
    var d: [String: Any] = ["id": id, "frame": rectJSON(CGDisplayBounds(id)),
                            "main": CGDisplayIsMain(id) != 0,
                            "mirrorOf": CGDisplayMirrorsDisplay(id)]
    if let m = CGDisplayCopyDisplayMode(id) {
        d["pixelWidth"] = m.pixelWidth; d["pixelHeight"] = m.pixelHeight
        d["scale"] = Double(m.pixelWidth) / Double(max(m.width, 1))
        d["refreshRate"] = m.refreshRate
    }
    return d
}

let stateDir = FileManager.default.temporaryDirectory.appendingPathComponent("vscreen", isDirectory: true)

func stateURL(_ name: String) -> URL { stateDir.appendingPathComponent(name + ".json") }

func readState(_ name: String) -> [String: Any]? {
    guard let data = try? Data(contentsOf: stateURL(name)),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    return obj
}

func allStateNames() -> [String] {
    let files = (try? FileManager.default.contentsOfDirectory(atPath: stateDir.path)) ?? []
    return files.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }
}

func processAlive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

func processName(_ pid: pid_t) -> String {
    var buf = [CChar](repeating: 0, count: 4096)
    let n = proc_pidpath(pid, &buf, UInt32(buf.count))
    return n > 0 ? String(cString: buf) : ""
}

/// Display id from --display, else from the state file of --name (default agent-screen).
func targetDisplay(_ a: Args) -> CGDirectDisplayID {
    if let s = a.opts["display"] {
        guard let v = UInt32(s) else { fail("--display needs a display id") }
        return v
    }
    let name = a.opts["name"] ?? "agent-screen"
    guard let st = readState(name), let id = st["displayID"] as? UInt32 else {
        fail("no virtual display '\(name)' is running; run `vscreen create` first or pass --display")
    }
    guard activeDisplays().contains(id) else { fail("display \(id) from state file is not active") }
    return id
}

// MARK: - permissions

func requireAccessibility() {
    if !AXIsProcessTrusted() {
        fail("""
        Accessibility permission is missing.
          The process that runs vscreen (your terminal or agent host app) must be allowed in
          System Settings > Privacy & Security > Accessibility. Add it, then run the command again.
        """, code: 3)
    }
}

func requireScreenRecording() {
    if !CGPreflightScreenCaptureAccess() {
        fail("""
        Screen Recording permission is missing.
          The process that runs vscreen (your terminal or agent host app) must be allowed in
          System Settings > Privacy & Security > Screen & System Audio Recording. Add it, then restart that app.
        """, code: 4)
    }
}

// MARK: - create

var liveDisplay: CGVirtualDisplay?

func create(_ a: Args) -> Never {
    let w = a.int("width", 1920), h = a.int("height", 1200), hz = a.int("hz", 60)
    let hidpi = a.flags.contains("hidpi")
    let name = a.opts["name"] ?? "agent-screen"
    let scale = hidpi ? 2 : 1

    if let st = readState(name), let pid = st["pid"] as? Int32, processAlive(pid),
       processName(pid).hasSuffix("vscreen") {
        fail("virtual display '\(name)' already runs (pid \(pid)); `vscreen destroy --name \(name)` first")
    }

    let mainBefore = CGMainDisplayID()

    let desc = CGVirtualDisplayDescriptor()
    desc.queue = DispatchQueue.main
    desc.name = name
    desc.maxPixelsWide = UInt32(w * scale)
    desc.maxPixelsHigh = UInt32(h * scale)
    let ppi = 110.0 * Double(scale)
    desc.sizeInMillimeters = CGSize(width: Double(w * scale) / ppi * 25.4, height: Double(h * scale) / ppi * 25.4)
    desc.vendorID = 0x7673 // "vs"
    desc.productID = 0x0001
    // Fixed serial per name so macOS reuses one arrangement entry instead of adding a new one per run.
    desc.serialNum = UInt32(truncatingIfNeeded: name.utf8.reduce(5381) { ($0 << 5) &+ $0 &+ Int($1) })
    desc.terminationHandler = { _, _ in
        FileHandle.standardError.write("vscreen: WindowServer terminated the virtual display\n".data(using: .utf8)!)
        try? FileManager.default.removeItem(at: stateURL(name))
        exit(2)
    }

    guard let display = CGVirtualDisplay(descriptor: desc), display.displayID != 0 else { fail("CGVirtualDisplay init returned display id 0 (API refused)") }
    let settings = CGVirtualDisplaySettings()
    settings.hiDPI = hidpi ? 1 : 0
    settings.modes = [CGVirtualDisplayMode(width: UInt32(w), height: UInt32(h), refreshRate: Double(hz))]
    guard display.apply(settings) else { fail("applySettings failed for \(w)x\(h)@\(hz) hidpi=\(hidpi)") }
    liveDisplay = display
    let id = display.displayID

    // Wait until WindowServer lists it.
    var ok = false
    for _ in 0..<50 {
        if activeDisplays().contains(id) { ok = true; break }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    guard ok else { fail("display \(id) never became active") }

    // Arrange: not mirrored, diagonal to the bottom-right corner of all real displays.
    let others = activeDisplays().filter { $0 != id }
    let union = others.map { CGDisplayBounds($0) }.reduce(CGRect.null) { $0.union($1) }
    var cfg: CGDisplayConfigRef?
    CGBeginDisplayConfiguration(&cfg)
    CGConfigureDisplayMirrorOfDisplay(cfg, id, kCGNullDirectDisplay)
    CGConfigureDisplayOrigin(cfg, id, Int32(union.maxX), Int32(union.maxY))
    let err = CGCompleteDisplayConfiguration(cfg, .forSession)
    if err != .success { FileHandle.standardError.write("vscreen: arrangement error \(err.rawValue)\n".data(using: .utf8)!) }
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))

    if CGMainDisplayID() != mainBefore {
        liveDisplay = nil
        fail("main display changed after create (\(mainBefore) -> \(CGMainDisplayID())); virtual display removed")
    }

    var info = displayJSON(id)
    info["displayID"] = id
    info["name"] = name
    info["pid"] = getpid()
    info["mainDisplayID"] = mainBefore
    info["mainDisplayUnchanged"] = true
    info["stateFile"] = stateURL(name).path
    try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    if let data = try? JSONSerialization.data(withJSONObject: info, options: [.sortedKeys]) {
        try? data.write(to: stateURL(name))
    }
    printJSON(info)

    let cleanup: () -> Never = {
        liveDisplay = nil
        try? FileManager.default.removeItem(at: stateURL(name))
        exit(0)
    }
    var sources: [DispatchSourceSignal] = []
    for sig in [SIGTERM, SIGINT, SIGHUP] {
        signal(sig, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        src.setEventHandler { cleanup() }
        src.resume()
        sources.append(src)
    }
    withExtendedLifetime(sources) { dispatchMain() }
}

// MARK: - windows

func windowsOf(_ pid: pid_t) -> [[String: Any]] {
    let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    return list.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
}

func bounds(_ w: [String: Any]) -> CGRect {
    guard let b = w[kCGWindowBounds as String] as? NSDictionary,
          let r = CGRect(dictionaryRepresentation: b) else { return .zero }
    return r
}

func axWindows(_ pid: pid_t) -> [AXUIElement] {
    let app = AXUIElementCreateApplication(pid)
    var v: CFTypeRef?
    let e = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &v)
    if e == .apiDisabled || e == .notImplemented && !AXIsProcessTrusted() { requireAccessibility() }
    return (v as? [AXUIElement]) ?? []
}

func axFrame(_ w: AXUIElement) -> CGRect {
    var pv: CFTypeRef?, sv: CFTypeRef?
    var p = CGPoint.zero, s = CGSize.zero
    if AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &pv) == .success {
        AXValueGetValue(pv as! AXValue, .cgPoint, &p)
    }
    if AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &sv) == .success {
        AXValueGetValue(sv as! AXValue, .cgSize, &s)
    }
    return CGRect(origin: p, size: s)
}

func move(_ a: Args) -> Never {
    guard let pidS = a.opts["pid"], let pid = Int32(pidS) else { fail("move needs --pid <pid>") }
    requireAccessibility()
    let id = targetDisplay(a)
    let frame = CGDisplayBounds(id)
    let timeout = Double(a.int("timeout", 10))
    let fill = a.flags.contains("fill")

    var wins: [AXUIElement] = []
    let deadline = Date().addingTimeInterval(timeout)
    while true {
        wins = axWindows(pid)
        if !wins.isEmpty || Date() > deadline { break }
        Thread.sleep(forTimeInterval: 0.2)
    }
    guard !wins.isEmpty else { fail("pid \(pid) has no Accessibility windows after \(Int(timeout))s") }

    var moved: [[String: Any]] = []
    for (i, w) in wins.enumerated() {
        var f = axFrame(w)
        var size = f.size
        if fill || size.width > frame.width || size.height > frame.height {
            size = CGSize(width: min(fill ? frame.width : size.width, frame.width),
                          height: min(fill ? frame.height : size.height, frame.height))
        }
        let inset = CGFloat(fill ? 0 : 40 + i * 30)
        var origin = CGPoint(x: frame.minX + inset, y: frame.minY + inset)
        // Position first so the size change is not clamped by the old screen.
        let pv = AXValueCreate(.cgPoint, &origin)!
        AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, pv)
        if size != f.size {
            let sv = AXValueCreate(.cgSize, &size)!
            AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, sv)
            AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, pv)
        }
        f = axFrame(w)
        moved.append(["frame": rectJSON(f), "onDisplay": frame.intersects(f) && frame.contains(CGPoint(x: f.midX, y: f.midY))])
    }
    printJSON(["pid": pid, "display": id, "displayFrame": rectJSON(frame), "windows": moved])
    exit(moved.allSatisfy { $0["onDisplay"] as? Bool == true } ? 0 : 5)
}

// MARK: - launch

/// The injected dylib: $VSCREEN_PLACE_DYLIB, else next to the vscreen executable.
let placeDylib: String = {
    if let p = ProcessInfo.processInfo.environment["VSCREEN_PLACE_DYLIB"], !p.isEmpty { return p }
    let exe = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
    return exe.deletingLastPathComponent().appendingPathComponent("libvscreen_place.dylib").path
}()

/// Hardened-runtime and platform (Apple) binaries ignore DYLD_INSERT_LIBRARIES.
func injectionBlocked(_ exe: String) -> String? {
    if exe.hasPrefix("/System/") || exe.hasPrefix("/usr/") { return "Apple platform binary" }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    p.arguments = ["-dv", exe]
    let pipe = Pipe(); p.standardError = pipe; p.standardOutput = Pipe()
    try? p.run(); p.waitUntilExit()
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    if let line = out.split(separator: "\n").first(where: { $0.contains("flags=") }), line.contains("runtime") {
        return "hardened runtime"
    }
    return nil
}

func launch(_ a: Args) -> Never {
    guard var exe = a.rest.first else { fail("launch needs: -- /path/to/binary-or.app [args...]") }
    let id = targetDisplay(a)
    if exe.hasSuffix(".app") || exe.hasSuffix(".app/") {
        guard let b = Bundle(path: exe), let e = b.executablePath else { fail("cannot read bundle \(exe)") }
        exe = e
    }
    guard FileManager.default.isExecutableFile(atPath: exe) else { fail("not executable: \(exe)") }
    guard FileManager.default.fileExists(atPath: placeDylib) else { fail("missing \(placeDylib); run build.sh") }
    let blocked = injectionBlocked(exe)

    var env = ProcessInfo.processInfo.environment
    env["DYLD_INSERT_LIBRARIES"] = placeDylib
    env["VSCREEN_DISPLAY"] = String(id)
    for kv in (a.opts["env"] ?? "").split(separator: ",") where kv.contains("=") {
        let parts = kv.split(separator: "=", maxSplits: 1)
        env[String(parts[0])] = String(parts[1])
    }
    let log = a.opts["log"] ?? "/dev/null"

    var fa: posix_spawn_file_actions_t? = nil
    posix_spawn_file_actions_init(&fa)
    posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_addopen(&fa, 1, log, O_WRONLY | O_CREAT | O_APPEND, 0o644)
    posix_spawn_file_actions_adddup2(&fa, 1, 2)
    if let cwd = a.opts["cwd"] { posix_spawn_file_actions_addchdir(&fa, cwd) }
    var attr: posix_spawnattr_t? = nil
    posix_spawnattr_init(&attr)
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
    let argv = a.rest.enumerated().map { strdup($0.offset == 0 ? exe : $0.element) } + [nil]
    let envp = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
    var pid: pid_t = 0
    let rc = posix_spawn(&pid, exe, &fa, &attr, argv, envp)
    guard rc == 0 else { fail("posix_spawn failed: \(String(cString: strerror(rc)))") }

    // Wait for the first window and report where it landed.
    let frame = CGDisplayBounds(id)
    let deadline = Date().addingTimeInterval(Double(a.int("timeout", 10)))
    var wins: [[String: Any]] = []
    while Date() < deadline {
        wins = windowsOf(pid).filter { bounds($0).width > 1 && ($0[kCGWindowIsOnscreen as String] as? Bool) == true }
        if !wins.isEmpty { Thread.sleep(forTimeInterval: 0.5); wins = windowsOf(pid).filter { bounds($0).width > 1 }; break }
        Thread.sleep(forTimeInterval: 0.1)
    }
    let report = wins.map { ["id": $0[kCGWindowNumber as String] ?? 0, "frame": rectJSON(bounds($0)),
                             "onDisplay": frame.intersects(bounds($0))] }
    var out: [String: Any] = ["pid": pid, "display": id, "windows": report, "log": log]
    if let b = blocked { out["warning"] = "\(b): injection ignored; use `vscreen move` (needs Accessibility)" }
    printJSON(out)
    let ok = !report.isEmpty && report.allSatisfy { $0["onDisplay"] as? Bool == true }
    exit(ok ? 0 : 5)
}

// MARK: - shot

func shot(_ a: Args) -> Never {
    guard let pidS = a.opts["pid"], let pid = Int32(pidS) else { fail("shot needs --pid <pid>") }
    guard let out = a.opts["out"] else { fail("shot needs --out file.png") }
    requireScreenRecording()

    var wins = windowsOf(pid).filter { bounds($0).width > 1 && bounds($0).height > 1 }
    if let idS = a.opts["window"], let wid = Int(idS) {
        wins = wins.filter { ($0[kCGWindowNumber as String] as? Int) == wid }
    } else if let st = a.opts["display"] ?? (readState(a.opts["name"] ?? "agent-screen")?["displayID"]).map({ "\($0)" }),
              let did = UInt32(st) {
        let df = CGDisplayBounds(did)
        let onIt = wins.filter { df.intersects(bounds($0)) }
        if !onIt.isEmpty { wins = onIt }
    }
    guard let win = wins.max(by: { bounds($0).width * bounds($0).height < bounds($1).width * bounds($1).height }),
          let wid = win[kCGWindowNumber as String] as? Int else { fail("no window found for pid \(pid)") }

    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = ["-l", String(wid), "-o", "-x", out]
    try! p.run(); p.waitUntilExit()
    guard p.terminationStatus == 0 else { fail("screencapture exited \(p.terminationStatus)") }

    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: out) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fail("shot file is not an image: \(out)") }
    // Check the image has content (not one flat colour).
    let sw = 64, sh = 64
    var px = [UInt8](repeating: 0, count: sw * sh * 4)
    let ctx = CGContext(data: &px, width: sw, height: sh, bitsPerComponent: 8, bytesPerRow: sw * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: sw, height: sh))
    var colours = Set<UInt32>()
    for i in stride(from: 0, to: px.count, by: 4) {
        colours.insert(UInt32(px[i]) << 16 | UInt32(px[i + 1]) << 8 | UInt32(px[i + 2]))
    }
    let bytes = (try? FileManager.default.attributesOfItem(atPath: out)[.size] as? Int) ?? 0
    printJSON(["path": out, "windowID": wid, "windowFrame": rectJSON(bounds(win)),
               "pixelWidth": img.width, "pixelHeight": img.height, "bytes": bytes,
               "distinctColoursInThumb": colours.count, "nonEmpty": colours.count > 1])
    exit(colours.count > 1 ? 0 : 6)
}

// MARK: - ensure

/// State of a running virtual display named `name`, or nil when its create process or display is gone.
func liveState(_ name: String) -> [String: Any]? {
    guard let st = readState(name), let pid = st["pid"] as? Int32, let id = st["displayID"] as? UInt32,
          processAlive(pid), processName(pid).hasSuffix("vscreen"), activeDisplays().contains(id) else { return nil }
    return st
}

/// Reuses the long-lived display `name` (default "shared"), or starts it in its own session so it
/// outlives the caller. Every create/destroy is a display change for window managers (Spaceman
/// re-parks hidden windows and macOS can pull them back on screen), so agents share one display.
func ensure(_ a: Args) -> Never {
    let name = a.opts["name"] ?? "shared"
    try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    let lockFD = open(stateDir.appendingPathComponent(name + ".lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
    guard lockFD >= 0 else { fail("cannot open lock file in \(stateDir.path)") }
    flock(lockFD, LOCK_EX)
    defer { flock(lockFD, LOCK_UN); close(lockFD) }

    if var st = liveState(name) {
        st["reused"] = true
        printJSON(st); exit(0)
    }
    try? FileManager.default.removeItem(at: stateURL(name))

    var argv = [CommandLine.arguments[0], "create", "--name", name,
                "--width", String(a.int("width", 1920)), "--height", String(a.int("height", 1200)),
                "--hz", String(a.int("hz", 60))]
    if !a.flags.contains("lodpi") { argv.append("--hidpi") }
    let logPath = stateDir.appendingPathComponent(name + ".log").path

    var fa: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&fa)
    posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_addopen(&fa, 1, logPath, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
    posix_spawn_file_actions_adddup2(&fa, 1, 2)
    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    // New session, and no inherited fds besides 0-2: the display outlives the caller and holds
    // none of its pipes or locks open.
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
    var pid: pid_t = 0
    let cargs = argv.map { strdup($0) } + [nil]
    let rc = posix_spawn(&pid, argv[0], &fa, &attr, cargs, environ)
    cargs.forEach { free($0) }
    posix_spawn_file_actions_destroy(&fa); posix_spawnattr_destroy(&attr)
    guard rc == 0 else { fail("cannot start `vscreen create` (\(rc))") }

    for _ in 0..<100 {
        if var st = liveState(name) {
            st["reused"] = false
            printJSON(st); exit(0)
        }
        if !processAlive(pid) { break }
        Thread.sleep(forTimeInterval: 0.1)
    }
    let log = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
    fail("shared display '\(name)' did not start; log \(logPath):\n\(log)")
}

// MARK: - destroy

func destroy(_ a: Args) -> Never {
    let names = a.opts["name"].map { [$0] } ?? allStateNames()
    var results: [[String: Any]] = []
    for name in names {
        guard let st = readState(name), let pid = st["pid"] as? Int32, let id = st["displayID"] as? UInt32 else { continue }
        if processAlive(pid) && processName(pid).hasSuffix("vscreen") {
            kill(pid, SIGTERM)
            for _ in 0..<50 where processAlive(pid) { Thread.sleep(forTimeInterval: 0.1) }
            if processAlive(pid) { kill(pid, SIGKILL) }
        }
        var gone = false
        for _ in 0..<50 {
            if !activeDisplays().contains(id) { gone = true; break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        try? FileManager.default.removeItem(at: stateURL(name))
        results.append(["name": name, "pid": pid, "displayID": id, "removed": gone])
    }
    printJSON(["destroyed": results, "activeDisplays": activeDisplays()])
    exit(results.allSatisfy { $0["removed"] as? Bool == true } ? 0 : 7)
}

// MARK: - main

let usage = """
usage:
  vscreen ensure [--name shared] [--width 1920] [--height 1200] [--lodpi] [--hz 60]
      reuses the long-lived shared display or starts it detached (it outlives the caller); prints
      its JSON with "reused". Agents use this and pass --name shared; never destroy it
  vscreen create [--width 1920] [--height 1200] [--hidpi] [--hz 60] [--name agent-screen]
      creates the display, prints JSON, keeps running until destroy/SIGTERM (run it in the background)
  vscreen launch [--display <id> | --name <n>] [--log f] [--cwd d] [--env K=V,K2=V2] -- <binary|.app> [args]
      starts the app with its windows on the virtual display and activation disabled (no
      Accessibility needed; not for hardened/Apple apps); prints pid + window frames
  vscreen move --pid <pid> [--display <id> | --name <n>] [--fill] [--timeout 10]
      moves the app's windows onto the virtual display via Accessibility, without activating it
  vscreen shot --pid <pid> --out file.png [--window <id>] [--display <id> | --name <n>]
      captures the app's window (the one on the virtual display if any) with screencapture -l
  vscreen windows --pid <pid>      lists the app's on-screen windows (id, frame)
  vscreen list                     lists active displays and running virtual displays
  vscreen destroy [--name <n>]     stops the create process(es) and checks the display is gone
"""

let args = Args(CommandLine.arguments)
if args.flags.contains("help") || args.opts["help"] != nil || CommandLine.arguments.contains("-h") {
    print(usage); exit(0)
}
switch args.cmd {
case "create": create(args)
case "ensure": ensure(args)
case "move": move(args)
case "launch": launch(args)
case "shot": shot(args)
case "destroy": destroy(args)
case "windows":
    guard let s = args.opts["pid"], let pid = Int32(s) else { fail("windows needs --pid") }
    printJSON(windowsOf(pid).map { ["id": $0[kCGWindowNumber as String] ?? 0, "frame": rectJSON(bounds($0)),
                                    "onScreen": $0[kCGWindowIsOnscreen as String] ?? false] })
case "list":
    printJSON(["displays": activeDisplays().map(displayJSON), "main": CGMainDisplayID(),
               "virtual": allStateNames().compactMap(readState)])
default:
    print(usage)
    exit(args.cmd.isEmpty || args.cmd == "help" || args.flags.contains("help") ? 0 : 1)
}

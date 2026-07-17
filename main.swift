//
//  main.swift
//  VividHUD — a highly visible custom Volume & Brightness HUD for macOS
//
//  Single-file app. Written with AppKit (NSPanel) + SwiftUI (the HUD view).
//  - Volume: event-driven via CoreAudio property listeners (no special permission).
//  - Brightness: read via DisplayServices (private framework, loaded with dlopen)
//    and polled on a lightweight timer (no Accessibility permission required).
//
//  Compile & run instructions are at the bottom of this file.
//

import Cocoa
import SwiftUI
import CoreAudio
import ServiceManagement

// MARK: - Shared HUD state (drives the SwiftUI view)

final class HUDState: ObservableObject {
    enum Kind { case volume, brightness }

    @Published var kind: Kind = .volume
    @Published var value: Double = 0.5   // normalized 0...1
    @Published var muted: Bool = false
}

// MARK: - The SwiftUI HUD view

struct HUDView: View {
    @ObservedObject var state: HUDState

    private var percent: Int { max(0, min(100, Int((state.value * 100).rounded()))) }

    private var iconName: String {
        switch state.kind {
        case .brightness:
            return state.value < 0.01 ? "sun.min.fill" : "sun.max.fill"
        case .volume:
            if state.muted || state.value < 0.001 { return "speaker.slash.fill" }
            if state.value < 0.34 { return "speaker.wave.1.fill" }
            if state.value < 0.67 { return "speaker.wave.2.fill" }
            return "speaker.wave.3.fill"
        }
    }

    private var accent: LinearGradient {
        let colors: [Color]
        switch state.kind {
        case .brightness:
            colors = [Color(red: 1.0, green: 0.85, blue: 0.35),
                      Color(red: 1.0, green: 0.62, blue: 0.20)]
        case .volume:
            colors = state.muted
                ? [Color.gray.opacity(0.7), Color.gray.opacity(0.5)]
                : [Color(red: 0.35, green: 0.72, blue: 1.0),
                   Color(red: 0.45, green: 0.45, blue: 1.0)]
        }
        return LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
    }

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: iconName)
                .font(.system(size: 78, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white)
                .frame(height: 84)
                .contentTransition(.symbolEffect(.replace))
                .shadow(color: .black.opacity(0.35), radius: 8, y: 2)

            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.15))
                    Capsule()
                        .fill(accent)
                        .frame(width: max(8, geo.size.width * state.value))
                        .animation(.spring(response: 0.28, dampingFraction: 0.75),
                                   value: state.value)
                }
            }
            .frame(height: 14)
            .padding(.horizontal, 4)

            Text(state.muted && state.kind == .volume ? "Muted" : "\(percent)%")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: percent)
        }
        .padding(30)
        .frame(width: 260, height: 260)
        .background(
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 34, style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.45), radius: 28, y: 10)
        )
        // Transparent margin so the soft shadow has room to render instead of
        // being clipped to the window's square bounds.
        .padding(48)
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - The floating panel controller

final class HUDController {
    let state = HUDState()

    private var panel: NSPanel!
    private var dismissWork: DispatchWorkItem?
    private let visibleDuration: TimeInterval = 1.5
    private let fadeDuration: TimeInterval = 0.35

    init() {
        // 260pt card + 48pt transparent margin on every side (see HUDView) so the
        // drop shadow renders fully instead of being clipped square by the window.
        let hosting = NSHostingView(rootView: HUDView(state: state))
        hosting.frame = NSRect(x: 0, y: 0, width: 356, height: 356)

        panel = NSPanel(
            contentRect: hosting.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver                 // above menu bar & full-screen apps
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true            // clicks pass through
        panel.collectionBehavior = [
            .canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle
        ]
        panel.alphaValue = 0
    }

    /// Show / refresh the HUD. Call from the main thread.
    func show(kind: HUDState.Kind, value: Double, muted: Bool = false) {
        state.kind = kind
        state.value = max(0, min(1, value))
        state.muted = muted

        recenter()
        panel.orderFrontRegardless()

        // Cancel any in-flight fade and snap to fully visible.
        dismissWork?.cancel()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 1.0
        }

        // Schedule the fade-out.
        let work = DispatchWorkItem { [weak self] in self?.fadeOut() }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + visibleDuration, execute: work)
    }

    private func fadeOut() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = fadeDuration
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            if self?.panel.alphaValue == 0 { self?.panel.orderOut(nil) }
        })
    }

    private func recenter() {
        guard let screen = NSScreen.main else { return }
        let f = screen.frame
        let size = panel.frame.size
        let origin = NSPoint(
            x: f.midX - size.width / 2,
            y: f.midY - size.height / 2
        )
        panel.setFrameOrigin(origin)
    }
}

// MARK: - Volume monitoring (CoreAudio, event-driven)

final class VolumeMonitor {
    private let onChange: (Double, Bool) -> Void

    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var volumeBlock: AudioObjectPropertyListenerBlock?
    private var muteBlock: AudioObjectPropertyListenerBlock?
    private var defaultDeviceBlock: AudioObjectPropertyListenerBlock?

    private var volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyVolumeScalar,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)

    private var muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)

    init(onChange: @escaping (Double, Bool) -> Void) {
        self.onChange = onChange
        registerDefaultDeviceListener()
        attachToCurrentDefaultDevice()
    }

    // Follow changes to the system default output device (e.g. plugging in headphones).
    private func registerDefaultDeviceListener() {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.attachToCurrentDefaultDevice()
        }
        defaultDeviceBlock = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main, block)
    }

    private func currentDefaultDevice() -> AudioObjectID {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var dev = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev)
        return dev
    }

    private func attachToCurrentDefaultDevice() {
        // Detach from the previous device first.
        if deviceID != kAudioObjectUnknown {
            if let b = volumeBlock {
                AudioObjectRemovePropertyListenerBlock(deviceID, &volumeAddress, DispatchQueue.main, b)
            }
            if let b = muteBlock {
                AudioObjectRemovePropertyListenerBlock(deviceID, &muteAddress, DispatchQueue.main, b)
            }
        }

        deviceID = currentDefaultDevice()
        guard deviceID != kAudioObjectUnknown else { return }

        let vBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self = self else { return }
            self.onChange(self.readVolume(), self.readMute())
        }
        volumeBlock = vBlock
        AudioObjectAddPropertyListenerBlock(deviceID, &volumeAddress, DispatchQueue.main, vBlock)

        let mBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self = self else { return }
            self.onChange(self.readVolume(), self.readMute())
        }
        muteBlock = mBlock
        AudioObjectAddPropertyListenerBlock(deviceID, &muteAddress, DispatchQueue.main, mBlock)
    }

    private func readVolume() -> Double {
        guard deviceID != kAudioObjectUnknown else { return 0 }

        // Try the master/main scalar first.
        var addr = volumeAddress
        var vol = Float(0)
        var size = UInt32(MemoryLayout<Float>.size)
        if AudioObjectHasProperty(deviceID, &addr),
           AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &vol) == noErr {
            return Double(vol)
        }

        // Fall back to averaging the first two channels.
        var total: Float = 0
        var count: Float = 0
        for ch: UInt32 in 1...2 {
            var chAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: ch)
            var v = Float(0)
            var s = UInt32(MemoryLayout<Float>.size)
            if AudioObjectHasProperty(deviceID, &chAddr),
               AudioObjectGetPropertyData(deviceID, &chAddr, 0, nil, &s, &v) == noErr {
                total += v; count += 1
            }
        }
        return count > 0 ? Double(total / count) : 0
    }

    private func readMute() -> Bool {
        guard deviceID != kAudioObjectUnknown else { return false }
        var addr = muteAddress
        var muted = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectHasProperty(deviceID, &addr),
           AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &muted) == noErr {
            return muted != 0
        }
        return false
    }
}

// MARK: - Brightness monitoring (DisplayServices, polled)

final class BrightnessMonitor {
    private typealias GetBrightnessFn =
        @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32

    private let onChange: (Double) -> Void
    private var getBrightness: GetBrightnessFn?
    private var timer: Timer?
    private var lastValue: Float = -1
    private let displayID = CGMainDisplayID()

    init?(onChange: @escaping (Double) -> Void) {
        self.onChange = onChange

        let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
        guard let handle = dlopen(path, RTLD_NOW),
              let sym = dlsym(handle, "DisplayServicesGetBrightness") else {
            NSLog("VividHUD: DisplayServices unavailable — brightness HUD disabled.")
            return nil
        }
        getBrightness = unsafeBitCast(sym, to: GetBrightnessFn.self)

        // Seed the baseline so we don't flash on launch.
        lastValue = readBrightness() ?? -1

        // Poll ~15x/sec. This is cheap and captures the ramp while holding F1/F2.
        let t = Timer(timeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func readBrightness() -> Float? {
        guard let fn = getBrightness else { return nil }
        var value: Float = 0
        return fn(displayID, &value) == 0 ? value : nil
    }

    private func tick() {
        guard let v = readBrightness() else { return }
        if lastValue < 0 { lastValue = v; return }
        if abs(v - lastValue) > 0.0025 {
            lastValue = v
            onChange(Double(v))
        }
    }
}

// MARK: - App delegate — wires everything together

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let hud = HUDController()
    private var volumeMonitor: VolumeMonitor?
    private var brightnessMonitor: BrightnessMonitor?

    private var statusItem: NSStatusItem?
    private var loginItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon, but we keep a menu-bar item so it can be controlled.
        NSApp.setActivationPolicy(.accessory)

        registerLoginItemIfNeeded()
        setupStatusItem()

        volumeMonitor = VolumeMonitor { [weak self] value, muted in
            self?.hud.show(kind: .volume, value: value, muted: muted)
        }

        brightnessMonitor = BrightnessMonitor { [weak self] value in
            self?.hud.show(kind: .brightness, value: value)
        }
    }

    // MARK: Menu bar

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "slider.horizontal.3",
                                   accessibilityDescription: "VividHUD")
            button.image?.isTemplate = true
        }

        let menu = NSMenu()
        menu.addItem(withTitle: "VividHUD", action: nil, keyEquivalent: "")
        menu.addItem(.separator())

        let login = NSMenuItem(title: "Start at Login",
                               action: #selector(toggleLoginItem),
                               keyEquivalent: "")
        login.target = self
        menu.addItem(login)
        loginItem = login

        let test = NSMenuItem(title: "Test HUD",
                              action: #selector(testHUD),
                              keyEquivalent: "")
        test.target = self
        menu.addItem(test)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit VividHUD",
                              action: #selector(quit),
                              keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
        refreshLoginItemState()
    }

    @objc private func testHUD() {
        hud.show(kind: .brightness, value: 0.7)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: Login item (auto-start at boot/login)

    private func registerLoginItemIfNeeded() {
        guard #available(macOS 13, *) else { return }
        // Register on first run so the app auto-starts after a restart.
        // Registering is idempotent, so this is safe to call every launch.
        if SMAppService.mainApp.status != .enabled {
            do { try SMAppService.mainApp.register() }
            catch { NSLog("VividHUD: could not register login item: \(error)") }
        }
    }

    @objc private func toggleLoginItem() {
        guard #available(macOS 13, *) else { return }
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("VividHUD: could not toggle login item: \(error)")
        }
        refreshLoginItemState()
    }

    private func refreshLoginItemState() {
        guard let loginItem = loginItem else { return }
        if #available(macOS 13, *) {
            loginItem.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
            loginItem.isEnabled = true
        } else {
            loginItem.state = .off
            loginItem.isEnabled = false
        }
    }
}

// MARK: - Entry point

// Maintenance hook: `VividHUD --unregister` removes the login-item entry and exits.
// Useful for uninstall scripts and for cleaning up a login item that points at an
// old location without launching the full UI.
if CommandLine.arguments.contains("--unregister") {
    if #available(macOS 13, *) {
        do { try SMAppService.mainApp.unregister(); print("VividHUD: login item removed.") }
        catch { print("VividHUD: could not remove login item: \(error)") }
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

/*
 ────────────────────────────────────────────────────────────────────────────
 HOW TO COMPILE & RUN
 ────────────────────────────────────────────────────────────────────────────

 ▸ Option A — Terminal (fastest)

   1. Compile:

        swiftc main.swift -o VividHUD \
            -framework Cocoa -framework SwiftUI -framework CoreAudio

      (DisplayServices is loaded at runtime via dlopen, so it needs no -framework flag.)

   2. Run:

        ./VividHUD

      Leave the terminal open. Press the volume or brightness keys and the HUD
      appears in the center of the screen. Ctrl-C to quit.

   3. (Optional) Run it as a proper background agent that survives closing the
      terminal:

        nohup ./VividHUD >/dev/null 2>&1 &


 ▸ Option B — Xcode

   1. Create a new project → macOS → App (choose Swift, "AppKit App Delegate"
      or SwiftUI — either works since we manage the app manually).
   2. Delete the generated App/ContentView files and drop this main.swift in.
      If Xcode complains about a duplicate @main / top-level entry point,
      remove the generated @main struct so this file's top-level code is the
      single entry point.
   3. In the target's Info tab, add the key:
        Application is agent (UIElement)  →  YES        (this is LSUIElement)
   4. Build & Run (⌘R).


 ────────────────────────────────────────────────────────────────────────────
 PERMISSIONS
 ────────────────────────────────────────────────────────────────────────────

 • Volume:      No permission required. CoreAudio property listeners are open API.
 • Brightness:  No Accessibility permission required with this approach — we read
                the value from DisplayServices and poll for changes, rather than
                tapping keyboard events.

 Note: DisplayServices is a *private* framework. It is stable and widely used,
 but Apple does not guarantee it, and an App Store submission would be rejected
 for using it. For personal/side use it is fine.

 If you would rather detect the F1/F2 keypresses directly (e.g. to also react to
 external monitors DisplayServices can't read), swap BrightnessMonitor for a
 CGEventTap listening for NSEvent.EventType.systemDefined / brightness keycodes.
 That approach DOES require:

     System Settings → Privacy & Security → Accessibility → enable your app.

 ────────────────────────────────────────────────────────────────────────────
*/

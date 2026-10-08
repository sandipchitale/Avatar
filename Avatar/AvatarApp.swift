import AppKit
import SwiftUI

// Avatar: a face that speaks and listens for Claude Code. A menu bar app (no Dock icon); its face
// window shows while a Claude Code session uses it. Everything else is the Presence mod inside
// Claude Code (its band above the prompt and `/presence`), which drives the avatar over its sockets (see `AvatarServers`).

/// Asks the menu bar item (which can open windows) to show the face window.
@MainActor
@Observable
final class WindowRequests {
    private(set) var count = 0
    func request() { count += 1 }
}

@MainActor
enum Services {
    static var commands: CommandServer?
    static var attach: AttachServer?
}

@main
struct AvatarApp: App {
    @State private var engine: SpeechEngine
    @State private var conductor: Conductor
    @State private var windows = WindowRequests()

    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""

    init() {
        let engine = SpeechEngine()
        let conductor = Conductor(voice: engine, ears: SpeechInputController())
        let windows = WindowRequests()
        conductor.onShowWindow = { windows.request() }
        _engine = State(initialValue: engine)
        _conductor = State(initialValue: conductor)
        _windows = State(initialValue: windows)

        // Under `xcodebuild test` the host app must not take the real sockets.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        let routes = AvatarRoutes(conductor: conductor, version: Self.version)
        let commands = CommandServer { method, path, body in routes.handle(method: method, path: path, body: body) }
        let attach = AttachServer(
            attach: { session, send in conductor.attach(session, send: send) },
            detach: { session in conductor.detach(session) })
        do {
            try commands.start()
            try attach.start()
            Services.commands = commands
            Services.attach = attach
        } catch {
            NSLog("Avatar: sockets not started: \(error)")
        }
    }

    var body: some Scene {
        MenuBarExtra {
            AvatarMenu()
                .environment(engine)
                .environment(conductor)
        } label: {
            MenuBarLabel()
                .environment(engine)
                .environment(windows)
        }

        Window("Avatar", id: AvatarWindow.id) {
            AvatarWindow()
                .environment(engine)
                .environment(conductor)
        }
        .defaultSize(width: 360, height: 460)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .windowResizability(.contentMinSize)
        .windowBackgroundDragBehavior(.enabled)
    }
}

/// The menu bar icon; it also opens the face window when asked, without taking the keyboard.
struct MenuBarLabel: View {
    @Environment(SpeechEngine.self) private var engine
    @Environment(WindowRequests.self) private var windows
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: engine.state == .speaking ? "face.smiling.inverse" : "face.smiling")
            .onChange(of: windows.count) {
                openWindow(id: AvatarWindow.id)
                DispatchQueue.main.async {
                    NSApp.windows.first { $0.identifier?.rawValue.hasPrefix(AvatarWindow.id) == true }?
                        .orderFrontRegardless()
                }
            }
    }
}

struct AvatarMenu: View {
    @Environment(SpeechEngine.self) private var engine
    @Environment(Conductor.self) private var conductor
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text("Avatar \(AvatarApp.version)")
        Text(conductor.sessionCount == 0 ? "No Claude Code session"
             : conductor.sessionCount == 1 ? "1 Claude Code session" : "\(conductor.sessionCount) Claude Code sessions")
        Divider()
        Button("Show Avatar") {
            openWindow(id: AvatarWindow.id)
            NSApp.activate()
        }
        Picker("Face", selection: Binding(get: { conductor.gender }, set: { conductor.setGender($0) })) {
            Text("Man").tag(Gender.male)
            Text("Woman").tag(Gender.female)
        }
        .pickerStyle(.inline)
        voiceMenu("Man's Voice", for: .man)
        voiceMenu("Woman's Voice", for: .woman)
        Divider()
        Button("Quit Avatar") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    /// The face's own voice (Daniel or Samantha), or an installed English voice of its gender.
    private func voiceMenu(_ title: String, for portrait: Portrait) -> some View {
        let choice = Binding<String?>(
            get: { engine.chosenVoices[portrait.id] },
            set: { engine.choose(voice: $0, for: portrait.id) })
        return Menu(title) {
            Picker(title, selection: choice) {
                Text("\(portrait.voiceName) (the face's own voice)").tag(String?.none)
                Divider()
                ForEach(SpeechEngine.choosableVoices(for: portrait), id: \.identifier) { voice in
                    Text(voice.name).tag(String?.some(voice.identifier))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
    }
}

/// The face in its own window. Clicking the head shows or hides the speech bubble, where a caret
/// (once stopped) marks where Play starts; the buttons below play or pause, stop, turn the mic on or
/// off, switch the face, and pin the window on top.
struct AvatarWindow: View {
    static let id = "avatar"
    @Environment(SpeechEngine.self) private var engine
    @Environment(Conductor.self) private var conductor
    @AppStorage("alwaysOnTop") private var alwaysOnTop = true
    @State private var bubble = SpeechBubble()
    @State private var window: NSWindow?

    var body: some View {
        VStack(spacing: 0) {
            FaceView(mouth: engine.mouth, portrait: engine.portrait, brows: engine.brows,
                     expression: engine.expression, presence: engine.presence,
                     pose: engine.presencePose, nodStarted: engine.nodStarted, nodDepth: engine.nodDepth,
                     isAttentive: engine.isHearing)
                .padding([.horizontal, .top], 12)
                .overlay {
                    ClickCatcher(toolTip: "Click to show or hide the speech bubble") { bubble.toggle() }
                }
            toolbar
        }
        .frame(minWidth: 300, maxWidth: .infinity, minHeight: 360, maxHeight: .infinity)
        .navigationTitle(engine.gender == .female ? "Woman" : "Man")
        .navigationSubtitle(engine.voiceName(for: engine.portrait) ?? "")
        .background(WindowAccessor { window in
            self.window = window
            bubble.attach(to: window, content: SpeechBubbleView(bubble: bubble)
                .environment(engine).environment(conductor))
            applyAlwaysOnTop()
        })
        .onChange(of: alwaysOnTop) { applyAlwaysOnTop() }
    }

    private var toolbar: some View {
        let isListening = conductor.listener != nil
        return HStack(spacing: 10) {
            let isSaying = conductor.current != nil && !conductor.isPaused
            Button(isSaying ? "Pause" : "Play", systemImage: isSaying ? "pause.fill" : "play.fill") {
                conductor.playPause()
            }
            .keyboardShortcut(.space, modifiers: [])
            .help(isSaying ? "Pause (Space)" : conductor.current != nil ? "Resume (Space)" : "Play from the caret in the speech bubble (Space)")
            Button("Stop", systemImage: "stop.fill") { conductor.stopAll() }
                .disabled(conductor.current == nil && conductor.queued.isEmpty)
                .help("Stop speaking")
            Button(isListening ? "Mic Off" : "Mic On", systemImage: isListening ? "mic.slash" : "mic.fill") {
                conductor.toggleMic()
            }
            .disabled(conductor.sessionCount == 0)
            .help(isListening ? "Stop listening" : "Listen: what you say goes into Claude Code's prompt")
            Button(engine.gender == .female ? "Man" : "Woman",
                   systemImage: engine.gender == .female ? "figure.stand" : "figure.stand.dress") {
                conductor.setGender(engine.gender == .female ? .male : .female)
            }
            .help(engine.gender == .female ? "Switch to the man" : "Switch to the woman")
            Button(alwaysOnTop ? "Unpin" : "Pin", systemImage: alwaysOnTop ? "pin.slash" : "pin.fill") {
                alwaysOnTop.toggle()
            }
            .help(alwaysOnTop ? "Stop keeping on top of other windows" : "Keep on top of other windows")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.regular)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }

    private func applyAlwaysOnTop() {
        window?.level = alwaysOnTop ? .floating : .normal
        bubble.matchParentLevel()
    }
}

/// Catches clicks on the head (for the speech bubble), even when the window isn't active.
struct ClickCatcher: NSViewRepresentable {
    var toolTip: String
    var onClick: () -> Void

    func makeNSView(context: Context) -> ClickView {
        let view = ClickView()
        view.toolTip = toolTip
        view.onClick = onClick
        return view
    }

    func updateNSView(_ view: ClickView, context: Context) {
        view.onClick = onClick
    }

    final class ClickView: NSView {
        var onClick: (() -> Void)?
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseUp(with event: NSEvent) {
            if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
        }
    }
}

/// Reports the `NSWindow` hosting a SwiftUI view.
struct WindowAccessor: NSViewRepresentable {
    var onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> WindowReportingView {
        let view = WindowReportingView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ view: WindowReportingView, context: Context) {}

    final class WindowReportingView: NSView {
        var onWindow: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }
}

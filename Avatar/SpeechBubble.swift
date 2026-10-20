import AppKit
import SwiftUI

/// A borderless speech-bubble window attached to the face window. As a child window it
/// follows the face when that is dragged. It sits beside the head (whichever side has
/// room on screen) with its tail pointing at the mouth.
@Observable
final class SpeechBubble {
    static let size = CGSize(width: 360, height: 190)

    /// Hidden until the head is clicked.
    private(set) var isShown = false
    /// The side of the bubble the tail comes out of (toward the head).
    private(set) var tailEdge: HorizontalEdge = .leading

    @ObservationIgnored private var panel: BubblePanel?
    @ObservationIgnored private weak var parent: NSWindow?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    /// Creates the bubble window for `window`, showing `content`.
    func attach(to window: NSWindow, content: some View) {
        guard parent !== window else { return }
        detach()
        parent = window

        let panel = BubblePanel(contentRect: CGRect(origin: .zero, size: Self.size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentView = NSHostingView(rootView: content)
        self.panel = panel

        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reposition() }
            },
            // SwiftUI reuses the window when it is reopened, so stay attached and just hide.
            center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.isShown = false
                    self?.hide()
                }
            },
        ]
        if isShown { show() }
    }

    func toggle() {
        isShown.toggle()
        if isShown { show() } else { hide() }
    }

    /// Keeps the bubble at the face window's level, e.g. when that becomes always-on-top.
    func matchParentLevel() {
        guard let panel, let parent else { return }
        panel.level = parent.level
    }

    private func show() {
        guard let panel, let parent else { return }
        reposition()
        panel.level = parent.level
        parent.addChildWindow(panel, ordered: .above)
    }

    private func hide() {
        guard let panel else { return }
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    private func detach() {
        hide()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        panel = nil
        parent = nil
    }

    /// Places the bubble beside the head with the tail tip at mouth height, on the right
    /// unless that would run off the screen.
    private func reposition() {
        guard let panel, let parent else { return }
        let frame = parent.frame
        let screen = (parent.screen ?? NSScreen.main)?.visibleFrame ?? .infinite
        // The mouth is about halfway down the face window (AppKit y runs upward).
        let mouthY = frame.minY + frame.height * 0.5
        // A small gap between the face window and the tip of the bubble's tail.
        let gap: CGFloat = 12

        var origin = CGPoint(x: frame.maxX + gap, y: mouthY - BubbleShape.tailTipHeight)
        tailEdge = .leading
        if origin.x + Self.size.width > screen.maxX {
            origin.x = frame.minX - Self.size.width - gap
            tailEdge = .trailing
        }
        panel.setFrameOrigin(origin)
    }
}

/// A borderless panel that can still take the keyboard (for the bubble's caret), without activating
/// the app.
final class BubblePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// The content of the speech bubble: the reply being said, its current word highlighted, and a caret
/// to play from once stopped; a quiet ellipsis while Claude is thinking and there is no reply yet.
struct SpeechBubbleView: View {
    let bubble: SpeechBubble
    @Environment(SpeechEngine.self) private var speech
    @Environment(Conductor.self) private var conductor

    var body: some View {
        let reply = conductor.bubble
        Group {
            // Thinking, before this turn has said anything (between its steps, its own reply stays).
            if reply.text.isEmpty || reply.isPrevious, speech.presence == .thinking, speech.state == .idle {
                ThinkingDots()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if reply.text.isEmpty {
                Text("…")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                SpokenTextView(text: reply.text, highlight: conductor.spokenWord, caret: reply.caret,
                               interactive: conductor.current == nil || conductor.isPaused,
                               onCaret: { conductor.moveCaret(to: $0) },
                               onPlay: { conductor.playPause() })
            }
        }
        .font(.title3)
        .padding(16)
        .padding(bubble.tailEdge == .leading ? .leading : .trailing, BubbleShape.tailLength)
        .frame(width: SpeechBubble.size.width, height: SpeechBubble.size.height)
        .background {
            let shape = BubbleShape(tailEdge: bubble.tailEdge)
            shape.fill(Color(nsColor: .textBackgroundColor))
            shape.stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        }
    }
}

/// A rounded rectangle with a curved tail on one side, near the bottom.
nonisolated struct BubbleShape: Shape {
    /// How far the tail sticks out from the bubble's side.
    static let tailLength: CGFloat = 20
    /// Height of the tail tip above the bubble's bottom edge.
    static let tailTipHeight: CGFloat = 30

    var tailEdge: HorizontalEdge
    var cornerRadius: CGFloat = 22

    func path(in rect: CGRect) -> Path {
        let tail = Self.tailLength
        let body = tailEdge == .leading
            ? CGRect(x: rect.minX + tail, y: rect.minY, width: rect.width - tail, height: rect.height)
            : CGRect(x: rect.minX, y: rect.minY, width: rect.width - tail, height: rect.height)
        let bubble = Path(roundedRect: body, cornerRadius: cornerRadius, style: .continuous)

        // The tail leaves the side between two points above the tip and curves down to it.
        let tipY = rect.maxY - Self.tailTipHeight
        let side = tailEdge == .leading ? body.minX : body.maxX
        let tipX = tailEdge == .leading ? rect.minX : rect.maxX
        let inward: CGFloat = tailEdge == .leading ? 1 : -1
        var pointer = Path()
        pointer.move(to: CGPoint(x: side + inward * 2, y: tipY - 34))
        pointer.addQuadCurve(to: CGPoint(x: tipX, y: tipY), control: CGPoint(x: side - inward * 4, y: tipY - 8))
        pointer.addQuadCurve(to: CGPoint(x: side + inward * 2, y: tipY - 10), control: CGPoint(x: side, y: tipY - 2))
        pointer.closeSubpath()

        return bubble.union(pointer)
    }
}

/// "…" drawn one dot at a time, for a face that is thinking. Redraws a few times a second only.
struct ThinkingDots: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.4)) { timeline in
            let count = Int(timeline.date.timeIntervalSinceReferenceDate / 0.4) % 4
            Text(String(repeating: "·", count: max(1, count)) + String(repeating: " ", count: 3 - max(1, count)))
                .font(.largeTitle.monospaced())
                .foregroundStyle(.secondary)
                .accessibilityLabel("Thinking")
        }
    }
}

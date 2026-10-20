import AppKit
import SwiftUI

/// The reply in the speech bubble, the word being said highlighted and kept in view. While nothing is
/// being said (or it is paused) it has a caret, moved by clicking or with the usual keys, where Play
/// starts; the word it is in is marked. Space or Return plays (or pauses).
struct SpokenTextView: NSViewRepresentable {
    var text: String
    /// Range, in `text`, of the word being spoken.
    var highlight: NSRange?
    /// Where Play starts, in `text` (nil: the top, unmarked).
    var caret: Int?
    /// The caret can be moved: nothing is being said.
    var interactive: Bool
    var onCaret: (Int) -> Void = { _ in }
    var onPlay: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        let textView = CaretTextView(frame: NSRect(origin: .zero, size: scroll.contentSize))
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 2
        textView.textContainerInset = .zero
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.font = Coordinator.font
        textView.textColor = .textColor
        textView.delegate = context.coordinator
        scroll.documentView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? CaretTextView, let storage = textView.textStorage else { return }
        let coordinator = context.coordinator
        coordinator.onCaret = onCaret
        textView.onPlay = onPlay
        // Changes made here aren't the user moving the caret.
        coordinator.isUpdating = true
        defer { coordinator.isUpdating = false }

        // Compared with the text last shown (the same string while it is unchanged: a quick check).
        if text != coordinator.text {
            let old = coordinator.text as NSString
            if old.length > 0, (text as NSString).hasPrefix(coordinator.text) {
                // The reply streaming in: add the new words, keeping the caret and the scroll.
                let added = (text as NSString).substring(from: old.length)
                storage.append(NSAttributedString(string: added, attributes: Coordinator.attributes))
                coordinator.words += Words.ranges(in: added).map { NSRange(location: $0.location + old.length, length: $0.length) }
            } else {
                storage.setAttributedString(NSAttributedString(string: text, attributes: Coordinator.attributes))
                coordinator.words = Words.ranges(in: text)
                coordinator.marked = nil
                textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
            }
            coordinator.text = text
        }

        if interactive {
            textView.isSelectable = true
            textView.isEditable = true
            let location = min(caret ?? 0, storage.length)
            if textView.selectedRange().location != location {
                textView.setSelectedRange(NSRange(location: location, length: 0))
            }
        } else {
            textView.isEditable = false
            textView.isSelectable = false
        }

        // The word being said, or (while stopped) the word Play starts from.
        let mark: (range: NSRange, color: NSColor)? =
            if !interactive, let highlight, let word = Words.containing(highlight.location, in: coordinator.words) {
                (word, Coordinator.spokenColor)
            } else if interactive, let caret, let word = Words.containing(caret, in: coordinator.words) {
                (word, Coordinator.caretColor)
            } else {
                nil
            }
        if mark?.range != coordinator.marked?.range || mark?.color != coordinator.marked?.color {
            storage.beginEditing()
            if let marked = coordinator.marked, NSMaxRange(marked.range) <= storage.length {
                storage.removeAttribute(.backgroundColor, range: marked.range)
            }
            if let mark, NSMaxRange(mark.range) <= storage.length {
                storage.addAttribute(.backgroundColor, value: mark.color, range: mark.range)
            }
            storage.endEditing()
            coordinator.marked = mark
            if let mark, !interactive { textView.scrollRangeToVisible(mark.range) }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        static let font = NSFont.preferredFont(forTextStyle: .title3)
        static let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.textColor]
        static let spokenColor = NSColor.systemYellow.withAlphaComponent(0.45)
        static let caretColor = NSColor.controlAccentColor.withAlphaComponent(0.25)

        var onCaret: (Int) -> Void = { _ in }
        var isUpdating = false
        /// The text shown, and its words (UTF-16 ranges), kept up as the text grows.
        var text = ""
        var words: [NSRange] = []
        /// The word marked now, and how.
        var marked: (range: NSRange, color: NSColor)?

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isUpdating, let textView = notification.object as? NSTextView, textView.isSelectable else { return }
            onCaret(textView.selectedRange().location)
        }
    }
}

/// A text view with a caret that refuses edits; Space and Return play instead of typing.
final class CaretTextView: NSTextView {
    var onPlay: () -> Void = {}

    // Space pauses even while the voice is speaking (when the text isn't selectable).
    override var acceptsFirstResponder: Bool { true }

    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool { false }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        if modifiers.isEmpty, event.charactersIgnoringModifiers == " " || event.charactersIgnoringModifiers == "\r" {
            onPlay()
            return
        }
        super.keyDown(with: event)
    }
}

#Preview {
    SpokenTextView(text: String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 12),
                   highlight: NSRange(location: 300, length: 5), caret: nil, interactive: false)
        .frame(width: 500, height: 80)
        .padding()
}

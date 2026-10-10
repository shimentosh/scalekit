import AppKit
import SwiftUI

/// A scrollable, selectable, monospaced text view backed by NSTextView, which
/// handles long reports far better than a single SwiftUI `Text`.
struct ReadOnlyTextView: NSViewRepresentable {
    let text: String
    var fontSize: CGFloat = 11

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        if let textView = scrollView.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.drawsBackground = false
            textView.isRichText = false
            textView.usesFindBar = true
            textView.isIncrementalSearchingEnabled = true
            textView.textContainerInset = NSSize(width: 10, height: 10)
            textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
            textView.textColor = .labelColor
            textView.string = text
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView, textView.string != text else { return }
        textView.string = text
        textView.scrollToBeginningOfDocument(nil)
    }
}

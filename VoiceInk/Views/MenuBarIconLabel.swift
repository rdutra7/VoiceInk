import SwiftUI

// Menu bar icon. While a meeting is being recorded the mic is drawn in white on a
// red pill (same idea as Teams' screen-sharing indicator) so it's obvious at a glance
// that the recording is still running and has to be stopped.
struct MenuBarIconLabel: View {
    @ObservedObject private var meetingRecorderController = MeetingRecorderController.shared

    var body: some View {
        Image(nsImage: meetingRecorderController.isRecording ? Self.recordingIcon : Self.idleIcon)
    }

    private static let idleIcon: NSImage = {
        let ratio = $0.size.height / $0.size.width
        $0.size.height = 22
        $0.size.width = 22 / ratio
        return $0
    }(NSImage(named: "menuBarIcon")!)

    private static let recordingIcon: NSImage = {
        let glyphHeight: CGFloat = 19
        let glyphSize = NSSize(width: glyphHeight * idleIcon.size.width / idleIcon.size.height, height: glyphHeight)

        let whiteGlyph = NSImage(size: glyphSize, flipped: false) { rect in
            idleIcon.draw(in: rect)
            NSColor.white.set()
            rect.fill(using: .sourceAtop)
            return true
        }

        let pill = NSImage(size: NSSize(width: 34, height: 22), flipped: false) { rect in
            NSColor.systemRed.setFill()
            NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
            whiteGlyph.draw(in: NSRect(
                x: rect.midX - glyphSize.width / 2,
                y: rect.midY - glyphSize.height / 2,
                width: glyphSize.width,
                height: glyphSize.height
            ))
            return true
        }
        pill.isTemplate = false
        return pill
    }()
}

import AppKit
import TransformerCore

@MainActor
final class OutputWindow: NSWindow {
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 || event.charactersIgnoringModifiers == "\u{1b}" {
            onEscape?()
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}

@MainActor
final class OutputWindowController {
    let frameReceiver: FrameReceiver

    private let window: OutputWindow
    private let renderer: FrameRenderer
    private let outputView: NSView
    private var isClosed = false

    init(
        screen: NSScreen,
        transform: DisplayTransform,
        onEscape: @escaping () -> Void,
        onFirstFrame: ((RenderingPath) -> Void)? = nil,
        onFailure: ((String) -> Void)? = nil
    ) throws {
        let window = OutputWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        let outputView = NSView(
            frame: NSRect(origin: .zero, size: screen.frame.size)
        )
        let renderer = try FrameRenderer(
            view: outputView,
            transform: transform,
            onFirstFrame: onFirstFrame,
            onFailure: onFailure
        )

        self.window = window
        self.outputView = outputView
        self.renderer = renderer
        frameReceiver = renderer.frameReceiver

        outputView.autoresizingMask = [.width, .height]

        window.contentView = outputView
        window.backgroundColor = .black
        window.isOpaque = true
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.level = NSWindow.Level(
            rawValue: NSWindow.Level.mainMenu.rawValue + 1
        )
        window.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary
        ]
        window.onEscape = onEscape
        window.setFrame(screen.frame, display: false)
    }

    func show() {
        guard !isClosed else {
            return
        }
        window.orderFrontRegardless()
        window.makeKey()
        renderer.start()
    }

    func updateTargetScreen(_ screen: NSScreen) {
        guard !isClosed else {
            return
        }
        window.setFrame(screen.frame, display: true)
        outputView.layoutSubtreeIfNeeded()
        renderer.targetBoundsDidChange()
    }

    func updateTransform(_ transform: DisplayTransform) {
        guard !isClosed else {
            return
        }
        renderer.updateTransform(transform)
    }

    func close() {
        guard !isClosed else {
            return
        }
        isClosed = true
        window.onEscape = nil
        renderer.stop()
        window.orderOut(nil)
        window.close()
    }
}

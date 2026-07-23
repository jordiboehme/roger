import AppKit
import UniformTypeIdentifiers
import os

private let logger = Logger(subsystem: "com.jordiboehme.roger", category: "MeetingCheckpointDrop")

/// Transparent drag destination covering the floating panel. Registers drag
/// types on a dedicated NSView because window-level registration is
/// unreliable on macOS 26 / LSUIElement apps — same pattern as
/// `StatusBarDropView`. `hitTest` returns nil so mouse clicks fall through to
/// the SwiftUI buttons beneath; drag events are still delivered to
/// registered types.
final class MeetingCheckpointDropView: NSView {
    /// Gates acceptance — true only while a meeting recording is live.
    var isActive: @MainActor () -> Bool = { false }
    /// Fired on hover changes so SwiftUI can highlight the drop target.
    var onHoverChange: @MainActor (Bool) -> Void = { _ in }
    /// Delivers the normalised image and the wall-clock drop moment.
    var onDrop: @MainActor (MeetingCheckpointImage, Date) -> Void = { _, _ in }

    /// Serial queue handed to `receivePromisedFiles` for promise writing.
    private let promiseQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        return q
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        var types: [NSPasteboard.PasteboardType] = [.fileURL, .png, .tiff]
        types += NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
        registerForDraggedTypes(types)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // Pass all mouse events through to the SwiftUI content below.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let acceptable = isActive() && offersImage(sender.draggingPasteboard)
        onHoverChange(acceptable)
        return acceptable ? .copy : []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        (isActive() && offersImage(sender.draggingPasteboard)) ? .copy : []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        onHoverChange(false)
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        onHoverChange(false)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        onHoverChange(false)
        guard isActive() else { return false }
        // Captured before any async work — file promises resolve later, but
        // the checkpoint belongs to the moment of the drop.
        let droppedAt = Date()
        let pb = sender.draggingPasteboard

        // 1. File promises — what dragging the macOS screenshot floating
        // thumbnail provides. Receipt is async: return true now, deliver on
        // the main actor once the file lands in a private temp folder.
        if let receivers = pb.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver],
           let receiver = receivers.first {
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("roger-checkpoint-\(UUID().uuidString)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            } catch {
                logger.warning("Could not create promise temp dir: \(error.localizedDescription, privacy: .public)")
                return false
            }
            let onDrop = self.onDrop
            receiver.receivePromisedFiles(atDestination: tempDir, options: [:], operationQueue: promiseQueue) { url, error in
                Task { @MainActor in
                    if let error {
                        logger.warning("File promise failed: \(error.localizedDescription, privacy: .public)")
                        return
                    }
                    onDrop(.file(url, deleteAfterCopy: true), droppedAt)
                }
            }
            return true
        }

        // 2. Image file URLs (Finder drags).
        if let url = imageFileURL(from: pb) {
            onDrop(.file(url, deleteAfterCopy: false), droppedAt)
            return true
        }

        // 3. Raw image data (browser drags). TIFF is converted to PNG so the
        // session folder stays uniform.
        if let data = pb.data(forType: .png) {
            onDrop(.pngData(data), droppedAt)
            return true
        }
        if let tiff = pb.data(forType: .tiff),
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            onDrop(.pngData(png), droppedAt)
            return true
        }
        return false
    }

    private func offersImage(_ pb: NSPasteboard) -> Bool {
        if pb.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil) { return true }
        if imageFileURL(from: pb) != nil { return true }
        return pb.availableType(from: [.png, .tiff]) != nil
    }

    private func imageFileURL(from pb: NSPasteboard) -> URL? {
        guard let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] else { return nil }
        return urls.first { url in
            guard let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType else { return false }
            return type.conforms(to: .image)
        }
    }
}

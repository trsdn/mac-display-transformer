import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit
import TransformerCore

enum CapturePipelineError: LocalizedError {
    case sourceDisplayUnavailable

    var errorDescription: String? {
        switch self {
        case .sourceDisplayUnavailable:
            return "Der gewählte Quellmonitor ist für ScreenCaptureKit nicht verfügbar."
        }
    }
}

final class StreamOutputBridge: NSObject, SCStreamOutput {
    private let frameReceiver: FrameReceiver
    private var loggedFirstFrame = false

    init(frameReceiver: FrameReceiver) {
        self.frameReceiver = frameReceiver
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen,
              sampleBuffer.isValid,
              CMSampleBufferDataIsReady(sampleBuffer),
              let pixelBuffer = sampleBuffer.imageBuffer else {
            return
        }

        if let statusNumber = CMGetAttachment(
            sampleBuffer,
            key: SCStreamFrameInfo.status.rawValue as CFString,
            attachmentModeOut: nil
        ) as? NSNumber,
        let status = SCFrameStatus(rawValue: statusNumber.intValue),
        status != .complete {
            return
        }

        if !loggedFirstFrame {
            loggedFirstFrame = true
            NSLog(
                "Erster Videoframe empfangen: %dx%d, Pixelformat %u",
                CVPixelBufferGetWidth(pixelBuffer),
                CVPixelBufferGetHeight(pixelBuffer),
                CVPixelBufferGetPixelFormatType(pixelBuffer)
            )
        }

        markForImmediateDisplay(sampleBuffer)
        frameReceiver.receive(
            sampleBuffer: sampleBuffer,
            pixelBuffer: pixelBuffer
        )
    }

    private func markForImmediateDisplay(_ sampleBuffer: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: true
        ), CFArrayGetCount(attachments) > 0 else {
            return
        }

        let dictionary = unsafeBitCast(
            CFArrayGetValueAtIndex(attachments, 0),
            to: CFMutableDictionary.self
        )
        CFDictionarySetValue(
            dictionary,
            Unmanaged.passUnretained(
                kCMSampleAttachmentKey_DisplayImmediately
            ).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
        )
    }
}

final class CaptureStreamDelegate: NSObject, SCStreamDelegate {
    private let onUnexpectedStop: @Sendable (String) -> Void

    init(onUnexpectedStop: @escaping @Sendable (String) -> Void) {
        self.onUnexpectedStop = onUnexpectedStop
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        onUnexpectedStop(error.localizedDescription)
    }
}

@MainActor
final class CaptureSession {
    private let stream: SCStream
    private let streamOutput: StreamOutputBridge
    private let streamDelegate: CaptureStreamDelegate
    private let sampleQueue = DispatchQueue(
        label: "com.github.trsdn.DisplayTransformer.capture",
        qos: .userInteractive
    )
    private var outputWasAdded = false
    private var captureStarted = false

    init(
        sourceDisplayID: CGDirectDisplayID,
        targetMaximumDimension: Int,
        frameReceiver: FrameReceiver,
        onUnexpectedStop: @escaping @Sendable (String) -> Void
    ) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard let sourceDisplay = content.displays.first(where: {
            $0.displayID == sourceDisplayID
        }) else {
            throw CapturePipelineError.sourceDisplayUnavailable
        }

        let ownApplications = content.applications.filter {
            $0.processID == getpid()
        }
        let filter = SCContentFilter(
            display: sourceDisplay,
            excludingApplications: ownApplications,
            exceptingWindows: []
        )

        let configuration = SCStreamConfiguration()
        let captureSize = CaptureSizing.fitted(
            sourceWidth: CGDisplayPixelsWide(sourceDisplayID),
            sourceHeight: CGDisplayPixelsHigh(sourceDisplayID),
            maximumDimension: targetMaximumDimension
        )
        configuration.width = captureSize.width
        configuration.height = captureSize.height
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        // The renderer is capped at 30 Hz; capturing faster only replaces
        // single-slot frames that can never be displayed.
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 2
        configuration.showsCursor = true
        configuration.capturesAudio = false

        let delegate = CaptureStreamDelegate(onUnexpectedStop: onUnexpectedStop)
        streamDelegate = delegate
        streamOutput = StreamOutputBridge(frameReceiver: frameReceiver)
        stream = SCStream(
            filter: filter,
            configuration: configuration,
            delegate: delegate
        )
    }

    func start() async throws {
        try stream.addStreamOutput(
            streamOutput,
            type: .screen,
            sampleHandlerQueue: sampleQueue
        )
        outputWasAdded = true

        do {
            try await stream.startCapture()
            captureStarted = true
        } catch {
            do {
                try stream.removeStreamOutput(streamOutput, type: .screen)
            } catch {
                NSLog(
                    "Stream-Ausgabe nach Startfehler nicht entfernbar: %@",
                    error.localizedDescription
                )
            }
            outputWasAdded = false
            throw error
        }
    }

    func stop() async throws {
        var firstError: (any Error)?

        if captureStarted {
            do {
                try await stream.stopCapture()
            } catch {
                firstError = error
            }
            captureStarted = false
        }

        if outputWasAdded {
            do {
                try stream.removeStreamOutput(streamOutput, type: .screen)
            } catch where firstError == nil {
                firstError = error
            } catch {
                // Preserve the original stop error, which is more actionable.
            }
            outputWasAdded = false
        }

        if let firstError {
            throw firstError
        }
    }
}

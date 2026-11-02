import AVFoundation
import CoreMedia
import ScreenCaptureKit

/// Captures the system audio mix with ScreenCaptureKit and turns it into one
/// A-weighted dBFS value per second. Audio is never stored.
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    enum CaptureError: LocalizedError {
        case noDisplay
        var errorDescription: String? { "No display available to attach the audio capture to." }
    }

    /// Called on the audio queue once per second of captured audio; nil = silence.
    var onLevel: ((Double?) -> Void)?
    /// Called when the stream stops unexpectedly (sleep, display change, permission revoked…).
    var onStop: ((Error) -> Void)?

    private var stream: SCStream?
    private var meter: LevelMeter?
    private let audioQueue = DispatchQueue(label: "decibel.capture.audio", qos: .userInitiated)
    private let screenQueue = DispatchQueue(label: "decibel.capture.screen", qos: .background)

    var isRunning: Bool { stream != nil }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw CaptureError.noDisplay }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        // Video is required by SCStream; keep it as cheap as possible.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: screenQueue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid,
              let asbd = sampleBuffer.formatDescription?.audioStreamBasicDescription,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0, asbd.mBitsPerChannel == 32
        else { return }

        if meter?.sampleRate != asbd.mSampleRate {
            let m = LevelMeter(sampleRate: asbd.mSampleRate)
            m.onSecond = { [weak self] level in self?.onLevel?(level) }
            meter = m
        }
        guard let meter else { return }
        let frames = sampleBuffer.numSamples
        let nonInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0

        try? sampleBuffer.withAudioBufferList { abl, _ in
            if nonInterleaved {
                let channels: [UnsafePointer<Float>] = abl.compactMap { buf in
                    buf.mData.map { UnsafePointer($0.assumingMemoryBound(to: Float.self)) }
                }
                let count = min(frames, abl.map { Int($0.mDataByteSize) / 4 }.min() ?? 0)
                meter.process(frameCount: count, channelCount: channels.count) { c, i in channels[c][i] }
            } else if let buf = abl.first, let data = buf.mData {
                let ptr = data.assumingMemoryBound(to: Float.self)
                let ch = max(1, Int(buf.mNumberChannels))
                let count = min(frames, Int(buf.mDataByteSize) / 4 / ch)
                meter.process(frameCount: count, channelCount: ch) { c, i in ptr[i * ch + c] }
            }
        }
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        self.stream = nil
        onStop?(error)
    }
}

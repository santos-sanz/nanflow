import AVFoundation
import CoreAudio
import Foundation

/// Captures microphone audio, accumulates 16 kHz mono samples, and writes a WAV on stop.
public final class MicRecorder {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let targetRate: Double = 16_000
    private var samples: [Float] = []
    private let queue = DispatchQueue(label: "nanflow.micrecorder")
    private(set) public var startedAt: Date?
    private(set) public var isRecording = false
    private var tapInstalled = false
    /// Persistent UID of the mic to dictate with; nil = system default input.
    public var preferredDeviceUID: String?

    public init() {}

    public var level: Float {
        queue.sync {
            guard samples.count > 64 else { return 0 }
            let tail = samples.suffix(2048)
            let rms = sqrt(tail.reduce(0) { $0 + $1 * $1 } / Float(max(tail.count, 1)))
            return min(1, rms * 8)
        }
    }

    public func start() throws {
        guard !isRecording else { return }
        queue.sync { samples.removeAll() }

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw NSError(domain: "Nanflow.MicRecorder", code: 2, userInfo: [NSLocalizedDescriptionKey: "Mic input format inválido"])
        }
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: targetRate, channels: 1, interleaved: false) else {
            throw NSError(domain: "Nanflow.MicRecorder", code: 3)
        }
        guard let conv = AVAudioConverter(from: inputFormat, to: target) else {
            throw NSError(domain: "Nanflow.MicRecorder", code: 4, userInfo: [NSLocalizedDescriptionKey: "No se pudo crear AVAudioConverter"])
        }
        converter = conv
        applyPreferredDevice(to: input)

        // The tap is installed once; reinstalling it after removeTap throws
        // NSException in AVAudioEngine. start/stop cycles only toggle the engine.
        if !tapInstalled {
            input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
                self?.enqueue(buffer: buffer, converter: conv)
            }
            tapInstalled = true
        }

        engine.prepare()
        try engine.start()
        startedAt = Date()
        isRecording = true
    }

    /// Points the engine's input HAL unit at the user-selected microphone (best effort).
    private func applyPreferredDevice(to input: AVAudioInputNode) {
        guard let uid = preferredDeviceUID, !uid.isEmpty,
              let deviceID = AudioDevices.deviceID(forUID: uid),
              deviceID != AudioDevices.defaultInputDeviceID()
        else { return }
        var device = deviceID
        let status = AudioUnitSetProperty(
            input.audioUnit!,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &device,
            UInt32(MemoryLayout<AudioObjectID>.size)
        )
        if status != noErr {
            NFLog.write("mic: no se pudo seleccionar el dispositivo \(deviceID) (\(status))")
        }
    }

    private func enqueue(buffer: AVAudioPCMBuffer, converter: AVAudioConverter) {
        let ratio = targetRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else { return }
        var error: NSError?
        var fed = false
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard error == nil, status != .error else { return }
        guard let channel = out.floatChannelData?[0] else { return }
        let count = Int(out.frameLength)
        let chunk = Array(UnsafeBufferPointer(start: channel, count: count))
        queue.async { self.samples.append(contentsOf: chunk) }
    }

    public func stop() -> (samples: [Float], sampleRate: Double, duration: TimeInterval)? {
        guard isRecording else { return nil }
        engine.stop()
        var result: [Float] = []
        var started: Date?
        queue.sync {
            result = samples
            samples.removeAll()
        }
        started = startedAt
        isRecording = false
        converter = nil
        let duration = started.map { Date().timeIntervalSince($0) } ?? 0
        return (result, targetRate, duration)
    }

    public func stopAndWrite(to url: URL) throws -> TimeInterval {
        guard let result = stop() else { throw NSError(domain: "Nanflow.MicRecorder", code: 5, userInfo: [NSLocalizedDescriptionKey: "No estaba grabando"]) }
        try WavWriter.write(samples: result.samples, sampleRate: result.sampleRate, to: url)
        return result.duration
    }
}

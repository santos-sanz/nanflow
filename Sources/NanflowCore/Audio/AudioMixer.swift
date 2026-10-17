import AVFoundation
import Foundation

public enum AudioMixer {
    /// Trims leading/trailing silence (below RMS threshold) with padding, to cut upload and whisper time.
    /// Window = 25 ms. Returns the original array if everything looks like speech (or all silence).
    public static func trimSilence(samples: [Float], sampleRate: Double, threshold: Float = 0.008) -> [Float] {
        guard samples.count > 64 else { return samples }
        let window = max(1, Int(sampleRate * 0.025))
        let pad = max(1, Int(sampleRate * 0.12))

        func rms(_ start: Int) -> Float {
            let end = min(start + window, samples.count)
            guard end > start else { return 0 }
            var acc: Float = 0
            for i in start..<end { acc += samples[i] * samples[i] }
            return sqrt(acc / Float(end - start))
        }

        var first = 0
        while first + window <= samples.count, rms(first) < threshold {
            first += window
        }
        var last = samples.count - window
        while last >= 0, rms(last) < threshold {
            last -= window
        }
        guard last >= first else { return samples } // todo silencio: dejar como está
        let lo = max(0, first - pad)
        let hi = min(samples.count, last + window + pad)
        return Array(samples[lo..<hi])
    }
    /// Resamples mono Float samples to the target rate using AVAudioConverter (linear interpolation quality).
    public static func resample(samples: [Float], fromRate: Double, toRate: Double) -> [Float] {
        guard fromRate != toRate, !samples.isEmpty else { return samples }
        guard let srcFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: fromRate, channels: 1, interleaved: false),
              let dstFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: toRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: srcFormat, to: dstFormat)
        else { return samples }

        guard let srcBuffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: AVAudioFrameCount(samples.count)) else { return samples }
        srcBuffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            srcBuffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }

        let estimatedOut = AVAudioFrameCount(Double(samples.count) * toRate / fromRate) + 1024
        guard let dstBuffer = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: estimatedOut) else { return samples }

        var fed = false
        var error: NSError?
        var out: [Float] = []
        // Drena el conversor: hay que señalizar endOfStream para que libere la cola del kernel.
        for _ in 0..<8 {
            let status = converter.convert(to: dstBuffer, error: &error) { _, outStatus in
                if fed {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                fed = true
                outStatus.pointee = .haveData
                return srcBuffer
            }
            if error != nil || status == .error { break }
            if let ch = dstBuffer.floatChannelData?[0], dstBuffer.frameLength > 0 {
                out.append(contentsOf: UnsafeBufferPointer(start: ch, count: Int(dstBuffer.frameLength)))
            }
            if status == .endOfStream { break }
        }
        return out
    }

    /// Mixes two mono tracks already at the same rate. `offsetSeconds` = how much later trackB started relative to trackA.
    public static func mix(trackA: [Float], trackB: [Float], offsetSeconds: Double = 0, rate: Double = 16_000, gainA: Float = 1.0, gainB: Float = 1.0) -> [Float] {
        let skip = max(0, Int(offsetSeconds * rate))
        let n = max(trackA.count, trackB.count + skip)
        guard n > 0 else { return [] }
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            var v: Float = 0
            if i < trackA.count { v += trackA[i] * gainA }
            let j = i - skip
            if j >= 0, j < trackB.count { v += trackB[j] * gainB }
            out[i] = max(-1, min(1, v))
        }
        // soft normalization if clipping
        let peak = out.map { abs($0) }.max() ?? 0
        if peak > 0.98 {
            let g = Float(0.95 / peak)
            out = out.map { $0 * g }
        }
        return out
    }
}

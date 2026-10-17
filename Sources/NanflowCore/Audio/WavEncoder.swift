import Foundation

/// In-memory WAV (PCM16 mono) encoder — avoids temp files on the dictation hot path.
public enum WavEncoder {
    public static func encode(samples: [Float], sampleRate: Double) -> Data {
        var data = Data(capacity: samples.count * 2 + 44)

        func appendAscii(_ s: String) {
            data.append(contentsOf: s.utf8)
        }
        func appendUInt32(_ v: UInt32) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        func appendUInt16(_ v: UInt16) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }

        let sr = UInt32(sampleRate)
        let dataSize = UInt32(samples.count * 2)

        appendAscii("RIFF")
        appendUInt32(dataSize + 36)
        appendAscii("WAVE")
        appendAscii("fmt ")
        appendUInt32(16)
        appendUInt16(1)           // PCM
        appendUInt16(1)           // mono
        appendUInt32(sr)
        appendUInt32(sr * 2)      // byte rate
        appendUInt16(2)           // block align
        appendUInt16(16)          // bits
        appendAscii("data")
        appendUInt32(dataSize)

        var pcm = [Int16]()
        pcm.reserveCapacity(samples.count)
        for s in samples {
            let clamped = max(-1.0, min(1.0, s))
            pcm.append(Int16(clamped * 32767))
        }
        pcm.withUnsafeBufferPointer { buf in
            data.append(contentsOf: UnsafeRawBufferPointer(buf))
        }
        return data
    }
}

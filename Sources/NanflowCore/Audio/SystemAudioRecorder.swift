import AVFoundation
import CoreAudio
import Foundation

/// Captures system audio via Core Audio Process Tap (macOS 14.2+).
/// No Screen Recording permission needed. Mixes all output processes to stereo (excludes our own).
public final class SystemAudioRecorder: @unchecked Sendable {
    private var tapID: AudioObjectID = 0
    private var aggDeviceID: AudioObjectID = 0
    private var procID: AudioDeviceIOProcID?
    private var samples: [Float] = []
    private var sampleRate: Double = 48_000
    private let lock = NSLock()
    private let lifecycleQueue = DispatchQueue(label: "nanflow.sysaudio.lifecycle")
    private(set) public var startedAt: Date?

    public enum SysAudioError: LocalizedError {
        case tapCreationFailed(OSStatus)
        case aggregateCreationFailed(OSStatus)
        case ioProcFailed(OSStatus)
        case startFailed(OSStatus)
        case unsupportedOS

        public var errorDescription: String? {
            switch self {
            case .tapCreationFailed(let s): return "No se pudo crear el Process Tap (\(s))"
            case .aggregateCreationFailed(let s): return "No se pudo crear el dispositivo agregado (\(s))"
            case .ioProcFailed(let s): return "No se pudo crear el IOProc (\(s))"
            case .startFailed(let s): return "No se pudo iniciar el device (\(s))"
            case .unsupportedOS: return "Requiere macOS 14.2+"
            }
        }
    }

    public init() {}

    public func start() throws {
        try lifecycleQueue.sync {
            guard #available(macOS 14.2, *) else { throw SysAudioError.unsupportedOS }
            try startLocked()
        }
    }

    @available(macOS 14.2, *)
    private func startLocked() throws {
        stopLocked()
        lock.lock()
        samples.removeAll()
        lock.unlock()

        let myProcessObject = Self.processObject(forPID: ProcessInfo.processInfo.processIdentifier) ?? 0
        let desc = CATapDescription(__stereoGlobalTapButExcludeProcesses: [NSNumber(value: myProcessObject)])
        desc.name = "Nanflow System Tap"
        desc.muteBehavior = .unmuted
        desc.isPrivate = true

        var tap = AudioObjectID(0)
        let st = AudioHardwareCreateProcessTap(desc, &tap)
        guard st == noErr else { throw SysAudioError.tapCreationFailed(st) }
        tapID = tap
        let tapUID = desc.uuid.uuidString

        let aggUID = "nanflow.agg.\(UUID().uuidString)"
        let aggDict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Nanflow Aggregate",
            kAudioAggregateDeviceUIDKey: aggUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [
                    kAudioSubDeviceUIDKey: tapUID,
                ] as [String: Any],
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUID,
                    kAudioSubTapDriftCompensationKey: 1,
                ] as [String: Any],
            ],
        ]

        var agg = AudioObjectID(0)
        let st2 = AudioHardwareCreateAggregateDevice(aggDict as CFDictionary, &agg)
        guard st2 == noErr else {
            AudioHardwareDestroyProcessTap(tap)
            tapID = 0
            throw SysAudioError.aggregateCreationFailed(st2)
        }
        aggDeviceID = agg

        sampleRate = Self.nominalRate(deviceID: agg)

        let ioCallback: AudioDeviceIOBlock = { [weak self] _, inBufs, _, _, _ in
            guard let self else { return }
            self.ingest(bufferList: inBufs)
        }
        var proc: AudioDeviceIOProcID? = nil
        let st3 = AudioDeviceCreateIOProcIDWithBlock(&proc, agg, nil, ioCallback)
        guard st3 == noErr, proc != nil else {
            AudioHardwareDestroyAggregateDevice(agg)
            aggDeviceID = 0
            AudioHardwareDestroyProcessTap(tap)
            tapID = 0
            throw SysAudioError.ioProcFailed(st3)
        }
        procID = proc

        let st4 = AudioDeviceStart(agg, proc!)
        guard st4 == noErr else {
            AudioDeviceDestroyIOProcID(agg, proc!)
            procID = nil
            AudioHardwareDestroyAggregateDevice(agg)
            aggDeviceID = 0
            AudioHardwareDestroyProcessTap(tap)
            tapID = 0
            throw SysAudioError.startFailed(st4)
        }

        startedAt = Date()
        NFLog.write("sysaudio: tap activo @\(Int(sampleRate))Hz")
    }

    private static func processObject(forPID pid: pid_t) -> AudioObjectID? {
        var pidValue = pid
        var translation = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var objectID = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &translation,
            UInt32(MemoryLayout<pid_t>.size),
            &pidValue,
            &size,
            &objectID
        )
        guard status == noErr, objectID != 0, objectID != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return objectID
    }

    private static func nominalRate(deviceID: AudioObjectID) -> Double {
        var rate = Float64(48_000)
        var size = UInt32(MemoryLayout<Float64>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &rate) == noErr, rate > 0 {
            return Double(rate)
        }
        return 48_000
    }

    private func ingest(bufferList: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        guard !buffers.isEmpty else { return }

        if buffers.count == 1, let buffer = buffers.first,
           let data = buffer.mData {
            let totalFloats = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            let channelCount = max(1, Int(buffer.mNumberChannels))
            let frames = totalFloats / channelCount
            guard frames > 0 else { return }
            let floats = data.assumingMemoryBound(to: Float.self)
            var mono: [Float]
            if channelCount == 1 {
                mono = Array(UnsafeBufferPointer(start: floats, count: frames))
            } else {
                mono = [Float](repeating: 0, count: frames)
                for i in 0..<frames {
                    var acc: Float = 0
                    for c in 0..<channelCount { acc += floats[i * channelCount + c] }
                    mono[i] = acc / Float(channelCount)
                }
            }
            lock.lock()
            samples.append(contentsOf: mono)
            lock.unlock()
            return
        }

        var channels: [[Float]] = []
        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            let totalFloats = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            guard totalFloats > 0 else { continue }
            let floats = data.assumingMemoryBound(to: Float.self)
            let channelCount = max(1, Int(buffer.mNumberChannels))
            let frames = totalFloats / channelCount
            if channelCount == 1 {
                channels.append(Array(UnsafeBufferPointer(start: floats, count: frames)))
            } else {
                for c in 0..<channelCount {
                    var channel = [Float](repeating: 0, count: frames)
                    for i in 0..<frames { channel[i] = floats[i * channelCount + c] }
                    channels.append(channel)
                }
            }
        }
        let mono = AudioMixer.downmix(channels: channels)
        guard !mono.isEmpty else { return }
        lock.lock()
        samples.append(contentsOf: mono)
        lock.unlock()
    }

    public func stop() -> (samples: [Float], sampleRate: Double)? {
        lifecycleQueue.sync { () -> (samples: [Float], sampleRate: Double)? in
            let hadStream = aggDeviceID != 0
            if #available(macOS 14.2, *) { stopLocked() }
            guard hadStream else { return nil }
            var result: [Float] = []
            lock.lock()
            result = samples
            samples.removeAll()
            lock.unlock()
            return (result, sampleRate)
        }
    }

    @available(macOS 14.2, *)
    private func stopLocked() {
        if aggDeviceID != 0, let proc = procID {
            AudioDeviceStop(aggDeviceID, proc)
            AudioDeviceDestroyIOProcID(aggDeviceID, proc)
        }

        procID = nil
        if aggDeviceID != 0 {
            AudioHardwareDestroyAggregateDevice(aggDeviceID)
            aggDeviceID = 0
        }
        if tapID != 0 {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = 0
        }
    }
}

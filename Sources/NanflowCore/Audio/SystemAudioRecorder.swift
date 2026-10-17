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
        guard #available(macOS 14.2, *) else { throw SysAudioError.unsupportedOS }
        stopInternal()

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
        let abl = bufferList.pointee
        guard abl.mNumberBuffers > 0 else { return }
        let buf = withUnsafeBytes(of: abl.mBuffers) { raw -> AudioBuffer in
            raw.load(as: AudioBuffer.self)
        }
        guard let data = buf.mData else { return }
        let floats = data.assumingMemoryBound(to: Float.self)
        let totalFloats = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
        let channels = max(1, Int(buf.mNumberChannels))
        var mono: [Float]
        if channels >= 2 {
            let frames = totalFloats / channels
            mono = Array(unsafeUninitializedCapacity: frames) { out, count in
                count = frames
                for i in 0..<frames {
                    var acc: Float = 0
                    for c in 0..<channels { acc += floats[i * channels + c] }
                    out[i] = acc / Float(channels)
                }
            }
        } else {
            mono = Array(UnsafeBufferPointer(start: floats, count: totalFloats))
        }
        lock.lock()
        samples.append(contentsOf: mono)
        lock.unlock()
    }

    public func stop() -> (samples: [Float], sampleRate: Double)? {
        let hadStream = aggDeviceID != 0
        if #available(macOS 14.2, *) { stopInternal() }
        guard hadStream else { return nil }
        var result: [Float] = []
        lock.lock()
        result = samples
        samples.removeAll()
        lock.unlock()
        return (result, sampleRate)
    }

    @available(macOS 14.2, *)
    private func stopInternal() {
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

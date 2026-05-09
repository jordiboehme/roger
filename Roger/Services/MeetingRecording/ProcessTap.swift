import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation
import os

/// A `CATapDescription`-backed system-audio tap. Captures everything the user
/// hears (excluding our own playback so transcription audio doesn't loop back).
///
/// Adapted from `insidegui/AudioCap` (MIT) with small Roger-specific tweaks:
/// - `nil`-safe lifecycle so re-creating taps in the same process won't trip
///   over a stale aggregate-device handle.
/// - All Core Audio calls funnel through a serial dispatch queue. The IOProc
///   block hands off to `bufferHandler` synchronously — the caller is
///   responsible for shipping the buffer copy to a writer queue.
final class ProcessTap: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.jordiboehme.roger", category: "ProcessTap")

    private let queue = DispatchQueue(label: "com.jordiboehme.roger.processtap", qos: .userInteractive)

    private(set) var streamDescription: AudioStreamBasicDescription?
    private var tapID: AudioObjectID = .unknown
    private var aggregateDeviceID: AudioObjectID = .unknown
    private var ioProcID: AudioDeviceIOProcID?

    /// Called for every audio packet on the IOProc thread. The handler MUST
    /// not allocate, lock or do file I/O — copy into a preallocated buffer
    /// and `dispatch_async` to a serial writer queue.
    var bufferHandler: ((UnsafePointer<AudioBufferList>, AudioTimeStamp) -> Void)?

    /// Starts capture. Throws if tap creation fails (most commonly because the
    /// user denied the system-audio permission). Idempotent.
    func activate() throws {
        guard tapID == .unknown else { return }

        let pid = ProcessInfo.processInfo.processIdentifier
        let selfProcessObject = AudioObjectID.translatePID(pid)
        let excluded: [AudioObjectID] = selfProcessObject == 0 ? [] : [selfProcessObject]
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        description.uuid = UUID()
        description.muteBehavior = CATapMuteBehavior.unmuted
        description.isPrivate = true
        description.isMixdown = true

        var newTapID: AudioObjectID = .unknown
        let createStatus = AudioHardwareCreateProcessTap(description, &newTapID)
        guard createStatus == noErr else {
            Self.logger.error("AudioHardwareCreateProcessTap failed: \(CoreAudioHelpers.errorString(createStatus), privacy: .public)")
            throw ProcessTapError.tapCreationFailed(createStatus)
        }
        tapID = newTapID
        Self.logger.info("Tap created (id \(newTapID))")

        let outputDevice = AudioObjectID.readDefaultSystemOutputDevice()
        guard outputDevice != 0 else {
            destroyTap()
            throw ProcessTapError.noDefaultOutputDevice
        }

        let aggregateUID = "Roger-Tap-Aggregate-\(description.uuid.uuidString)"
        let outputUID = (outputDevice.readProperty(kAudioDevicePropertyDeviceUID) as CFString?) as String? ?? ""

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceUIDKey as String: aggregateUID,
            kAudioAggregateDeviceNameKey as String: "Roger Tap",
            kAudioAggregateDeviceMainSubDeviceKey as String: outputUID,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceSubDeviceListKey as String: [
                [kAudioSubDeviceUIDKey as String: outputUID]
            ],
            kAudioAggregateDeviceTapListKey as String: [
                [
                    kAudioSubTapDriftCompensationKey as String: true,
                    kAudioSubTapUIDKey as String: description.uuid.uuidString
                ]
            ]
        ]

        var aggregateID: AudioDeviceID = .unknown
        let aggregateStatus = AudioHardwareCreateAggregateDevice(
            aggregateDescription as CFDictionary,
            &aggregateID
        )
        guard aggregateStatus == noErr else {
            Self.logger.error("AudioHardwareCreateAggregateDevice failed: \(CoreAudioHelpers.errorString(aggregateStatus), privacy: .public)")
            destroyTap()
            throw ProcessTapError.aggregateDeviceCreationFailed(aggregateStatus)
        }
        aggregateDeviceID = aggregateID
        Self.logger.info("Aggregate device created (id \(aggregateID))")

        guard let asbd: AudioStreamBasicDescription = tapID.readProperty(kAudioTapPropertyFormat) else {
            destroyAggregate()
            destroyTap()
            throw ProcessTapError.formatReadFailed
        }
        streamDescription = asbd
        Self.logger.info("Tap stream format: \(asbd.mSampleRate, privacy: .public) Hz × \(asbd.mChannelsPerFrame, privacy: .public)ch")

        var procID: AudioDeviceIOProcID?
        // The IOProc must read the current `bufferHandler` value on every
        // invocation — callers (SystemAudioTap) often configure their
        // closure AFTER `activate()` returns. Capturing into a local snapshot
        // here would freeze a nil reference and silently drop every packet.
        let createIOProcStatus = AudioDeviceCreateIOProcIDWithBlock(
            &procID,
            aggregateID,
            queue,
            { [weak self] _, inInputData, inInputTime, _, _ in
                self?.bufferHandler?(inInputData, inInputTime.pointee)
            }
        )
        guard createIOProcStatus == noErr, let createdProc = procID else {
            Self.logger.error("AudioDeviceCreateIOProcIDWithBlock failed: \(CoreAudioHelpers.errorString(createIOProcStatus), privacy: .public)")
            destroyAggregate()
            destroyTap()
            throw ProcessTapError.ioProcCreationFailed(createIOProcStatus)
        }
        ioProcID = createdProc

        let startStatus = AudioDeviceStart(aggregateID, createdProc)
        guard startStatus == noErr else {
            Self.logger.error("AudioDeviceStart failed: \(CoreAudioHelpers.errorString(startStatus), privacy: .public)")
            AudioDeviceDestroyIOProcID(aggregateID, createdProc)
            ioProcID = nil
            destroyAggregate()
            destroyTap()
            throw ProcessTapError.deviceStartFailed(startStatus)
        }

        Self.logger.notice("ProcessTap running on aggregate \(aggregateID)")
    }

    /// Stops capture and tears down the tap + aggregate device. Idempotent.
    func invalidate() {
        if let procID = ioProcID {
            AudioDeviceStop(aggregateDeviceID, procID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
            ioProcID = nil
        }
        destroyAggregate()
        destroyTap()
        streamDescription = nil
    }

    private func destroyAggregate() {
        guard aggregateDeviceID != .unknown else { return }
        let status = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
        if status != noErr {
            Self.logger.warning("AudioHardwareDestroyAggregateDevice failed: \(CoreAudioHelpers.errorString(status), privacy: .public)")
        }
        aggregateDeviceID = .unknown
    }

    private func destroyTap() {
        guard tapID != .unknown else { return }
        let status = AudioHardwareDestroyProcessTap(tapID)
        if status != noErr {
            Self.logger.warning("AudioHardwareDestroyProcessTap failed: \(CoreAudioHelpers.errorString(status), privacy: .public)")
        }
        tapID = .unknown
    }
}

enum ProcessTapError: LocalizedError {
    case tapCreationFailed(OSStatus)
    case aggregateDeviceCreationFailed(OSStatus)
    case formatReadFailed
    case ioProcCreationFailed(OSStatus)
    case deviceStartFailed(OSStatus)
    case noDefaultOutputDevice

    var errorDescription: String? {
        switch self {
        case .tapCreationFailed(let s):
            return "Couldn't create system-audio tap (\(CoreAudioHelpers.errorString(s))). Grant permission in System Settings › Privacy & Security › Audio."
        case .aggregateDeviceCreationFailed(let s):
            return "Couldn't create the audio aggregate device (\(CoreAudioHelpers.errorString(s)))."
        case .formatReadFailed:
            return "Couldn't read the system-audio tap format."
        case .ioProcCreationFailed(let s):
            return "Couldn't install the audio capture callback (\(CoreAudioHelpers.errorString(s)))."
        case .deviceStartFailed(let s):
            return "Couldn't start system audio capture (\(CoreAudioHelpers.errorString(s)))."
        case .noDefaultOutputDevice:
            return "No default audio output device is currently active."
        }
    }
}

extension AudioObjectID {
    static let unknown: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
}

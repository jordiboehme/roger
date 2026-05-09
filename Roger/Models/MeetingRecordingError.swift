import Foundation

/// User-facing failures from the meeting-recording pipeline. Wrapped errors
/// (e.g. `ProcessTapError`, `MicrophoneTapError`) are folded into the closest
/// case rather than being exposed verbatim — this gives the UI a stable
/// surface to switch on.
enum MeetingRecordingError: LocalizedError, Sendable {
    case unsupportedOS
    case alreadyRecording
    case dictationActive
    case fileTranscriptionActive
    case microphonePermissionDenied
    case audioCapturePermissionDenied
    case tapStartFailed(String)
    case audioWriterFailed(String)
    case finalisationFailed(String)
    case noAudioCaptured
    case sleepInterrupted

    var errorDescription: String? {
        switch self {
        case .unsupportedOS:
            return "Meeting recording requires macOS 14.4 or later."
        case .alreadyRecording:
            return "A meeting recording is already in progress."
        case .dictationActive:
            return "Stop dictation before starting a meeting recording."
        case .fileTranscriptionActive:
            return "Wait for the current file transcription to finish before starting a meeting."
        case .microphonePermissionDenied:
            return "Microphone access denied — grant permission in System Settings › Privacy & Security."
        case .audioCapturePermissionDenied:
            return "System audio recording denied — grant permission in System Settings › Privacy & Security › Audio."
        case .tapStartFailed(let reason):
            return "Couldn't start system audio capture: \(reason)"
        case .audioWriterFailed(let reason):
            return "Couldn't write audio to disk: \(reason)"
        case .finalisationFailed(let reason):
            return "Couldn't finalise the meeting recording: \(reason)"
        case .noAudioCaptured:
            return "No audio captured — the recording is too short to transcribe."
        case .sleepInterrupted:
            return "Recording paused because the system went to sleep."
        }
    }
}

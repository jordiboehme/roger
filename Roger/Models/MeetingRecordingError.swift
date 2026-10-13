import Foundation

/// User-facing failures from the meeting-recording pipeline. Wrapped errors
/// (e.g. `ProcessTapError`, `MicrophoneTapError`) are folded into the closest
/// case rather than being exposed verbatim — this gives the UI a stable
/// surface to switch on.
enum MeetingRecordingError: LocalizedError, Sendable {
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
    /// The transcript was written, but a track's audio could not be saved.
    case trackAudioFailed(mic: Bool, system: Bool)
    /// The transcript was written, but some audio could not be merged into
    /// the archive. It is kept in these leftover files; there is nothing to retry.
    case audioSetAside(files: [String])

    var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            return "A meeting recording is already in progress."
        case .dictationActive:
            return "Stop dictation before starting a meeting recording."
        case .fileTranscriptionActive:
            return "Wait for the current file transcription to finish before starting a meeting."
        case .microphonePermissionDenied:
            return "Microphone access denied. Grant permission in System Settings › Privacy & Security."
        case .audioCapturePermissionDenied:
            return "System audio recording denied. Grant permission in System Settings › Privacy & Security › Audio."
        case .tapStartFailed(let reason):
            return "Couldn't start system audio capture: \(reason)"
        case .audioWriterFailed(let reason):
            return "Couldn't write audio to disk: \(reason)"
        case .finalisationFailed(let reason):
            return "Couldn't finalise the meeting recording: \(reason)"
        case .noAudioCaptured:
            return "No audio captured. The recording is too short to transcribe."
        case .sleepInterrupted:
            return "Recording paused because the system went to sleep."
        case .trackAudioFailed(let mic, let system):
            let tracks = mic && system ? "Microphone and system audio" : (mic ? "Microphone audio" : "System audio")
            return "\(tracks) could not be fully saved, so the transcript may be incomplete. Roger kept the recording. Try again from the menu bar."
        case .audioSetAside(let files):
            return "Some audio could not be merged. It is saved as \(Self.listed(files)) in the meeting folder."
        }
    }

    /// The error a finished finalisation reports, or nil. Kept chunks mean a
    /// retry can help ("Try again"). Audio that only sits in a leftover file
    /// needs no retry, so the message says where it is instead.
    static func afterFinalisation(micNeedsRetry: Bool, systemNeedsRetry: Bool, setAside: [String]) -> MeetingRecordingError? {
        if micNeedsRetry || systemNeedsRetry {
            return .trackAudioFailed(mic: micNeedsRetry, system: systemNeedsRetry)
        }
        if !setAside.isEmpty {
            return .audioSetAside(files: setAside)
        }
        return nil
    }

    /// "a", "a and b", "a, b and c".
    static func listed(_ names: [String]) -> String {
        guard let last = names.last else { return "" }
        guard names.count > 1 else { return last }
        return names.dropLast().joined(separator: ", ") + " and " + last
    }
}

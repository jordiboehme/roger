import Testing
@testable import Roger

struct MeetingRecordingErrorTests {
    @Test func keptChunksAskForARetry() {
        let error = MeetingRecordingError.afterFinalisation(micNeedsRetry: true, systemNeedsRetry: false, setAside: ["mic.leftover.m4a"])
        guard case .trackAudioFailed(let mic, let system, _)? = error else {
            Issue.record("expected trackAudioFailed, got \(String(describing: error))")
            return
        }
        #expect(mic && !system)
        #expect(error?.errorDescription?.contains("Try again") == true)
    }

    @Test func audioSetAsideSaysWhereItIs() {
        let error = MeetingRecordingError.afterFinalisation(micNeedsRetry: false, systemNeedsRetry: false, setAside: ["mic.leftover.m4a"])
        #expect(error?.errorDescription == "Some audio could not be merged. It is saved as mic.leftover.m4a in the meeting folder.")
        #expect(error?.errorDescription?.contains("Try again") == false)
    }

    @Test func severalFilesAreListedWithoutOxfordComma() {
        let error = MeetingRecordingError.afterFinalisation(
            micNeedsRetry: false, systemNeedsRetry: false,
            setAside: ["mic.leftover.m4a", "system.leftover.m4a"]
        )
        #expect(error?.errorDescription == "Some audio could not be merged. It is saved as mic.leftover.m4a and system.leftover.m4a in the meeting folder.")
        #expect(MeetingRecordingError.listed(["a", "b", "c"]) == "a, b and c")
    }

    @Test func nothingWrongIsNoError() {
        #expect(MeetingRecordingError.afterFinalisation(micNeedsRetry: false, systemNeedsRetry: false, setAside: []) == nil)
    }

    /// A mic track that needs a retry and a system leftover: both are said.
    @Test func aRetryErrorNamesTheLeftoverToo() {
        let error = MeetingRecordingError.afterFinalisation(micNeedsRetry: true, systemNeedsRetry: false, setAside: ["system.leftover.m4a"])
        #expect(error?.errorDescription == "Microphone audio could not be fully saved, so the transcript may be incomplete. Roger kept the recording. Try again from the menu bar. Some audio is also saved as system.leftover.m4a in the meeting folder.")
    }

    @Test func aRetryErrorWithoutLeftoverStaysShort() {
        let error = MeetingRecordingError.afterFinalisation(micNeedsRetry: false, systemNeedsRetry: true, setAside: [])
        #expect(error?.errorDescription == "System audio could not be fully saved, so the transcript may be incomplete. Roger kept the recording. Try again from the menu bar.")
    }
}

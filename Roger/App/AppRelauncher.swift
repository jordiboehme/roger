import AppKit

/// Relaunches Roger. This is the reliable fix for a process-scoped CoreAudio
/// wedge (macOS 26.5.x can stop delivering input buffers to a long-lived
/// audio client; only a fresh process gets a fresh HAL connection). A helper
/// shell re-opens the bundle after the current process has terminated.
enum AppRelauncher {
    static func relaunch() {
        let bundlePath = Bundle.main.bundlePath
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", "sleep 0.5; /usr/bin/open \"\(bundlePath)\""]
        do {
            try helper.run()
        } catch {
            // Without the helper a terminate would just quit the app —
            // leave it running instead.
            return
        }
        NSApp.terminate(nil)
    }
}

import AppKit
import SwiftUI

/// Exactly `AppCoordinator.pendingMeetingSessions`: unfinished meetings
/// that were not dismissed. Finalise runs the existing retry; Dismiss uses
/// the existing persisted dismissal.
struct LibraryUnfinishedListView: View {
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        List(coordinator.pendingMeetingSessions) { session in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "tray.full")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Meeting \(MeetingTranscriptWriter.displayDate(session.startedAt))")
                        .font(.system(size: 13, weight: .medium))
                    Text(session.folder.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button("Finalise") {
                    Task { await coordinator.resumeMeetingFinalisation(session) }
                }
                .disabled(coordinator.meetingRecorder.isActive)
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([session.folder])
                } label: {
                    Image(systemName: "folder")
                }
                .help("Show in Finder")
                Button {
                    coordinator.dismissPendingMeeting(session)
                } label: {
                    Image(systemName: "xmark")
                }
                .help("Dismiss. The files stay where they are.")
            }
            .buttonStyle(.borderless)
            .padding(.vertical, 4)
        }
        .overlay {
            if coordinator.pendingMeetingSessions.isEmpty {
                ContentUnavailableView("Nothing Unfinished", systemImage: "checkmark.circle")
            }
        }
    }
}

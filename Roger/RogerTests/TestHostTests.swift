import Testing
@testable import Roger

@MainActor
struct TestHostTests {
    /// The tests run inside Roger.app. Building the coordinator there would
    /// read the developer's real settings and library folder.
    @Test func theTestHostBuildsNoCoordinator() {
        #expect(AppLaunch.isRunningTests)
        #expect(AppCoordinator.instancesCreated == 0)
    }
}

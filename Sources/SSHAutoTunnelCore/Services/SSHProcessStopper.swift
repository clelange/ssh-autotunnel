import Foundation

enum SSHProcessStopper {
    static func waitForExit(
        sessions: [SSHProcessSession],
        timeout: TimeInterval,
        forceKillAfter: TimeInterval = 2.0,
        pollInterval: TimeInterval = 0.05,
        onForceKill: ((SSHProcessSession) -> Void)? = nil
    ) -> Bool {
        guard !sessions.isEmpty else { return true }
        let timeout = max(0, timeout)
        let forceKillAfter = min(max(0, forceKillAfter), timeout)
        let deadline = Date().addingTimeInterval(timeout)
        let forceKillDeadline = Date().addingTimeInterval(forceKillAfter)
        var didForceKill = false

        while Date() < deadline {
            if sessions.allSatisfy({ !$0.isRunning }) {
                return true
            }

            if !didForceKill, Date() >= forceKillDeadline {
                forceKillRunningSessions(sessions, onForceKill: onForceKill)
                didForceKill = true
            }

            Thread.sleep(forTimeInterval: min(max(0.005, pollInterval), max(0.005, deadline.timeIntervalSinceNow)))
        }

        if !didForceKill {
            forceKillRunningSessions(sessions, onForceKill: onForceKill)
        }
        return sessions.allSatisfy({ !$0.isRunning })
    }

    private static func forceKillRunningSessions(
        _ sessions: [SSHProcessSession],
        onForceKill: ((SSHProcessSession) -> Void)?
    ) {
        for session in sessions where session.isRunning {
            onForceKill?(session)
            session.forceKill()
        }
    }
}

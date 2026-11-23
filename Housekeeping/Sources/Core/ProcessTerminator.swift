// Housekeeping — ending a process, with or without root
//
// Any process the reader owns can be signalled directly. A root daemon cannot:
// kill() returns EPERM, and the old answer was an administrator password dialog
// every time. The helper does those, silently, once it has been installed.

import Foundation
import Darwin
import AppKit

enum ProcessTerminator {

    /// Returns nil on success, or a short reason the process could not be ended.
    @discardableResult
    static func terminate(pid: pid_t, graceSeconds: Double = 0.9) async -> String? {
        guard pid > 1, pid != getpid() else { return "That process id is not valid." }

        var denied = false
        if kill(pid, SIGTERM) != 0 {
            if errno == EPERM {
                denied = true
            } else if errno == ESRCH {
                return nil // already gone
            } else {
                denied = true
            }
        }

        if denied {
            let request = HelperRequest(command: .killPID, pid: pid, signal: SIGTERM)
            guard let reply = try? await PrivilegedHelper.shared.call(request), reply.ok else {
                return "macOS would not let Housekeeper stop PID \(pid). Install the one-time helper to stop root services."
            }
        }

        try? await Task.sleep(nanoseconds: UInt64(graceSeconds * 1_000_000_000))
        if kill(pid, 0) != 0 { return nil }

        // Still there. Ask again, this time without the option to ignore it.
        if kill(pid, SIGKILL) != 0 {
            _ = try? await PrivilegedHelper.shared.call(
                HelperRequest(command: .killPID, pid: pid, signal: SIGKILL)
            )
        }
        try? await Task.sleep(nanoseconds: 350_000_000)
        return kill(pid, 0) == 0
            ? "PID \(pid) is still running. macOS restarted it, or it is protected."
            : nil
    }
}

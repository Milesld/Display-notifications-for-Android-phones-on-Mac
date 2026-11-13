import Foundation
import Darwin

enum ScreenLockResult: Equatable {
    case locked(via: String)
    case failed(String)

    var summary: String {
        switch self {
        case .locked(let via):
            return "已锁定屏幕（\(via)）"
        case .failed(let reason):
            return "锁屏失败：\(reason)"
        }
    }
}

/// Locks the current user session.
///
/// macOS has never exposed a public "lock now" API. The primary path calls
/// loginwindow's private SACLockScreenImmediate, the same lock-screen action as
/// the Ctrl-Cmd-Q shortcut. Older systems may still have CGSession -suspend.
/// If neither lock-only API exists, this returns a failure instead of sleeping
/// the system or the display: a lock request must not turn into sleep.
final class ScreenLocker {
    private typealias LockFunction = @convention(c) () -> Void

    private static let loginFrameworkPath =
        "/System/Library/PrivateFrameworks/login.framework/Versions/A/login"
    private static let cgsessionPaths = [
        "/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession",
        "/System/Library/CoreServices/CGSession"
    ]

    private var loginHandle: UnsafeMutableRawPointer?
    private var didTryLoadingLogin = false

    func lock() -> ScreenLockResult {
        if lockWithLoginWindow() {
            return .locked(via: "loginwindow")
        }
        if lockWithCGSession() {
            return .locked(via: "CGSession")
        }
        return .failed("找不到可用的锁屏接口；已拒绝用睡眠代替")
    }

    private func lockWithLoginWindow() -> Bool {
        if !didTryLoadingLogin {
            didTryLoadingLogin = true
            loginHandle = dlopen(Self.loginFrameworkPath, RTLD_LAZY)
            if loginHandle == nil {
                let reason = dlerror().map { String(cString: $0) } ?? "unknown"
                AppLogger.error("Unable to load login.framework for screen lock: \(reason)")
            }
        }

        guard let loginHandle,
              let symbol = dlsym(loginHandle, "SACLockScreenImmediate") else {
            AppLogger.error("SACLockScreenImmediate is unavailable; trying CGSession")
            return false
        }

        let lock = unsafeBitCast(symbol, to: LockFunction.self)
        lock()
        return true
    }

    private func lockWithCGSession() -> Bool {
        guard let path = Self.cgsessionPaths.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else {
            AppLogger.error("CGSession is unavailable")
            return false
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["-suspend"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                AppLogger.error("CGSession -suspend exited with status \(process.terminationStatus)")
                return false
            }
            return true
        } catch {
            AppLogger.error("CGSession -suspend failed: \(error.localizedDescription)")
            return false
        }
    }
}

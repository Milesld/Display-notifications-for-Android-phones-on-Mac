import Foundation
import NotifyBridgeCore

/// Owns the grace-period countdown between a trusted BLE link loss and the
/// screen lock. A reconnect, a manual disconnect, sleep/wake, settings changes
/// or user cancellation all cancel the pending lock.
final class AutoLockController {
    var onStateChange: (() -> Void)?

    private let presenter: NotificationPresenter
    private let locker = ScreenLocker()

    private var pendingWork: DispatchWorkItem?
    private var pendingDelay: TimeInterval = 0
    private var pendingStartedAt: Date?
    private var pendingActivity: NSObjectProtocol?
    private var countdownTimer: Timer?
    private var lastArmableLoss: AutoLockLinkLoss?
    private var linkIsUp = true

    init(presenter: NotificationPresenter) {
        self.presenter = presenter
    }

    var isPending: Bool {
        pendingWork != nil
    }

    var pendingStatus: String? {
        guard isPending, let pendingStartedAt else { return nil }
        let remaining = max(0, Int(ceil(pendingDelay - Date().timeIntervalSince(pendingStartedAt))))
        return remaining > 0 ? "手机已离开，\(remaining) 秒后锁屏…" : "手机已离开，即将锁屏…"
    }

    /// Called for every non-manual, non-sleep disconnect of the trusted link.
    func handleLinkLoss(_ loss: AutoLockLinkLoss) {
        linkIsUp = false

        guard AutoLockSettings.enabled else {
            AppLogger.info("Auto-lock is disabled; ignoring link loss (rssi=\(rssiText(loss.lastRSSI)))")
            return
        }

        let decision = AutoLockPolicy.decide(
            loss,
            rssiThreshold: AutoLockSettings.rssiThreshold,
            maxRSSIAge: AutoLockSettings.maxRSSIAge,
            minimumSessionDuration: AutoLockSettings.minimumSessionDuration
        )
        guard decision.shouldArm else {
            AppLogger.info(
                "Auto-lock skipped: \(decision) (rssi=\(rssiText(loss.lastRSSI)) dBm, " +
                "age=\(format(loss.rssiAge))s, session=\(format(loss.sessionDuration))s)"
            )
            return
        }

        lastArmableLoss = loss
        arm(after: AutoLockSettings.delay, loss: loss)
    }

    /// Called when any new BLE connection is established. The phone is back in
    /// range even if pairing has not completed yet, so a pending lock is stale.
    func handleLinkRestored() {
        linkIsUp = true
        guard isPending else { return }
        cancel(reason: "手机重新连接")
    }

    func cancel(reason: String) {
        guard pendingWork != nil else { return }
        clearPendingState()
        AppLogger.info("Auto-lock cancelled: \(reason)")
        onStateChange?()
    }

    /// Called after the user enables/disables the feature or changes its delay.
    func settingsDidChange() {
        guard isPending else { return }
        if !AutoLockSettings.enabled {
            cancel(reason: "自动锁屏已关闭")
        }
    }

    func delayDidChange() {
        guard isPending, let loss = lastArmableLoss else { return }
        // Re-arm with the new delay instead of silently dropping the pending
        // lock. The phone is still away; only the countdown changed.
        cancel(reason: "锁屏延迟已修改，重新计时")
        arm(after: AutoLockSettings.delay, loss: loss)
    }

    /// Used by the menu's explicit test item. It bypasses the BLE trigger but
    /// still goes through the same ScreenLocker implementation.
    @discardableResult
    func lockNowForTesting() -> ScreenLockResult {
        cancel(reason: "开始手动锁屏测试")
        let result = locker.lock()
        AppLogger.info("Manual screen lock test: \(result.summary)")
        return result
    }

    private func arm(after delay: TimeInterval, loss: AutoLockLinkLoss) {
        if isPending {
            clearPendingState()
        }

        linkIsUp = false
        pendingDelay = max(0, delay)
        pendingStartedAt = Date()

        if pendingDelay > 0 {
            pendingActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .automaticTerminationDisabled, .suddenTerminationDisabled],
                reason: "Keep the auto-lock countdown alive"
            )
            presenter.showAutoLockWarning(seconds: Int(ceil(pendingDelay)))
        }

        let work = DispatchWorkItem { [weak self] in
            self?.fire()
        }
        pendingWork = work
        if pendingDelay > 0 {
            // Refresh the menu's remaining-seconds text while the countdown is
            // active. The activity above keeps App Nap from stretching it.
            let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.onStateChange?()
            }
            RunLoop.main.add(timer, forMode: .common)
            countdownTimer = timer
        }
        AppLogger.info(
            "Auto-lock armed: rssi=\(rssiText(loss.lastRSSI)) dBm, " +
            "age=\(format(loss.rssiAge))s, session=\(format(loss.sessionDuration))s, " +
            "delay=\(format(pendingDelay))s"
        )
        onStateChange?()
        DispatchQueue.main.asyncAfter(deadline: .now() + pendingDelay, execute: work)
    }

    private func fire() {
        guard let work = pendingWork, !work.isCancelled else { return }

        let delay = pendingDelay
        clearPendingState()

        guard AutoLockSettings.enabled else {
            AppLogger.info("Auto-lock timer fired, but the feature was disabled")
            onStateChange?()
            return
        }
        guard !linkIsUp else {
            AppLogger.info("Auto-lock timer fired, but the link is back")
            onStateChange?()
            return
        }

        let result = locker.lock()
        AppLogger.info("Auto-lock fired after \(format(delay))s: \(result.summary)")
        onStateChange?()
    }

    private func clearPendingState() {
        pendingWork?.cancel()
        pendingWork = nil
        pendingDelay = 0
        pendingStartedAt = nil
        countdownTimer?.invalidate()
        countdownTimer = nil
        if let pendingActivity {
            ProcessInfo.processInfo.endActivity(pendingActivity)
            self.pendingActivity = nil
        }
        presenter.clearAutoLockWarning()
    }

    private func rssiText(_ value: Int?) -> String {
        value.map(String.init) ?? "nil"
    }

    private func format(_ value: TimeInterval) -> String {
        String(format: "%.1f", value)
    }
}

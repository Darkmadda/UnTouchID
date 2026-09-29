import Foundation
import CryptoKit
import TouchBridgeProtocol

/// The result of an attempt to unlock the login keychain via a phone.
public enum KeychainUnlockOutcome: Sendable, Equatable {
    /// The keychain was locked and is now unlocked.
    case unlocked
    /// The keychain was already unlocked — nothing to do.
    case alreadyUnlocked
    /// The feature isn't set up (`keychain-setup` hasn't run).
    case notConfigured
    /// No enrolled phone was connected/reachable within the wait window.
    case noDeviceConnected
    /// The handshake or unlock failed; the string is a short machine reason.
    case failed(String)
}

/// Opt-in keychain unlock: after a phone approves a screen/login unlock, the
/// daemon asks it to unwrap the (decoupled, random) login-keychain password so
/// the keychain unlocks in lock-step with the session — the behaviour Touch ID
/// gives natively but a third-party PAM module otherwise can't.
///
/// Every step here is inert unless the user has run `keychain-setup`
/// (`keychainStore.isActive()`), so a stock install behaves exactly as before.
extension DaemonCoordinator {

    /// PAM services for which a successful auth should also unlock the keychain.
    /// `sudo` is deliberately excluded — it is a shell action, not a session
    /// unlock, and shouldn't touch the login keychain.
    static let keychainUnlockServices: Set<String> = [
        "screensaver", "login", "screensaver_new", "authorization",
    ]

    // MARK: - Enrollment (phone → Mac)

    /// Handle a `keychainEnroll` message: store the phone's biometric-gated
    /// key-agreement public key. Only accepted from a session that has already
    /// identified as a known paired device, so a stranger can't enroll.
    /// Handle a `keychainEnroll` message. Never throws out to the pairing path —
    /// an enroll failure must not be answered with a pairing rejection.
    func handleKeychainEnroll(data: Data, from centralID: UUID) async {
        guard let session = stateLock.withLock({ sessions[centralID] }),
              let crypto = session.sessionCrypto else {
            logger.warning("keychainEnroll from \(centralID): no session crypto — ignoring")
            return
        }
        guard let sessionDeviceID = session.deviceID else {
            logger.warning("keychainEnroll from \(centralID): session not identified — ignoring")
            return
        }

        let msg: KeychainEnrollMessage
        do {
            let plaintext = try crypto.decrypt(ciphertext: Data(data.dropFirst(2)))
            msg = try WireFormat.decodePayload(KeychainEnrollMessage.self, from: plaintext)
        } catch {
            logger.warning("keychainEnroll from \(centralID): could not decode — ignoring")
            return
        }

        // The enrolling device must be the one that identified on this session.
        guard msg.deviceID == sessionDeviceID else {
            logger.warning("keychainEnroll deviceID \(msg.deviceID) != session \(sessionDeviceID) — ignoring")
            return
        }

        // It must also be a genuinely paired device.
        let displayName: String
        do {
            displayName = try deviceStore.retrievePairedDevice(deviceID: msg.deviceID).displayName
        } catch {
            logger.warning("keychainEnroll from unpaired device \(msg.deviceID) — ignoring")
            return
        }

        do {
            try keychainStore.upsertEnrollment(
                deviceID: msg.deviceID,
                displayName: displayName,
                unlockPublicKey: msg.unlockPublicKey
            )
        } catch {
            logger.error("keychainEnroll: failed to persist — \(error.localizedDescription)")
            return
        }
        logger.info("Keychain-unlock key enrolled for \(displayName) (\(msg.deviceID))")

        await auditLog.log(AuditEntry(
            sessionID: centralID.uuidString,
            surface: "keychain_enroll",
            companionDevice: displayName,
            deviceID: msg.deviceID,
            result: "ENROLLED"
        ))
    }

    // MARK: - Unlock handshake (Mac ↔ phone)

    /// After a verified screen/login auth, unlock the keychain if configured and
    /// currently locked. Never blocks the auth path (called from a detached Task).
    ///
    /// The companion routinely drops and re-establishes the BLE link right after a
    /// screen unlock, so the session that answered the challenge is often gone by
    /// the time this runs. Rather than fire once at that exact session and give up
    /// silently, prefer it but wait briefly for it (or any enrolled phone) to be
    /// reachable — and audit the give-up so the failure is diagnosable.
    func unlockKeychainAfterAuth(service: String, winner: AuthWinner) async {
        guard Self.keychainUnlockServices.contains(service) else { return }
        guard keychainStore.isActive(), let path = keychainStore.keychainPath() else { return }
        // PAM returns before macOS has finished the screen-unlock authorization,
        // and the rest of that flow can lock the login keychain a moment *after*
        // our module approved (observed on macOS 26: unlocked at approval time,
        // locked seconds later, so a single check here skipped the unlock). So
        // if it's usable right now, keep watching for a short window instead of
        // giving up. A stale "unlocked" keychain counts as needing unlock.
        if keychainState(path: path) == .unlocked {
            let started = Date()
            guard await waitForKeychainToNeedUnlock(path: path, window: Self.postAuthKeychainWatchSeconds) else {
                logger.info("Keychain stayed unlocked after \(service) auth — nothing to do")
                await auditLog.log(AuditEntry(sessionID: UUID().uuidString, surface: "keychain_unlock",
                                              deviceID: winner.deviceID, result: "SKIPPED_UNLOCKED"))
                return
            }
            let delayMs = Int(Date().timeIntervalSince(started) * 1000)
            logger.info("Keychain locked \(delayMs)ms after \(service) auth — unlocking via phone")
            await auditLog.log(AuditEntry(sessionID: UUID().uuidString, surface: "keychain_unlock",
                                          deviceID: winner.deviceID, result: "LOCKED_AFTER_AUTH",
                                          latencyMs: delayMs))
        }

        guard let target = await waitForEnrolledTarget(preferred: winner.centralID, timeout: 8) else {
            logger.warning("Keychain unlock after auth: no enrolled phone reachable (winner \(winner.deviceID))")
            await auditLog.log(AuditEntry(sessionID: UUID().uuidString, surface: "keychain_unlock",
                                          deviceID: winner.deviceID, result: "FAILED_NO_DEVICE"))
            return
        }
        _ = await performKeychainUnlock(centralID: target.centralID,
                                        deviceID: target.deviceID,
                                        reason: "unlock your Mac keychain")
    }

    /// On-demand keychain unlock (menu-bar "Unlock Keychain Now", or any caller
    /// that isn't tied to a specific PAM auth). Waits up to `waitForDevice` for an
    /// enrolled phone to be reachable, then runs the handshake. Every outcome —
    /// including "no phone connected" — is reported and audited.
    public func requestKeychainUnlock(reason: String, waitForDevice: TimeInterval) async -> KeychainUnlockOutcome {
        guard keychainStore.isActive(), let path = keychainStore.keychainPath() else {
            return .notConfigured
        }
        if keychainState(path: path) == .unlocked {
            return .alreadyUnlocked
        }
        guard let target = await waitForEnrolledTarget(preferred: nil, timeout: waitForDevice) else {
            logger.warning("Keychain unlock (on demand): no enrolled phone connected")
            await auditLog.log(AuditEntry(sessionID: UUID().uuidString, surface: "keychain_unlock",
                                          result: "FAILED_NO_DEVICE"))
            return .noDeviceConnected
        }
        return await performKeychainUnlock(centralID: target.centralID,
                                           deviceID: target.deviceID,
                                           reason: reason)
    }

    /// How long to keep watching the keychain after a session-unlock auth.
    static let postAuthKeychainWatchSeconds: TimeInterval = 20

    /// Poll the keychain state for up to `window` seconds. Returns true as soon
    /// as it is locked, stale, or unreadable; false if it stayed usable.
    func waitForKeychainToNeedUnlock(path: String, window: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(window)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if keychainState(path: path) != .unlocked { return true }
        }
        return false
    }

    /// Poll for a connected, identified phone that has a wrapped secret ready, up
    /// to `timeout`. If `preferred` is given and becomes ready it wins; otherwise
    /// the first ready phone does. Returns nil if none appears in time.
    func waitForEnrolledTarget(preferred: UUID?, timeout: TimeInterval) async -> AuthWinner? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let ready: [AuthWinner] = stateLock.withLock {
                sessions.compactMap { (centralID, state) in
                    guard state.sessionCrypto != nil, let deviceID = state.deviceID else { return nil }
                    return (centralID: centralID, deviceID: deviceID)
                }
            }.filter { keychainStore.wrappedSecret(forDeviceID: $0.deviceID) != nil }

            if let preferred, let match = ready.first(where: { $0.centralID == preferred }) {
                return match
            }
            if let first = ready.first { return first }
            if Date() >= deadline { return nil }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    /// On daemon start (i.e. at login), proactively unlock the keychain via the
    /// phone so the user gets a single Face ID prompt at login instead of having
    /// to lock and unlock the screen first. Waits up to `timeout` for a suitable
    /// enrolled phone to connect.
    public func startKeychainAutoUnlock(timeout: TimeInterval = 60) {
        guard keychainStore.isActive() else { return }
        Task { [weak self] in
            guard let self else { return }
            let deadline = Date().addingTimeInterval(timeout)
            // Only bother if the keychain is actually locked.
            if let path = self.keychainStore.keychainPath(),
               self.keychainState(path: path) == .unlocked {
                return
            }
            while Date() < deadline {
                if let target = self.connectedEnrolledTarget() {
                    self.logger.info("Startup keychain unlock: found enrolled phone \(target.deviceID)")
                    await self.performKeychainUnlock(
                        centralID: target.centralID,
                        deviceID: target.deviceID,
                        reason: "unlock your Mac keychain at login"
                    )
                    return
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            self.logger.info("Startup keychain unlock: no enrolled phone connected within \(Int(timeout))s")
        }
    }

    /// A currently-connected, identified session whose device has a wrapped
    /// secret ready — the first such device, for startup auto-unlock.
    func connectedEnrolledTarget() -> AuthWinner? {
        let identified: [AuthWinner] = stateLock.withLock {
            sessions.compactMap { (centralID, state) in
                guard state.sessionCrypto != nil, let deviceID = state.deviceID else { return nil }
                return (centralID: centralID, deviceID: deviceID)
            }
        }
        return identified.first { keychainStore.wrappedSecret(forDeviceID: $0.deviceID) != nil }
    }

    /// Run one unlock handshake with a specific phone, then unlock the keychain.
    @discardableResult
    func performKeychainUnlock(centralID: UUID, deviceID: String, reason: String) async -> KeychainUnlockOutcome {
        guard let path = keychainStore.keychainPath() else { return .notConfigured }

        // Skip if already unlocked and usable (cheap, avoids a needless Face ID).
        let initialState = keychainState(path: path)
        if initialState == .unlocked { return .alreadyUnlocked }
        if initialState == .stale {
            logger.warning("Keychain reports unlocked but is unusable (stale key) — will re-lock and unlock")
            await auditLog.log(AuditEntry(sessionID: UUID().uuidString, surface: "keychain_unlock",
                                          deviceID: deviceID, result: "STALE_DETECTED"))
        }

        guard let wrapped = keychainStore.wrappedSecret(forDeviceID: deviceID) else {
            logger.warning("Keychain unlock: device \(deviceID) has no wrapped secret — skipping")
            await auditLog.log(AuditEntry(sessionID: UUID().uuidString, surface: "keychain_unlock",
                                          deviceID: deviceID, result: "FAILED_NO_SECRET"))
            return .failed("no_secret")
        }
        guard let crypto = stateLock.withLock({ sessions[centralID]?.sessionCrypto }) else {
            logger.warning("Keychain unlock: no session crypto for \(centralID) — skipping")
            await auditLog.log(AuditEntry(sessionID: UUID().uuidString, surface: "keychain_unlock",
                                          deviceID: deviceID, result: "FAILED_NO_SESSION"))
            return .failed("no_session")
        }

        let requestID = UUID()
        let requestMsg = KeychainUnlockRequestMessage(
            requestID: requestID.uuidString,
            ephemeralPublicKey: wrapped.ephemeralPublicKey,
            reason: reason
        )

        // Frame + session-encrypt, then notify the phone on the challenge channel.
        let wire: Data
        do {
            let payload = try JSONEncoder().withoutSlashEscaping.encode(requestMsg)
            let encrypted = try crypto.encrypt(plaintext: payload)
            var framed = Data([TouchBridgeConstants.protocolVersion, MessageType.keychainUnlockRequest.rawValue])
            framed.append(encrypted)
            wire = framed
        } catch {
            logger.error("Keychain unlock: failed to build request — \(error.localizedDescription)")
            await auditLog.log(AuditEntry(sessionID: requestID.uuidString, surface: "keychain_unlock",
                                          deviceID: deviceID, result: "FAILED_BUILD"))
            return .failed("build_error")
        }

        // Await the phone's shared-secret reply, racing a timeout. `sendFailed`
        // distinguishes "couldn't even notify the phone" from a genuine timeout.
        let sendFailed = LockedBox<Bool>(false)
        let sharedSecret: Data? = await withCheckedContinuation { outer in
            let cont = UnlockContinuation(outer)
            stateLock.withLock { pendingUnlocks[requestID] = cont }

            guard bleServer.sendChallenge(wire, to: centralID) else {
                sendFailed.mutate { $0 = true }
                stateLock.withLock { _ = pendingUnlocks.removeValue(forKey: requestID) }
                cont.resume(returning: nil)
                return
            }

            Task {
                try? await Task.sleep(nanoseconds: UInt64(TouchBridgeConstants.keychainUnlockTimeoutSeconds * 1_000_000_000))
                cont.resume(returning: nil)
            }
        }
        stateLock.withLock { _ = pendingUnlocks.removeValue(forKey: requestID) }

        guard let sharedSecret else {
            if sendFailed.value {
                logger.warning("Keychain unlock: could not send request to \(deviceID)")
                await auditLog.log(AuditEntry(sessionID: requestID.uuidString, surface: "keychain_unlock",
                                              deviceID: deviceID, result: "FAILED_SEND"))
                return .failed("send_failed")
            }
            logger.warning("Keychain unlock: no response from \(deviceID) (timeout)")
            await auditLog.log(AuditEntry(sessionID: requestID.uuidString, surface: "keychain_unlock",
                                          deviceID: deviceID, result: "FAILED_TIMEOUT"))
            return .failed("timeout")
        }

        // Unwrap → password → unlock. The plaintext lives only in this scope.
        var password: Data
        do {
            password = try KeychainSecretCrypto.unwrap(wrapped, rawSharedSecret: sharedSecret)
        } catch {
            logger.error("Keychain unlock: unwrap failed — \(error.localizedDescription)")
            await auditLog.log(AuditEntry(sessionID: requestID.uuidString, surface: "keychain_unlock",
                                          deviceID: deviceID, result: "FAILED_UNWRAP"))
            return .failed("unwrap_failed")
        }
        defer { for i in password.indices { password[i] = 0 } }

        // A stale keychain is "unlocked" already, so SecKeychainUnlock would be a
        // no-op that leaves the bad cached key in place. Lock it first so the
        // unlock re-derives the key from the file. Re-check now: the state may
        // have changed while the phone was prompting.
        if keychainState(path: path) == .stale {
            do {
                try keychainUnlocker.lock(path: path)
            } catch {
                logger.error("Keychain unlock: could not re-lock stale keychain — \(error.localizedDescription)")
                await auditLog.log(AuditEntry(sessionID: requestID.uuidString, surface: "keychain_unlock",
                                              deviceID: deviceID, result: "FAILED_RELOCK"))
                return .failed("relock_failed")
            }
        }

        do {
            let pwString = String(decoding: password, as: UTF8.self)
            try keychainUnlocker.unlock(path: path, password: pwString)
        } catch {
            // The wrapped password was decrypted fine but the keychain rejected
            // it: the keychain's password was changed outside TouchBridge (e.g.
            // macOS re-synced it to the login password). Re-run keychain-setup.
            logger.error("Keychain unlock: keychain rejected the stored password — \(error.localizedDescription)")
            await auditLog.log(AuditEntry(sessionID: requestID.uuidString, surface: "keychain_unlock",
                                          deviceID: deviceID, result: "FAILED_WRONG_PASSWORD"))
            return .failed("wrong_password")
        }

        // Only report success if the keychain is actually usable now.
        if let after = keychainState(path: path), after != .unlocked {
            logger.error("Keychain unlock: still unusable after unlock")
            await auditLog.log(AuditEntry(sessionID: requestID.uuidString, surface: "keychain_unlock",
                                          deviceID: deviceID, result: "FAILED_VERIFY"))
            return .failed("verify_failed")
        }
        logger.info("Keychain unlocked via \(deviceID)")
        await auditLog.log(AuditEntry(sessionID: requestID.uuidString, surface: "keychain_unlock",
                                      deviceID: deviceID, result: "UNLOCKED"))
        return .unlocked
    }

    /// Usable lock state of the managed keychain, or nil if it can't be read
    /// (callers then proceed as if it needs unlocking).
    func keychainState(path: String) -> KeychainLockState? {
        try? keychainUnlocker.lockState(path: path)
    }

    /// Handle a `keychainUnlockResponse`: decrypt and resume the waiting handshake.
    func handleKeychainUnlockResponse(payload: Data, from centralID: UUID) throws {
        guard let crypto = stateLock.withLock({ sessions[centralID]?.sessionCrypto }) else {
            logger.warning("keychainUnlockResponse from \(centralID): no session crypto — ignoring")
            return
        }
        let plaintext = try crypto.decrypt(ciphertext: payload)
        let msg = try WireFormat.decodePayload(KeychainUnlockResponseMessage.self, from: plaintext)

        guard let requestID = UUID(uuidString: msg.requestID) else {
            logger.error("keychainUnlockResponse: invalid requestID")
            return
        }
        let cont = stateLock.withLock { pendingUnlocks.removeValue(forKey: requestID) }
        cont?.resume(returning: msg.sharedSecret)
    }
}

// MARK: - Helpers

private extension JSONEncoder {
    /// A JSONEncoder that doesn't escape forward slashes, keeping base64 fields
    /// compact enough for the 256-byte BLE frame (matches `WireFormat`).
    var withoutSlashEscaping: JSONEncoder {
        outputFormatting = .withoutEscapingSlashes
        return self
    }
}

import Foundation
import CryptoKit
import TouchBridgeProtocol

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
    func unlockKeychainAfterAuth(service: String, winner: AuthWinner) async {
        guard Self.keychainUnlockServices.contains(service) else { return }
        guard keychainStore.isActive() else { return }
        await performKeychainUnlock(centralID: winner.centralID,
                                    deviceID: winner.deviceID,
                                    reason: "unlock your Mac keychain")
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
               (try? self.keychainUnlocker.isLocked(path: path)) == false {
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
    func performKeychainUnlock(centralID: UUID, deviceID: String, reason: String) async {
        guard let path = keychainStore.keychainPath() else { return }

        // Skip if already unlocked (cheap, avoids a needless Face ID).
        if (try? keychainUnlocker.isLocked(path: path)) == false { return }

        guard let wrapped = keychainStore.wrappedSecret(forDeviceID: deviceID) else {
            logger.warning("Keychain unlock: device \(deviceID) has no wrapped secret — skipping")
            return
        }
        guard let crypto = stateLock.withLock({ sessions[centralID]?.sessionCrypto }) else {
            logger.warning("Keychain unlock: no session crypto for \(centralID) — skipping")
            return
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
            return
        }

        // Await the phone's shared-secret reply, racing a timeout.
        let sharedSecret: Data? = await withCheckedContinuation { outer in
            let cont = UnlockContinuation(outer)
            stateLock.withLock { pendingUnlocks[requestID] = cont }

            guard bleServer.sendChallenge(wire, to: centralID) else {
                stateLock.withLock { _ = pendingUnlocks.removeValue(forKey: requestID) }
                cont.resume(returning: nil)
                return
            }

            Task {
                try? await Task.sleep(nanoseconds: UInt64(TouchBridgeConstants.responseTimeoutSeconds * 1_000_000_000))
                cont.resume(returning: nil)
            }
        }
        stateLock.withLock { _ = pendingUnlocks.removeValue(forKey: requestID) }

        guard let sharedSecret else {
            logger.warning("Keychain unlock: no response from \(deviceID) (timeout)")
            await auditLog.log(AuditEntry(sessionID: requestID.uuidString, surface: "keychain_unlock",
                                          deviceID: deviceID, result: "FAILED_TIMEOUT"))
            return
        }

        // Unwrap → password → unlock. The plaintext lives only in this scope.
        do {
            var password = try KeychainSecretCrypto.unwrap(wrapped, rawSharedSecret: sharedSecret)
            defer { for i in password.indices { password[i] = 0 } }
            let pwString = String(decoding: password, as: UTF8.self)
            try keychainUnlocker.unlock(path: path, password: pwString)
            logger.info("Keychain unlocked via \(deviceID)")
            await auditLog.log(AuditEntry(sessionID: requestID.uuidString, surface: "keychain_unlock",
                                          deviceID: deviceID, result: "UNLOCKED"))
        } catch {
            logger.error("Keychain unlock failed: \(error.localizedDescription)")
            await auditLog.log(AuditEntry(sessionID: requestID.uuidString, surface: "keychain_unlock",
                                          deviceID: deviceID, result: "FAILED_UNWRAP"))
        }
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

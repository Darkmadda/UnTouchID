import ArgumentParser
import Foundation
import Security
import TouchBridgeCore
import TouchBridgeProtocol

// MARK: - keychain

/// `touchbridge-test keychain …` — set up, inspect, and recover the opt-in
/// "unlock the login keychain from your phone" feature.
struct KeychainCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "keychain",
        abstract: "Set up or recover phone-driven login-keychain unlock (opt-in).",
        subcommands: [KeychainSetup.self, KeychainStatus.self, KeychainRecover.self]
    )
}

// MARK: - Shared helpers

enum KeychainCLIError: Error, CustomStringConvertible {
    case message(String)
    var description: String { if case .message(let m) = self { return m } else { return "error" } }
}

/// Read a secret from the terminal without echoing it.
func readSecret(prompt: String) -> String {
    guard let raw = getpass(prompt) else { return "" }
    return String(cString: raw)
}

/// Generate a strong random password (base64 of 24 random bytes).
func generateRandomPassword() throws -> String {
    var bytes = [UInt8](repeating: 0, count: 24)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
        throw KeychainCLIError.message("Failed to generate secure random password.")
    }
    return Data(bytes).base64EncodedString()
}

// MARK: - keychain setup

struct KeychainSetup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "Re-key the login keychain to a random password and wrap it to your paired phone(s)."
    )

    @Option(name: .long, help: "Login keychain path (default: ~/Library/Keychains/login.keychain-db).")
    var keychain: String?

    func run() throws {
        let store = KeychainSecretStore.standard()
        let unlocker: KeychainUnlocking = SystemKeychainUnlocker()
        let path = keychain ?? defaultLoginKeychainPath()

        let enrollments = try store.enrollments()
        guard !enrollments.isEmpty else {
            throw KeychainCLIError.message("""
            No phone has enrolled a keychain-unlock key yet.

            On your paired iPhone: open TouchBridge → Settings → turn on
            "Unlock Mac keychain", keep the phone connected, then re-run:
                touchbridge-test keychain setup
            """)
        }

        print("=== TouchBridge keychain unlock — setup ===\n")
        print("This will change your login keychain's password to a NEW random value,")
        print("decoupling it from your macOS account password, and wrap that random")
        print("password so each of these paired phones can unlock it:\n")
        for e in enrollments {
            print("  • \(e.displayName) (\(e.deviceID))")
        }
        print("""

        You will be shown the new random password ONCE. Save it in your password
        manager — it is your recovery if every phone is lost or the daemon is
        removed (see: touchbridge-test keychain recover).

        """)

        // Current keychain password: the account password on first run, or the
        // previously-set random password when rotating. Verify by unlocking.
        let current = readSecret(prompt: "Current keychain password (account password on first setup): ")
        do {
            try unlocker.unlock(path: path, password: current)
        } catch {
            throw KeychainCLIError.message("That password did not unlock \(path). Aborting — nothing changed.")
        }

        let newPassword = try generateRandomPassword()

        // Wrap first (so we never re-key without a usable wrap), then re-key.
        var wraps: [(deviceID: String, wrapped: KeychainSecretCrypto.WrappedSecret)] = []
        for e in enrollments {
            do {
                let wrapped = try KeychainSecretCrypto.wrap(
                    secret: Data(newPassword.utf8), recipientPublicKey: e.unlockPublicKey)
                wraps.append((e.deviceID, wrapped))
            } catch {
                print("  ! Skipping \(e.displayName): unlock key is invalid (\(error)). Re-enroll on that phone.")
            }
        }
        guard !wraps.isEmpty else {
            throw KeychainCLIError.message("No usable phone keys to wrap to. Aborting — nothing changed.")
        }

        do {
            try unlocker.changePassword(path: path, oldPassword: current, newPassword: newPassword)
        } catch {
            throw KeychainCLIError.message("Failed to change the keychain password: \(error). Nothing changed.")
        }

        for w in wraps {
            try store.setWrappedSecret(forDeviceID: w.deviceID, wrapped: w.wrapped, keychainPath: path)
        }

        print("""

        ✅ Done. Keychain unlock is now ON for \(wraps.count) device(s).

        ┌──────────────────────────────────────────────────────────────┐
        │ SAVE THIS RECOVERY PASSWORD IN YOUR PASSWORD MANAGER NOW.     │
        └──────────────────────────────────────────────────────────────┘

            \(newPassword)

        It is the ONLY way back in if every paired phone is lost or the
        daemon is removed. TouchBridge does not store it in recoverable form.

        """)

        // Require explicit acknowledgement so it isn't skimmed past.
        print("Type 'saved' once you have stored it: ", terminator: "")
        let ack = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ack != "saved" {
            print("\n⚠️  Not acknowledged. The password above is still valid — save it now;")
            print("   it will not be shown again.")
        }
    }
}

// MARK: - keychain status

struct KeychainStatus: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show keychain-unlock enrollment and setup state."
    )

    func run() throws {
        let store = KeychainSecretStore.standard()
        let enrollments = try store.enrollments()

        print("TouchBridge keychain unlock")
        print("  Enabled:  \(store.isEnabled())")
        print("  Active:   \(store.isActive())  (enabled AND at least one phone wrapped)")
        print("  Keychain: \(store.keychainPath() ?? "—")")
        print("")
        if enrollments.isEmpty {
            print("  No phones enrolled. Turn on \"Unlock Mac keychain\" in the app.")
            return
        }
        print("  Enrolled phones (\(enrollments.count)):")
        for e in enrollments {
            print("    • \(e.displayName) (\(e.deviceID)) — \(e.wrapped != nil ? "ready" : "not set up (run: keychain setup)")")
        }
    }
}

// MARK: - keychain recover

struct KeychainRecover: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "recover",
        abstract: "Re-couple the login keychain to a chosen password and turn keychain unlock off."
    )

    @Option(name: .long, help: "Login keychain path (default: ~/Library/Keychains/login.keychain-db).")
    var keychain: String?

    func run() throws {
        let store = KeychainSecretStore.standard()
        let unlocker: KeychainUnlocking = SystemKeychainUnlocker()
        let path = keychain ?? defaultLoginKeychainPath()

        print("=== TouchBridge keychain unlock — recover / disable ===\n")
        print("This restores a keychain you can unlock by typing a password again")
        print("(e.g. after losing every paired phone, or before uninstalling).\n")
        print("It changes the keychain password from the current RANDOM value")
        print("(from your password manager) to a NEW one you choose — set it to")
        print("your macOS account password to restore native login unlock.\n")

        let current = readSecret(prompt: "Current keychain password (the saved random one): ")
        do {
            try unlocker.unlock(path: path, password: current)
        } catch {
            throw KeychainCLIError.message("""
            That password did not unlock \(path).

            The current password is the random value shown at setup and saved in
            your password manager — not your account password. Aborting.
            """)
        }

        let new1 = readSecret(prompt: "New keychain password (your macOS account password to re-couple): ")
        let new2 = readSecret(prompt: "Confirm new keychain password: ")
        guard new1 == new2 else {
            throw KeychainCLIError.message("Passwords did not match. Nothing changed.")
        }
        guard !new1.isEmpty else {
            throw KeychainCLIError.message("Empty password rejected. Nothing changed.")
        }

        do {
            try unlocker.changePassword(path: path, oldPassword: current, newPassword: new1)
        } catch {
            throw KeychainCLIError.message("Failed to change the keychain password: \(error). Nothing changed.")
        }

        try store.disableAndClear()

        print("""

        ✅ Recovered. The login keychain now unlocks with the password you just set,
           and TouchBridge keychain unlock is OFF (all wrapped copies discarded).

           If you set it to your account password, native login unlock works again.
           To re-enable phone unlock later: touchbridge-test keychain setup
        """)
    }
}

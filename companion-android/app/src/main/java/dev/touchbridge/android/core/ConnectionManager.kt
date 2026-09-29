package dev.touchbridge.android.core

import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.security.keystore.UserNotAuthenticatedException
import android.util.Base64
import android.util.Log
import dev.touchbridge.android.Constants
import dev.touchbridge.android.util.PermissionUtils
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import org.json.JSONObject
import java.util.UUID

enum class PairingPhase { IDLE, SCANNING, CONNECTING, WAITING_FOR_MAC, PAIRED, ERROR }

/** One paired Mac as shown in the UI. */
data class MacStatus(
    val id: String,
    /** Name to display: the user's nickname if set, else the Mac's own name. */
    val name: String,
    val isConnected: Boolean,
    /** The Mac's own computer name; equals [name] when no nickname is set. */
    val macName: String = name,
) {
    val hasNickname: Boolean get() = name != macName
}

data class TouchBridgeUiState(
    val macs: List<MacStatus> = emptyList(),
    val hasPermissions: Boolean = true,
    val statusMessage: String = "Not connected",
    val challengeCount: Int = 0,
    val lastChallenge: String? = null,
    val pairingPhase: PairingPhase = PairingPhase.IDLE,
    val pairingError: String? = null,
    /** Challenge from a Mac awaiting biometric approval (drives BiometricPrompt). */
    val pendingChallenge: PendingChallenge? = null,
    /** Keychain-unlock request awaiting biometric approval (drives BiometricPrompt). */
    val pendingUnlock: PendingUnlock? = null,
    /** Whether "Unlock Mac keychain" is on. */
    val keychainUnlockEnabled: Boolean = false,
) {
    val isPaired: Boolean get() = macs.isNotEmpty()
    val isConnected: Boolean get() = macs.any { it.isConnected }
}

/**
 * App-scoped owner of the BLE links to every paired Mac and the challenge flow.
 *
 * This lives for the life of the process (held by [dev.touchbridge.android.TouchBridgeApp]),
 * NOT the Activity — so connections survive the app being backgrounded, and
 * challenges can be handled without any UI in the foreground. The foreground
 * service keeps the process itself alive; the UI (ViewModel) and the background
 * ChallengeActivity are both thin observers of this single owner.
 *
 * Any number of Macs can be paired. One scan covers every Mac that isn't
 * currently linked; each discovered Mac gets its own GATT connection and its
 * own encrypted session. The phone presents the same identity (deviceID and
 * hardware-backed signing key) to every Mac.
 */
class ConnectionManager(context: Context) : BLEClient.Listener {

    companion object {
        private const val TAG = "TouchBridgeConn"
        /** Pause before rescanning after a link drops — avoids hammering the radio. */
        private const val RESCAN_DELAY_MS = 1500L
        /** Give up a pairing attempt after this many failed connections and tell the user. */
        private const val MAX_PAIRING_CONNECT_FAILURES = 5
    }

    private val appContext = context.applicationContext

    private val _uiState = MutableStateFlow(TouchBridgeUiState())
    val uiState: StateFlow<TouchBridgeUiState> = _uiState.asStateFlow()

    val keystoreManager = KeystoreManager()
    val bleClient = BLEClient(appContext)
    val challengeHandler = ChallengeHandler()

    private val prefs = appContext.getSharedPreferences(Constants.PREFS_NAME, Context.MODE_PRIVATE)
    private val store = PairedMacStore(prefs)
    private val mainHandler = Handler(Looper.getMainLooper())

    private val lock = Any()
    /** macId → paired Mac. Guarded by [lock]. */
    private val pairedMacs = LinkedHashMap<String, PairedMac>()

    private class PendingPairing(val mac: PairedMac, val token: ByteArray) {
        var connectFailures = 0
    }
    /** The pairing ceremony in progress, if any. Guarded by [lock]. */
    private var pendingPairing: PendingPairing? = null

    /**
     * macId → elapsedRealtime() of the last challenge this phone approved for
     * that Mac. A keychain-unlock request from the same Mac shortly afterwards
     * (the Mac asks right after a screen unlock) is answered without a second
     * prompt — see [trySilentKeychainUnlock]. One approval covers one unlock.
     */
    private val recentApprovals = HashMap<String, Long>()

    private val deviceID: String =
        prefs.getString(Constants.PREF_DEVICE_ID, null) ?: UUID.randomUUID().toString().also {
            prefs.edit().putString(Constants.PREF_DEVICE_ID, it).apply()
        }

    private val deviceName: String = Build.MODEL.take(20)

    val isPaired: Boolean get() = _uiState.value.isPaired

    init {
        bleClient.listener = this
        synchronized(lock) { store.load().forEach { pairedMacs[it.id] = it } }
        publish()
        refreshScanning()
    }

    // MARK: - State publishing

    /** Recompute the derived parts of the state (Mac list, permissions, status line). */
    private fun publish(transform: (TouchBridgeUiState) -> TouchBridgeUiState = { it }) {
        val hasPerms = PermissionUtils.hasBluetoothPermissions(appContext)
        val macs = synchronized(lock) {
            pairedMacs.values.map { MacStatus(it.id, it.displayName, bleClient.isConnected(it.id), it.name) }
        }
        _uiState.update {
            transform(it).copy(
                macs = macs,
                hasPermissions = hasPerms,
                statusMessage = statusMessage(macs, hasPerms),
                keychainUnlockEnabled = prefs.getBoolean(Constants.PREF_KEYCHAIN_UNLOCK_ENABLED, false),
            )
        }
    }

    private fun statusMessage(macs: List<MacStatus>, hasPerms: Boolean): String {
        if (!hasPerms) return "Bluetooth permissions required"
        if (!bleClient.isAdapterEnabled) return "Bluetooth is off"
        if (macs.isEmpty()) return "Not connected"
        val connected = macs.filter { it.isConnected }
        return when {
            connected.size == macs.size && macs.size == 1 -> "Connected to ${macs[0].name}"
            connected.size == macs.size -> "Connected to all ${macs.size} Macs"
            connected.isEmpty() && bleClient.isScanning -> "Looking for your Mac${if (macs.size > 1) "s" else ""}..."
            connected.isEmpty() -> "Disconnected"
            else -> "Connected to ${connected.size} of ${macs.size} Macs"
        }
    }

    private fun macName(macId: String): String = synchronized(lock) {
        pairedMacs[macId]?.displayName ?: pendingPairing?.takeIf { it.mac.id == macId }?.mac?.displayName ?: "Mac"
    }

    // MARK: - Scanning / reconnection

    /**
     * Scan for every Mac we should be linked to but aren't: all paired Macs plus
     * the one being paired. Stops scanning when there's nothing left to find.
     */
    private fun refreshScanning() {
        if (!PermissionUtils.hasBluetoothPermissions(appContext)) {
            publish()
            return
        }
        val targets = synchronized(lock) {
            val ids = pairedMacs.keys.filterTo(LinkedHashSet()) { !bleClient.hasLink(it) }
            pendingPairing?.mac?.id?.let { if (!bleClient.hasLink(it)) ids += it }
            ids
        }
        if (targets.isEmpty()) {
            bleClient.stopScanning()
        } else {
            bleClient.startScanning(targets.map(UUID::fromString))
        }
        publish()
    }

    /** Called by the foreground service to (re)establish links to paired Macs. */
    fun ensureConnected() = refreshScanning()

    /** Manual "Reconnect" from the UI. */
    fun startScanning() = refreshScanning()

    fun updatePermissionsState() = refreshScanning()

    // MARK: - Pairing

    fun startPairing(payloadJson: String) {
        val payload = PairingPayload.parse(payloadJson)
        if (payload == null) {
            publish {
                it.copy(
                    pairingPhase = PairingPhase.ERROR,
                    pairingError = "Couldn't parse pairing data — copy the full JSON from 'touchbridge-test pair'."
                )
            }
            return
        }

        if (!PermissionUtils.hasBluetoothPermissions(appContext)) {
            publish()
            return
        }

        val mac = PairedMac(
            id = PairedMac.idFor(payload.serviceUUID),
            name = payload.macName,
            pairedAt = System.currentTimeMillis(),
        )
        synchronized(lock) { pendingPairing = PendingPairing(mac, payload.pairingToken) }

        // Re-pairing an already-paired Mac starts from a clean link.
        bleClient.disconnect(mac.id)
        challengeHandler.clearSession(mac.id)

        if (!keystoreManager.hasKey(Constants.SIGNING_KEY_ALIAS)) {
            keystoreManager.generateKeyPair(Constants.SIGNING_KEY_ALIAS)
        }

        publish { it.copy(pairingPhase = PairingPhase.SCANNING, pairingError = null) }
        refreshScanning()

        if (!bleClient.isScanning) {
            synchronized(lock) { pendingPairing = null }
            publish {
                it.copy(
                    pairingPhase = PairingPhase.ERROR,
                    pairingError = "Couldn't start Bluetooth scan — is Bluetooth on?"
                )
            }
        }
    }

    /** Cancel an in-progress pairing, or dismiss a finished one. Paired Macs are untouched. */
    fun resetPairing() {
        val pending = synchronized(lock) { pendingPairing.also { pendingPairing = null } }
        if (pending != null && !isPairedMac(pending.mac.id)) {
            bleClient.disconnect(pending.mac.id)
            challengeHandler.clearSession(pending.mac.id)
        }
        publish { it.copy(pairingPhase = PairingPhase.IDLE, pairingError = null) }
        refreshScanning()
    }

    private fun isPairedMac(macId: String): Boolean = synchronized(lock) { pairedMacs.containsKey(macId) }

    private fun pendingFor(macId: String): PendingPairing? = synchronized(lock) {
        pendingPairing?.takeIf { it.mac.id == macId }
    }

    private fun completePairing(pending: PendingPairing) {
        val macs = synchronized(lock) {
            // Re-pairing refreshes the Mac's own name but keeps any nickname the user chose.
            val nickname = pairedMacs[pending.mac.id]?.nickname
            pairedMacs[pending.mac.id] = pending.mac.copy(nickname = nickname)
            pendingPairing = null
            pairedMacs.values.toList()
        }
        store.save(macs)
        publish { it.copy(pairingPhase = PairingPhase.PAIRED, pairingError = null) }
        Log.i(TAG, "Pairing accepted by ${pending.mac.name}")
    }

    private fun failPairing(pending: PendingPairing, message: String) {
        synchronized(lock) { if (pendingPairing === pending) pendingPairing = null }
        if (!isPairedMac(pending.mac.id)) {
            bleClient.disconnect(pending.mac.id)
            challengeHandler.clearSession(pending.mac.id)
        }
        publish { it.copy(pairingPhase = PairingPhase.ERROR, pairingError = message) }
        Log.w(TAG, "Pairing with ${pending.mac.name} failed: $message")
    }

    // MARK: - Renaming

    /**
     * Give a paired Mac a friendlier name, or pass blank/null to go back to the
     * name the Mac reported. Only the phone's label changes; the Mac is not told.
     */
    fun rename(macId: String, nickname: String?) {
        val macs = synchronized(lock) {
            val mac = pairedMacs[macId] ?: return
            pairedMacs[macId] = mac.withNickname(nickname)
            pairedMacs.values.toList()
        }
        store.save(macs)
        publish {
            it.copy(
                pendingChallenge = it.pendingChallenge?.let { c ->
                    if (c.macId == macId) c.copy(macName = macName(macId)) else c
                }
            )
        }
        Log.i(TAG, "Renamed Mac $macId")
    }

    // MARK: - Unpairing

    /** Forget one Mac. The signing key is kept while any other Mac remains paired. */
    fun unpair(macId: String) {
        bleClient.disconnect(macId)
        challengeHandler.clearSession(macId)

        val remaining = synchronized(lock) {
            pairedMacs.remove(macId)
            if (pendingPairing?.mac?.id == macId) pendingPairing = null
            pairedMacs.values.toList()
        }
        store.save(remaining)

        if (remaining.isEmpty()) {
            keystoreManager.deleteKey(Constants.SIGNING_KEY_ALIAS)
        }

        publish {
            it.copy(
                pendingChallenge = it.pendingChallenge?.takeUnless { c -> c.macId == macId },
                pairingPhase = if (it.pairingPhase == PairingPhase.PAIRED) PairingPhase.IDLE else it.pairingPhase,
            )
        }
        refreshScanning()
        Log.i(TAG, "Unpaired Mac $macId (${remaining.size} remaining)")
    }

    // MARK: - Challenge handling (called by ChallengeActivity after biometrics)

    /** Biometric approval succeeded — send the signed nonce back to the Mac that asked. */
    fun completeChallenge(challengeID: String, signature: ByteArray) {
        val challenge = _uiState.value.pendingChallenge?.takeIf { it.challengeID == challengeID }
        if (challenge == null) {
            Log.w(TAG, "Challenge $challengeID is no longer pending — dropping response")
            return
        }
        val wire = challengeHandler.buildResponseWire(challengeID, signature, deviceID)
        val sent = bleClient.sendResponse(challenge.macId, wire)
        Log.i(TAG, "Challenge $challengeID response to ${challenge.macName} sent=$sent")
        if (sent) {
            synchronized(lock) { recentApprovals[challenge.macId] = SystemClock.elapsedRealtime() }
        }
        publish {
            it.copy(
                pendingChallenge = null,
                challengeCount = it.challengeCount + 1,
                lastChallenge = "Approved",
            )
        }
    }

    /** Biometric denied/cancelled/failed — drop the challenge; the Mac times out. */
    fun declineChallenge() {
        Log.i(TAG, "Challenge declined")
        publish { it.copy(pendingChallenge = null, lastChallenge = "Denied") }
    }

    fun challengeKeyInvalidated(challengeID: String) {
        Log.w(TAG, "Signing key invalidated — every Mac must re-pair this device")
        val challenge = _uiState.value.pendingChallenge?.takeIf { it.challengeID == challengeID }
        if (challenge != null) {
            try {
                bleClient.sendResponse(
                    challenge.macId,
                    challengeHandler.buildKeyInvalidatedErrorWire(challenge.macId, challengeID)
                )
            } catch (e: Exception) {
                Log.e(TAG, "Failed to send key-invalidated error", e)
            }
        }
        publish {
            it.copy(
                pendingChallenge = null,
                lastChallenge = "Key invalidated — re-pair required",
                statusMessage = "Signing key invalidated — unpair and pair again",
            )
        }
    }

    // MARK: - Keychain unlock (opt-in)

    val isKeychainUnlockEnabled: Boolean
        get() = prefs.getBoolean(Constants.PREF_KEYCHAIN_UNLOCK_ENABLED, false)

    /** Whether this device can do keychain unlock (needs API 31 for PURPOSE_AGREE_KEY). */
    val keychainUnlockSupported: Boolean
        get() = Build.VERSION.SDK_INT >= Build.VERSION_CODES.S

    /**
     * Turn on keychain unlock: create the biometric-gated key-agreement key and
     * register it with every connected Mac. The user still runs
     * `touchbridge-test keychain setup` on the Mac to finish.
     */
    fun enableKeychainUnlock(): Boolean {
        if (!keychainUnlockSupported) {
            Log.w(TAG, "Keychain unlock needs Android 12+ (StrongBox key agreement)")
            return false
        }
        try {
            if (!keystoreManager.hasKey(Constants.KEYCHAIN_UNLOCK_KEY_ALIAS)) {
                keystoreManager.generateKeyAgreementKeyPair(Constants.KEYCHAIN_UNLOCK_KEY_ALIAS)
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to create keychain-unlock key", e)
            return false
        }
        prefs.edit().putBoolean(Constants.PREF_KEYCHAIN_UNLOCK_ENABLED, true).apply()
        synchronized(lock) { pairedMacs.keys.toList() }.forEach { macId ->
            if (challengeHandler.isSessionReady(macId)) sendKeychainEnroll(macId)
        }
        publish()
        Log.i(TAG, "Keychain unlock enabled")
        return true
    }

    /** Turn off keychain unlock and destroy this phone's key. */
    fun disableKeychainUnlock() {
        prefs.edit().putBoolean(Constants.PREF_KEYCHAIN_UNLOCK_ENABLED, false).apply()
        keystoreManager.deleteKey(Constants.KEYCHAIN_UNLOCK_KEY_ALIAS)
        publish()
        Log.i(TAG, "Keychain unlock disabled")
    }

    /** Decrypt an incoming keychain-unlock request and surface it for biometric approval. */
    private fun handleKeychainUnlockRequest(macId: String, data: ByteArray) {
        if (!challengeHandler.isSessionReady(macId) || data.size <= 2) return
        try {
            val plaintext = challengeHandler.decrypt(macId, data.copyOfRange(2, data.size))
            val json = JSONObject(String(plaintext))
            val unlock = PendingUnlock(
                macId = macId,
                macName = macName(macId),
                requestID = json.getString("requestID"),
                ephemeralPublicKey = Base64.decode(json.getString("ephemeralPublicKey"), Base64.DEFAULT),
                reason = json.optString("reason", "unlock your Mac keychain"),
            )
            Log.i(TAG, "Keychain unlock request ${unlock.requestID} from ${unlock.macName}")
            if (trySilentKeychainUnlock(unlock)) return
            publish { it.copy(pendingUnlock = unlock) }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to parse keychain unlock request", e)
        }
    }

    /**
     * Answer a keychain-unlock request without a second prompt when it follows
     * an approval this phone just gave the same Mac (within
     * [Constants.KEYCHAIN_SILENT_GRACE_MS]).
     *
     * The app-side window is only a policy gate; the actual authorisation is the
     * Keystore's: the key-agreement key is time-bound to a recent strong
     * biometric ([KeystoreManager.KEYCHAIN_AUTH_VALIDITY_SECONDS]), so if the
     * Keystore doesn't consider the approval's biometric fresh, ECDH throws
     * [UserNotAuthenticatedException] and we fall back to the normal prompt.
     * The grace is consumed on first use, so one approval covers one unlock.
     */
    private fun trySilentKeychainUnlock(unlock: PendingUnlock): Boolean {
        val approvedAt = synchronized(lock) { recentApprovals.remove(unlock.macId) } ?: return false
        val ageMs = SystemClock.elapsedRealtime() - approvedAt
        if (ageMs > Constants.KEYCHAIN_SILENT_GRACE_MS) {
            Log.i(TAG, "Keychain unlock ${unlock.requestID}: last approval ${ageMs}ms ago — prompting")
            return false
        }
        val shared = try {
            keystoreManager.computeSharedSecret(Constants.KEYCHAIN_UNLOCK_KEY_ALIAS, unlock.ephemeralPublicKey)
        } catch (e: UserNotAuthenticatedException) {
            Log.i(TAG, "Keychain unlock ${unlock.requestID}: Keystore wants a fresh biometric — prompting")
            return false
        } catch (e: Exception) {
            Log.w(TAG, "Keychain unlock ${unlock.requestID}: silent key agreement failed — prompting", e)
            return false
        }
        Log.i(TAG, "Keychain unlock ${unlock.requestID}: covered by approval ${ageMs}ms ago — no second prompt")
        sendKeychainUnlockResponse(unlock, shared)
        return true
    }

    /**
     * Biometric approved — the caller has already computed the ECDH shared secret
     * with the keychain-unlock key. Send it back so the Mac can unwrap and unlock.
     */
    fun completeKeychainUnlock(requestID: String, sharedSecret: ByteArray) {
        val unlock = _uiState.value.pendingUnlock?.takeIf { it.requestID == requestID }
        if (unlock == null) {
            Log.w(TAG, "Keychain unlock $requestID no longer pending — dropping")
            return
        }
        sendKeychainUnlockResponse(unlock, sharedSecret)
        publish { it.copy(pendingUnlock = null) }
    }

    private fun sendKeychainUnlockResponse(unlock: PendingUnlock, sharedSecret: ByteArray) {
        val requestID = unlock.requestID
        try {
            val payload = JSONObject()
                .put("requestID", requestID)
                .put("sharedSecret", Base64.encodeToString(sharedSecret, Base64.NO_WRAP))
                .toString().toByteArray()
            val wire = byteArrayOf(Constants.PROTOCOL_VERSION, Constants.MSG_TYPE_KEYCHAIN_UNLOCK_RESPONSE) +
                challengeHandler.encrypt(unlock.macId, payload)
            bleClient.sendResponse(unlock.macId, wire)
            Log.i(TAG, "Keychain unlock $requestID answered to ${unlock.macName}")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to send keychain unlock response", e)
        }
    }

    /** Biometric denied/cancelled/failed — drop the unlock request. */
    fun declineKeychainUnlock() {
        Log.i(TAG, "Keychain unlock declined")
        publish { it.copy(pendingUnlock = null) }
    }

    // MARK: - Wire messages

    private fun sendKeychainEnroll(macId: String) {
        try {
            val publicKey = keystoreManager.getPublicKey(Constants.KEYCHAIN_UNLOCK_KEY_ALIAS)
            val payload = JSONObject()
                .put("deviceID", deviceID)
                .put("unlockPublicKey", Base64.encodeToString(publicKey, Base64.NO_WRAP))
                .toString().toByteArray()
            val wire = byteArrayOf(Constants.PROTOCOL_VERSION, Constants.MSG_TYPE_KEYCHAIN_ENROLL) +
                challengeHandler.encrypt(macId, payload)
            bleClient.sendPairingData(macId, wire)
            Log.i(TAG, "Sent keychain enroll for device $deviceID to $macId")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to send keychain enroll", e)
        }
    }

    private fun sendPairRequest(macId: String, token: ByteArray) {
        try {
            val publicKey = keystoreManager.getPublicKey(Constants.SIGNING_KEY_ALIAS)
            val json = JSONObject()
                .put("deviceName", deviceName)
                .put("publicKey", Base64.encodeToString(publicKey, Base64.NO_WRAP))
                .put("deviceID", deviceID)
                .put("pairingToken", Base64.encodeToString(token, Base64.NO_WRAP))
            val wire = byteArrayOf(Constants.PROTOCOL_VERSION, Constants.MSG_TYPE_PAIR_REQUEST) +
                json.toString().toByteArray()
            bleClient.sendPairingData(macId, wire)
            Log.i(TAG, "Sent pairing request to $macId (${wire.size} bytes)")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to send pairing request", e)
            pendingFor(macId)?.let { failPairing(it, "Failed to send pairing request: ${e.message}") }
        }
    }

    private fun sendIdentify(macId: String) {
        try {
            val payload = JSONObject()
                .put("deviceID", deviceID)
                .put("deviceName", deviceName)
                .toString().toByteArray()
            val wire = byteArrayOf(Constants.PROTOCOL_VERSION, Constants.MSG_TYPE_IDENTIFY) +
                challengeHandler.encrypt(macId, payload)
            bleClient.sendPairingData(macId, wire)
            Log.i(TAG, "Sent identify for device $deviceID to $macId")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to send identify", e)
        }
    }

    // MARK: - BLEClient.Listener

    override fun onAdapterStateChanged(enabled: Boolean) {
        if (enabled) {
            // Give the freshly powered adapter a moment before asking it to scan.
            mainHandler.postDelayed({ refreshScanning() }, RESCAN_DELAY_MS)
        }
        publish()
    }

    override fun onDeviceDiscovered(macId: String, deviceAddress: String, rssi: Int) {
        if (bleClient.hasLink(macId)) return
        if (pendingFor(macId) != null) {
            publish {
                if (it.pairingPhase == PairingPhase.SCANNING) it.copy(pairingPhase = PairingPhase.CONNECTING) else it
            }
        }
        bleClient.connect(macId)
    }

    override fun onConnectionChanged(macId: String, connected: Boolean) {
        if (connected) {
            publish()
            // Keep looking for the other Macs once this link has had a moment to settle.
            mainHandler.postDelayed({ refreshScanning() }, RESCAN_DELAY_MS)
            return
        }

        challengeHandler.clearSession(macId)

        val pending = pendingFor(macId)
        if (pending != null) {
            pending.connectFailures++
            if (pending.connectFailures >= MAX_PAIRING_CONNECT_FAILURES) {
                failPairing(
                    pending,
                    "Your phone's Bluetooth dropped the connection ${pending.connectFailures} times. " +
                        "Close other Bluetooth apps or toggle Bluetooth off and on, then try again."
                )
            } else {
                publish {
                    if (it.pairingPhase == PairingPhase.CONNECTING || it.pairingPhase == PairingPhase.WAITING_FOR_MAC) {
                        it.copy(pairingPhase = PairingPhase.SCANNING)
                    } else it
                }
            }
        }

        publish {
            it.copy(pendingChallenge = it.pendingChallenge?.takeUnless { c -> c.macId == macId })
        }
        mainHandler.postDelayed({ refreshScanning() }, RESCAN_DELAY_MS)
    }

    override fun onReadyForSecureSession(macId: String) {
        val publicKey = challengeHandler.initiateECDH(macId)
        bleClient.sendSessionKey(macId, publicKey)
        pendingFor(macId)?.let { pending ->
            sendPairRequest(macId, pending.token)
            publish { it.copy(pairingPhase = PairingPhase.WAITING_FOR_MAC) }
        }
    }

    override fun onSessionKeyReceived(macId: String, data: ByteArray) {
        try {
            challengeHandler.completeECDH(macId, data)
        } catch (e: Exception) {
            Log.e(TAG, "ECDH with $macId failed", e)
            return
        }
        sendIdentify(macId)
        if (prefs.getBoolean(Constants.PREF_KEYCHAIN_UNLOCK_ENABLED, false)) {
            sendKeychainEnroll(macId)
        }
        publish()
    }

    override fun onChallengeReceived(macId: String, data: ByteArray) {
        // The challenge channel also carries keychain-unlock requests (type 8).
        if (data.size > 1 && data[1] == Constants.MSG_TYPE_KEYCHAIN_UNLOCK_REQUEST) {
            handleKeychainUnlockRequest(macId, data)
            return
        }

        val challenge = challengeHandler.parseChallengeWire(macId, macName(macId), data)
        if (challenge == null) {
            Log.w(TAG, "Ignoring unparseable/expired challenge from $macId")
            return
        }
        Log.i(TAG, "Challenge ${challenge.challengeID} from ${challenge.macName} pending biometric approval")
        // The foreground service observes this and launches ChallengeActivity —
        // which shows the biometric prompt even with no app UI in the foreground.
        publish { it.copy(pendingChallenge = challenge, lastChallenge = challenge.reason) }
    }

    override fun onPairingDataReceived(macId: String, data: ByteArray) {
        val pending = pendingFor(macId) ?: return

        val payload = if (data.size > 2 && data[0] == Constants.PROTOCOL_VERSION) {
            data.copyOfRange(2, data.size)
        } else {
            data
        }

        try {
            val json = JSONObject(String(payload))
            if (json.optBoolean("accepted", false)) {
                completePairing(pending)
            } else {
                failPairing(
                    pending,
                    "The Mac rejected the pairing — the token may have expired. Run 'touchbridge-test pair' again."
                )
            }
        } catch (e: Exception) {
            failPairing(pending, "Couldn't read the Mac's pairing response.")
        }
    }
}

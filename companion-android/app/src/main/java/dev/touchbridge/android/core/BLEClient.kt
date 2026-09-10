package dev.touchbridge.android.core

import android.annotation.SuppressLint
import android.bluetooth.*
import android.bluetooth.le.*
import android.content.Context
import android.os.ParcelUuid
import android.util.Log
import dev.touchbridge.android.Constants
import dev.touchbridge.android.util.PermissionUtils
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/**
 * BLE GATT client that talks to any number of paired Macs at once.
 *
 * One scan runs at a time, filtered to every Mac we still need to reach (each
 * Mac advertises its own service UUID). Each Mac that is found gets its own
 * [MacLink]: a GATT connection, its discovered characteristics, and — because
 * Android's GATT stack allows only one outstanding operation per connection —
 * its own serialized operation queue.
 *
 * Macs are identified everywhere by [PairedMac.id], the canonical string form
 * of their service UUID.
 */
@SuppressLint("MissingPermission")
class BLEClient(private val context: Context) {

    companion object {
        private const val TAG = "BLEClient"
        // Wire messages are ≤256 bytes; the default BLE MTU (23) truncates them.
        private const val REQUESTED_MTU = 517
    }

    interface Listener {
        fun onDeviceDiscovered(macId: String, deviceAddress: String, rssi: Int)
        fun onConnectionChanged(macId: String, connected: Boolean)
        /** Characteristics discovered and notifications enabled — safe to write. */
        fun onReadyForSecureSession(macId: String)
        fun onChallengeReceived(macId: String, data: ByteArray)
        fun onSessionKeyReceived(macId: String, data: ByteArray)
        fun onPairingDataReceived(macId: String, data: ByteArray)
    }

    var listener: Listener? = null

    private val bluetoothManager = context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
    private val bluetoothAdapter: BluetoothAdapter? get() = bluetoothManager.adapter
    private var scanner: BluetoothLeScanner? = null

    /** serviceUUID → macId for the scan currently running. */
    private var scanTargets: Map<UUID, String> = emptyMap()
    @Volatile
    var isScanning: Boolean = false
        private set

    /** macId → device seen in the current scan (a device is reported once per scan). */
    private val discovered = HashMap<String, BluetoothDevice>()

    /** macId → live link (connecting or connected). */
    private val links = ConcurrentHashMap<String, MacLink>()

    fun hasLink(macId: String): Boolean = links.containsKey(macId)
    fun isConnected(macId: String): Boolean = links[macId]?.connected == true
    val connectedMacIds: Set<String> get() = links.filterValues { it.connected }.keys

    // MARK: - Scanning

    /**
     * Scan for the Macs advertising any of [serviceUUIDs]. Restarts the scan if
     * the target set changed; a no-op if the same scan is already running.
     */
    fun startScanning(serviceUUIDs: Collection<UUID>): Boolean {
        val targets = serviceUUIDs.associateWith { PairedMac.idFor(it) }
        if (targets.isEmpty()) {
            stopScanning()
            return false
        }
        if (isScanning && targets.keys == scanTargets.keys) return true
        if (isScanning) stopScanning()

        if (!PermissionUtils.hasBluetoothPermissions(context)) {
            Log.w(TAG, "Cannot start scan: missing Bluetooth permissions")
            return false
        }

        try {
            val leScanner = bluetoothAdapter?.bluetoothLeScanner
            if (leScanner == null) {
                Log.w(TAG, "BluetoothLeScanner is null (Bluetooth may be off)")
                return false
            }
            scanner = leScanner

            // Stale results from a previous filter set would connect to the wrong Mac.
            synchronized(discovered) { discovered.clear() }
            scanTargets = targets

            val filters = targets.keys.map {
                ScanFilter.Builder().setServiceUuid(ParcelUuid(it)).build()
            }
            val settings = ScanSettings.Builder()
                .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
                .build()

            leScanner.startScan(filters, settings, scanCallback)
            isScanning = true
            Log.i(TAG, "Started scanning for ${targets.size} Mac(s): ${targets.keys}")
            return true
        } catch (e: SecurityException) {
            Log.e(TAG, "SecurityException while starting scan", e)
            isScanning = false
            return false
        }
    }

    fun stopScanning() {
        if (!isScanning) return
        isScanning = false
        if (!PermissionUtils.hasBluetoothPermissions(context)) return
        try {
            scanner?.stopScan(scanCallback)
        } catch (e: SecurityException) {
            Log.e(TAG, "SecurityException while stopping scan", e)
        } finally {
            Log.i(TAG, "Stopped scanning")
        }
    }

    // MARK: - Connection

    /**
     * Connect to a Mac discovered in the current scan. Scanning is paused while
     * the connection is set up (Android connects far more reliably that way);
     * the owner restarts it for any remaining Macs once this one settles.
     */
    fun connect(macId: String): Boolean {
        if (!PermissionUtils.hasBluetoothPermissions(context)) {
            Log.w(TAG, "Cannot connect: missing Bluetooth permissions")
            return false
        }
        if (links.containsKey(macId)) {
            Log.i(TAG, "Already connected/connecting to $macId — ignoring connect()")
            return true
        }
        val device = synchronized(discovered) { discovered[macId] } ?: run {
            Log.w(TAG, "connect($macId): device not seen in the current scan")
            return false
        }
        stopScanning()

        val link = MacLink(macId, device)
        links[macId] = link
        try {
            link.gatt = device.connectGatt(context, false, link.gattCallback, BluetoothDevice.TRANSPORT_LE)
            Log.i(TAG, "Connecting to ${device.address} for Mac $macId")
            return true
        } catch (e: SecurityException) {
            Log.e(TAG, "SecurityException while connecting to ${device.address}", e)
            links.remove(macId, link)
            return false
        }
    }

    fun disconnect(macId: String) {
        links.remove(macId)?.close()
    }

    fun disconnectAll() {
        links.keys.toList().forEach { disconnect(it) }
    }

    // MARK: - Writes

    fun sendResponse(macId: String, data: ByteArray): Boolean =
        links[macId]?.write("response", { it.responseChar }, data) ?: notLinked(macId, "response")

    fun sendSessionKey(macId: String, data: ByteArray): Boolean =
        links[macId]?.write("sessionKey", { it.sessionKeyChar }, data) ?: notLinked(macId, "sessionKey")

    fun sendPairingData(macId: String, data: ByteArray): Boolean =
        links[macId]?.write("pairing", { it.pairingChar }, data) ?: notLinked(macId, "pairing")

    private fun notLinked(macId: String, label: String): Boolean {
        Log.w(TAG, "Cannot send $label: no link to Mac $macId")
        return false
    }

    // MARK: - Scan callback

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            val macId = macIdFor(result) ?: return
            val device = result.device
            val isNew = synchronized(discovered) {
                if (discovered.containsKey(macId)) false else {
                    discovered[macId] = device
                    true
                }
            }
            if (isNew) {
                Log.i(TAG, "Discovered Mac $macId at ${device.address} (RSSI: ${result.rssi})")
                listener?.onDeviceDiscovered(macId, device.address, result.rssi)
            }
        }

        override fun onScanFailed(errorCode: Int) {
            Log.e(TAG, "Scan failed: $errorCode")
            isScanning = false
        }
    }

    /** Which target Mac produced this result, via the advertised service UUIDs. */
    private fun macIdFor(result: ScanResult): String? {
        val targets = scanTargets
        val advertised = result.scanRecord?.serviceUuids?.map { it.uuid } ?: emptyList()
        advertised.firstNotNullOfOrNull { targets[it] }?.let { return it }
        // The filter matched, so if there's only one target this must be it even
        // when the record parser didn't surface the UUID.
        return if (targets.size == 1) targets.values.first() else null
    }

    // MARK: - Per-Mac link

    private inner class MacLink(val macId: String, val device: BluetoothDevice) {
        private val serviceUUID = UUID.fromString(macId)

        var gatt: BluetoothGatt? = null
        @Volatile
        var connected = false

        var sessionKeyChar: BluetoothGattCharacteristic? = null
        var challengeChar: BluetoothGattCharacteristic? = null
        var responseChar: BluetoothGattCharacteristic? = null
        var pairingChar: BluetoothGattCharacteristic? = null

        private val ops = ArrayDeque<() -> Boolean>()
        private var opInFlight = false
        private var pendingCccdWrites = 0

        fun close() {
            try {
                gatt?.disconnect()
                gatt?.close()
            } catch (e: SecurityException) {
                Log.e(TAG, "SecurityException while disconnecting $macId", e)
            } finally {
                clear()
            }
        }

        private fun clear() {
            gatt = null
            connected = false
            sessionKeyChar = null
            challengeChar = null
            responseChar = null
            pairingChar = null
            synchronized(ops) {
                ops.clear()
                opInFlight = false
                pendingCccdWrites = 0
            }
        }

        fun write(
            label: String,
            target: (MacLink) -> BluetoothGattCharacteristic?,
            data: ByteArray,
        ): Boolean {
            if (!PermissionUtils.hasBluetoothPermissions(context)) return false
            if (gatt == null || target(this) == null) {
                Log.w(TAG, "Cannot send $label to $macId: not connected or characteristic missing")
                return false
            }
            enqueue {
                val char = target(this)
                val g = gatt
                if (char == null || g == null) {
                    false
                } else {
                    char.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
                    char.value = data
                    val ok = g.writeCharacteristic(char)
                    if (!ok) Log.e(TAG, "writeCharacteristic($label) refused by stack for $macId")
                    ok
                }
            }
            return true
        }

        // One GATT operation in flight per connection.

        private fun enqueue(op: () -> Boolean) {
            synchronized(ops) { ops.addLast(op) }
            drive()
        }

        private fun drive() {
            while (true) {
                val op: (() -> Boolean)?
                synchronized(ops) {
                    if (opInFlight) return
                    op = ops.removeFirstOrNull()
                    if (op != null) opInFlight = true
                }
                if (op == null) return
                val started = try {
                    op()
                } catch (e: SecurityException) {
                    Log.e(TAG, "SecurityException in GATT operation", e)
                    false
                }
                if (started) return // wait for the completion callback
                synchronized(ops) { opInFlight = false } // op failed; try next
            }
        }

        private fun opCompleted() {
            synchronized(ops) { opInFlight = false }
            drive()
        }

        private fun enableNotifications(g: BluetoothGatt, char: BluetoothGattCharacteristic) {
            enqueue {
                try {
                    g.setCharacteristicNotification(char, true)
                    val descriptor = char.getDescriptor(Constants.CCCD_UUID)
                    if (descriptor == null) {
                        // No CCCD — count it as done so readiness still fires.
                        if (cccdDone()) listener?.onReadyForSecureSession(macId)
                        false
                    } else {
                        descriptor.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                        g.writeDescriptor(descriptor)
                    }
                } catch (e: SecurityException) {
                    Log.e(TAG, "SecurityException while enabling notifications", e)
                    false
                }
            }
        }

        /** Decrement the outstanding CCCD count; true when the last one finished. */
        private fun cccdDone(): Boolean = synchronized(ops) {
            if (pendingCccdWrites > 0) pendingCccdWrites--
            pendingCccdWrites == 0
        }

        val gattCallback = object : BluetoothGattCallback() {

            override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) {
                when (newState) {
                    BluetoothProfile.STATE_CONNECTED -> {
                        Log.i(TAG, "Connected to Mac $macId")
                        connected = true
                        listener?.onConnectionChanged(macId, true)
                        try {
                            if (!g.requestMtu(REQUESTED_MTU)) g.discoverServices()
                        } catch (e: SecurityException) {
                            Log.e(TAG, "SecurityException during MTU/service discovery", e)
                        }
                    }
                    BluetoothProfile.STATE_DISCONNECTED -> {
                        Log.i(TAG, "Disconnected from Mac $macId (status $status)")
                        try {
                            g.close()
                        } catch (e: SecurityException) {
                            Log.e(TAG, "SecurityException closing GATT", e)
                        }
                        // Only forget ourselves — a newer link for the same Mac may already exist.
                        links.remove(macId, this@MacLink)
                        clear()
                        listener?.onConnectionChanged(macId, false)
                    }
                }
            }

            override fun onMtuChanged(g: BluetoothGatt, mtu: Int, status: Int) {
                Log.i(TAG, "MTU negotiated with $macId: $mtu (status $status)")
                try {
                    g.discoverServices()
                } catch (e: SecurityException) {
                    Log.e(TAG, "SecurityException during discoverServices", e)
                }
            }

            override fun onServicesDiscovered(g: BluetoothGatt, status: Int) {
                if (status != BluetoothGatt.GATT_SUCCESS) {
                    Log.e(TAG, "Service discovery failed for $macId: $status")
                    return
                }
                val service = g.getService(serviceUUID)
                if (service == null) {
                    Log.e(TAG, "TouchBridge service $serviceUUID not found on $macId")
                    return
                }

                sessionKeyChar = service.getCharacteristic(Constants.SESSION_KEY_CHAR_UUID)
                challengeChar = service.getCharacteristic(Constants.CHALLENGE_CHAR_UUID)
                responseChar = service.getCharacteristic(Constants.RESPONSE_CHAR_UUID)
                pairingChar = service.getCharacteristic(Constants.PAIRING_CHAR_UUID)
                Log.i(TAG, "Characteristics discovered on $macId")

                // Subscribe to notifications; the CCCD writes complete one at a
                // time through the op queue, then onReadyForSecureSession fires.
                val notifyChars = listOfNotNull(challengeChar, sessionKeyChar, pairingChar)
                synchronized(ops) { pendingCccdWrites = notifyChars.size }
                notifyChars.forEach { enableNotifications(g, it) }
            }

            override fun onDescriptorWrite(g: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
                if (status != BluetoothGatt.GATT_SUCCESS) {
                    Log.e(TAG, "CCCD write failed for ${descriptor.characteristic.uuid}: $status")
                }
                val ready = cccdDone()
                opCompleted()
                if (ready) {
                    Log.i(TAG, "Notifications enabled on $macId — ready for secure session")
                    listener?.onReadyForSecureSession(macId)
                }
            }

            override fun onCharacteristicChanged(g: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
                val data = characteristic.value ?: return
                when (characteristic.uuid) {
                    Constants.CHALLENGE_CHAR_UUID -> {
                        Log.i(TAG, "Challenge received from $macId (${data.size} bytes)")
                        listener?.onChallengeReceived(macId, data)
                    }
                    Constants.SESSION_KEY_CHAR_UUID -> {
                        Log.i(TAG, "Session key received from $macId (${data.size} bytes)")
                        listener?.onSessionKeyReceived(macId, data)
                    }
                    Constants.PAIRING_CHAR_UUID -> {
                        Log.i(TAG, "Pairing data received from $macId (${data.size} bytes)")
                        listener?.onPairingDataReceived(macId, data)
                    }
                }
            }

            override fun onCharacteristicWrite(g: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) {
                if (status != BluetoothGatt.GATT_SUCCESS) {
                    Log.e(TAG, "Write failed for ${characteristic.uuid} on $macId: $status")
                }
                opCompleted()
            }
        }
    }
}

package dev.touchbridge.android.ui.screens

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import dev.touchbridge.android.TouchBridgeApp
import dev.touchbridge.android.core.ConnectionManager

// Re-exported so existing UI code keeps importing these from this package.
typealias TouchBridgeUiState = dev.touchbridge.android.core.TouchBridgeUiState
typealias PairingPhase = dev.touchbridge.android.core.PairingPhase
typealias MacStatus = dev.touchbridge.android.core.MacStatus

/**
 * Thin UI-facing delegate over the process-scoped [ConnectionManager].
 *
 * The connection and challenge logic no longer live here — they outlive any
 * Activity in [ConnectionManager] so a backgrounded app still handles challenges.
 * This just exposes that shared state/actions to Compose.
 */
class TouchBridgeViewModel(app: Application) : AndroidViewModel(app) {

    private val manager: ConnectionManager = (app as TouchBridgeApp).connectionManager

    val uiState = manager.uiState

    fun updatePermissionsState() = manager.updatePermissionsState()
    fun startPairing(payloadJson: String) = manager.startPairing(payloadJson)
    fun resetPairing() = manager.resetPairing()
    fun startScanning() = manager.startScanning()
    fun unpair(macId: String) = manager.unpair(macId)

    class Factory(private val app: Application) : ViewModelProvider.Factory {
        @Suppress("UNCHECKED_CAST")
        override fun <T : ViewModel> create(modelClass: Class<T>): T {
            return TouchBridgeViewModel(app) as T
        }
    }
}

package dev.touchbridge.android.ui.screens

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.journeyapps.barcodescanner.ScanContract
import com.journeyapps.barcodescanner.ScanOptions

/**
 * Pairing flow. Used both for first-run onboarding (no [onClose]) and for
 * adding another Mac from the home screen, where [onClose] returns to the list.
 */
@Composable
fun PairingScreen(
    viewModel: TouchBridgeViewModel,
    onRequestPermissions: () -> Unit = {},
    onClose: (() -> Unit)? = null,
) {
    val uiState by viewModel.uiState.collectAsState()
    var manualInput by remember { mutableStateOf("") }

    // Submit the pairing payload; without Bluetooth permission, ask for it first
    // (the payload stays in the field so the user can tap Pair afterwards).
    val submit: (String) -> Unit = { payload ->
        if (uiState.hasPermissions) {
            viewModel.startPairing(payload)
        } else {
            onRequestPermissions()
        }
    }

    // The scanner activity requests CAMERA permission itself. A scanned QR code
    // fills the JSON field and submits immediately; a cancelled scan does nothing.
    val scanLauncher = rememberLauncherForActivityResult(ScanContract()) { result ->
        val contents = result.contents
        if (!contents.isNullOrBlank()) {
            manualInput = contents
            submit(contents)
        }
    }

    Column(
        modifier = Modifier.fillMaxWidth(),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Text(
            text = if (onClose != null) "Add another Mac" else "Pair with your Mac",
            fontSize = 20.sp,
            fontWeight = FontWeight.SemiBold,
            modifier = Modifier.padding(bottom = 8.dp)
        )

        Text(
            text = "Run 'touchbridge-test pair' on your Mac,\nthen scan the QR code or paste the JSON below.",
            fontSize = 13.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
            modifier = Modifier.padding(bottom = 16.dp)
        )

        if (!uiState.hasPermissions) {
            Button(
                onClick = onRequestPermissions,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(vertical = 8.dp)
            ) {
                Text("Grant Bluetooth Permission")
            }
        }

        when (uiState.pairingPhase) {
            PairingPhase.IDLE -> {
                OutlinedButton(
                    onClick = {
                        scanLauncher.launch(
                            ScanOptions().apply {
                                setDesiredBarcodeFormats(ScanOptions.QR_CODE)
                                setPrompt("Scan the QR code shown on your Mac")
                                setBeepEnabled(false)
                            }
                        )
                    },
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Text("Scan QR Code")
                }

                Spacer(modifier = Modifier.height(12.dp))

                OutlinedTextField(
                    value = manualInput,
                    onValueChange = { manualInput = it },
                    label = { Text("Pairing JSON") },
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(120.dp),
                    maxLines = 6,
                )

                Spacer(modifier = Modifier.height(12.dp))

                Button(
                    onClick = { submit(manualInput) },
                    enabled = manualInput.isNotBlank(),
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Text("Pair")
                }

                Spacer(modifier = Modifier.height(8.dp))

                Text(
                    text = "Each Mac uses its own Bluetooth identity,\nso the pairing data is required to find it.",
                    fontSize = 11.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    textAlign = TextAlign.Center,
                )

                if (onClose != null) {
                    Spacer(modifier = Modifier.height(8.dp))
                    TextButton(onClick = onClose) { Text("Back") }
                }
            }

            PairingPhase.SCANNING -> {
                CircularProgressIndicator(modifier = Modifier.padding(16.dp))
                Text("Looking for your Mac...")
                Text(
                    text = "Keep 'touchbridge-test pair' running on the Mac.",
                    fontSize = 12.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(top = 4.dp)
                )
                CancelPairingButton(viewModel)
            }

            PairingPhase.CONNECTING -> {
                CircularProgressIndicator(modifier = Modifier.padding(16.dp))
                Text("Connecting...")
                CancelPairingButton(viewModel)
            }

            PairingPhase.WAITING_FOR_MAC -> {
                CircularProgressIndicator(modifier = Modifier.padding(16.dp))
                Text("Waiting for the Mac to accept...")
                CancelPairingButton(viewModel)
            }

            PairingPhase.PAIRED -> {
                Text(
                    text = "✅ Paired!",
                    fontSize = 20.sp,
                    fontWeight = FontWeight.Bold,
                    color = MaterialTheme.colorScheme.primary
                )
                if (onClose != null) {
                    Spacer(modifier = Modifier.height(16.dp))
                    Button(
                        onClick = {
                            viewModel.resetPairing()
                            onClose()
                        },
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        Text("Done")
                    }
                }
            }

            PairingPhase.ERROR -> {
                Text(
                    text = "❌ ${uiState.pairingError ?: "Pairing failed"}",
                    color = MaterialTheme.colorScheme.error,
                    textAlign = TextAlign.Center,
                )
                Spacer(modifier = Modifier.height(8.dp))
                TextButton(onClick = { viewModel.resetPairing() }) {
                    Text("Try Again")
                }
                if (onClose != null) {
                    TextButton(onClick = {
                        viewModel.resetPairing()
                        onClose()
                    }) {
                        Text("Back")
                    }
                }
            }
        }
    }
}

@Composable
private fun CancelPairingButton(viewModel: TouchBridgeViewModel) {
    Spacer(modifier = Modifier.height(8.dp))
    TextButton(onClick = { viewModel.resetPairing() }) {
        Text("Cancel")
    }
}

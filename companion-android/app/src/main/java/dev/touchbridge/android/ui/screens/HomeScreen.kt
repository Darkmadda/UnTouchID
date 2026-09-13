package dev.touchbridge.android.ui.screens

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import dev.touchbridge.android.core.PairedMac
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

private val ConnectedGreen = Color(0xFF30D158)
private val WaitingOrange = Color(0xFFFF9500)

@Composable
fun HomeScreen(
    viewModel: TouchBridgeViewModel,
    uiState: TouchBridgeUiState,
    modifier: Modifier = Modifier,
    onRequestPermissions: () -> Unit = {},
    onAddMac: () -> Unit = {},
) {
    var macToUnpair by remember { mutableStateOf<MacStatus?>(null) }
    var macToRename by remember { mutableStateOf<MacStatus?>(null) }

    Column(
        modifier = modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Spacer(modifier = Modifier.height(24.dp))

        // Overall status indicator
        Box(
            contentAlignment = Alignment.Center,
            modifier = Modifier
                .size(120.dp)
                .clip(CircleShape)
        ) {
            Surface(
                color = if (uiState.isConnected)
                    ConnectedGreen.copy(alpha = 0.15f)
                else
                    Color.Gray.copy(alpha = 0.1f),
                shape = CircleShape,
                modifier = Modifier.fillMaxSize()
            ) {}

            Text(text = "🔐", fontSize = 48.sp)
        }

        Spacer(modifier = Modifier.height(16.dp))

        Row(verticalAlignment = Alignment.CenterVertically) {
            StatusDot(connected = uiState.isConnected)
            Spacer(modifier = Modifier.width(8.dp))
            Text(
                text = uiState.statusMessage,
                fontSize = 14.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }

        Spacer(modifier = Modifier.height(24.dp))

        // Paired Macs
        Text(
            text = "Paired Macs",
            fontSize = 13.sp,
            fontWeight = FontWeight.SemiBold,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier
                .fillMaxWidth()
                .padding(bottom = 8.dp)
        )

        uiState.macs.forEach { mac ->
            MacRow(mac = mac, onRename = { macToRename = mac }, onUnpair = { macToUnpair = mac })
            Spacer(modifier = Modifier.height(8.dp))
        }

        OutlinedButton(
            onClick = onAddMac,
            modifier = Modifier.fillMaxWidth()
        ) {
            Text("Add another Mac")
        }

        Spacer(modifier = Modifier.height(24.dp))

        // Stats
        if (uiState.challengeCount > 0) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceEvenly
            ) {
                StatCard("Authenticated", "${uiState.challengeCount}")
                uiState.lastChallenge?.let { last ->
                    StatCard("Last", last)
                }
            }
        }

        Spacer(modifier = Modifier.weight(1f))
        Spacer(modifier = Modifier.height(16.dp))

        if (!uiState.hasPermissions) {
            Button(
                onClick = onRequestPermissions,
                modifier = Modifier
                    .fillMaxWidth()
                    .height(48.dp)
            ) {
                Text("Grant Bluetooth Permission")
            }
        } else if (uiState.macs.any { !it.isConnected }) {
            Button(
                onClick = { viewModel.startScanning() },
                modifier = Modifier
                    .fillMaxWidth()
                    .height(48.dp)
            ) {
                Text("Reconnect")
            }
        }
    }

    macToRename?.let { mac ->
        RenameMacDialog(
            mac = mac,
            onConfirm = { nickname ->
                viewModel.rename(mac.id, nickname)
                macToRename = null
            },
            onDismiss = { macToRename = null },
        )
    }

    macToUnpair?.let { mac ->
        AlertDialog(
            onDismissRequest = { macToUnpair = null },
            title = { Text("Unpair ${mac.name}?") },
            text = {
                Text(
                    if (uiState.macs.size == 1)
                        "This is your only paired Mac. Unpairing removes this phone's signing key; you'll need to pair again from scratch."
                    else
                        "This phone will stop approving sign-ins on ${mac.name}. Your other Macs are unaffected."
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        viewModel.unpair(mac.id)
                        macToUnpair = null
                    },
                    colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.error)
                ) {
                    Text("Unpair")
                }
            },
            dismissButton = {
                TextButton(onClick = { macToUnpair = null }) { Text("Cancel") }
            }
        )
    }
}

@Composable
private fun MacRow(mac: MacStatus, onRename: () -> Unit, onUnpair: () -> Unit) {
    var menuOpen by remember { mutableStateOf(false) }

    Card(modifier = Modifier.fillMaxWidth()) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(start = 16.dp, end = 4.dp, top = 8.dp, bottom = 8.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            StatusDot(connected = mac.isConnected)
            Spacer(modifier = Modifier.width(12.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(mac.name, fontWeight = FontWeight.SemiBold, fontSize = 14.sp)
                Text(
                    text = buildString {
                        append(if (mac.isConnected) "Connected" else "Not in range")
                        // When renamed, keep the Mac's own name visible so it can still be matched
                        // to what System Settings shows.
                        if (mac.hasNickname) append(" · ").append(mac.macName)
                    },
                    fontSize = 12.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            Box {
                TextButton(onClick = { menuOpen = true }) {
                    Text("⋮", fontSize = 20.sp)
                }
                DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                    DropdownMenuItem(
                        text = { Text("Rename") },
                        onClick = { menuOpen = false; onRename() }
                    )
                    DropdownMenuItem(
                        text = { Text("Unpair", color = MaterialTheme.colorScheme.error) },
                        onClick = { menuOpen = false; onUnpair() }
                    )
                }
            }
        }
    }
}

/**
 * Lets the user pick a friendlier label for one Mac. Saving an empty field
 * reverts to the name the Mac reported at pairing.
 */
@Composable
private fun RenameMacDialog(
    mac: MacStatus,
    onConfirm: (String?) -> Unit,
    onDismiss: () -> Unit,
) {
    // Start with the current label fully selected so typing replaces it.
    var value by remember(mac.id) {
        mutableStateOf(TextFieldValue(mac.name, selection = TextRange(0, mac.name.length)))
    }
    val focusRequester = remember { FocusRequester() }
    val trimmed = value.text.trim()
    val unchanged = trimmed == mac.name || (trimmed.isEmpty() && !mac.hasNickname)

    LaunchedEffect(mac.id) { focusRequester.requestFocus() }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Rename Mac") },
        text = {
            Column {
                OutlinedTextField(
                    value = value,
                    onValueChange = {
                        if (it.text.length <= PairedMac.MAX_NICKNAME_LENGTH && !it.text.contains('\n')) value = it
                    },
                    singleLine = true,
                    label = { Text("Name") },
                    placeholder = { Text(mac.macName) },
                    supportingText = {
                        Text(
                            if (mac.hasNickname) "Leave empty to use “${mac.macName}” again."
                            else "This name is only used on this phone."
                        )
                    },
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                    keyboardActions = KeyboardActions(onDone = { if (!unchanged) onConfirm(trimmed) }),
                    modifier = Modifier
                        .fillMaxWidth()
                        .focusRequester(focusRequester),
                )
            }
        },
        confirmButton = {
            TextButton(onClick = { onConfirm(trimmed) }, enabled = !unchanged) { Text("Save") }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("Cancel") }
        }
    )
}

@Composable
private fun StatusDot(connected: Boolean) {
    Surface(
        color = if (connected) ConnectedGreen else WaitingOrange,
        shape = CircleShape,
        modifier = Modifier.size(8.dp)
    ) {}
}

@Composable
fun StatCard(title: String, value: String) {
    Card(
        modifier = Modifier
            .width(150.dp)
            .padding(4.dp)
    ) {
        Column(
            modifier = Modifier
                .padding(16.dp)
                .fillMaxWidth(),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            Text(value, fontWeight = FontWeight.Bold, fontSize = 16.sp)
            Text(title, fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

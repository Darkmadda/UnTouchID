package dev.touchbridge.android

import android.Manifest
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.viewmodel.compose.viewModel
import dev.touchbridge.android.service.TouchBridgeService
import dev.touchbridge.android.ui.screens.*
import dev.touchbridge.android.ui.theme.TouchBridgeTheme
import dev.touchbridge.android.util.PermissionUtils

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        setContent {
            TouchBridgeTheme {
                val viewModel: TouchBridgeViewModel = viewModel(
                    factory = TouchBridgeViewModel.Factory(application)
                )
                val uiState by viewModel.uiState.collectAsState()
                val context = LocalContext.current

                val permissionLauncher = rememberLauncherForActivityResult(
                    contract = ActivityResultContracts.RequestMultiplePermissions()
                ) { _ ->
                    viewModel.updatePermissionsState()
                }

                val requestPermissions = {
                    permissionLauncher.launch(PermissionUtils.getRequiredBluetoothPermissions())
                }

                val notifLauncher = rememberLauncherForActivityResult(
                    contract = ActivityResultContracts.RequestPermission()
                ) { }

                LaunchedEffect(Unit) {
                    if (!PermissionUtils.hasBluetoothPermissions(context)) {
                        requestPermissions()
                    } else {
                        viewModel.updatePermissionsState()
                    }
                    // Needed to post the always-on and full-screen challenge notifications.
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        notifLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
                    }
                }

                // Once paired, run the foreground service so challenges are handled
                // even when this Activity is gone. Nudge the user to exempt us from
                // battery optimization (critical on aggressive OEMs like ColorOS).
                LaunchedEffect(uiState.isPaired) {
                    if (uiState.isPaired) {
                        TouchBridgeService.start(context)
                        requestBatteryExemption(context)
                    } else {
                        TouchBridgeService.stop(context)
                    }
                }

                Surface(
                    modifier = Modifier.fillMaxSize(),
                    color = MaterialTheme.colorScheme.background
                ) {
                    if (uiState.isPaired) {
                        MainScreen(
                            viewModel = viewModel,
                            uiState = uiState,
                            onRequestPermissions = requestPermissions
                        )
                    } else {
                        OnboardingScreen(
                            viewModel = viewModel,
                            onRequestPermissions = requestPermissions
                        )
                    }
                }
            }
        }
    }
}

/** Ask the user to exempt TouchBridge from Doze/battery optimization (one-time). */
private fun requestBatteryExemption(context: Context) {
    val pm = context.getSystemService(Context.POWER_SERVICE) as? PowerManager ?: return
    if (pm.isIgnoringBatteryOptimizations(context.packageName)) return
    try {
        context.startActivity(
            Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                data = Uri.parse("package:${context.packageName}")
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
        )
    } catch (e: Exception) {
        // Some OEMs don't expose this intent — the user can set it manually.
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MainScreen(
    viewModel: TouchBridgeViewModel,
    uiState: TouchBridgeUiState,
    onRequestPermissions: () -> Unit = {}
) {
    var addingMac by rememberSaveable { mutableStateOf(false) }

    // Start the add-Mac flow from a clean pairing state (a previous pairing may
    // have been left on the PAIRED screen).
    LaunchedEffect(addingMac) {
        if (addingMac) viewModel.resetPairing()
    }

    Scaffold(
        bottomBar = {
            NavigationBar {
                NavigationBarItem(
                    selected = true,
                    onClick = { },
                    icon = { Icon(painter = painterResource(android.R.drawable.ic_lock_idle_lock), "Home") },
                    label = { Text("Home") }
                )
                NavigationBarItem(
                    selected = false,
                    onClick = { },
                    icon = { Icon(painter = painterResource(android.R.drawable.ic_menu_recent_history), "Activity") },
                    label = { Text("Activity") }
                )
                NavigationBarItem(
                    selected = false,
                    onClick = { },
                    icon = { Icon(painter = painterResource(android.R.drawable.ic_menu_preferences), "Settings") },
                    label = { Text("Settings") }
                )
            }
        }
    ) { padding ->
        if (addingMac) {
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(padding)
                    .verticalScroll(rememberScrollState())
                    .padding(24.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.Center
            ) {
                PairingScreen(
                    viewModel = viewModel,
                    onRequestPermissions = onRequestPermissions,
                    onClose = { addingMac = false }
                )
            }
        } else {
            HomeScreen(
                viewModel = viewModel,
                uiState = uiState,
                modifier = Modifier.padding(padding),
                onRequestPermissions = onRequestPermissions,
                onAddMac = { addingMac = true }
            )
        }
    }
}

@Composable
fun OnboardingScreen(
    viewModel: TouchBridgeViewModel,
    onRequestPermissions: () -> Unit = {}
) {
    var showPairing by remember { mutableStateOf(false) }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center
    ) {
        Text(
            text = "🔐",
            fontSize = 64.sp,
            modifier = Modifier.padding(bottom = 8.dp)
        )

        Text(
            text = "TouchBridge",
            fontSize = 28.sp,
            fontWeight = FontWeight.Bold,
        )

        Text(
            text = "Use your fingerprint or face to\nauthenticate on your Mac.",
            fontSize = 14.sp,
            textAlign = TextAlign.Center,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(top = 8.dp, bottom = 24.dp)
        )

        if (!showPairing) {
            FeatureItem(icon = "🔒", title = "Secure", desc = "Keys stored in hardware security module")
            FeatureItem(icon = "📡", title = "Wireless", desc = "Connects via Bluetooth LE")
            FeatureItem(icon = "👆", title = "Biometric", desc = "Fingerprint or face — no passwords")

            Spacer(modifier = Modifier.height(24.dp))

            Button(
                onClick = { showPairing = true },
                modifier = Modifier
                    .fillMaxWidth()
                    .height(52.dp),
            ) {
                Text("Get Started", fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
            }
        } else {
            PairingScreen(
                viewModel = viewModel,
                onRequestPermissions = onRequestPermissions
            )
        }
    }
}

@Composable
fun FeatureItem(icon: String, title: String, desc: String) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text(icon, fontSize = 24.sp, modifier = Modifier.padding(end = 16.dp))
        Column {
            Text(title, fontWeight = FontWeight.SemiBold, fontSize = 14.sp)
            Text(desc, fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

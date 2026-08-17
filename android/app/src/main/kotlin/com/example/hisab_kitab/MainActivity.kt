package com.example.hisab_kitab

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.content.pm.PackageManager
import android.util.Log
import com.google.android.gms.common.ConnectionResult
import com.google.android.gms.common.GoogleApiAvailability
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "hisab_kitab/google_play_services"
        ).setMethodCallHandler { call, result ->
            if (call.method != "status") {
                result.notImplemented()
                return@setMethodCallHandler
            }

            val availability = GoogleApiAvailability.getInstance()
            val statusCode = availability.isGooglePlayServicesAvailable(this)
            val packageInfo = try {
                packageManager.getPackageInfo("com.google.android.gms", 0)
            } catch (_: PackageManager.NameNotFoundException) {
                null
            }

            result.success(
                mapOf(
                    "available" to (statusCode == ConnectionResult.SUCCESS),
                    "statusCode" to statusCode,
                    "statusString" to availability.getErrorString(statusCode),
                    "isUserResolvableError" to availability.isUserResolvableError(statusCode),
                    "versionName" to packageInfo?.versionName,
                    "longVersionCode" to packageInfo?.longVersionCode,
                )
            )
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "hisab_kitab/install_permission"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "canRequestPackageInstalls" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        result.success(packageManager.canRequestPackageInstalls())
                    } else {
                        result.success(true)
                    }
                }
                "openInstallPermissionSettings" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        try {
                            val intent = Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES).apply {
                                data = Uri.parse("package:$packageName")
                            }
                            startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            try {
                                val intent = Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES)
                                startActivity(intent)
                                result.success(true)
                            } catch (ex: Exception) {
                                result.error("ERROR", ex.message, null)
                            }
                        }
                    } else {
                        result.success(true)
                    }
                }
                else -> {
                    result.notImplemented()
                }
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "hisab_kitab/upi_launcher"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getInstalledUpiApps" -> {
                    try {
                        val upiPackages = setOf(
                            "com.google.android.apps.nbu.paisa.user",
                            "net.one97.paytm",
                            "com.phonepe.app",
                            "in.org.npci.upiapp",
                            "com.supermoney.app"
                        )
                        val apps = mutableListOf<Map<String, String>>()
                        for (packageName in upiPackages) {
                            try {
                                val info = packageManager.getApplicationInfo(packageName, 0)
                                val appLabel = packageManager.getApplicationLabel(info).toString()
                                apps.add(mapOf("name" to appLabel, "packageName" to packageName))
                                Log.d("UPI_DEBUG", "Selected Package: $packageName")
                            } catch (e: PackageManager.NameNotFoundException) {
                                // Package not installed
                            }
                        }
                        result.success(apps)
                    } catch (e: Exception) {
                        result.error("ERROR", e.message, null)
                    }
                }
                "launchUpiApp" -> {
                    val packageName = call.argument<String>("packageName")
                    if (packageName != null) {
                        try {
                            Log.d("UPI_DEBUG", "Intent creation: Getting launch intent for package: $packageName")
                            val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
                            if (launchIntent != null) {
                                Log.d("UPI_DEBUG", "Selected Package: $packageName")
                                Log.d("UPI_DEBUG", "Intent launch: Starting activity for package: $packageName")
                                startActivity(launchIntent)
                                Log.d("UPI_DEBUG", "Activity results: Activity started successfully")
                                result.success(true)
                            } else {
                                Log.d("UPI_DEBUG", "Exception: Could not get launch intent for package: $packageName")
                                result.error("LAUNCH_FAILED", "Could not get launch intent for package: $packageName", null)
                            }
                        } catch (e: Exception) {
                            Log.d("UPI_DEBUG", "Exception: " + e.message)
                            result.error("ERROR", e.message, null)
                        }
                    } else {
                        result.error("INVALID_ARGUMENT", "packageName is null", null)
                    }
                }
                "launchUpiPayment" -> {
                    try {
                        Log.d("UPI_DEBUG", "Generated URI: none (direct app launch)")
                        Log.d("UPI_DEBUG", "Intent creation: Querying package manager for launcher apps")
                        
                        val launcherIntent = Intent(Intent.ACTION_MAIN).apply {
                            addCategory(Intent.CATEGORY_LAUNCHER)
                        }
                        val resolveInfos = packageManager.queryIntentActivities(launcherIntent, 0)
                        
                        Log.d("UPI_DEBUG", "Total installed launcher apps found: ${resolveInfos.size}")
                        
                        val upiPackages = setOf(
                            "com.google.android.apps.nbu.paisa.user",
                            "net.one97.paytm",
                            "com.phonepe.app",
                            "in.org.npci.upiapp",
                            "com.supermoney.app"
                        )
                        
                        val targetIntents = mutableListOf<Intent>()
                        val foundPackages = mutableListOf<String>()
                        
                        for (packageName in upiPackages) {
                            val launchIntent = try {
                                packageManager.getLaunchIntentForPackage(packageName)
                            } catch (e: Exception) {
                                null
                            }
                            if (launchIntent != null) {
                                targetIntents.add(launchIntent)
                                foundPackages.add(packageName)
                                Log.d("UPI_DEBUG", "Selected Package: $packageName")
                            }
                        }
                        
                        Log.d("UPI_DEBUG", "Total UPI apps found: ${targetIntents.size}")
                        Log.d("UPI_DEBUG", "Package names found: ${foundPackages.joinToString(", ")}")
                        
                        if (targetIntents.isEmpty()) {
                            val reason = "No launchable UPI apps found on the device. Total launcher apps: ${resolveInfos.size}. Packages queried: ${upiPackages.joinToString(", ")}."
                            Log.d("UPI_DEBUG", "Exception: $reason")
                            result.error("NO_UPI_APP", "No launchable UPI apps installed", reason)
                            return@setMethodCallHandler
                        }

                        Log.d("UPI_DEBUG", "Intent creation: Creating chooser with launcher intents")
                        val chooserIntent = Intent.createChooser(targetIntents.removeAt(0), "Open UPI App")
                        if (targetIntents.isNotEmpty()) {
                            chooserIntent.putExtra(Intent.EXTRA_INITIAL_INTENTS, targetIntents.toTypedArray())
                        }
                        
                        Log.d("UPI_DEBUG", "Intent launch: Starting chooser activity")
                        startActivity(chooserIntent)
                        Log.d("UPI_DEBUG", "Activity results: Chooser activity started successfully")
                        result.success(true)
                    } catch (e: Exception) {
                        Log.d("UPI_DEBUG", "Exception: " + e.message)
                        result.error("ERROR", e.message, null)
                    }
                }
                else -> {
                    result.notImplemented()
                }
            }
        }
    }
}

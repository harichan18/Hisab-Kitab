package com.example.hisab_kitab

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.content.pm.PackageManager
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
    }
}

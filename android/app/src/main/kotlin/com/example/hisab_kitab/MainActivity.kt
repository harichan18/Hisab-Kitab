package com.example.hisab_kitab

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
    }
}

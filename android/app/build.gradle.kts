import java.io.File

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    id("com.google.gms.google-services")
}

android {
    namespace = "com.example.hisab_kitab"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.hisab_kitab"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation("com.google.android.gms:play-services-base:18.10.0")
    implementation("com.google.mlkit:text-recognition-devanagari:16.0.1")
}

tasks.matching { it.name == "stripReleaseDebugSymbols" }.configureEach {
    dependsOn(tasks.matching { it.name.contains("FlutterBuild") || it.name.contains("mergeReleaseJniLib") })
    doLast {
        val buildDir = project.layout.buildDirectory.get().asFile
        val mergedDir = File(buildDir, "intermediates/merged_jni_libs/release/mergeReleaseJniLibFolders/out")
        val strippedDir = File(buildDir, "intermediates/stripped_native_libs/release/stripReleaseDebugSymbols/out/lib")
        if (mergedDir.exists() && strippedDir.exists()) {
            mergedDir.listFiles()?.forEach { abiDir: File ->
                if (abiDir.isDirectory) {
                    val libApp = File(abiDir, "libapp.so")
                    if (libApp.exists()) {
                        val targetAbiDir = File(strippedDir, abiDir.name)
                        targetAbiDir.mkdirs()
                        libApp.copyTo(File(targetAbiDir, "libapp.so"), overwrite = true)
                    }
                }
            }
        }
    }
}





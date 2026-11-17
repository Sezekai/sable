plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.sezekai.sable"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.sezekai.sable"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // Releases are signed with Sable's own key (kept as a GitHub secret), so each
    // new version installs over the last one and keeps the phone's library.
    // Without the key (a local build) the debug key is used.
    val ks = System.getenv("SABLE_KEYSTORE")
    signingConfigs {
        if (ks != null && file(ks).exists()) {
            create("sable") {
                storeFile = file(ks)
                storePassword = System.getenv("SABLE_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("SABLE_KEY_ALIAS") ?: "sable"
                keyPassword = System.getenv("SABLE_KEY_PASSWORD") ?: System.getenv("SABLE_KEYSTORE_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (ks != null && file(ks).exists()) signingConfigs.getByName("sable") else signingConfigs.getByName("debug")
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

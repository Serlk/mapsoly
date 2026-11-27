plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "dev.mapsoly.mapsoly"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "dev.mapsoly.mapsoly"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // The offline routing server ships as jniLibs/<abi>/libmapsoly_valhalla.so
    // (tool/build_valhalla_android.sh): an executable that the app spawns. It
    // can only be exec'ed as a real file in the native library directory, so
    // the libraries must be extracted at install time instead of being mapped
    // from the APK. This also sets extractNativeLibs="true" in the manifest.
    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // Prebuilt libsqlite3.so (FTS5, R*Tree) for package:sqlite3, which
    // opens it by that name on Android. Android-only on purpose: the Linux
    // build keeps using the system SQLite and gains no dependency (this is
    // the same artifact the sqlite3_flutter_libs plugin would pull in,
    // without the plugin's Linux part that compiles SQLite from source).
    implementation("eu.simonbinder:sqlite3-native-library:3.52.0")
}

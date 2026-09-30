plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.zaoji.zaoji"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // R47 · `flutter_local_notifications` 的 AAR 元数据要求宿主 App 开
        // **core library desugaring**（它用到 java.time 这些高版本 API）。
        // ★ 它是 compileOptions 的属性，放 defaultConfig 里是 `Unresolved reference`。
        // ★ 而这条只有**第一次真编 apk** 才会撞到：Dart 侧 analyze 与 432 例全绿
        //   都不走 Gradle，看不见它（R44 之后 apk 一直没重编，所以攒到现在才炸）。
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.zaoji.zaoji"
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
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // 配套上面 isCoreLibraryDesugaringEnabled：AGP 8.11 配 2.1.x。
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

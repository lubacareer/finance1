import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val releaseKeys = Properties()
val releaseKeyFile = rootProject.file("key.properties")
if (releaseKeyFile.isFile) {
    releaseKeyFile.inputStream().use { releaseKeys.load(it) }
}
val requiredReleaseKeys = listOf("storeFile", "storePassword", "keyAlias", "keyPassword")

// Fail with actionable guidance before any release task can run, but allow
// ordinary debug builds without a release keystore.
gradle.taskGraph.whenReady {
    if (allTasks.any { it.project == project && it.name.contains("release", ignoreCase = true) }) {
        val missing = requiredReleaseKeys.filter { releaseKeys.getProperty(it).isNullOrBlank() }
        require(missing.isEmpty()) {
            "Release signing requires android/key.properties with storeFile, storePassword, keyAlias and keyPassword."
        }
        require(rootProject.file(releaseKeys.getProperty("storeFile")).isFile) {
            "Release signing keystore does not exist; check storeFile in android/key.properties."
        }
    }
}

android {
    namespace = "com.example.finance_diary"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // Keep the existing ID so debug updates retain the installed diary.
        // Choose a permanent distribution ID with an explicit backup migration.
        applicationId = "com.example.finance_diary"
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

    signingConfigs {
        create("release") {
            releaseKeys.getProperty("storeFile")?.let { storeFile = rootProject.file(it) }
            storePassword = releaseKeys.getProperty("storePassword")
            keyAlias = releaseKeys.getProperty("keyAlias")
            keyPassword = releaseKeys.getProperty("keyPassword")
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
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

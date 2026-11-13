plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
    id("io.sentry.android.gradle")
}

val signingValues = mapOf(
    "storeFile" to System.getenv("ANDROID_KEYSTORE_PATH"),
    "storePassword" to System.getenv("ANDROID_KEYSTORE_PASSWORD"),
    "keyAlias" to System.getenv("ANDROID_KEY_ALIAS"),
    "keyPassword" to System.getenv("ANDROID_KEY_PASSWORD"),
)
val releaseRequested = gradle.startParameter.taskNames.any {
    it.contains("release", ignoreCase = true)
}
if (releaseRequested) {
    require(signingValues.values.all { !it.isNullOrBlank() }) {
        "Release signing requires ANDROID_KEYSTORE_PATH, ANDROID_KEYSTORE_PASSWORD, ANDROID_KEY_ALIAS and ANDROID_KEY_PASSWORD; debug signing is never used for release."
    }
    require(file(signingValues.getValue("storeFile")!!).isFile) { "Release keystore does not exist" }
}

android {
    namespace = "teikengstudio.xmplus"
    compileSdk = 36
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "teikengstudio.xmplus"
        minSdk = 26
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    packaging {
        jniLibs {
            useLegacyPackaging = true
            keepDebugSymbols += setOf("**/libxmplus_ffmpeg.so", "**/libxmplus_ffprobe.so")
        }
    }

    signingConfigs {
        if (signingValues.values.all { !it.isNullOrBlank() }) {
            create("release") {
                storeFile = file(signingValues.getValue("storeFile")!!)
                storePassword = signingValues.getValue("storePassword")
                keyAlias = signingValues.getValue("keyAlias")
                keyPassword = signingValues.getValue("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.findByName("release")
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
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

val sentryUploadEnabled = !System.getenv("SENTRY_AUTH_TOKEN").isNullOrBlank() &&
    System.getenv("SENTRY_UPLOAD_SYMBOLS") == "true"
sentry {
    org.set("tkstudio")
    projectName.set("xmplus")
    authToken.set(System.getenv("SENTRY_AUTH_TOKEN"))
    autoInstallation { enabled.set(false) }
    includeProguardMapping.set(true)
    autoUploadProguardMapping.set(sentryUploadEnabled)
    uploadNativeSymbols.set(sentryUploadEnabled)
    autoUploadNativeSymbols.set(sentryUploadEnabled)
    includeSourceContext.set(false)
    includeNativeSources.set(false)
    tracingInstrumentation { enabled.set(false) }
    ignoredBuildTypes.set(setOf("debug"))
}

dependencies {
    implementation("androidx.core:core:1.15.0")
}

val verifyAndroidMediaTools = tasks.register("verifyAndroidMediaTools") {
    val platforms = providers.gradleProperty("target-platform")
        .orElse("android-arm,android-arm64,android-x64")
    doLast {
        val abiNames = mapOf("android-arm" to "armeabi-v7a", "android-arm64" to "arm64-v8a", "android-x64" to "x86_64")
        for (platform in platforms.get().split(",")) {
            val abi = requireNotNull(abiNames[platform.trim()]) { "Unsupported Android target: $platform" }
            for (tool in listOf("ffmpeg", "ffprobe")) {
                val executable = file("src/main/jniLibs/$abi/libxmplus_$tool.so")
                require(executable.isFile && executable.length() > 0) {
                    "Missing Android $abi $tool. Run bash tool/build_android_media.sh $abi before building Flutter."
                }
            }
        }
    }
}
tasks.named("preBuild") { dependsOn(verifyAndroidMediaTools) }

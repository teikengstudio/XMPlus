pluginManagement {
    val flutterSdkPath = run {
        val properties = java.util.Properties()
        file("local.properties").inputStream().use { properties.load(it) }
        requireNotNull(properties.getProperty("flutter.sdk")) { "flutter.sdk not set in local.properties" }
    }
    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}
plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "9.5.1" apply false
    // Keep the compiler version above Flutter's minimum without applying legacy KGP.
    id("org.jetbrains.kotlin.android") version "2.4.21" apply false
    id("io.sentry.android.gradle") version "6.26.0" apply false
}
include(":app")

// flutter_inappwebview_android 1.1.3: Copyright 2023 Lorenzo Pichilli (Apache-2.0).
// https://github.com/pichillilorenzo/flutter_inappwebview/tree/master/flutter_inappwebview_android
// Remove only the AGP 9-unsupported ProGuard template; keep upstream projectDir and sources.
val webViewProject = project(":flutter_inappwebview_android")
val webViewBuildFile = webViewProject.projectDir.resolve("build.gradle")
val webViewBuildBytes = webViewBuildFile.readBytes()
val webViewBuildHash = java.util.HexFormat.of().formatHex(
    java.security.MessageDigest.getInstance("SHA-256").digest(webViewBuildBytes)
)
check(webViewBuildHash == "82b483da0a2885adb5b5a5601bdad16289a0a68631b596ffb1001b6016fc0690") {
    "Recheck flutter_inappwebview_android 1.1.3 before applying the AGP 9 ProGuard patch: " +
        "unexpected build.gradle SHA-256 $webViewBuildHash ($webViewBuildFile)."
}
val webViewBuildSource = webViewBuildBytes.toString(Charsets.UTF_8)
val unsupportedProguardTemplate = "getDefaultProguardFile('proguard-android.txt')"
var templateOccurrences = 0
var templateOffset = webViewBuildSource.indexOf(unsupportedProguardTemplate)
while (templateOffset >= 0) {
    templateOccurrences++
    templateOffset = webViewBuildSource.indexOf(
        unsupportedProguardTemplate, templateOffset + unsupportedProguardTemplate.length
    )
}
check(templateOccurrences == 2) {
    "Recheck flutter_inappwebview_android 1.1.3: expected 2 unsupported ProGuard templates, " +
        "found $templateOccurrences."
}
val patchedWebViewBuild = "// Copyright 2023 Lorenzo Pichilli; Apache-2.0 (see upstream LICENSE).\n" +
    "// Source: https://github.com/pichillilorenzo/flutter_inappwebview/tree/master/flutter_inappwebview_android\n" +
    "// Modified: replace the AGP 9-unsupported ProGuard template with the optimized template.\n" +
    webViewBuildSource.replace(
        unsupportedProguardTemplate, "getDefaultProguardFile('proguard-android-optimize.txt')"
    )
val generatedWebViewBuildFile = rootProject.projectDir.parentFile.resolve(
    "build/android-plugin-gradle/flutter_inappwebview_android.gradle"
)
if (!generatedWebViewBuildFile.isFile || generatedWebViewBuildFile.readText() != patchedWebViewBuild) {
    generatedWebViewBuildFile.parentFile.mkdirs()
    generatedWebViewBuildFile.writeText(patchedWebViewBuild)
}
webViewProject.buildFileName = generatedWebViewBuildFile.relativeTo(webViewProject.projectDir).path

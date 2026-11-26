plugins { id("com.android.application"); id("org.jetbrains.kotlin.android"); id("org.jetbrains.kotlin.plugin.compose") }
// Every installed copy only accepts updates signed with this key; losing it means every user uninstalls and loses phone data.
// The password lives in the login keychain (see docs/installation.md). Debug builds use it too so dev installs update the phone in place.
val releaseKeystore = file("${System.getProperty("user.home")}/.config/tacit/android-release.p12")
val releasePassword: String? = if (releaseKeystore.isFile) providers.exec {
    commandLine("/usr/bin/security", "find-generic-password", "-a", "tacit", "-s", "tacit-android-release", "-w")
}.standardOutput.asText.get().trim() else null
android {
    namespace = "top.jinso.tacit"
    compileSdk = 35
    defaultConfig {
        applicationId = "top.jinso.tacit"
        minSdk = 28
        targetSdk = 35
        versionCode = 18
        versionName = "0.7.2"
        ndk { abiFilters += "arm64-v8a" }
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }
    signingConfigs {
        if (releasePassword != null) create("release") {
            storeFile = releaseKeystore; storePassword = releasePassword; keyAlias = "tacit"; keyPassword = releasePassword
        }
    }
    buildTypes {
        getByName("release") { signingConfig = signingConfigs.findByName("release") }
        getByName("debug") { signingConfigs.findByName("release")?.let { signingConfig = it } }
    }
    // Both locales must be present for the existing-install pin, even on English devices.
    bundle { language { enableSplit = false } }
    buildFeatures { compose = true; buildConfig = true }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
    kotlinOptions { jvmTarget = "17" }
    packaging {
        resources.excludes += setOf("/META-INF/{AL2.0,LGPL2.1}", "/META-INF/versions/9/OSGI-INF/MANIFEST.MF")
        // FastRPC needs the Hexagon skeleton as a real file in nativeLibraryDir.
        jniLibs.useLegacyPackaging = true
        jniLibs.keepDebugSymbols += "**/libQnn*.so"
    }
}
dependencies {
    implementation(files("libs/sherpa-onnx-2.0.1-qnn-arm64.aar"))
    implementation("org.apache.commons:commons-compress:1.28.0")
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.activity:activity-compose:1.10.1")
    implementation(platform("androidx.compose:compose-bom:2025.04.01"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.7")
    implementation("org.bouncycastle:bcprov-jdk18on:1.79")
    implementation("com.journeyapps:zxing-android-embedded:4.3.0")
    implementation("com.google.zxing:core:3.5.3")
    implementation("androidx.work:work-runtime-ktx:2.10.1")
    implementation("net.zetetic:sqlcipher-android:4.10.0")
    implementation("androidx.sqlite:sqlite:2.4.0")
    testImplementation("org.json:json:20240303")
    testImplementation("junit:junit:4.13.2")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("androidx.test:runner:1.6.2")
    debugImplementation("androidx.compose.ui:ui-tooling")
}

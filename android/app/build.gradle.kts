plugins { id("com.android.application"); id("org.jetbrains.kotlin.android"); id("org.jetbrains.kotlin.plugin.compose") }
android {
    namespace = "top.jinso.tacit"
    compileSdk = 35
    defaultConfig {
        applicationId = "top.jinso.tacit"
        minSdk = 28
        targetSdk = 35
        versionCode = 6
        versionName = "0.4.2"
        ndk { abiFilters += "arm64-v8a" }
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }
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

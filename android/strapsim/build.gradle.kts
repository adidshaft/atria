plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

// Development tool: a simulated WHOOP 4.0 BLE peripheral for end-to-end testing of
// Atria's Android Bluetooth stack on a second emulator (shared netsim radio).
android {
    namespace = "com.adidshaft.strapsim"
    compileSdk = 36
    defaultConfig {
        applicationId = "com.adidshaft.strapsim"
        minSdk = 31
        targetSdk = 36
        versionCode = 1
        versionName = "1.0"
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
}

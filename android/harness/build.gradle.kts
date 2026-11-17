plugins { id("com.android.application") }
android {
    namespace = "io.github.stefan814.garden.harness"
    compileSdk = 37
    defaultConfig {
        applicationId = "io.github.stefan814.garden.harness"
        minSdk = 31; targetSdk = 36; versionCode = 1; versionName = "0.1.0"
        ndk { abiFilters += listOf("arm64-v8a") }
    }
    flavorDimensions += "role"
    productFlavors {
        create("a") { dimension = "role"; applicationIdSuffix = ".a" }
        create("b") { dimension = "role"; applicationIdSuffix = ".b" }
    }
    androidResources { noCompress += listOf("onnx", "txt", "wav") }
    packaging { jniLibs { useLegacyPackaging = true } }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
}
dependencies {
    implementation(project(":modellibrary"))
    implementation(files("libs/sherpa-onnx-2.0.1.aar"))
}

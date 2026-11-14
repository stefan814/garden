plugins { id("com.android.library") }
android {
    namespace = "io.github.stefan814.garden"
    compileSdk = 37
    defaultConfig { minSdk = 31; consumerProguardFiles("consumer-rules.pro") }
    // The catalog lives at the repo root so the iOS package can read the same file.
    sourceSets { getByName("main") { assets.srcDir("../../catalog") } }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
    testOptions { unitTests.isReturnDefaultValues = true }
}
dependencies {
    implementation("androidx.annotation:annotation:1.9.1")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.11.0")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20250517")
}

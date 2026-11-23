plugins {
    id("com.android.application")
}

// The engine of the Flutter release the module is built with (bin/internal/engine.version of
// Flutter 3.47.7). A stock `flutter build aar` names these two artifacts in the pom of the module's AAR.
val flutterEngine = "1.0.0-deb287481e3ce9468f3434937ced4240a70539ca"

android {
    namespace = "com.example.aarhost"
    compileSdk = 36
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.example.aarhost"
        minSdk = 24
        targetSdk = 36
        versionCode = 1
        versionName = "1.0"
        ndk {
            abiFilters += listOf("x86_64")
        }
    }

    buildTypes {
        release {
            // Signed with the debug key, so that the test can install it.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

dependencies {
    implementation("io.flutter:flutter_embedding_release:$flutterEngine")
    implementation("io.flutter:x86_64_release:$flutterEngine")
}

allprojects {
    repositories {
        google()
        mavenCentral()
        // The Flutter engine and its Java embedding, as for any app that embeds a Flutter module.
        maven { url = uri("https://storage.googleapis.com/download.flutter.io") }
    }
}

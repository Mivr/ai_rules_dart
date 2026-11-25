// A native Android app (no Flutter Gradle plugin) that embeds a Flutter module: add-to-app.
pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("com.android.application") version "9.1.1" apply false
}

include(":app")

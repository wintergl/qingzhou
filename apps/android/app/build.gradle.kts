plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "dev.splitvpn.android"
    compileSdk = 35
    ndkVersion = "27.0.12077973"

    defaultConfig {
        applicationId = "dev.splitvpn.android"
        minSdk = 26
        targetSdk = 35
        versionCode = 16
        versionName = "0.6.9"

        // libmihomo.so, libtun2socks.so and the Rust core ship for arm64 only.
        ndk {
            abiFilters += "arm64-v8a"
        }

        externalNativeBuild {
            cmake {
                cppFlags += "-std=c++17"
                arguments += "-DANDROID_SUPPORT_FLEXIBLE_PAGE_SIZES=ON"
            }
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    packaging {
        jniLibs {
            useLegacyPackaging = true
            keepDebugSymbols += listOf("**/libmihomo.so", "**/libtun2socks.so")
        }
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }
}

dependencies {
    testImplementation("junit:junit:4.13.2")
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

// Package the notices for the exact source/dependency snapshot used by this APK.
// Keep Go module notices from prepare-dependencies.py in their own directories.
val stageThirdPartyNotices by tasks.registering(Exec::class) {
    val repositoryRoot = rootProject.projectDir.resolve("../..").canonicalFile
    workingDir(repositoryRoot)
    commandLine("python3", "scripts/stage-notices.py", "--platform", "android-arm64",
        "--output", "apps/android/app/src/main/assets/third-party-licenses/source-notices")
}

val verifyNativeExecutables by tasks.registering(Exec::class) {
    workingDir(rootProject.projectDir.resolve("../..").canonicalFile)
    commandLine("python3", "apps/android/scripts/prepare-dependencies.py", "--check")
}

tasks.named("preBuild") {
    dependsOn(stageThirdPartyNotices, verifyNativeExecutables)
}

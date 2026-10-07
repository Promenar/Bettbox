plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
}

// 原生模块遵循 Flutter 传入的目标，避免为未生成核心的 ABI 启动 CMake。
val nativePlatformAbis = mapOf(
    "android-arm" to "armeabi-v7a",
    "android-arm64" to "arm64-v8a",
    "android-x64" to "x86_64",
)
val requestedNativeAbis = providers.gradleProperty("target-platform").orNull?.split(",")?.map { target ->
    nativePlatformAbis[target] ?: throw GradleException("不支持的 Flutter 原生目标：$target")
}?.distinct()

android {
    namespace = "com.appshub.bettbox.core"
    compileSdk = 36
    ndkVersion = "28.2.13676358"

    defaultConfig {
        minSdk = 26
        if (requestedNativeAbis != null) {
            ndk {
                abiFilters.addAll(requestedNativeAbis)
            }
        }
    }

    buildTypes {
        release {
            isJniDebuggable = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }

    sourceSets {
        getByName("main") {
            jniLibs.srcDirs("src/main/jniLibs")
        }
    }

    externalNativeBuild {
        cmake {
            path("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}
dependencies {
    implementation("androidx.annotation:annotation-jvm:1.9.1")
}

val copyNativeLibs by tasks.register<Copy>("copyNativeLibs") {
    doFirst {
        delete("src/main/jniLibs")
    }
    from("../../libclash/android")
    into("src/main/jniLibs")
}

afterEvaluate {
    tasks.named("preBuild") {
        dependsOn(copyNativeLibs)
    }
}

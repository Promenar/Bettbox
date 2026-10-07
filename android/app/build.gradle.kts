import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

val localProperties = Properties().apply {
    rootProject.file("local.properties").takeIf { it.exists() }?.inputStream()?.use { load(it) }
}

// 本机发行凭据由任务执行器从登录钥匙串注入，不将密码写入项目配置。
val mStoreFile = file(
    System.getenv("BETTBOX_ANDROID_STORE_FILE") ?: localProperties.getProperty("storeFile") ?: "keystore.jks"
)
val mStorePassword: String? = System.getenv("BETTBOX_ANDROID_STORE_PASSWORD") ?: localProperties.getProperty("storePassword")
val mKeyAlias: String? = System.getenv("BETTBOX_ANDROID_KEY_ALIAS") ?: localProperties.getProperty("keyAlias")
val mKeyPassword: String? = System.getenv("BETTBOX_ANDROID_KEY_PASSWORD") ?: localProperties.getProperty("keyPassword")
val hasReleaseSigningConfig = mStoreFile.isFile &&
    !mStorePassword.isNullOrBlank() &&
    !mKeyAlias.isNullOrBlank() &&
    !mKeyPassword.isNullOrBlank()

// 根据实际任务图检查，覆盖 Flutter、Gradle 聚合任务与缩写任务入口。
// debug 构建不依赖正式签名；release 任务在执行前拒绝缺失的签名配置。
gradle.taskGraph.whenReady {
    val hasReleaseTask = allTasks.any {
        it.project == project && it.name.contains("release", ignoreCase = true)
    }
    if (hasReleaseTask && !hasReleaseSigningConfig) {
        throw GradleException(
            "正式 release 任务需要有效的 keystore 文件及非空的 " +
                "storePassword、keyAlias、keyPassword 配置；禁止使用 debug 签名发行。"
        )
    }
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
val splitPerAbi = providers.gradleProperty("split-per-abi").orNull?.toBoolean() ?: false


android {
    namespace = "com.appshub.bettbox"
    compileSdk = 36
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.appshub.bettbox"
        minSdk = 26
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // Flutter 默认包含所有支持 ABI，显式任务目标必须覆盖打包过滤。
        if (requestedNativeAbis != null && !splitPerAbi) {
            ndk {
                abiFilters.clear()
                abiFilters.addAll(requestedNativeAbis)
            }
        }
    }

    signingConfigs {
        if (hasReleaseSigningConfig) {
            create("release") {
                storeFile = mStoreFile
                storePassword = mStorePassword
                keyAlias = mKeyAlias
                keyPassword = mKeyPassword
            }
        }
    }

    buildTypes {
        debug {
            isMinifyEnabled = false
            applicationIdSuffix = ".debug"
        }
        release {
            isMinifyEnabled = true
            isDebuggable = false
            signingConfig = if (hasReleaseSigningConfig) signingConfigs.getByName("release") else null
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }

    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }

    applicationVariants.all {
        outputs.all {
            (this as? com.android.build.gradle.internal.api.ApkVariantOutputImpl)?.versionCodeOverride = flutter.versionCode
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation(project(":core"))
    implementation("com.google.code.gson:gson:2.10.1")
    implementation("com.android.tools.smali:smali-dexlib2:3.0.9") {
        exclude(group = "com.google.guava", module = "guava")
    }
    implementation("androidx.core:core-splashscreen:1.0.1")
}

configurations.all {
    resolutionStrategy {
        eachDependency {
            if (requested.group == "androidx.datastore") useVersion("1.1.2")
        }
    }
}

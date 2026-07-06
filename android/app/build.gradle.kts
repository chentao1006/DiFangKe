import org.gradle.api.DefaultTask
import org.gradle.api.GradleException
import org.gradle.api.file.DirectoryProperty
import org.gradle.api.provider.Property
import org.gradle.api.tasks.Input
import org.gradle.api.tasks.InputDirectory
import org.gradle.api.tasks.TaskAction
import java.io.File
import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("com.google.devtools.ksp")
    id("org.jetbrains.kotlin.plugin.compose")
}

val requiredNdkVersion = "27.1.12297006"
val requiredNativePageAlignment = 16 * 1024

abstract class VerifyNativePageSizeTask : DefaultTask() {
    @get:InputDirectory
    abstract val nativeLibDir: DirectoryProperty

    @get:Input
    abstract val sdkDir: Property<String>

    @get:Input
    abstract val ndkVersion: Property<String>

    @get:Input
    abstract val requiredAlignment: Property<Int>

    @TaskAction
    fun verify() {
        val readelf = findReadelf()
        val nativeLibs = nativeLibDir.get().asFile
            .listFiles { file -> file.isFile && file.extension == "so" }
            ?.sortedBy { nativeLib -> nativeLib.name }
            ?: emptyList()

        val incompatibleLibs = nativeLibs.mapNotNull { nativeLib ->
            val process = ProcessBuilder(readelf.absolutePath, "-lW", nativeLib.absolutePath)
                .redirectErrorStream(true)
                .start()
            val output = process.inputStream.bufferedReader().use { reader -> reader.readText() }
            val exitCode = process.waitFor()
            if (exitCode != 0) {
                throw GradleException("llvm-readelf failed for ${nativeLib.name}:\n$output")
            }

            val loadAlignments = output
                .lineSequence()
                .filter { line -> line.trimStart().startsWith("LOAD") }
                .mapNotNull { line -> line.trim().split(Regex("\\s+")).lastOrNull()?.removePrefix("0x")?.toIntOrNull(16) }
                .toList()

            if (loadAlignments.isEmpty() || loadAlignments.any { alignment -> alignment < requiredAlignment.get() }) {
                val alignmentSummary = if (loadAlignments.isEmpty()) {
                    "no LOAD segment alignment found"
                } else {
                    loadAlignments.joinToString { alignment -> "0x${alignment.toString(16)}" }
                }
                "${nativeLib.name}: $alignmentSummary"
            } else {
                null
            }
        }

        if (incompatibleLibs.isNotEmpty()) {
            throw GradleException(
                "AMap native libraries are not Android 16 KB page-size compatible. " +
                    "Upgrade app/libs to AMap SDK artifacts built with the new ABI/NDK toolchain, then rerun the build.\n" +
                    incompatibleLibs.joinToString(separator = "\n")
            )
        }
    }

    private fun findReadelf(): File {
        val executableNamesByHost = listOf(
            "darwin-arm64" to "llvm-readelf",
            "darwin-x86_64" to "llvm-readelf",
            "linux-x86_64" to "llvm-readelf",
            "windows-x86_64" to "llvm-readelf.exe"
        )

        return executableNamesByHost
            .map { (host, executableName) ->
                File("${sdkDir.get()}/ndk/${ndkVersion.get()}/toolchains/llvm/prebuilt/$host/bin/$executableName")
            }
            .firstOrNull { candidate -> candidate.isFile }
            ?: throw GradleException("NDK ${ndkVersion.get()} llvm-readelf was not found under ${sdkDir.get()}.")
    }
}

android {
    namespace = "com.ct106.difangke"
    compileSdk = 36
    ndkVersion = requiredNdkVersion

    // 从源码 AppConfig.kt 中动态读取配置的函数 (保留用于其它配置如果需要)
    fun readConfigValue(key: String): String {
        val configFile = file("src/main/java/com/ct106/difangke/AppConfig.kt")
        if (!configFile.exists()) return ""
        val content = configFile.readText()
        val match = Regex("const val $key\\s*=\\s*\"([^\"]*)\"").find(content)
        return match?.groupValues?.get(1) ?: ""
    }

    val localProperties = Properties()
    val localPropertiesFile = rootProject.file("local.properties")
    if (localPropertiesFile.exists()) {
        localProperties.load(localPropertiesFile.inputStream())
    }

    val versionProperties = Properties()
    val versionPropertiesFile = rootProject.file("version.properties")
    if (versionPropertiesFile.exists()) {
        versionProperties.load(versionPropertiesFile.inputStream())
    }

    defaultConfig {
        applicationId = "com.ct106.difangke"
        minSdk = 26
        targetSdk = 36
        versionCode = versionProperties.getProperty("VERSION_CODE")?.toInt() 
            ?: throw GradleException("VERSION_CODE missing in version.properties")
        versionName = versionProperties.getProperty("VERSION_NAME") 
            ?: throw GradleException("VERSION_NAME missing in version.properties")
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"

        ndk {
            abiFilters.add("arm64-v8a")
        }

        // 地图 Key 配置：直接从 local.properties 读取，避免泄露
        manifestPlaceholders["AMAP_KEY"] = localProperties.getProperty("AMAP_REST_KEY") ?: ""
        
        buildConfigField("String", "SERVICE_SECRET", "\"${localProperties.getProperty("SERVICE_SECRET") ?: ""}\"")
        buildConfigField("String", "PUBLIC_SERVICE_URL", "\"${localProperties.getProperty("PUBLIC_SERVICE_URL") ?: ""}\"")
        buildConfigField("String", "AMAP_REST_KEY", "\"${localProperties.getProperty("AMAP_REST_KEY") ?: ""}\"")
        buildConfigField("String", "APTABASE_APP_KEY", "\"${localProperties.getProperty("APTABASE_APP_KEY") ?: ""}\"")
    }

    signingConfigs {
        create("release") {
            storeFile = file("../" + (localProperties.getProperty("KEY_FILE") ?: "key.jks"))
            storePassword = localProperties.getProperty("STORE_PASSWORD") ?: ""
            keyAlias = localProperties.getProperty("KEY_ALIAS") ?: ""
            keyPassword = localProperties.getProperty("KEY_PASSWORD") ?: ""
            isV1SigningEnabled = true
            isV2SigningEnabled = true
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
            ndk {
                debugSymbolLevel = "FULL"
            }
        }
        debug {
            isDebuggable = true
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
        freeCompilerArgs += listOf("-opt-in=androidx.compose.foundation.ExperimentalFoundationApi")
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    packaging {
        resources {
            excludes += "/META-INF/{AL2.0,LGPL2.1}"
        }
        jniLibs {
            excludes += listOf(
                "**/armeabi-v7a/*.so",
                "**/x86/*.so",
                "**/x86_64/*.so"
            )
        }
    }

    sourceSets {
        getByName("main") {
            // Native AMap binaries are loaded from app/libs. Keep a single source of truth
            // so stale duplicates under src/main/jniLibs do not get repackaged by mistake.
            jniLibs.setSrcDirs(listOf("libs"))
        }
    }
}

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2024.06.00")
    implementation(composeBom)

    // Compose Core
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-graphics")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.material3:material3")
    implementation("com.google.android.material:material:1.12.0")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.activity:activity-compose:1.9.0")

    // Navigation
    implementation("androidx.navigation:navigation-compose:2.7.7")

    // Lifecycle & ViewModel
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.1")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.1")
    implementation("androidx.lifecycle:lifecycle-service:2.8.1")

    // Room 数据库
    implementation("androidx.room:room-runtime:2.6.1")
    implementation("androidx.room:room-ktx:2.6.1")
    ksp("androidx.room:room-compiler:2.6.1")

    // DataStore
    implementation("androidx.datastore:datastore-preferences:1.1.1")

    // Coroutines
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")

    // Retrofit + OkHttp + Gson
    implementation("com.squareup.retrofit2:retrofit:2.11.0")
    implementation("com.squareup.retrofit2:converter-gson:2.11.0")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("com.squareup.okhttp3:logging-interceptor:4.12.0")

    // WorkManager
    implementation("androidx.work:work-runtime-ktx:2.9.0")

    // Splash Screen API
    implementation("androidx.core:core-splashscreen:1.0.1")

    // Core
    implementation("androidx.core:core-ktx:1.13.1")

    // Gson
    implementation("com.google.code.gson:gson:2.11.0")

    // 高德地图 SDK (使用本地最新版本)
    implementation(fileTree(mapOf("dir" to "libs", "include" to listOf("*.jar"))))

    // Debug tools
    debugImplementation("androidx.compose.ui:ui-tooling")
    debugImplementation("androidx.compose.ui:ui-test-manifest")

    // Aptabase Analytics
    implementation("com.github.aptabase:aptabase-kotlin:0.0.8")

    // Testing
    testImplementation("junit:junit:4.13.2")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
}

val nativeVerificationProperties = Properties()
val nativeVerificationPropertiesFile = rootProject.file("local.properties")
if (nativeVerificationPropertiesFile.exists()) {
    nativeVerificationPropertiesFile.inputStream().use(nativeVerificationProperties::load)
}

val verifyAmapNativePageSize by tasks.registering(VerifyNativePageSizeTask::class) {
    group = "verification"
    description = "Verifies bundled AMap arm64 native libraries support Android 16 KB page sizes."
    nativeLibDir.set(layout.projectDirectory.dir("libs/arm64-v8a"))
    sdkDir.set(
        nativeVerificationProperties.getProperty("sdk.dir")
            ?: System.getenv("ANDROID_HOME")
            ?: System.getenv("ANDROID_SDK_ROOT")
            ?: ""
    )
    ndkVersion.set(requiredNdkVersion)
    requiredAlignment.set(requiredNativePageAlignment)
}

tasks.named("preBuild") {
    dependsOn(verifyAmapNativePageSize)
}

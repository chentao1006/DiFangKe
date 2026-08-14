import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("com.google.devtools.ksp")
    id("org.jetbrains.kotlin.plugin.compose")
}

val requiredNdkVersion = "27.1.12297006"
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

        manifestPlaceholders["TENCENT_MAP_KEY"] =
            localProperties.getProperty("TENCENT_MAP_KEY") ?: ""
        buildConfigField(
            "String",
            "TENCENT_MAP_KEY",
            "\"${localProperties.getProperty("TENCENT_MAP_KEY") ?: ""}\""
        )
        buildConfigField(
            "String",
            "TENCENT_MAP_SECRET",
            "\"${localProperties.getProperty("TENCENT_MAP_SECRET") ?: ""}\""
        )

        buildConfigField("String", "SERVICE_SECRET", "\"${localProperties.getProperty("SERVICE_SECRET") ?: ""}\"")
        buildConfigField("String", "PUBLIC_SERVICE_URL", "\"${localProperties.getProperty("PUBLIC_SERVICE_URL") ?: ""}\"")
        buildConfigField("String", "APTABASE_APP_KEY", "\"${localProperties.getProperty("APTABASE_APP_KEY") ?: ""}\"")
    }

    flavorDimensions += "distribution"
    productFlavors {
        create("direct") {
            dimension = "distribution"
            buildConfigField("boolean", "IS_PLAY_DISTRIBUTION", "false")
        }
        create("play") {
            dimension = "distribution"
            buildConfigField("boolean", "IS_PLAY_DISTRIBUTION", "true")
        }
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
            // Tencent Map supplies native binaries through Maven AARs.
            jniLibs.setSrcDirs(emptyList<String>())
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

    // Health Connect: read user-authorized steps/distance/floors for timeline metrics.
    implementation("androidx.health.connect:connect-client:1.1.0-alpha11")

    // Gson
    implementation("com.google.code.gson:gson:2.11.0")

    // 腾讯地图与定位 SDK
    implementation("com.tencent.map:tencent-map-vector-sdk:5.10.0")
    implementation("com.tencent.map.geolocation:TencentLocationSdk-openplatform:7.6.1.12")

    // Debug tools
    debugImplementation("androidx.compose.ui:ui-tooling")
    debugImplementation("androidx.compose.ui:ui-test-manifest")

    // Aptabase Analytics
    implementation("com.github.aptabase:aptabase-kotlin:0.0.8")

    // Testing
    testImplementation("junit:junit:4.13.2")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
}

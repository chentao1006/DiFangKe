# Tencent Map SDK keeps its consumer rules in the published AARs.
# Tencent Location SDK optionally reads this OPlus system class at runtime.
# It is absent on non-OPlus devices, so R8 must not require it at build time.
-dontwarn com.oplus.os.OplusBuild

# GSON
-keepattributes Signature
-keepattributes *Annotation*
-keep class com.google.gson.** { *; }

# Apps Data Models & Config
-keep class com.ct106.difangke.AppConfig { *; }
-keep class com.ct106.difangke.service.UpdateInfo { *; }
-keep class com.ct106.difangke.service.UpdateManager { *; }
-keep class com.ct106.difangke.data.db.entity.** { *; }

# Preserve source file and line number information for crash reporting
-keepattributes SourceFile,LineNumberTable

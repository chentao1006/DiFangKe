# AMap SDK ProGuard Rules
-dontwarn com.amap.ams.gnss.**
-dontwarn net.jafama.**
-dontwarn com.amap.api.**
-dontwarn com.autonavi.**
-dontwarn com.loc.**

-keep class com.amap.api.** {*;}
-keep class com.autonavi.** {*;}
-keep class com.amap.location.** {*;}
-keep class com.loc.** {*;}
-keep class com.amap.api.location.** {*;}
-keep class com.amap.api.fence.** {*;}
-keep class com.autonavi.aps.amapapi.model.** {*;}
-keep class com.amap.api.maps.** {*;}
-keep class com.autonavi.amap.mapcore.** {*;}
-keep class com.amap.api.services.** {*;}

# If you use search
-keep class com.amap.api.services.** {*;}

# If you use navigation
-keep class com.amap.api.navi.** {*;}
-keep class com.autonavi.tbt.** {*;}

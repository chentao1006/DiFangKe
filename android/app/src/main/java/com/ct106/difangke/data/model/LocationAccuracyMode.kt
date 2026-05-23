package com.ct106.difangke.data.model

enum class LocationAccuracyMode(val id: String, val title: String, val description: String) {
    AUTOMATIC("automatic", "自动 (推荐)", "根据活动状态智能调整定位精度，兼顾轨迹质量与电池续航。"),
    HIGH("high", "高精度", "强制保持最高精度定位，轨迹最准但耗电量大。"),
    BALANCED("balanced", "均衡", "使用标准精度，适合日常通勤记录。"),
    POWER_SAVING("powerSaving", "省电", "仅在移动距离较大时记录，最大程度省电。");

    companion object {
        fun fromId(id: String): LocationAccuracyMode {
            return values().firstOrNull { it.id == id } ?: AUTOMATIC
        }
    }
}

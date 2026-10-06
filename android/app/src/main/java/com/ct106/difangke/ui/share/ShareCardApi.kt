package com.ct106.difangke.ui.share

import androidx.compose.runtime.Composable
import java.util.Date

/**
 * Public entry points for the iOS-parity share cards (ios/DiFangKe/Views/ShareCards.swift).
 *
 * Callers only describe *what* to share; the preview dialog loads its own data
 * from Room, renders a 1080-px card bitmap, and shares it through FileProvider.
 *
 * Usage:
 * ```
 * var request by remember { mutableStateOf<ShareCardRequest?>(null) }
 * request?.let { ShareCardPreviewDialog(it, onDismiss = { request = null }) }
 * ```
 */
sealed class ShareCardRequest {
    /** A single footprint ("单次足迹"); `footprintId` is `FootprintEntity.footprintID`. */
    data class Moment(val footprintId: String) : ShareCardRequest()

    /**
     * All footprints of the local calendar days `startDate`..`endDate` (inclusive,
     * time-of-day ignored). Pass the same date twice for a single day.
     */
    data class Timeline(val startDate: Date, val endDate: Date) : ShareCardRequest()

    /**
     * Statistics card ("我的生活总结") over [startDate, endDate). `rangeText` is the
     * header text, e.g. "最近30天" / "2025年".
     */
    data class Stats(val rangeText: String, val startDate: Date, val endDate: Date) : ShareCardRequest()
}

/** Full-screen share preview: themes, editable/AI title, per-entry toggles, "分享给朋友". */
@Composable
fun ShareCardPreviewDialog(request: ShareCardRequest, onDismiss: () -> Unit) {
    ShareCardPreviewScreen(request = request, onDismiss = onDismiss)
}

/**
 * iOS DFKTimelineShareRangePicker: pick a start (and optional end) day.
 * `onPick(start, end)` receives start-of-day dates; `end == start` when no end was chosen.
 */
@Composable
fun ShareRangePickerDialog(
    onPick: (startDate: Date, endDate: Date) -> Unit,
    onDismiss: () -> Unit,
    initialDate: Date = Date()
) {
    ShareRangePickerContent(initialDate = initialDate, onPick = onPick, onDismiss = onDismiss)
}

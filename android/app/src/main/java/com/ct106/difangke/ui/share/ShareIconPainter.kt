package com.ct106.difangke.ui.share

import android.graphics.Canvas
import android.graphics.Paint
import androidx.compose.ui.graphics.PathFillType
import androidx.compose.ui.graphics.asAndroidPath
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.VectorGroup
import androidx.compose.ui.graphics.vector.VectorPath
import androidx.compose.ui.graphics.vector.toPath
import com.ct106.difangke.ui.components.getIconForName

/**
 * Draws the app's Material activity icons (the same names `getIconForName`
 * resolves for the timeline) onto a plain android.graphics.Canvas, so the
 * share-card bitmap uses identical glyphs without a Compose composition.
 */
internal object ShareIconPainter {
    fun draw(canvas: Canvas, iconName: String?, centerX: Float, centerY: Float, size: Float, color: Int) {
        val vector = getIconForName(iconName ?: "place")
        drawVector(canvas, vector, centerX - size / 2f, centerY - size / 2f, size, color)
    }

    fun drawVector(canvas: Canvas, vector: ImageVector, left: Float, top: Float, size: Float, color: Int) {
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            this.color = color
            style = Paint.Style.FILL
        }
        canvas.save()
        canvas.translate(left, top)
        canvas.scale(size / vector.viewportWidth, size / vector.viewportHeight)
        drawGroup(canvas, vector.root, paint, android.graphics.Color.alpha(color))
        canvas.restore()
    }

    private fun drawGroup(canvas: Canvas, group: VectorGroup, paint: Paint, baseAlpha: Int) {
        canvas.save()
        canvas.translate(group.translationX + group.pivotX, group.translationY + group.pivotY)
        canvas.rotate(group.rotation)
        canvas.scale(group.scaleX, group.scaleY)
        canvas.translate(-group.pivotX, -group.pivotY)
        for (node in group) {
            when (node) {
                is VectorPath -> {
                    val path = node.pathData.toPath().asAndroidPath()
                    path.fillType = if (node.pathFillType == PathFillType.EvenOdd) {
                        android.graphics.Path.FillType.EVEN_ODD
                    } else {
                        android.graphics.Path.FillType.WINDING
                    }
                    paint.alpha = (baseAlpha * node.fillAlpha).toInt().coerceIn(0, 255)
                    canvas.drawPath(path, paint)
                    paint.alpha = baseAlpha
                }
                is VectorGroup -> drawGroup(canvas, node, paint, baseAlpha)
            }
        }
        canvas.restore()
    }
}

package com.pacewisdom.oneplusconnect.input

import android.view.MotionEvent
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Encodes a MotionEvent as the binary TOUCH payload with coordinates normalized to the
 * video rectangle (0..1), so the Mac maps them onto its display independent of resolution.
 *
 * u8 action, u8 actionIndex, u8 pointerCount, u8 flags
 * per pointer: u8 id, u8 toolType, u16 reserved, f32 x, f32 y, f32 pressure
 */
object TouchEncoder {
    private const val ACTION_DOWN = 0
    private const val ACTION_MOVE = 1
    private const val ACTION_UP = 2
    private const val ACTION_POINTER_DOWN = 3
    private const val ACTION_POINTER_UP = 4
    private const val ACTION_CANCEL = 5

    fun encode(event: MotionEvent, viewWidth: Int, viewHeight: Int): ByteArray? {
        val action = when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> ACTION_DOWN
            MotionEvent.ACTION_MOVE -> ACTION_MOVE
            MotionEvent.ACTION_UP -> ACTION_UP
            MotionEvent.ACTION_POINTER_DOWN -> ACTION_POINTER_DOWN
            MotionEvent.ACTION_POINTER_UP -> ACTION_POINTER_UP
            MotionEvent.ACTION_CANCEL -> ACTION_CANCEL
            else -> return null
        }
        val count = event.pointerCount.coerceAtMost(10)
        val w = viewWidth.coerceAtLeast(1).toFloat()
        val h = viewHeight.coerceAtLeast(1).toFloat()
        val buf = ByteBuffer.allocate(4 + count * 16).order(ByteOrder.BIG_ENDIAN)
        buf.put(action.toByte())
        buf.put(event.actionIndex.toByte())
        buf.put(count.toByte())
        buf.put(0)
        for (i in 0 until count) {
            val tool = when (event.getToolType(i)) {
                MotionEvent.TOOL_TYPE_STYLUS, MotionEvent.TOOL_TYPE_ERASER -> 1
                MotionEvent.TOOL_TYPE_FINGER -> 0
                else -> 255
            }
            buf.put(event.getPointerId(i).coerceIn(0, 255).toByte())
            buf.put(tool.toByte())
            buf.putShort(0)
            buf.putFloat((event.getX(i) / w).coerceIn(0f, 1f))
            buf.putFloat((event.getY(i) / h).coerceIn(0f, 1f))
            buf.putFloat(event.getPressure(i))
        }
        return buf.array()
    }
}

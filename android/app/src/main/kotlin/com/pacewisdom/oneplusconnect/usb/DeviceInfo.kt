package com.pacewisdom.oneplusconnect.usb

import android.content.Context
import android.content.res.Configuration
import android.hardware.display.DisplayManager
import android.os.BatteryManager
import android.os.Build
import android.os.PowerManager
import android.view.Display
import android.view.InputDevice
import android.view.Surface
import com.pacewisdom.oneplusconnect.protocol.Messages
import com.pacewisdom.oneplusconnect.video.VideoDecoder

/** Reads the tablet's capabilities for HELLO_ACK and the dashboard. */
object DeviceInfo {

    fun defaultDisplay(context: Context): Display? =
        context.getSystemService(DisplayManager::class.java)?.getDisplay(Display.DEFAULT_DISPLAY)

    /** Physical panel size in the current rotation (width/height swap with orientation). */
    fun physicalSize(context: Context): Pair<Int, Int> {
        val d = defaultDisplay(context) ?: return 0 to 0
        val mode = d.mode
        var w = mode.physicalWidth
        var h = mode.physicalHeight
        val portrait = context.resources.configuration.orientation == Configuration.ORIENTATION_PORTRAIT
        if (portrait && w > h) { val t = w; w = h; h = t }
        if (!portrait && w < h) { val t = w; w = h; h = t }
        return w to h
    }

    fun refreshRates(context: Context): List<Double> {
        val d = defaultDisplay(context) ?: return listOf(60.0)
        return d.supportedModes.map { Math.round(it.refreshRate).toDouble() }.distinct().sorted()
    }

    fun currentRefreshRate(context: Context): Int =
        defaultDisplay(context)?.refreshRate?.let { Math.round(it) } ?: 60

    fun orientation(context: Context): String {
        val portrait = context.resources.configuration.orientation == Configuration.ORIENTATION_PORTRAIT
        val rotation = defaultDisplay(context)?.rotation ?: Surface.ROTATION_0
        val reversed = rotation == Surface.ROTATION_180 || rotation == Surface.ROTATION_270
        return when {
            portrait && reversed -> "reverse_portrait"
            portrait -> "portrait"
            reversed -> "reverse_landscape"
            else -> "landscape"
        }
    }

    fun hasStylus(): Boolean = InputDevice.getDeviceIds().any { id ->
        InputDevice.getDevice(id)?.supportsSource(InputDevice.SOURCE_STYLUS) == true
    }

    fun modelName(): String {
        val model = Build.MODEL ?: "Android tablet"
        val manufacturer = Build.MANUFACTURER ?: ""
        return if (model.lowercase().startsWith(manufacturer.lowercase())) model else "$manufacturer $model".trim()
    }

    fun capabilities(context: Context): Messages.DeviceCapabilities {
        val (w, h) = physicalSize(context)
        return Messages.DeviceCapabilities(
            deviceModel = modelName(),
            manufacturer = Build.MANUFACTURER ?: "",
            androidVersion = Build.VERSION.RELEASE ?: "",
            displayWidth = w,
            displayHeight = h,
            refreshRates = refreshRates(context),
            codecs = VideoDecoder.supportedDecoderMimes(),
            touch = true,
            multitouch = true,
            stylus = hasStylus(),
            orientation = orientation(context),
            densityDpi = context.resources.configuration.densityDpi,
            maxFpsAtNative = VideoDecoder.maxFrameRateFor(maxOf(w, h), minOf(w, h), VideoDecoder.MIME_H264),
            maxFpsAtNativeHevc = VideoDecoder.maxFrameRateFor(maxOf(w, h), minOf(w, h), VideoDecoder.MIME_HEVC),
        )
    }

    fun batteryPercent(context: Context): Int? {
        val bm = context.getSystemService(BatteryManager::class.java) ?: return null
        val v = bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
        return if (v in 0..100) v else null
    }

    fun thermalStatus(context: Context): String {
        val pm = context.getSystemService(PowerManager::class.java) ?: return "unknown"
        return when (pm.currentThermalStatus) {
            PowerManager.THERMAL_STATUS_NONE -> "none"
            PowerManager.THERMAL_STATUS_LIGHT -> "light"
            PowerManager.THERMAL_STATUS_MODERATE -> "moderate"
            PowerManager.THERMAL_STATUS_SEVERE -> "severe"
            PowerManager.THERMAL_STATUS_CRITICAL -> "critical"
            PowerManager.THERMAL_STATUS_EMERGENCY -> "emergency"
            PowerManager.THERMAL_STATUS_SHUTDOWN -> "shutdown"
            else -> "unknown"
        }
    }
}

package com.pacewisdom.oneplusconnect.usb

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.database.ContentObserver
import android.os.BatteryManager
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import androidx.core.content.ContextCompat

/** Reports USB cable presence and whether USB debugging is enabled. */
class UsbMonitor(private val context: Context, private val onChange: (usbConnected: Boolean, adbEnabled: Boolean) -> Unit) {

    companion object {
        // Hidden but stable system broadcast; sticky.
        private const val ACTION_USB_STATE = "android.hardware.usb.action.USB_STATE"
    }

    @Volatile var usbConnected = false; private set
    @Volatile var adbEnabled = false; private set
    private var pluggedUsb = false
    private var usbStateConnected: Boolean? = null

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(ctx: Context, intent: Intent) {
            when (intent.action) {
                ACTION_USB_STATE -> usbStateConnected = intent.getBooleanExtra("connected", false)
                Intent.ACTION_BATTERY_CHANGED -> {
                    val plugged = intent.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0)
                    pluggedUsb = plugged == BatteryManager.BATTERY_PLUGGED_USB
                }
            }
            recompute()
        }
    }

    private val adbObserver = object : ContentObserver(Handler(Looper.getMainLooper())) {
        override fun onChange(selfChange: Boolean) = recompute()
    }

    fun start() {
        val filter = IntentFilter().apply {
            addAction(ACTION_USB_STATE)
            addAction(Intent.ACTION_BATTERY_CHANGED)
        }
        ContextCompat.registerReceiver(context, receiver, filter, ContextCompat.RECEIVER_EXPORTED)
        context.contentResolver.registerContentObserver(Settings.Global.getUriFor(Settings.Global.ADB_ENABLED), false, adbObserver)
        recompute()
    }

    fun stop() {
        runCatching { context.unregisterReceiver(receiver) }
        context.contentResolver.unregisterContentObserver(adbObserver)
    }

    fun recompute() {
        val adb = Settings.Global.getInt(context.contentResolver, Settings.Global.ADB_ENABLED, 0) == 1
        val usb = usbStateConnected ?: pluggedUsb
        val changed = usb != usbConnected || adb != adbEnabled
        usbConnected = usb
        adbEnabled = adb
        if (changed) onChange(usb, adb)
    }
}

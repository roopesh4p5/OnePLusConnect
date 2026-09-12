package com.pacewisdom.oneplusconnect

import android.app.Application
import com.pacewisdom.oneplusconnect.connection.ConnectionEngine

class OnePlusConnectApp : Application() {
    lateinit var engine: ConnectionEngine
        private set

    override fun onCreate() {
        super.onCreate()
        engine = ConnectionEngine(this)
        engine.start()
    }
}

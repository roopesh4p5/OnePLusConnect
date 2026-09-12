package com.pacewisdom.oneplusconnect.protocol

import org.json.JSONArray
import org.json.JSONObject

/** JSON control payloads. Field names must match the Mac's Codable structs. */
object Messages {

    data class Hello(val protocolVersion: Int, val appVersion: String, val deviceId: String, val hostName: String, val capabilities: List<String>) {
        companion object {
            fun parse(bytes: ByteArray): Hello? = runCatching {
                val j = JSONObject(String(bytes, Charsets.UTF_8))
                val caps = j.optJSONArray("capabilities")?.let { a -> List(a.length()) { a.getString(it) } } ?: emptyList()
                Hello(j.optInt("protocolVersion", 1), j.optString("appVersion", "?"), j.optString("deviceId", ""), j.optString("hostName", "Mac"), caps)
            }.getOrNull()
        }
    }

    data class DeviceCapabilities(
        val deviceModel: String,
        val manufacturer: String,
        val androidVersion: String,
        val displayWidth: Int,
        val displayHeight: Int,
        val refreshRates: List<Double>,
        val codecs: List<String>,
        val touch: Boolean,
        val multitouch: Boolean,
        val stylus: Boolean,
        val orientation: String,
        val densityDpi: Int,
        /** Max decodable fps at the panel's native size, per codec (0 = unknown). */
        val maxFpsAtNative: Int = 0,
        val maxFpsAtNativeHevc: Int = 0,
    )

    fun helloAck(c: DeviceCapabilities, appVersion: String): ByteArray = JSONObject().apply {
        put("protocolVersion", 1)
        put("appVersion", appVersion)
        put("deviceModel", c.deviceModel)
        put("manufacturer", c.manufacturer)
        put("androidVersion", c.androidVersion)
        put("displayWidth", c.displayWidth)
        put("displayHeight", c.displayHeight)
        put("refreshRates", JSONArray(c.refreshRates))
        put("codecs", JSONArray(c.codecs))
        put("touch", c.touch)
        put("multitouch", c.multitouch)
        put("stylus", c.stylus)
        put("orientation", c.orientation)
        put("densityDpi", c.densityDpi)
        if (c.maxFpsAtNative > 0) put("maxFpsAtNative", c.maxFpsAtNative)
        if (c.maxFpsAtNativeHevc > 0) put("maxFpsAtNativeHevc", c.maxFpsAtNativeHevc)
    }.bytes()

    data class SessionConfig(
        val sessionId: Long,
        val mode: String,
        val width: Int,
        val height: Int,
        val fps: Int,
        val bitrate: Int,
        val codec: String,
        val colorFormat: String,
        val orientation: String,
    ) {
        val bitrateMbps: Double get() = bitrate / 1_000_000.0

        companion object {
            fun parse(bytes: ByteArray): SessionConfig? = runCatching {
                val j = JSONObject(String(bytes, Charsets.UTF_8))
                SessionConfig(
                    sessionId = j.getLong("sessionId"),
                    mode = j.optString("mode", "mirror"),
                    width = j.getInt("width"),
                    height = j.getInt("height"),
                    fps = j.optInt("fps", 60),
                    bitrate = j.optInt("bitrate", 10_000_000),
                    codec = j.optString("codec", "h264"),
                    colorFormat = j.optString("colorFormat", "nv12"),
                    orientation = j.optString("orientation", "landscape"),
                )
            }.getOrNull()
        }
    }

    fun configAck(sessionId: Long, ok: Boolean, error: String?): ByteArray = JSONObject().apply {
        put("sessionId", sessionId)
        put("ok", ok)
        if (error != null) put("error", error)
    }.bytes()

    fun sessionStop(reason: String): ByteArray = JSONObject().put("reason", reason).bytes()

    fun pingT1(bytes: ByteArray): Long = runCatching { JSONObject(String(bytes, Charsets.UTF_8)).getLong("t1") }.getOrDefault(0L)

    fun pong(t1: Long, t2: Long, t3: Long): ByteArray = JSONObject().apply {
        put("t1", t1); put("t2", t2); put("t3", t3)
    }.bytes()

    fun orientation(orientation: String, displayWidth: Int, displayHeight: Int): ByteArray = JSONObject().apply {
        put("orientation", orientation)
        put("displayWidth", displayWidth)
        put("displayHeight", displayHeight)
    }.bytes()

    data class Stats(
        val fps: Double,
        val decodeLatencyMs: Double,
        val renderedFrames: Int,
        val droppedFrames: Int,
        val queueDepth: Int,
        val battery: Int?,
        val thermal: String,
        val pipelineLatencyRawMs: Double,
    )

    fun stats(s: Stats): ByteArray = JSONObject().apply {
        put("fps", s.fps)
        put("decodeLatencyMs", s.decodeLatencyMs)
        put("renderedFrames", s.renderedFrames)
        put("droppedFrames", s.droppedFrames)
        put("queueDepth", s.queueDepth)
        if (s.battery != null) put("battery", s.battery)
        put("thermal", s.thermal)
        put("pipelineLatencyRawMs", s.pipelineLatencyRawMs)
    }.bytes()

    fun error(code: String, message: String): ByteArray = JSONObject().apply {
        put("code", code); put("message", message)
    }.bytes()

    private fun JSONObject.bytes(): ByteArray = toString().toByteArray(Charsets.UTF_8)
}

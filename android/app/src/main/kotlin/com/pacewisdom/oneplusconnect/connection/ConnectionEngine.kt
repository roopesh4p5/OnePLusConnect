package com.pacewisdom.oneplusconnect.connection

import android.content.Context
import android.util.Log
import android.view.MotionEvent
import android.view.Surface
import com.pacewisdom.oneplusconnect.input.TouchEncoder
import com.pacewisdom.oneplusconnect.network.DiscoveryBeacon
import com.pacewisdom.oneplusconnect.network.WifiMonitor
import com.pacewisdom.oneplusconnect.protocol.Clock
import com.pacewisdom.oneplusconnect.protocol.Messages
import com.pacewisdom.oneplusconnect.protocol.Packet
import com.pacewisdom.oneplusconnect.protocol.PacketIO
import com.pacewisdom.oneplusconnect.protocol.PacketType
import com.pacewisdom.oneplusconnect.usb.DeviceInfo
import com.pacewisdom.oneplusconnect.usb.UsbMonitor
import com.pacewisdom.oneplusconnect.video.VideoDecoder
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.IOException
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong

/**
 * Tablet-side connection service: listens on port 27183 on every interface — reached through
 * `adb forward` over USB-C, or directly over Wi-Fi — answers the handshake, feeds video to the
 * decoder, and sends touch/stats back. While no Mac is connected and Wi-Fi is up, a UDP beacon
 * announces the tablet so the Mac can fall back to wireless when no cable is detected.
 */
class ConnectionEngine(private val context: Context) : VideoDecoder.Listener {

    companion object {
        private const val TAG = "ConnectionEngine"
        const val APP_VERSION = "0.1.0"
        const val DEFAULT_PORT = 27183
    }

    data class StatsSnapshot(
        val fps: Double = 0.0,
        val decodeLatencyMs: Double = 0.0,
        val dropped: Int = 0,
        val rendered: Int = 0,
    )

    data class UiState(
        val usbConnected: Boolean = false,
        val adbEnabled: Boolean = false,
        val wifiConnected: Boolean = false,
        val wifiAddress: String? = null,
        val macConnected: Boolean = false,
        val macName: String? = null,
        /** "USB" or "Wi-Fi" while a Mac is connected. */
        val link: String? = null,
        val session: Messages.SessionConfig? = null,
        val videoActive: Boolean = false,
        val inputActive: Boolean = false,
        val battery: Int? = null,
        val statusText: String = "Connect your tablet to your Mac using USB-C, or join the same Wi-Fi network.",
        val stats: StatsSnapshot = StatsSnapshot(),
        val lastError: String? = null,
    ) {
        val streaming: Boolean get() = session != null
    }

    private val _state = MutableStateFlow(UiState())
    val state: StateFlow<UiState> = _state

    private val usbMonitor = UsbMonitor(context) { usb, adb ->
        _state.update { it.copy(usbConnected = usb, adbEnabled = adb) }
        refreshStatusText()
    }
    private val wifiMonitor = WifiMonitor(context) { connected, address ->
        Log.i(TAG, if (connected) "Wi-Fi up: $address" else "Wi-Fi down")
        _state.update { it.copy(wifiConnected = connected, wifiAddress = address) }
        refreshStatusText()
    }
    private val beacon = DiscoveryBeacon(
        wifi = wifiMonitor,
        port = DiscoveryBeacon.DEFAULT_PORT,
        servicePort = DEFAULT_PORT,
        deviceName = DeviceInfo.modelName(),
        shouldAnnounce = { !_state.value.macConnected },
    )

    private var server: ServerSocket? = null
    private var acceptThread: Thread? = null
    @Volatile private var client: ClientLink? = null
    private val decoder = VideoDecoder(this)
    @Volatile private var sessionConfig: Messages.SessionConfig? = null
    private var statsThread: Thread? = null
    @Volatile private var running = false
    private val sequence = AtomicLong()

    // ---------------------------------------------------------------- lifecycle

    fun start() {
        if (running) return
        running = true
        usbMonitor.start()
        wifiMonitor.start()
        beacon.start()
        _state.update { it.copy(battery = DeviceInfo.batteryPercent(context)) }
        acceptThread = Thread({ acceptLoop() }, "opc-accept").apply { isDaemon = true; start() }
        statsThread = Thread({ statsLoop() }, "opc-stats").apply { isDaemon = true; start() }
        refreshStatusText()
    }

    fun stop() {
        running = false
        client?.close()
        runCatching { server?.close() }
        beacon.stop()
        wifiMonitor.stop()
        usbMonitor.stop()
        decoder.release()
    }

    private fun acceptLoop() {
        while (running) {
            try {
                val ss = ServerSocket().apply {
                    reuseAddress = true
                    // All interfaces: loopback for the adb tunnel (USB), the Wi-Fi address for wireless.
                    bind(InetSocketAddress(DEFAULT_PORT), 1)
                }
                server = ss
                Log.i(TAG, "Listening on 0.0.0.0:$DEFAULT_PORT")
                while (running) {
                    val socket = ss.accept()
                    socket.tcpNoDelay = true
                    socket.receiveBufferSize = 1 shl 20
                    // The Mac pings every second. If nothing arrives for 10 s the link is dead (e.g. the cable
                    // was pulled and adbd kept the tunnel half-open); closing it lets the Wi-Fi beacon resume.
                    socket.soTimeout = 10_000
                    Log.i(TAG, "Mac connected from ${socket.remoteSocketAddress} (${linkName(socket)})")
                    client?.close() // a newer connection always wins (Mac restarted / reconnected)
                    val link = ClientLink(socket)
                    client = link
                    Thread({
                        link.run() // blocks until this client disconnects
                        if (client === link) {
                            client = null
                            onClientClosed()
                        }
                    }, "opc-link").apply { isDaemon = true; start() }
                }
            } catch (e: IOException) {
                if (running) {
                    Log.w(TAG, "Server socket error: ${e.message}; retrying in 1s")
                    try { Thread.sleep(1000) } catch (_: InterruptedException) {}
                }
            } finally {
                runCatching { server?.close() }
            }
        }
    }

    private fun onClientClosed() {
        endSession(notifyMac = false, reason = "link closed")
        _state.update { it.copy(macConnected = false, macName = null, link = null, inputActive = false) }
        refreshStatusText()
    }

    /** USB traffic arrives through the adb tunnel on loopback; anything else came over the network. */
    private fun linkName(socket: Socket): String =
        if (socket.inetAddress?.isLoopbackAddress == true) "USB" else "Wi-Fi"

    // ---------------------------------------------------------------- client link

    private inner class ClientLink(private val socket: Socket) {
        val link: String = linkName(socket)
        private val input = DataInputStream(BufferedInputStream(socket.getInputStream(), 512 * 1024))
        private val output = DataOutputStream(BufferedOutputStream(socket.getOutputStream(), 64 * 1024))
        private val outgoing = LinkedBlockingQueue<Packet>(512)
        @Volatile private var open = true
        private val writer = Thread({ writeLoop() }, "opc-writer").apply { isDaemon = true }

        fun run() {
            writer.start()
            try {
                while (open) {
                    val packet = PacketIO.read(input)
                    handle(packet)
                }
            } catch (e: IOException) {
                if (open) Log.i(TAG, "Link closed: ${e.message}")
            } finally {
                close()
            }
        }

        private fun writeLoop() {
            try {
                while (open) {
                    val p = outgoing.poll(200, TimeUnit.MILLISECONDS) ?: continue
                    PacketIO.write(output, p)
                }
            } catch (e: Exception) {
                if (open) Log.w(TAG, "Write failed: ${e.message}")
                close()
            }
        }

        /** Control packets block until queued; touch packets are dropped if the queue is full. */
        fun send(p: Packet, dropIfBusy: Boolean = false) {
            if (!open) return
            if (dropIfBusy) outgoing.offer(p) else outgoing.put(p)
        }

        fun close() {
            if (!open) return
            open = false
            runCatching { socket.close() }
            writer.interrupt()
        }
    }

    private fun send(type: Int, payload: ByteArray = Packet.EMPTY, dropIfBusy: Boolean = false) {
        val link = client ?: return
        link.send(Packet(type, payload, sessionId = sessionConfig?.sessionId ?: 0, sequence = sequence.incrementAndGet()), dropIfBusy)
    }

    // ---------------------------------------------------------------- packet handling

    private fun handle(p: Packet) {
        when (p.type) {
            PacketType.HELLO -> {
                val hello = Messages.Hello.parse(p.payload)
                val link = client?.link ?: "USB"
                Log.i(TAG, "HELLO from ${hello?.hostName} v${hello?.appVersion} over $link")
                val caps = DeviceInfo.capabilities(context)
                send(PacketType.HELLO_ACK, Messages.helloAck(caps, APP_VERSION))
                _state.update { it.copy(macConnected = true, macName = hello?.hostName ?: "Mac", link = link, lastError = null) }
                refreshStatusText()
            }
            PacketType.CONFIG -> {
                val cfg = Messages.SessionConfig.parse(p.payload)
                if (cfg == null) {
                    send(PacketType.CONFIG_ACK, Messages.configAck(0, false, "malformed config"))
                    return
                }
                startSession(cfg)
            }
            PacketType.VIDEO_CONFIG -> decoder.setParameterSets(p.payload)
            PacketType.VIDEO, PacketType.KEYFRAME -> {
                decoder.enqueue(p.payload, p.type == PacketType.KEYFRAME || p.isKeyframe, p.timestamp)
            }
            PacketType.PING -> {
                val t1 = Messages.pingT1(p.payload)
                val t2 = Clock.nowMicros()
                send(PacketType.PONG, Messages.pong(t1, t2, Clock.nowMicros()))
            }
            PacketType.PONG -> {}
            PacketType.SESSION_STOP -> {
                Log.i(TAG, "Mac stopped the session")
                endSession(notifyMac = false, reason = "mac")
            }
            PacketType.DISCONNECT -> client?.close()
            PacketType.ERROR -> Log.w(TAG, "Mac error: ${String(p.payload, Charsets.UTF_8)}")
            else -> Log.d(TAG, "Unhandled packet type 0x${Integer.toHexString(p.type)}")
        }
    }

    // ---------------------------------------------------------------- session

    private fun startSession(cfg: Messages.SessionConfig) {
        val mime = VideoDecoder.mimeFor(cfg.codec)
        if (!VideoDecoder.isHardwareDecoderAvailable(mime)) {
            send(PacketType.CONFIG_ACK, Messages.configAck(cfg.sessionId, false, "Tablet could not decode the selected video format (${cfg.codec})."))
            return
        }
        val previous = sessionConfig
        sessionConfig = cfg
        Log.i(TAG, "Session ${cfg.sessionId}: ${cfg.mode} ${cfg.width}x${cfg.height} @${cfg.fps} ${cfg.codec} ${cfg.bitrateMbps} Mbps")
        if (previous == null) decoder.resetStats()
        decoder.setCodec(cfg.codec)
        decoder.setStreamSize(cfg.width, cfg.height)
        _state.update { it.copy(session = cfg, videoActive = false, inputActive = true, lastError = null) }
        send(PacketType.CONFIG_ACK, Messages.configAck(cfg.sessionId, true, null))
        refreshStatusText()
        // The decoder starts once the stream surface is attached and VIDEO_CONFIG arrives;
        // it then asks the Mac for a keyframe.
    }

    /** Called from the UI ("Stop Sharing" / back) or internally. */
    fun stopSession() = endSession(notifyMac = true, reason = "user")

    private fun endSession(notifyMac: Boolean, reason: String) {
        val cfg = sessionConfig ?: return
        if (notifyMac) send(PacketType.SESSION_STOP, Messages.sessionStop(reason))
        sessionConfig = null
        decoder.release()
        Log.i(TAG, "Session ${cfg.sessionId} ended ($reason)")
        _state.update { it.copy(session = null, videoActive = false, stats = StatsSnapshot()) }
        refreshStatusText()
    }

    // ---------------------------------------------------------------- surface / input

    fun attachSurface(surface: Surface) = decoder.setSurface(surface)
    fun detachSurface() = decoder.setSurface(null)

    fun onTouch(event: MotionEvent, viewWidth: Int, viewHeight: Int) {
        if (sessionConfig == null) return
        val payload = TouchEncoder.encode(event, viewWidth, viewHeight) ?: return
        val link = client ?: return
        val dropIfBusy = event.actionMasked == MotionEvent.ACTION_MOVE
        link.send(Packet(PacketType.TOUCH, payload, sessionId = sessionConfig?.sessionId ?: 0, sequence = sequence.incrementAndGet()), dropIfBusy)
    }

    fun notifyOrientationChanged() {
        val (w, h) = DeviceInfo.physicalSize(context)
        val o = DeviceInfo.orientation(context)
        if (client != null) send(PacketType.ORIENTATION, Messages.orientation(o, w, h))
    }

    // ---------------------------------------------------------------- decoder callbacks

    override fun onRequestKeyframe() {
        send(PacketType.REQUEST_KEYFRAME)
    }

    override fun onDecoderError(message: String) {
        Log.e(TAG, "Decoder error: $message")
        send(PacketType.ERROR, Messages.error("decoder_failed", message))
        _state.update { it.copy(lastError = "Tablet could not decode the video: $message") }
        endSession(notifyMac = false, reason = "decoder error")
    }

    override fun onFirstFrameRendered() {
        _state.update { it.copy(videoActive = true) }
        refreshStatusText()
    }

    // ---------------------------------------------------------------- stats

    private fun statsLoop() {
        while (running) {
            try { Thread.sleep(1000) } catch (_: InterruptedException) { return }
            val battery = DeviceInfo.batteryPercent(context)
            if (sessionConfig != null && client != null) {
                val s = decoder.sampleStats()
                val stats = Messages.Stats(
                    fps = s.fps,
                    decodeLatencyMs = s.decodeLatencyMs,
                    renderedFrames = s.renderedTotal,
                    droppedFrames = s.droppedTotal,
                    queueDepth = s.queueDepth,
                    battery = battery,
                    thermal = DeviceInfo.thermalStatus(context),
                    pipelineLatencyRawMs = s.pipelineRawMs,
                )
                send(PacketType.STATS, Messages.stats(stats), dropIfBusy = true)
                _state.update { it.copy(battery = battery, stats = StatsSnapshot(s.fps, s.decodeLatencyMs, s.droppedTotal, s.renderedTotal)) }
            } else {
                _state.update { it.copy(battery = battery) }
            }
        }
    }

    private fun refreshStatusText() {
        _state.update { s ->
            val wifi = if (s.wifiConnected) " Wi-Fi is ready on ${s.wifiAddress ?: "this network"} — pick “Wi-Fi” on the Mac to connect wirelessly." else ""
            val text = when {
                s.session != null && !s.videoActive -> "Starting video…"
                s.session != null -> "Sharing over ${s.link ?: "USB"}"
                s.macConnected -> "Mac connected over ${s.link ?: "USB"}. Click Start Sharing on your Mac."
                s.usbConnected && !s.adbEnabled -> "Enable USB debugging in Developer Options.$wifi"
                s.usbConnected -> "Waiting for Mac over USB…$wifi"
                s.wifiConnected -> "Waiting for Mac over Wi-Fi (${s.wifiAddress})…"
                else -> "Connect your tablet to your Mac using USB-C, or join the same Wi-Fi network as your Mac."
            }
            s.copy(statusText = text)
        }
    }
}

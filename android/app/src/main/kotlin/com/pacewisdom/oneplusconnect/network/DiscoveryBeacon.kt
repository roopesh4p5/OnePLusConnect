package com.pacewisdom.oneplusconnect.network

import android.util.Log
import org.json.JSONObject
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress

/**
 * Announces the tablet app on the local network so the Mac can find it without a cable:
 * one small JSON datagram per second to the subnet broadcast address (and 255.255.255.255)
 * on [port]. See PROTOCOL.md "Wi-Fi discovery". Sends only while [shouldAnnounce] is true.
 */
class DiscoveryBeacon(
    private val wifi: WifiMonitor,
    private val port: Int,
    private val servicePort: Int,
    private val deviceName: String,
    private val shouldAnnounce: () -> Boolean,
) {
    companion object {
        private const val TAG = "DiscoveryBeacon"
        const val DEFAULT_PORT = 27184
    }

    @Volatile private var running = false
    private var thread: Thread? = null

    fun start() {
        if (running) return
        running = true
        thread = Thread({ loop() }, "opc-beacon").apply { isDaemon = true; start() }
    }

    fun stop() {
        running = false
        thread?.interrupt()
    }

    private fun loop() {
        var socket: DatagramSocket? = null
        var boundTo: android.net.Network? = null
        while (running) {
            try {
                val snap = wifi.snapshot
                if (snap == null || !shouldAnnounce()) {
                    Thread.sleep(1000); continue
                }
                if (socket == null || boundTo != snap.network) {
                    runCatching { socket?.close() }
                    socket = DatagramSocket().apply { broadcast = true }
                    // Pin the beacon to the Wi-Fi interface even if mobile data is the default route.
                    runCatching { snap.network.bindSocket(socket) }
                    boundTo = snap.network
                }
                val body = JSONObject().apply {
                    put("app", "oneplusconnect")
                    put("v", 1)
                    put("name", deviceName)
                    put("host", snap.address.hostAddress)
                    put("port", servicePort)
                }.toString().toByteArray(Charsets.UTF_8)
                val targets = listOfNotNull(snap.broadcast, InetAddress.getByName("255.255.255.255")).distinct()
                for (t in targets) {
                    runCatching { socket.send(DatagramPacket(body, body.size, t, port)) }
                        .onFailure { Log.d(TAG, "beacon to $t failed: ${it.message}") }
                }
                Thread.sleep(1000)
            } catch (_: InterruptedException) {
                break
            } catch (e: Exception) {
                Log.w(TAG, "beacon error: ${e.message}")
                runCatching { socket?.close() }; socket = null; boundTo = null
                try { Thread.sleep(2000) } catch (_: InterruptedException) { break }
            }
        }
        runCatching { socket?.close() }
    }
}

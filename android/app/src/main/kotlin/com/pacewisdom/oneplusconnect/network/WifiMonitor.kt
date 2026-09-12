package com.pacewisdom.oneplusconnect.network

import android.content.Context
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import java.net.Inet4Address
import java.net.InetAddress
import java.net.NetworkInterface

/**
 * Tracks whether the tablet is on Wi-Fi (or wired Ethernet through a USB-C hub) and what its IPv4
 * address is, so the dashboard can show it and the discovery beacon knows which interface to use.
 */
class WifiMonitor(context: Context, private val onChange: (connected: Boolean, address: String?) -> Unit) {

    data class Snapshot(val network: Network, val address: Inet4Address, val broadcast: InetAddress?)

    private val cm = context.getSystemService(ConnectivityManager::class.java)
    @Volatile var snapshot: Snapshot? = null; private set
    val connected: Boolean get() = snapshot != null
    val address: String? get() = snapshot?.address?.hostAddress

    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onLinkPropertiesChanged(network: Network, linkProperties: LinkProperties) = update(network, linkProperties)
        override fun onAvailable(network: Network) { cm?.getLinkProperties(network)?.let { update(network, it) } }
        override fun onLost(network: Network) {
            if (snapshot?.network == network) { snapshot = null; onChange(false, null) }
        }
    }

    fun start() {
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .addTransportType(NetworkCapabilities.TRANSPORT_ETHERNET)
            .build()
        runCatching { cm?.registerNetworkCallback(request, callback) }
    }

    fun stop() {
        runCatching { cm?.unregisterNetworkCallback(callback) }
    }

    private fun update(network: Network, lp: LinkProperties) {
        val v4 = lp.linkAddresses.mapNotNull { it.address as? Inet4Address }.firstOrNull { !it.isLoopbackAddress }
        if (v4 == null) {
            if (snapshot?.network == network) { snapshot = null; onChange(false, null) }
            return
        }
        val broadcast = runCatching {
            NetworkInterface.getByName(lp.interfaceName)?.interfaceAddresses
                ?.firstOrNull { it.address == v4 }?.broadcast
        }.getOrNull()
        val previous = snapshot
        snapshot = Snapshot(network, v4, broadcast)
        if (previous?.address != v4) onChange(true, v4.hostAddress)
    }
}

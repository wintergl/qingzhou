package dev.splitvpn.android.runtime

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager

/** No scans, SSIDs, internet probes or periodic broadcasts. All callbacks use main. */
class AndroidEnvironmentMonitor(
    private val context: Context,
    private val visible: () -> Boolean,
    private val networkChanged: (NetworkState) -> Unit,
    private val powerChanged: (PowerState) -> Unit
) : AutoCloseable {
    private val handler = Handler(Looper.getMainLooper())
    private val connectivity = context.getSystemService(ConnectivityManager::class.java)
    private val power = context.getSystemService(PowerManager::class.java)
    private var closed = false
    private var queued = false
    private var receiverRegistered = false
    private var networkRegistered = false
    private var defaultRegistered = false
    private var previousNetwork: NetworkState? = null
    private var previousPower: PowerState? = null
    val eventsAvailable: Boolean get() = networkRegistered && defaultRegistered

    private val publishNetwork = Runnable {
        queued = false
        if (!closed) {
            val next = readNetwork()
            if (next != previousNetwork) { previousNetwork = next; networkChanged(next) }
        }
    }
    private fun queueNetwork() {
        if (closed || queued) return
        queued = true
        handler.postDelayed(publishNetwork, 250L)
    }
    private fun callback() = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) = queueNetwork()
        override fun onLost(network: Network) = queueNetwork()
        override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) = queueNetwork()
        override fun onLinkPropertiesChanged(network: Network, properties: LinkProperties) = queueNetwork()
        override fun onBlockedStatusChanged(network: Network, blocked: Boolean) = queueNetwork()
    }
    private val physicalCallback = callback()
    private val defaultCallback = callback()
    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            refreshPower()
            if (intent?.action == Intent.ACTION_SCREEN_ON || intent?.action == PowerManager.ACTION_DEVICE_IDLE_MODE_CHANGED)
                queueNetwork()
        }
    }

    fun start(): NetworkState {
        val request = NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN).build()
        runCatching { connectivity.registerNetworkCallback(request, physicalCallback, handler); networkRegistered = true }
        runCatching { connectivity.registerDefaultNetworkCallback(defaultCallback, handler); defaultRegistered = true }
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_ON); addAction(Intent.ACTION_SCREEN_OFF)
            addAction(PowerManager.ACTION_POWER_SAVE_MODE_CHANGED)
            addAction(PowerManager.ACTION_DEVICE_IDLE_MODE_CHANGED)
        }
        if (Build.VERSION.SDK_INT >= 33) context.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        else context.registerReceiver(receiver, filter)
        receiverRegistered = true
        refreshPower()
        return readNetwork().also { previousNetwork = it }
    }

    fun readNetwork(): NetworkState = runCatching {
        val paths = connectivity.allNetworks.mapNotNull { network ->
            val caps = connectivity.getNetworkCapabilities(network) ?: return@mapNotNull null
            val props = connectivity.getLinkProperties(network) ?: return@mapNotNull null
            val preference = when {
                caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> 3
                caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> 2
                else -> 1
            }
            // Identity is used in memory only; never write local addresses to logs.
            val signature = listOf(props.interfaceName.orEmpty(),
                props.linkAddresses.map { it.toString() }.sorted().joinToString(),
                props.routes.filter { it.isDefaultRoute }.map { it.toString() }.sorted().joinToString(),
                props.dnsServers.map { it.hostAddress.orEmpty() }.sorted().joinToString()).joinToString("|")
            PhysicalPath(network.networkHandle, signature,
                !caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN),
                caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET),
                caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED), preference)
        }
        NetworkState.select(paths, connectivity.activeNetwork?.networkHandle)
    }.getOrDefault(NetworkState.Unknown)

    fun refreshPower() {
        if (closed) return
        val next = PowerState(power.isInteractive, power.isPowerSaveMode, power.isDeviceIdleMode, visible())
        if (previousPower != next) { previousPower = next; powerChanged(next) }
    }

    override fun close() {
        closed = true
        handler.removeCallbacks(publishNetwork)
        if (networkRegistered) runCatching { connectivity.unregisterNetworkCallback(physicalCallback) }
        if (defaultRegistered) runCatching { connectivity.unregisterNetworkCallback(defaultCallback) }
        if (receiverRegistered) runCatching { context.unregisterReceiver(receiver) }
    }
}

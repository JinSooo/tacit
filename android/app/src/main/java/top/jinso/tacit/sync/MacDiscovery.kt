package top.jinso.tacit.sync

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeoutOrNull
import java.net.InetAddress
import java.net.URI
import kotlin.coroutines.resume

internal class MacDiscovery(private val context: Context) {
    private val nsd = context.getSystemService(NsdManager::class.java)
    private val connectivity = context.getSystemService(ConnectivityManager::class.java)

    suspend fun find(
        hubId: String, last: String?, invited: List<String>, manual: String?,
        remainingMillis: () -> Int = { Int.MAX_VALUE },
    ): String {
        val checked = mutableSetOf<String>()
        var exhausted = false
        fun valid(origin: String): Boolean {
            val remaining = remainingMillis()
            if (remaining <= 0) { exhausted = true; return false }
            return checked.add(origin) && matchesHub(origin, hubId, minOf(2_500, remaining))
        }
        // The last working address, then Bonjour and the hand-entered address, and only then the rest of the
        // invitation's addresses: a few unreachable VPN or container addresses used to eat the whole budget
        // before Bonjour ran (2026-11-24 review).
        if (last != null && valid(last)) return last
        if (remainingMillis() <= 0) exhausted = true
        discover(hubId, minOf(5_000, remainingMillis()).toLong(), ::valid)?.let { return it }
        if (manual != null && valid(manual)) return manual
        invited.firstOrNull(::valid)?.let { return it }
        val active = connectivity.activeNetwork
        val capabilities = connectivity.getNetworkCapabilities(active)
        val links = connectivity.getLinkProperties(active)?.linkAddresses.orEmpty()
        val cellularOnly = capabilities?.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) == true &&
            listOf(NetworkCapabilities.TRANSPORT_WIFI, NetworkCapabilities.TRANSPORT_ETHERNET,
                NetworkCapabilities.TRANSPORT_VPN).none(capabilities::hasTransport)
        val numericAddresses = invited.mapNotNull {
            val host = URI(it).host
            if (host.matches(Regex("[0-9.]+")) || host.startsWith("[")) {
                runCatching { InetAddress.getByName(host) }.getOrNull()
            } else null
        }.filter { it.isSiteLocalAddress || it.isLinkLocalAddress }
        val differentSubnet = links.isNotEmpty() && numericAddresses.isNotEmpty() && numericAddresses.all { remote ->
            val sameFamily = links.filter { it.address.address.size == remote.address.size }
            sameFamily.isNotEmpty() && sameFamily.none { local ->
                val own = local.address.address
                val other = remote.address
                (0 until local.prefixLength).all { bit ->
                    val mask = 0x80 shr (bit % 8)
                    (own[bit / 8].toInt() and mask) == (other[bit / 8].toInt() and mask)
                }
            }
        }
        throw MacUnavailable(manual == null && (cellularOnly || differentSubnet), incomplete = exhausted)
    }

    private suspend fun discover(hubId: String, timeout: Long, valid: (String) -> Boolean): String? {
        if (timeout <= 0) return null
        val services = Channel<NsdServiceInfo>(Channel.UNLIMITED)
        val listener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(type: String) {}
            override fun onDiscoveryStopped(type: String) { services.close() }
            override fun onStartDiscoveryFailed(type: String, errorCode: Int) { services.close() }
            override fun onStopDiscoveryFailed(type: String, errorCode: Int) { services.close() }
            override fun onServiceFound(info: NsdServiceInfo) { services.trySend(info) }
            override fun onServiceLost(info: NsdServiceInfo) {}
        }
        if (runCatching { nsd.discoverServices("_tacit._tcp.", NsdManager.PROTOCOL_DNS_SD, listener) }.isFailure) return null
        try {
            return withTimeoutOrNull(timeout) {
                for (found in services) {
                    val resolved = withTimeoutOrNull(1_500) { resolve(found) } ?: continue
                    if (resolved.attributes["hub"]?.toString(Charsets.UTF_8) != hubId) continue
                    val origin = origins(resolved).firstOrNull(valid)
                    if (origin != null) return@withTimeoutOrNull origin
                }
                null
            }
        } finally {
            runCatching { nsd.stopServiceDiscovery(listener) }
            services.cancel()
        }
    }

    @Suppress("DEPRECATION")
    private suspend fun resolve(service: NsdServiceInfo): NsdServiceInfo? = suspendCancellableCoroutine { continuation ->
        val listener = object : NsdManager.ResolveListener {
            override fun onResolveFailed(info: NsdServiceInfo, errorCode: Int) { continuation.resume(null) }
            override fun onServiceResolved(info: NsdServiceInfo) { continuation.resume(info) }
        }
        try { nsd.resolveService(service, listener) }
        catch (_: RuntimeException) { continuation.resume(null) }
    }

    @Suppress("DEPRECATION")
    private fun origins(info: NsdServiceInfo): List<String> {
        if (info.port !in 1..65535) return emptyList()
        val addresses = if (Build.VERSION.SDK_INT >= 34) info.hostAddresses else listOfNotNull(info.host)
        return addresses.mapNotNull { address ->
            val host = address.hostAddress ?: return@mapNotNull null
            val authority = if (':' in host) "[$host]" else host
            runCatching { macOrigin("http://$authority:${info.port}") }.getOrNull()
        }
    }
}

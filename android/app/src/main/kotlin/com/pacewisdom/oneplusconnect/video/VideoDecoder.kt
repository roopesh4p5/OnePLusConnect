package com.pacewisdom.oneplusconnect.video

import android.media.MediaCodec
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Build
import android.os.SystemClock
import android.util.Log
import android.view.Surface
import java.nio.ByteBuffer
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

/**
 * H.264 / HEVC Annex B → MediaCodec → Surface, tuned for latency:
 * tiny input queue, drop-and-request-keyframe instead of buffering, render immediately.
 * The codec comes from SESSION_CONFIG; HEVC is preferred because it carries the same picture in
 * about half the bits, which is what keeps a Wi-Fi link as sharp as the cable.
 */
class VideoDecoder(private val listener: Listener) {

    interface Listener {
        fun onRequestKeyframe()
        fun onDecoderError(message: String)
        fun onFirstFrameRendered()
    }

    private class Frame(val data: ByteArray, val isKeyframe: Boolean, val timestampUs: Long, val enqueuedNs: Long)

    data class Stats(
        val fps: Double,
        val decodeLatencyMs: Double,
        val renderedTotal: Int,
        val droppedTotal: Int,
        val queueDepth: Int,
        val pipelineRawMs: Double,
    )

    companion object {
        private const val TAG = "VideoDecoder"
        const val MIME_H264 = "video/avc"
        const val MIME_HEVC = "video/hevc"
        private const val QUEUE_CAPACITY = 6

        /** SESSION_CONFIG codec name ("h264"/"hevc") → MediaCodec MIME type. */
        fun mimeFor(codec: String): String =
            if (codec.equals("hevc", true) || codec.equals("h265", true)) MIME_HEVC else MIME_H264

        fun isHardwareDecoderAvailable(mime: String = MIME_H264): Boolean =
            MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.any { info ->
                !info.isEncoder && info.supportedTypes.any { it.equals(mime, ignoreCase = true) }
            }

        fun supportedDecoderMimes(): List<String> {
            val wanted = listOf(MIME_H264 to "h264", MIME_HEVC to "hevc")
            val infos = MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos
            return wanted.filter { (mime, _) -> infos.any { !it.isEncoder && it.supportedTypes.any { t -> t.equals(mime, true) } } }
                .map { it.second }
        }

        /**
         * Highest frame rate the hardware [mime] decoder advertises for a [w]x[h] stream,
         * or 0 when the size itself is unsupported / unknown. Sent in HELLO_ACK so the Mac
         * can keep native-resolution streams within what this tablet can actually decode.
         */
        fun maxFrameRateFor(w: Int, h: Int, mime: String = MIME_H264): Int = runCatching {
            MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos
                .filter { !it.isEncoder && it.supportedTypes.any { t -> t.equals(mime, true) } }
                .sortedBy { it.name.contains("google", true) || it.name.contains(".sw", true) } // hardware first
                .mapNotNull { info ->
                    val vc = info.getCapabilitiesForType(mime).videoCapabilities ?: return@mapNotNull null
                    if (!vc.isSizeSupported(w, h)) return@mapNotNull null
                    vc.getSupportedFrameRatesFor(w, h).upper.toInt()
                }
                .maxOrNull() ?: 0
        }.getOrDefault(0)

        /** Splits Annex B into NAL units (without start codes). */
        fun splitNals(data: ByteArray): List<ByteArray> {
            val out = ArrayList<ByteArray>()
            var i = 0
            var start = -1
            val n = data.size
            while (i + 2 < n) {
                if (data[i].toInt() == 0 && data[i + 1].toInt() == 0 && data[i + 2].toInt() == 1) {
                    if (start >= 0) {
                        var end = i
                        if (end > start && data[end - 1].toInt() == 0) end-- // 4-byte start code
                        out.add(data.copyOfRange(start, end))
                    }
                    i += 3
                    start = i
                } else {
                    i++
                }
            }
            if (start in 0 until n) out.add(data.copyOfRange(start, n))
            return out
        }

        private val START_CODE = byteArrayOf(0, 0, 0, 1)
    }

    @Volatile private var surface: Surface? = null
    @Volatile private var width = 0
    @Volatile private var height = 0
    @Volatile private var mime = MIME_H264
    // Codec-specific config buffers: H.264 → csd-0 = SPS, csd-1 = PPS; HEVC → csd-0 = VPS+SPS+PPS.
    private var csd0: ByteArray? = null
    private var csd1: ByteArray? = null

    private var codec: MediaCodec? = null
    private var inputThread: Thread? = null
    private var outputThread: Thread? = null
    @Volatile private var running = false
    @Volatile private var awaitingKeyframe = true
    private val queue = ArrayBlockingQueue<Frame>(QUEUE_CAPACITY)
    private val enqueueTimes = ConcurrentHashMap<Long, Long>()
    private var lastKeyframeRequestMs = 0L
    private var firstFrameRendered = false

    // Stats (per second)
    private val renderedTotal = AtomicInteger()
    private val droppedTotal = AtomicInteger()
    private val renderedSinceSample = AtomicInteger()
    private val decodeLatencySumUs = AtomicLong()
    private val pipelineRawSumUs = AtomicLong()
    private var lastSampleNs = System.nanoTime()

    private val lock = Any()

    fun setSurface(s: Surface?) {
        synchronized(lock) {
            if (surface === s) return
            surface = s
            if (s == null) stopLocked() else maybeStartLocked()
        }
    }

    fun setStreamSize(w: Int, h: Int) {
        synchronized(lock) {
            if (w == width && h == height) return
            width = w; height = h
            // A new size needs new parameter sets; the Mac sends them with the next keyframe.
            if (running) {
                stopLocked()
                csd0 = null; csd1 = null
            }
        }
    }

    /** Codec for the next session ("h264"/"hevc"); a change restarts the decoder on the next keyframe. */
    fun setCodec(codec: String) {
        synchronized(lock) {
            val m = mimeFor(codec)
            if (m == mime) return
            mime = m
            Log.i(TAG, "Codec set to $m")
            if (running) stopLocked()
            csd0 = null; csd1 = null
        }
    }

    /** Annex B parameter sets from a VIDEO_CONFIG packet: SPS+PPS (H.264) or VPS+SPS+PPS (HEVC). */
    fun setParameterSets(annexB: ByteArray) {
        synchronized(lock) {
            val nals = splitNals(annexB).filter { it.isNotEmpty() }
            var newCsd0: ByteArray? = null
            var newCsd1: ByteArray? = null
            if (mime == MIME_HEVC) {
                // HEVC wants all three sets concatenated in csd-0, in VPS, SPS, PPS order.
                var vps: ByteArray? = null; var sps: ByteArray? = null; var pps: ByteArray? = null
                for (nal in nals) {
                    when ((nal[0].toInt() and 0xFF) shr 1 and 0x3F) {
                        32 -> vps = nal
                        33 -> sps = nal
                        34 -> pps = nal
                    }
                }
                if (vps == null || sps == null || pps == null) return
                newCsd0 = START_CODE + vps + START_CODE + sps + START_CODE + pps
            } else {
                var sps: ByteArray? = null; var pps: ByteArray? = null
                for (nal in nals) {
                    when (nal[0].toInt() and 0x1F) {
                        7 -> sps = nal
                        8 -> pps = nal
                    }
                }
                if (sps == null || pps == null) return
                newCsd0 = START_CODE + sps
                newCsd1 = START_CODE + pps
            }
            val changed = !newCsd0.contentEquals(csd0) || !newCsd1.contentEquals(csd1)
            csd0 = newCsd0; csd1 = newCsd1
            if (changed && running) {
                Log.i(TAG, "Parameter sets changed; restarting decoder")
                stopLocked()
            }
            maybeStartLocked()
        }
    }

    fun enqueue(data: ByteArray, isKeyframe: Boolean, timestampUs: Long) {
        if (!running) { droppedTotal.incrementAndGet(); return }
        if (awaitingKeyframe && !isKeyframe) {
            droppedTotal.incrementAndGet()
            requestKeyframeRateLimited()
            return
        }
        awaitingKeyframe = false
        val frame = Frame(data, isKeyframe, timestampUs, System.nanoTime())
        if (!queue.offer(frame)) {
            // Behind: drop everything queued and resync on the next keyframe (PRD §22/§23).
            val dropped = ArrayList<Frame>()
            queue.drainTo(dropped)
            droppedTotal.addAndGet(dropped.size + 1)
            awaitingKeyframe = true
            requestKeyframeRateLimited()
        }
    }

    private fun requestKeyframeRateLimited() {
        val now = SystemClock.elapsedRealtime()
        if (now - lastKeyframeRequestMs > 300) {
            lastKeyframeRequestMs = now
            listener.onRequestKeyframe()
        }
    }

    private fun maybeStartLocked() {
        val s = surface ?: return
        val config0 = csd0 ?: return
        if (mime == MIME_H264 && csd1 == null) return
        if (running || width == 0 || height == 0) return
        try {
            val format = MediaFormat.createVideoFormat(mime, width, height).apply {
                setByteBuffer("csd-0", ByteBuffer.wrap(config0))
                csd1?.let { setByteBuffer("csd-1", ByteBuffer.wrap(it)) }
                setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, width * height)
                if (Build.VERSION.SDK_INT >= 30) setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
                setInteger(MediaFormat.KEY_PRIORITY, 0) // realtime
            }
            val c = MediaCodec.createDecoderByType(mime)
            c.configure(format, s, null, 0)
            c.start()
            codec = c
            running = true
            awaitingKeyframe = true
            firstFrameRendered = false
            queue.clear()
            enqueueTimes.clear()
            inputThread = Thread({ inputLoop(c) }, "opc-decoder-in").apply { priority = Thread.MAX_PRIORITY; start() }
            outputThread = Thread({ outputLoop(c) }, "opc-decoder-out").apply { priority = Thread.MAX_PRIORITY; start() }
            Log.i(TAG, "Decoder started $mime ${width}x$height on ${c.name} (max ${maxFrameRateFor(width, height, mime)} fps at this size)")
            listener.onRequestKeyframe()
        } catch (e: Exception) {
            Log.e(TAG, "Decoder start failed", e)
            running = false
            codec = null
            listener.onDecoderError(e.message ?: e.javaClass.simpleName)
        }
    }

    private fun inputLoop(c: MediaCodec) {
        try {
            while (running) {
                val frame = queue.poll(50, TimeUnit.MILLISECONDS) ?: continue
                var index = -1
                while (running && index < 0) index = c.dequeueInputBuffer(10_000)
                if (!running) break
                val buf = c.getInputBuffer(index) ?: continue
                buf.clear()
                if (frame.data.size > buf.capacity()) {
                    Log.w(TAG, "Frame larger than input buffer (${frame.data.size} > ${buf.capacity()}); dropping")
                    c.queueInputBuffer(index, 0, 0, 0, 0)
                    droppedTotal.incrementAndGet()
                    awaitingKeyframe = true
                    requestKeyframeRateLimited()
                    continue
                }
                buf.put(frame.data)
                enqueueTimes[frame.timestampUs] = frame.enqueuedNs
                if (enqueueTimes.size > 64) enqueueTimes.clear()
                c.queueInputBuffer(index, 0, frame.data.size, frame.timestampUs, if (frame.isKeyframe) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0)
            }
        } catch (e: InterruptedException) {
            // stopping
        } catch (e: Exception) {
            if (running) {
                Log.e(TAG, "Decoder input error", e)
                listener.onDecoderError(e.message ?: "input error")
            }
        }
    }

    private fun outputLoop(c: MediaCodec) {
        val info = MediaCodec.BufferInfo()
        try {
            while (running) {
                val index = c.dequeueOutputBuffer(info, 10_000)
                if (index >= 0) {
                    c.releaseOutputBuffer(index, true) // render as soon as decoded
                    val nowNs = System.nanoTime()
                    enqueueTimes.remove(info.presentationTimeUs)?.let { decodeLatencySumUs.addAndGet((nowNs - it) / 1000) }
                    pipelineRawSumUs.addAndGet(System.currentTimeMillis() * 1000L - info.presentationTimeUs)
                    renderedTotal.incrementAndGet()
                    renderedSinceSample.incrementAndGet()
                    if (!firstFrameRendered) { firstFrameRendered = true; listener.onFirstFrameRendered() }
                } else if (index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    Log.i(TAG, "Output format: ${c.outputFormat}")
                }
            }
        } catch (e: Exception) {
            if (running) {
                Log.e(TAG, "Decoder output error", e)
                listener.onDecoderError(e.message ?: "output error")
            }
        }
    }

    private fun stopLocked() {
        if (!running && codec == null) return
        running = false
        inputThread?.interrupt()
        try { inputThread?.join(300) } catch (_: InterruptedException) {}
        try { outputThread?.join(300) } catch (_: InterruptedException) {}
        inputThread = null; outputThread = null
        codec?.let { c ->
            try { c.stop() } catch (e: Exception) { Log.w(TAG, "stop: ${e.message}") }
            try { c.release() } catch (e: Exception) { Log.w(TAG, "release: ${e.message}") }
        }
        codec = null
        queue.clear()
        enqueueTimes.clear()
        Log.i(TAG, "Decoder stopped")
    }

    fun release() {
        synchronized(lock) {
            stopLocked()
            csd0 = null; csd1 = null
            width = 0; height = 0
        }
    }

    val isRunning: Boolean get() = running

    /** Per-second stats sample; resets the per-interval accumulators. */
    fun sampleStats(): Stats {
        val now = System.nanoTime()
        val dt = (now - lastSampleNs) / 1e9
        lastSampleNs = now
        val rendered = renderedSinceSample.getAndSet(0)
        val decodeSum = decodeLatencySumUs.getAndSet(0)
        val pipeSum = pipelineRawSumUs.getAndSet(0)
        return Stats(
            fps = if (dt > 0) rendered / dt else 0.0,
            decodeLatencyMs = if (rendered > 0) decodeSum / rendered / 1000.0 else 0.0,
            renderedTotal = renderedTotal.get(),
            droppedTotal = droppedTotal.get(),
            queueDepth = queue.size,
            pipelineRawMs = if (rendered > 0) pipeSum / rendered / 1000.0 else 0.0,
        )
    }

    fun resetStats() {
        renderedTotal.set(0); droppedTotal.set(0); renderedSinceSample.set(0)
        decodeLatencySumUs.set(0); pipelineRawSumUs.set(0)
        lastSampleNs = System.nanoTime()
    }
}

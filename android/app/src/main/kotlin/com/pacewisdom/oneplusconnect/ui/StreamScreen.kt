package com.pacewisdom.oneplusconnect.ui

import android.view.MotionEvent
import android.view.SurfaceHolder
import android.view.SurfaceView
import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import com.pacewisdom.oneplusconnect.connection.ConnectionEngine
import kotlinx.coroutines.delay

/**
 * Fullscreen "my tablet is now a monitor" view (PRD §47/§48).
 * The SurfaceView is letterboxed to the stream aspect ratio; touches inside it are normalized.
 * A three-finger tap shows the overlay with Stop Sharing.
 */
@Composable
fun StreamScreen(engine: ConnectionEngine, state: ConnectionEngine.UiState) {
    val cfg = state.session ?: return
    var overlayVisible by remember { mutableStateOf(true) }
    var overlayToken by remember { mutableIntStateOf(0) }

    BackHandler { engine.stopSession() }

    LaunchedEffect(overlayToken) {
        overlayVisible = true
        delay(4000)
        overlayVisible = false
    }

    val aspect = cfg.width.toFloat() / cfg.height.toFloat()

    Box(modifier = Modifier.fillMaxSize().background(Color.Black), contentAlignment = Alignment.Center) {
        AndroidView(
            // aspectRatio picks the largest size that fits the screen: letterbox or pillarbox.
            modifier = Modifier.aspectRatio(aspect),
            factory = { ctx ->
                SurfaceView(ctx).apply {
                    holder.addCallback(object : SurfaceHolder.Callback {
                        override fun surfaceCreated(holder: SurfaceHolder) = engine.attachSurface(holder.surface)
                        override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {}
                        override fun surfaceDestroyed(holder: SurfaceHolder) = engine.detachSurface()
                    })
                    setOnTouchListener { v, event ->
                        if (event.actionMasked == MotionEvent.ACTION_POINTER_DOWN && event.pointerCount == 3) {
                            overlayToken++
                        }
                        engine.onTouch(event, v.width, v.height)
                        true
                    }
                }
            },
        )

        AnimatedVisibility(
            visible = overlayVisible,
            enter = fadeIn(),
            exit = fadeOut(),
            modifier = Modifier.align(Alignment.TopEnd).padding(16.dp),
        ) {
            Column(
                modifier = Modifier
                    .background(Color(0xCC111111), RoundedCornerShape(12.dp))
                    .padding(horizontal = 16.dp, vertical = 12.dp),
                horizontalAlignment = Alignment.End,
            ) {
                Row {
                    Text("${state.link ?: "USB"} ●", color = Color(0xFF4CD964), fontSize = 13.sp)
                    Spacer(Modifier.width(12.dp))
                    Text("${cfg.width}×${cfg.height}", color = Color.LightGray, fontSize = 13.sp)
                    Spacer(Modifier.width(12.dp))
                    Text("${cfg.fps} FPS", color = Color.LightGray, fontSize = 13.sp)
                    Spacer(Modifier.width(12.dp))
                    Text("${cfg.bitrateMbps} Mbps", color = Color.LightGray, fontSize = 13.sp)
                }
                if (state.stats.rendered > 0) {
                    Text(
                        "decode ${"%.1f".format(state.stats.decodeLatencyMs)} ms · ${"%.0f".format(state.stats.fps)} fps · dropped ${state.stats.dropped}",
                        color = Color.Gray, fontSize = 11.sp,
                    )
                }
                Spacer(Modifier.height(8.dp))
                Button(onClick = { engine.stopSession() }) { Text("Stop Sharing") }
                Text("Three-finger tap shows this menu", color = Color.Gray, fontSize = 10.sp)
            }
        }

        if (!state.videoActive) {
            Text("Waiting for video…", color = Color.Gray, fontSize = 16.sp, modifier = Modifier.align(Alignment.BottomCenter).padding(24.dp))
        }
    }
}

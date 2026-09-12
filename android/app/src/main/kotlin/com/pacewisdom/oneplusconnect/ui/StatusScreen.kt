package com.pacewisdom.oneplusconnect.ui

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.painterResource
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.pacewisdom.oneplusconnect.AppInfo
import com.pacewisdom.oneplusconnect.R
import com.pacewisdom.oneplusconnect.connection.ConnectionEngine
import com.pacewisdom.oneplusconnect.usb.DeviceInfo

/** Simple status dashboard (PRD §7 / §37). */
@Composable
fun StatusScreen(state: ConnectionEngine.UiState) {
    val context = LocalContext.current
    val (w, h) = DeviceInfo.physicalSize(context)
    val hz = DeviceInfo.currentRefreshRate(context)

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black)
            .safeDrawingPadding()
            .verticalScroll(rememberScrollState())
            .padding(32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Column(modifier = Modifier.widthIn(max = 520.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Image(
                    painter = painterResource(R.drawable.logo),
                    contentDescription = "One+Connect logo",
                    modifier = Modifier.size(56.dp).clip(RoundedCornerShape(12.dp)),
                )
                Spacer(Modifier.width(16.dp))
                Column {
                    Text("ONE+CONNECT", color = Color.White, fontSize = 28.sp, fontWeight = FontWeight.Bold, letterSpacing = 4.sp)
                    Text(AppInfo.TAGLINE, color = Color.Gray, fontSize = 13.sp)
                }
            }
            Spacer(Modifier.height(28.dp))

            SectionTitle("Connection")
            StatusRow("USB cable", state.usbConnected)
            StatusRow("USB debugging", state.adbEnabled)
            StatusRow("Wi-Fi", state.wifiConnected, detail = state.wifiAddress)
            StatusRow("Mac connected", state.macConnected, detail = listOfNotNull(state.macName, state.link?.let { "via $it" }).joinToString(" · "))
            StatusRow("Screen sharing", state.streaming, detail = state.link)

            Spacer(Modifier.height(20.dp))
            HorizontalDivider(color = Color.DarkGray)
            Spacer(Modifier.height(20.dp))

            SectionTitle("Tablet")
            Text(DeviceInfo.modelName(), color = Color.White, fontSize = 18.sp)
            Text("$w × $h", color = Color.LightGray, fontSize = 16.sp)
            Text("$hz Hz", color = Color.LightGray, fontSize = 16.sp)
            state.battery?.let { Text("Battery: $it%", color = Color.LightGray, fontSize = 16.sp) }

            Spacer(Modifier.height(20.dp))
            HorizontalDivider(color = Color.DarkGray)
            Spacer(Modifier.height(20.dp))

            Text(state.statusText, color = Color.White, fontSize = 18.sp)
            state.lastError?.let {
                Spacer(Modifier.height(8.dp))
                Text(it, color = Color(0xFFFF6E6E), fontSize = 14.sp)
            }
            Spacer(Modifier.height(28.dp))
            Text(
                "Your display data is transmitted directly between your Mac and tablet over USB-C or over your own Wi-Fi network — you choose which on the Mac. One+Connect does not use cloud servers.",
                color = Color.Gray, fontSize = 12.sp,
            )

            Spacer(Modifier.height(20.dp))
            HorizontalDivider(color = Color.DarkGray)
            Spacer(Modifier.height(20.dp))

            SectionTitle("About")
            Text(AppInfo.DEVELOPED_BY, color = Color.White, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
            Text(AppInfo.CREDITS, color = Color.LightGray, fontSize = 14.sp)
            Text("Proof of concept · Mac ↔ ${DeviceInfo.modelName()}", color = Color.Gray, fontSize = 12.sp)
        }
    }
}

@Composable
private fun SectionTitle(text: String) {
    Text(text, color = Color.Gray, fontSize = 13.sp, letterSpacing = 2.sp)
    Spacer(Modifier.height(10.dp))
}

@Composable
private fun StatusRow(label: String, ok: Boolean, detail: String? = null) {
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(vertical = 4.dp)) {
        Text(if (ok) "✓" else "○", color = if (ok) Color(0xFF4CD964) else Color.Gray, fontSize = 20.sp)
        Spacer(Modifier.width(14.dp))
        Text(label, color = if (ok) Color.White else Color.LightGray, fontSize = 18.sp)
        if (!detail.isNullOrEmpty() && ok) {
            Spacer(Modifier.width(10.dp))
            Text(detail, color = Color.Gray, fontSize = 14.sp)
        }
    }
}

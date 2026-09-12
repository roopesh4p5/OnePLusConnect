# One+Connect wire protocol v1

Reliable byte stream: TCP to the tablet app on port 27183. Mac is the client, tablet the server.
Two links carry the same stream, chosen by the Mac in this order:

1. **USB** — `adb forward tcp:27183 tcp:27183`; the Mac dials `127.0.0.1:27183`.
2. **Wi-Fi fallback** — when adb reports no authorized tablet, the Mac dials the tablet's LAN address
   found through the discovery beacon below (or a manually entered address).

The tablet listens on `0.0.0.0:27183` so both work at once; it tells the links apart by the peer address
(loopback = USB). `HELLO.transport` (`"usb"` | `"wifi"`) is sent as a hint as well.

## Wi-Fi discovery (UDP 27184)

While the tablet app is open, on Wi-Fi and not connected to a Mac, it broadcasts once per second to the
subnet broadcast address and `255.255.255.255`, UDP port 27184:

```json
{"app":"oneplusconnect","v":1,"name":"OnePlus Pad Go 2","host":"192.168.1.20","port":27183}
```

The Mac listens on UDP 27184, trusts the datagram's source address over `host`, and treats a tablet as
present while a beacon was seen within the last 6 s.

## Packet header — 28 bytes, big-endian

| Offset | Size | Field | Notes |
| --- | --- | --- | --- |
| 0 | 4 | MAGIC | `0x4F504331` ("OPC1") |
| 4 | 1 | VERSION | 1 |
| 5 | 1 | TYPE | see below |
| 6 | 1 | FLAGS | bit0 keyframe, bit1 end-of-frame |
| 7 | 1 | reserved | 0 |
| 8 | 4 | SESSION_ID | 0 outside a session |
| 12 | 4 | SEQUENCE | per-sender counter |
| 16 | 8 | TIMESTAMP | microseconds since Unix epoch, sender's wall clock |
| 24 | 4 | PAYLOAD_LENGTH | ≤ 32 MiB |

## Packet types

| Type | Name | Dir | Payload |
| --- | --- | --- | --- |
| 0x01 | HELLO | Mac→Tab | JSON `{protocolVersion, appVersion, deviceId, hostName, capabilities[], transport?}` |
| 0x02 | HELLO_ACK | Tab→Mac | JSON `{protocolVersion, appVersion, deviceModel, manufacturer, androidVersion, displayWidth, displayHeight, refreshRates[], codecs[], touch, multitouch, stylus, orientation, densityDpi}` |
| 0x03 | CONFIG | Mac→Tab | JSON `{sessionId, mode: "mirror"\|"extend", width, height, fps, bitrate, codec: "h264", colorFormat: "nv12", orientation}` |
| 0x04 | CONFIG_ACK | Tab→Mac | JSON `{sessionId, ok, error?}` (= SESSION_READY) |
| 0x06 | SESSION_STOP | both | JSON `{reason}` |
| 0x10 | VIDEO | Mac→Tab | one H.264 access unit, Annex B (P-frame) |
| 0x11 | KEYFRAME | Mac→Tab | one H.264 IDR access unit, Annex B |
| 0x12 | VIDEO_CONFIG | Mac→Tab | Annex B SPS + PPS; always sent right before a keyframe |
| 0x13 | REQUEST_KEYFRAME | Tab→Mac | empty |
| 0x20 | TOUCH | Tab→Mac | binary, below |
| 0x21 | GESTURE | reserved | |
| 0x22 | STYLUS | reserved | |
| 0x23 | ORIENTATION | Tab→Mac | JSON `{orientation, displayWidth, displayHeight}` |
| 0x30 | PING | Mac→Tab | JSON `{t1}` |
| 0x31 | PONG | Tab→Mac | JSON `{t1, t2, t3}` (NTP-style; Mac derives RTT and clock offset) |
| 0x32 | STATS | Tab→Mac | JSON `{fps, decodeLatencyMs, renderedFrames, droppedFrames, queueDepth, battery, thermal, pipelineLatencyRawMs}` |
| 0x40 | ERROR | both | JSON `{code, message}` — `decoder_failed` ends the session |
| 0x41 | DISCONNECT | both | empty |

Orientation values: `portrait`, `landscape`, `reverse_portrait`, `reverse_landscape`.

## TOUCH payload

```
u8 action      0 down, 1 move, 2 up, 3 pointerDown, 4 pointerUp, 5 cancel
u8 actionIndex
u8 pointerCount
u8 flags
per pointer (16 bytes):
  u8  id
  u8  toolType   0 finger, 1 stylus, 255 unknown
  u16 reserved
  f32 x          0..1 relative to the video rectangle on the tablet
  f32 y          0..1
  f32 pressure
```

Gesture recognition happens on the Mac (`GestureRecognizer`), so the tablet stays dumb and
resolution-independent.

## Session flow

```
Mac                                   Tablet
 |-- HELLO ---------------------------->|
 |<-- HELLO_ACK ------------------------|          (Mac: READY)
 |-- CONFIG --------------------------->|          (tablet shows stream screen)
 |<-- CONFIG_ACK {ok} ------------------|          (Mac: capture + encoder start)
 |<-- REQUEST_KEYFRAME -----------------|          (decoder started on surface)
 |-- VIDEO_CONFIG, KEYFRAME, VIDEO... ->|
 |<-- TOUCH / STATS / ORIENTATION ------|
 |-- PING -> / <- PONG  (1 Hz, 5 s timeout drops the link)
 |-- SESSION_STOP ----------------------> or <-- SESSION_STOP
```

Latency rules: the Mac skips capture frames when the send backlog exceeds ~4 frames; the tablet
drops its whole queue and asks for a keyframe when its 6-frame input queue overflows.

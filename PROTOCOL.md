# Stick ⇄ Phone BLE protocol (v1)

The stick is the BLE **peripheral**, the phone app is the **central**. The macOS
StickSim and the M5StickS3 firmware implement the same thing, so the phone app
does not care which one it talks to.

## GATT

| Item | UUID | Properties | Direction |
|---|---|---|---|
| Service | `5A1D0001-8F3C-4C59-9B0A-6D2E5A7C1E01` | — | advertised |
| TX | `5A1D0002-8F3C-4C59-9B0A-6D2E5A7C1E01` | notify | stick → phone |
| RX | `5A1D0003-8F3C-4C59-9B0A-6D2E5A7C1E01` | write, write without response | phone → stick |

Advertised local name: `StickS3`. Byte order is little-endian everywhere.

Battery uses the standard Bluetooth Battery Service: service `0x180F`,
characteristic `0x2A19` (read, notify), one byte 0–100. The StickS3 firmware
reads it from the M5PM1 PMIC (`M5.Power.getBatteryLevel()`) and notifies on
change; StickSim reports the Mac's battery.

## Audio

- 16 kHz, mono, 16-bit PCM before encoding.
- Codec 1 = IMA ADPCM, 4 bits per sample, low nibble first.
- Every audio packet carries its own predictor + step index, so each packet
  decodes on its own (a lost packet is a gap, not a corrupted stream).

## Stick → phone (TX notify)

Every packet starts with `type: u8`, `session: u8`. `session` increments per
recording (wraps at 255) so late packets from an old recording are dropped.

| type | name | rest of packet |
|---|---|---|
| `0x01` | START | `codec: u8` (1), `sampleRate: u16` |
| `0x02` | AUDIO | `seq: u16`, `predictor: i16`, `index: u8`, `adpcm: [u8]` |
| `0x03` | END | `packetCount: u16` |
| `0x04` | CANCEL | — |
| `0x05` | SETTINGS | `session: u8` (0), then `key: u8, value: u8` pairs (all of them) |
| `0x06` | SLEEPING | `session: u8` (0); sent just before deep sleep |

AUDIO header is 8 bytes; payload fills the rest of the negotiated
notification size (`maximumUpdateValueLength` on Apple, `MTU - 3` on ESP32).

## Phone → stick (RX write)

| type | name | rest of packet |
|---|---|---|
| `0x10` | TRANSCRIBING | `session: u8` |
| `0x11` | DONE | `session: u8`, `preview: utf8` (≤ 160 bytes, cut on a character boundary) |
| `0x12` | ERROR | `session: u8`, `message: utf8` (≤ 160 bytes) |
| `0x13` | FIND | `session: u8` (always 0, ignored), `on: u8` (1 sound off, 0 stop) |
| `0x14` | SETTINGS | `session: u8` (0), then `key: u8, value: u8` pairs (any subset) |

FIND is for finding a misplaced stick: while `on`, the stick chirps every
second or so (StickS3: `M5.Speaker.tone`, volume under 75% on battery) and
shows it on its screen; a button press or `on: 0` stops it. The phone reads
the link's RSSI meanwhile to say how close the stick is.

SETTINGS are what the phone can adjust on the stick. The stick stores them
(StickS3: NVS), applies a write at once, and answers every write, and every
new subscription, with a SETTINGS report of all keys. Unknown keys are
skipped on both sides.

| key | setting | value |
|---|---|---|
| 1 | screen brightness | 8–255 |
| 2 | seconds idle before the screen dims | 0 = never |
| 3 | seconds idle before the screen turns off | 0 = never |
| 4 | mic gain after the fixed +30 dB analog stage | 0–32 dB |
| 5 | speaker volume while finding | 0–190 (louder browns out on battery) |
| 6 | a short press starts recording, the next press sends it | 0 / 1 |
| 7 | seconds idle before deep sleep | 0 = never |

The stick deep-sleeps when idle (key 7) unless a computer is talking to it
over USB. A press wakes it and starts a recording at once; the audio waits
in PSRAM until the phone, which keeps a pending connection, reconnects, then
START, the buffered AUDIO and END go out as usual. SLEEPING lets the app say
the stick is asleep rather than out of range.

DONE means the text is on the phone's clipboard. On the real stick, this is
where the HID `⌘V` would be sent (not part of v1).

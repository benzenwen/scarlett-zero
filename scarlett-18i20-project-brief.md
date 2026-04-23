# Scarlett 18i20 Gen 1 — macOS Control Tool Project Brief

## Summary

We have fully validated that a userspace tool on macOS Tahoe (26.x, Apple
Silicon) can read and write all control surfaces on a Focusrite Scarlett 18i20
Gen 1 audio interface — clock source, output routing, mixer matrix gains,
bus volumes, and mutes — without any Focusrite software, kernel extensions,
or DriverKit entitlements.

Focusrite has officially dropped support for Scarlett MixControl on Tahoe.
The legacy app (x86_64, built against 10.14 SDK, signed Nov 2021) fails at
IOKit enumeration due to use of the deprecated `IOUSBDevice` matching class
that Tahoe no longer populates. This is not fixable from outside Focusrite.

This document captures everything needed to build a replacement tool.

---

## Hardware Details

- **Device:** Focusrite Scarlett 18i20 Gen 1
- **Vendor ID:** `0x1235` (4661)
- **Product ID:** `0x800c` (32780)
- **USB Speed:** High Speed (480 Mbps)
- **Configurations:** 2 (device uses config 1)
- **Device Class:** 0xEF / 0x02 / 0x01 (IAD composite)
- **The device stores its mixer state in hardware** — settings persist
  across power cycles and re-plugs

### USB Interface Map (Config 1)

| # | Class | SubClass | Protocol | Name | Owner | Endpoints | Notes |
|---|-------|----------|----------|------|-------|-----------|-------|
| 0 | 1 (Audio) | 1 (Control) | 32 (UAC2) | — | usbaudiod | 1 | Main audio control |
| 1 | 1 (Audio) | 2 (Streaming) | 32 | USB-Out | usbaudiod | 2 | Playback (multiple alt settings) |
| 2 | 1 (Audio) | 2 (Streaming) | 32 | USB-In | usbaudiod | 1 | Recording (multiple alt settings) |
| 3 | 1 (Audio) | 1 (Control) | 0 | — | **UNCLAIMED** | 0 | Vendor control surface |
| 4 | 1 (Audio) | 3 (MIDI) | 0 | — | MIDIServer | 2 | MIDI I/O |
| 5 | 254 (App-specific) | 1 (DFU) | 0 | USB-DFU | **UNCLAIMED** | 0 | Firmware update |

### Key Finding: Interface 3

Interface 3 is an audio-control-class interface with zero endpoints and no
kernel driver claim. It exists as a vendor control surface. However, we do
NOT need to claim it. The working approach uses device-level IOKit handles
(see Transport Layer below).

---

## Transport Layer — What Works and What Doesn't

### ❌ libusb / pyusb — DOES NOT WORK for control protocol

pyusb can enumerate the device and claim Interface 3, but **cannot send
control transfers** to the audio control entities. The entities live on
Interface 0 (owned by `usbaudiod`), and macOS blocks class-type control
transfers to interfaces you haven't claimed. Even `sudo` doesn't help.
Even claiming Interface 3 first doesn't help — macOS checks the wIndex
target interface, not the claimed interface.

```
bmRequestType=0xA1, wIndex=0x2800 → "Access denied (insufficient permissions)"
```

pyusb IS useful for enumeration and validation but not for the actual
control protocol.

### ✅ IOKit DeviceRequest — WORKS PERFECTLY

Opening the device via `IOCreatePlugInInterfaceForService` →
`IOUSBDeviceInterface` → `USBDeviceOpen` → `DeviceRequest` bypasses the
per-interface ownership model entirely. This is the same code path that
Focusrite's own `FocusriteControlServer` daemon uses (it creates an
`AppleUSBHostDeviceUserClient` at the device level).

No `sudo` required. No entitlements. No code signing beyond ad-hoc.
Works on Apple Silicon + Tahoe with a standard user account.

### ⚠️ Important Operational Constraints

1. **Only one device-level user client at a time.** If another process
   (FocusriteControlServer, Google Chrome WebMIDI, etc.) holds an
   `AppleUSBHostDeviceUserClient`, our control transfers fail with
   `kIOReturnNotPermitted` (0xe00002ed). The tool should check for this
   and report which process is blocking.

2. **Don't scan past known boundaries.** Probing matrix node 144+ causes
   a USB pipe stall (0xe0004051) that can wedge the device, requiring a
   power cycle. Always stop at node 143 (18×8 = 144 nodes, indices 0–143).

3. **Open once, do everything, close cleanly.** Rapid open/close cycles
   can leave IOKit in a stale state where subsequent opens succeed but
   transfers fail. The tool should open the device once at startup and
   hold the handle.

4. **FocusriteControlServer must be disabled.** It auto-launches as a
   LoginItem from Focusrite Control.app (the Gen 2+ app, not MixControl)
   and camps on the device handle even though it doesn't support Gen 1.
   ```
   sudo launchctl bootout system/com.focusrite.ControlServer
   sudo launchctl disable system/com.focusrite.ControlServer
   ```
   Also disable in System Settings → General → Login Items & Extensions.
   Ideally uninstall Focusrite Control.app entirely (it's not needed).

5. **Google Chrome WebMIDI** also grabs device-level handles on USB
   audio/MIDI devices. Quit Chrome or revoke MIDI access in
   `chrome://settings/content/midiDevices` before using the tool.

---

## Control Protocol

The protocol was reverse-engineered by Robin Gareus (x42) in 2013 from USB
captures of Scarlett MixControl communicating with a Scarlett 18i6. The
18i20 uses the same protocol with a larger channel count.

Reference sources:
- https://github.com/x42/scarlettmixer/blob/master/scarlettmixer.py
- Linux kernel: sound/usb/mixer_scarlett.c
- https://github.com/x42/scarlett-mixer/blob/master/src/scarlett_mixer.c

### USB Control Transfer Format

**Read (GET CUR):**
```
bmRequestType = 0xA1  (device-to-host, class, interface)
bRequest      = 0x01  (CUR)
wValue        = varies per control
wIndex        = varies per control (entity_id << 8 | interface)
wLength       = varies (1, 2, or 4 bytes)
```

**Write (SET CUR):**
```
bmRequestType = 0x21  (host-to-device, class, interface)
bRequest      = 0x01  (CUR)
wValue        = same as read
wIndex        = same as read
wLength       = same as read
pData         = value to set
```

### Control Map

#### Clock Source
- **wIndex:** `0x2800`
- **wValue:** `0x0100`
- **Length:** 1 byte
- **Values:** `1` = Internal, `2` = S/PDIF, `3` = ADAT
- **Verified:** Read ✅ Write ✅ Round-trip confirmed ✅

#### Sample Rate
- **wIndex:** `0x2900`
- **wValue:** `0x0100`
- **Length:** 4 bytes (little-endian uint32)
- **Values:** e.g., `48000` = `0x0000BB80` → bytes `[80 BB 00 00]`
- **Verified:** Read ✅ Write: not tested yet

#### Input Impedance (Line/Instrument)
- **wIndex:** `0x0100`
- **wValue:** `0x0901 + channel` (channel 0-based)
- **Length:** 2 bytes
- **Values:** `0` = Line, `1` = Instrument
- **Verified:** ❌ Did not respond on 18i20 — may use different wIndex
  or may only apply to channels 1-2 (the combo jacks on front panel).
  Needs USB capture from MixControl to verify.

#### Bus Mute
- **wIndex:** `0x0a00`
- **wValue:** `0x0100 + bus` (bus 0 = master, 1-20 = outputs)
- **Length:** 2 bytes
- **Values:** Per x42 docs: `[0x00, 0x00]` = unmuted, `[0x01, 0x00]` = muted
- **Verified:** Read ✅ but 18i20 returns `[0x00, 0x0b]` for all buses
  regardless of mute state. The `0x0b` byte may be a capability bitmask
  or the encoding may differ from the 18i6. Needs further investigation
  with controlled mute toggling via MixControl + USB capture.

#### Bus Volume (Post-Route Attenuation)
- **wIndex:** `0x0a00`
- **wValue:** `0x0200 + bus` (bus 0 = master, 1-20 = outputs)
- **Length:** 2 bytes
- **Encoding:** Signed, `0x0000` = 0 dB (unity), `0x8000` = -inf (muted/silent)
  Per x42: `int(65536.5 + 256.0 * dB_value) & 0xFFFF` for range -128..0 dB
- **Verified:** Read ✅

#### Output Routing Table
- **wIndex:** `0x3300`
- **wValue:** output index (0-19)
- **Length:** 2 bytes
- **Values:** Source ID (see Signal Source Map below). `0x2e` = "Off" (routed to empty Mix 9)
- **Verified:** Read ✅ Confirmed changes from MixControl visible ✅

#### Mixer Input Source Assignment
- **wIndex:** `0x3200`
- **wValue:** `0x0600 + mixer_channel` (channel 0-17)
- **Length:** 2 bytes
- **Values:** Source ID (see Signal Source Map below)
- **Verified:** Read ✅

#### Matrix Mixer Gains
- **wIndex:** `0x3c00`
- **wValue:** node index (0-143)
- **Length:** 2 bytes
- **Layout:** 18 inputs × 8 mix outputs. Node = input * 8 + output (stride TBD, see below)
- **Encoding:** Gain byte in `buf[1]` as signed int8.
  `0x0000` = 0 dB. Observed: `0xdf00` when MixControl showed ~-22.3 dB.
  `0xf600` ≈ -10 dB, `0xfc00` ≈ -4 dB, `0xfb00` ≈ -5 dB, `0xf800` ≈ -8 dB.
  Exact calibration needed — set known dB values in MixControl and read back.
- **Boundary:** Node 144+ causes pipe stall (0xe0004051). NEVER probe past 143.
- **Verified:** Read ✅ Confirmed gain changes from MixControl visible ✅

#### Save Settings to Hardware
- **bmRequestType:** `0x21`
- **bRequest:** `0x03` (not 0x01!)
- **wValue:** `0x005a`
- **wIndex:** `0x3c00`
- **pData:** `[0xa5]`
- **Verified:** Not tested. Use with caution — persists state to flash.

---

## Signal Source Map (18i20 Gen 1)

Verified against actual device reads and MixControl screenshots:

| ID Range | Hex | Source |
|----------|-----|--------|
| 0–19 | 0x00–0x13 | DAW 1–20 (USB playback from computer) |
| 20–27 | 0x14–0x1b | Analog Input 1–8 |
| 28 | 0x1c | S/PDIF Input L |
| 29 | 0x1d | S/PDIF Input R |
| 30–37 | 0x1e–0x25 | ADAT Input 1–8 |
| 38–47 | 0x26–0x2f | Mix 1–10 (mixer matrix outputs) |
| 255 | 0xff | OFF (explicit) |

Note: MixControl uses `0x2e` (Mix 9) as its "Off" routing — it routes to
an empty/unused mix bus rather than using a dedicated off value.

---

## Output Map (18i20 Gen 1)

| Index | Output | Physical |
|-------|--------|----------|
| 0 | Mon L | Monitor Output 1 (rear TRS) |
| 1 | Mon R | Monitor Output 2 (rear TRS) |
| 2 | HP1 L | Headphone 1 Left (front) |
| 3 | HP1 R | Headphone 1 Right (front) |
| 4 | HP2 L | Headphone 2 Left (front) — also Line Output 9 |
| 5 | HP2 R | Headphone 2 Right (front) — also Line Output 10 |
| 6 | Out 7 | Line Output 7 (rear TRS) |
| 7 | Out 8 | Line Output 8 (rear TRS) |
| 8 | Out 9 | Line Output 9 (rear TRS, shared with HP2 L) |
| 9 | Out 10 | Line Output 10 (rear TRS, shared with HP2 R) |
| 10 | SPDIF L | S/PDIF Output Left |
| 11 | SPDIF R | S/PDIF Output Right |
| 12–19 | ADAT 1–8 | ADAT Outputs 1–8 |

---

## Bus Map (Volume/Mute Controls)

| Bus | Name | Notes |
|-----|------|-------|
| 0 | Master | Global master volume |
| 1–2 | Mon L/R | Monitor outputs 1-2 |
| 3–4 | HP1 L/R | Headphone 1 |
| 5–6 | HP2 L/R | Headphone 2 |
| 7–10 | Out 7–10 | Line outputs 7-10 |
| 11–12 | SPDIF L/R | S/PDIF outputs |
| 13–20 | ADAT 1–8 | ADAT outputs |

---

## Mixer Matrix Layout

18 inputs × 8 mix bus outputs = 144 nodes (indices 0–143).

**Mixer inputs (18 channels, configurable via wIndex 0x3200):**
Default assignment observed:
- Slots 0–7: Analog In 1–8
- Slots 8–9: S/PDIF L/R
- Slots 10–15: Unused (parked on Mix 9)
- Slots 16–17: DAW 1–2

**Mix bus outputs (8 buses):**
- Mix 1–8 appear as source IDs 0x26–0x2d in the routing table
- Mix 9–10 (0x2e–0x2f) are used as "Off" parking by MixControl

**Node index formula (needs verification):**
Likely: `node = input_channel * 8 + mix_bus`
The stride in the x42 scarlett-mixer.c source has a comment about a possible
kernel driver bug where stride=9 instead of expected stride. This needs
calibration by setting a single known gain value and reading which node
changes.

---

## IOKit Boilerplate (Proven Working)

```c
#include <IOKit/IOKitLib.h>
#include <IOKit/usb/IOUSBLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>

// Find device
CFMutableDictionaryRef match = IOServiceMatching("IOUSBHostDevice");
CFDictionarySetValue(match, CFSTR("idVendor"),
    CFNumberCreate(NULL, kCFNumberSInt32Type, &(int32_t){0x1235}));
CFDictionarySetValue(match, CFSTR("idProduct"),
    CFNumberCreate(NULL, kCFNumberSInt32Type, &(int32_t){0x800c}));
io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, match);

// Get plugin + device interface
IOCFPlugInInterface **plug = NULL; SInt32 score;
IOCreatePlugInInterfaceForService(svc, kIOUSBDeviceUserClientTypeID,
    kIOCFPlugInInterfaceID, &plug, &score);
IOObjectRelease(svc);

IOUSBDeviceInterface **dev = NULL;
(*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID),
    (LPVOID *)&dev);
(*plug)->Release(plug);

// Open device
kern_return_t kr = (*dev)->USBDeviceOpen(dev);
// if kr != 0, check for competing processes

// Read: GET CUR
IOUSBDevRequest req = {
    .bmRequestType = 0xA1, .bRequest = 0x01,
    .wValue = wValue, .wIndex = wIndex,
    .wLength = len, .pData = buf
};
kr = (*dev)->DeviceRequest(dev, &req);

// Write: SET CUR
IOUSBDevRequest req = {
    .bmRequestType = 0x21, .bRequest = 0x01,
    .wValue = wValue, .wIndex = wIndex,
    .wLength = len, .pData = buf
};
kr = (*dev)->DeviceRequest(dev, &req);

// Close
(*dev)->USBDeviceClose(dev);
(*dev)->Release(dev);
```

### Common Error Codes
- `0x00000000` — success
- `0xe00002ed` — `kIOReturnNotPermitted` — another process holds the device
  user client (check for FocusriteControlServer, Chrome, etc.)
- `0xe0004051` — USB pipe stall — device rejected the request (wrong
  wValue/wIndex, or probed past boundary)

---

## Architecture Recommendation

### Language: Rust

Rust is recommended for the distributable tool for several reasons:
- Single static binary, `cargo install` distribution
- IOKit access via `core-foundation-rs` + `io-kit-sys` crates, or thin C FFI
- Strong type system maps perfectly to the control schema
- Side-effect isolation enforced structurally by the type system
- Cross-platform potential (Linux support via the existing kernel driver)

**Note:** `nusb` (pure-Rust USB library) needs investigation on whether it
exposes device-level `DeviceRequest` or only interface-level transfers.
If not, use direct IOKit FFI or a thin C shim (the proven C code above).

### Crate Structure

```
scarlett-ctl/
├── Cargo.toml              (workspace)
├── scarlett-protocol/      (lib crate, PURE, no I/O)
│   └── src/
│       ├── lib.rs
│       ├── types.rs        # ClockSource, SourceId, OutputId, etc.
│       ├── message.rs      # encode/decode control transfers
│       └── device_map.rs   # 18i20 Gen 1 specific: channel counts,
│                           # matrix dimensions, source ID ranges
├── scarlett-transport/     (lib crate, the dirty layer)
│   └── src/
│       ├── lib.rs
│       ├── iokit.rs        # IOKit FFI: open, DeviceRequest, close
│       └── error.rs        # IOKit error code mapping
├── scarlett-cli/           (binary crate)
│   └── src/
│       └── main.rs         # clap-based CLI
└── scarlett-gui/           (future: optional binary crate)
    └── ...                 # Tauri or egui matrix mixer UI
```

### CLI Design (MVP)

```
scarlett clock                  # read current clock source
scarlett clock internal         # set clock to internal
scarlett clock spdif            # set clock to S/PDIF
scarlett clock adat             # set clock to ADAT

scarlett rate                   # read current sample rate

scarlett route                  # show all output routing
scarlett route mon-l daw-1      # route Monitor L to DAW 1
scarlett route out-7 anlg-3     # route Line Output 7 to Analog In 3
scarlett route spdif-l off      # turn off S/PDIF output

scarlett mix                    # show mixer input assignments
scarlett gains                  # show matrix gains (non-silent)

scarlett dump                   # full state dump (like scarlett_full)
scarlett save                   # persist current state to hardware flash

scarlett doctor                 # check for competing processes, device presence
```

### Testing Strategy

The `scarlett-protocol` crate has zero dependencies on `scarlett-transport`
and contains no I/O. Every function is pure: bytes in, typed data out (and
vice versa). 100% unit test coverage is trivially achievable.

The `scarlett-transport` crate is thin and mockable. Tests can swap in a
fake transport that records calls and returns canned byte responses.

Integration tests require the physical device but are structured as:
read → verify → write → read-back → verify → restore original value.

---

## Open Questions

1. **Mute encoding on 18i20:** Returns `[0x00, 0x0b]` regardless of
   mute state. The 18i6 uses `[0x00, 0x00]`/`[0x01, 0x00]`. Need a
   controlled test: toggle mute via MixControl, read back the bytes.

2. **Matrix stride:** Is it 8 (18 inputs × 8 outputs) or 9 (as noted
   in x42's scarlett-mixer.c with a "bug in kernel driver?!" comment)?
   Need calibration: set one known gain, read which node changes.

3. **Impedance controls:** Did not respond on 18i20. May use different
   wIndex or may only exist for the front-panel combo jacks (inputs 1-2).
   Needs USB capture from MixControl on Sequoia.

4. **nusb device-level requests:** Does the Rust nusb crate support
   device-level control transfers, or only interface-level? If not,
   IOKit FFI or C shim is required.

5. **Gain encoding precision:** Observed 0xdf (-33) when MixControl
   showed -22.3 dB. Either half-dB steps, fractional encoding in the
   low byte, or pan interaction. Calibrate with known values.

6. **Config 2:** The device has `bNumConfigurations = 2`. What's in
   config 2? Possibly a different channel layout for lower sample rates
   or a vendor-specific mode. Low priority.

---

## Files from This Session

All in `/tmp/` on the M3 Mac (ephemeral):

- `scarlett_probe.c` — minimal read-only probe (clock + sample rate)
- `scarlett_full.c` — comprehensive state dump (all controls)
- `scarlett_write.c` — clock source write with read-verify round trip
- `scarlett_dump.c` — earlier version, superseded by scarlett_full.c
- `scarlett_diag.c` — diagnostic version with error code reporting
- `scarlett_raw.c` — earlier version with incorrect source names

**Copy these somewhere permanent before the next reboot:**
```bash
mkdir -p ~/projects/scarlett-ctl/probes
cp /tmp/scarlett_probe.c /tmp/scarlett_full.c /tmp/scarlett_write.c \
   /tmp/scarlett_diag.c ~/projects/scarlett-ctl/probes/
```

---

## Reference Links

- x42 scarlettmixer.py (Gen 1 protocol):
  https://github.com/x42/scarlettmixer/blob/master/scarlettmixer.py
- x42 scarlett-mixer GUI (Gen 1):
  https://github.com/x42/scarlett-mixer
- Geoffrey Bennett's Linux kernel driver (Gen 1+):
  https://github.com/geoffreybennett/linux-fcp
- ALSA Scarlett GUI (Gen 1–4):
  https://github.com/geoffreybennett/alsa-scarlett-gui
- Linux kernel mixer_scarlett.c (Gen 1):
  sound/usb/mixer_scarlett.c in torvalds/linux
- Focusrite-Scarlett-on-Linux (protocol dumps):
  https://github.com/Focusrite-Scarlett-on-Linux

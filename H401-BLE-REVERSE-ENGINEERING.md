# IPSTube H401 --- BLE Time Protocol: Reverse-Engineering Notes

This document records the full investigation that led to controlling the IPSTube H401 nixie clock over Bluetooth, and the protocol extracted from the stock firmware / companion app. Result: the companion script `h401-set-time.sh` in this
repository.

- Date: 2026-10-25
- Device: IPSTube H401 (IPS "nixie tube" clock, ESP32-based), advertising as `IPSTube_XXXXXX`
- Firmware: V1.0.3 (read back over BLE during this session)
- Companion app: `com.ipstube.ipstube` (IPSTUBE), v4.3.7 --- a Flutter app
- Host: Linux, BlueZ 5.72, `gatttool` used for all exchanges
- Authorship: the entire investigation described below, all analysis, and all artifacts (this document, the script) were produced by **Mistral Vibe**, an AI coding agent (using GLM 5.3) — not by a human; the repository owner only supplied the device and directed the work

## 1. GATT profile

The clock exposes a single application service, the Nordic UART Service (NUS):

  | Handle (decl) | Handle (value) | UUID                                 | Properties    | Role                 |
  | ---           | ---            | ---                                  | ---           | ---                  |
  | 0x002c        | 0x002d         | 6e400002-b5a3-f393-e0a9-e50e24dcca9e | write (0x08)  | app -> clock         |
  | 0x0029        | 0x002a         | 6e400003-b5a3-f393-e0a9-e50e24dcca9e | notify (0x10) | clock -> app         |
  | —             | 0x002b         | 0x2902 (CCCD of 0x002a)              | —             | enable notifications |

Plus standard GAP (0x2a00 device name, 0x2a01 appearance, 0x2aa6) and GATT service-changed characteristics. GAP values are unremarkable.

Important wire-level details discovered empirically:

- The clock **only processes Write Commands** (ATT Write Without Response). Write Requests (with response) are ACKed at the ATT layer but silently ignored, and `bluetoothctl`'s default write path gets rejected with `NotSupported`. Use
  `gatttool` interactive `char-write-cmd` (one-shot `--char-write`).
- Notifications must be enabled (CCCD 0x002b <- 0x0100) to receive responses.
- Command IDs are echoed in responses, so commands are self-identifying.

## 2. Frame format

```text
Request:  A5 <cmd> <payload...> <checksum> 5A
Response: A5 <cmd> <status> <payload...> <checksum> 5A   (status 00 = OK)
checksum = (cmd + sum(payload bytes)) & 0xFF
```

Verified example (firmware version query):

```text
Request:  a5 33 33 5a
Response: a5 33 00 56 31 2e 30 2e 33 79 5a
                   \_ "V1.0.3" _/      checksum = (0x33 + 0x56+0x31+0x2e+0x30+0x2e+0x33) & 0xff = 0x79
```

## 3. Commands recovered from the app

Extracted by decompiling the app's Dart AOT snapshot (`MsgHelper` class, `package:xinxin/common/msg_helper.dart`). Payloads marked "(empirical)" were confirmed against the live clock; the rest come from static analysis only.

  | Cmd  | Function in app              | Payload                                                               |
  | ---  | ---                          | ---                                                                   |
  | 0x59 | setTimestampMsg              | Unix epoch seconds, big-endian, variable length (see 3.1) (empirical) |
  | 0x53 | setSynchronizePhoneTimeMsg   | GMT offset in quarter-hours, 1 byte (see 3.2) (empirical)             |
  | 0x51 | setSynchronizeNetworkTimeMsg | flag (enable network/NTP time mode)                                   |
  | 0x57 | setTimeFormatIs24HMsg        | 0/1 (12h / 24h)                                                       |
  | 0xB4 | getBatteryMsg                | none — no response observed on this unit                              |
  | 0x33 | getDeviceFirmwareVersionMsg  | none (empirical)                                                      |
  | 0x5A | getClockStyleMsg             | none                                                                  |
  | 0xB5 | getMusicBlueConnectStatusMsg | none                                                                  |
  | 0x5C | getScreenBrightnessMsg       | none                                                                  |
  | 0x64 | getLedBrightnessMsg          | none                                                                  |
  | 0x47 | getWifiIp (demo page)        | none                                                                  |
  | 0xB9 | setStockCodeMsg              | UTF-8 string bytes of stock symbol                                    |

The app also contains two sibling helper classes for other device generations: `MsgHelperWithLength` (frames carry a length byte) and `MsgJsonHelper` (JSON-based protocol). The H401 with firmware V1.0.3 uses the plain `MsgHelper` format
described in section 2.

### 3.1 Timestamp (cmd 0x59)

The app computes Unix epoch seconds (with negative-safe truncation toward the past), converts to a hex string (`toRadixString(16)`), left-pads to even length, and splits into byte pairs --- i.e. big-endian bytes of the seconds value:

```text
seconds = 1792903696 = 0x6add8a10
payload = 6a dd 8a 10
frame   = a5 59 6a dd 8a 10 <checksum> 5a
```

### 3.2 Phone-time sync (cmd 0x53)

The app sends the phone's GMT offset truncated to 15-minute units: `quarterHours = int(timeZoneOffset.inMinutes / 15)` (Dart `int()` on a double truncates toward zero; negative offsets truncate toward zero as well). Europe/Brussels in
winter (UTC+1) => 4. India (+5:30) => 22.

```text
frame = a5 53 04 57 5a     (checksum = (0x53 + 0x04) & 0xff = 0x57)
```

Both commands ACK immediately: `a5 59 00 59 5a` and `a5 53 00 53 5a`.

## 4. Investigation log

1. **BLE discovery.** `bluetoothctl scan` found the clock already known to BlueZ as `IPSTube_XXXXXX`. Connected; only NUS + GAP/GATT services present.
2. **Probing.** ASCII probes ("AT", "time?", JSON, etc.) over NUS produced no response. Writes via `bluetoothctl` failed (`NotSupported`); raw ATT with `gatttool` succeeded only as Write Commands (see section 1). No public documentation of
   the stock BLE protocol exists --- all search hits lead to replacement firmwares (EleksTubeHAX, judge2005/EleksTubeIPS), which do not use this protocol.
3. **App acquisition.** Downloaded the official app XAPK from APKPure (`com.ipstube.ipstube` 4.3.7) --- direct CDN was Cloudflare-gated, the alternate host `d.apkpure.net` worked. Unpacked the XAPK to get `libapp.so` (Dart AOT snapshot, ~25
   MB, arm64) and `classes.dex`.
4. **Decompilation.** `jadx` on classes.dex showed the app is Flutter-based (flutter_blue_plus), so the BLE logic lives in `libapp.so`. Built and ran `blutter` (needed `libcapstone-dev`) which dumped readable pseudo-Dart:
   `xinxin/common/msg_helper.dart` contains every command builder.
5. **Static analysis.** Recovered `getBluetoothCmdMsg(cmd, payload)` (frame builder), `sumCheck` (checksum), and the command IDs. Dart Smi tagging (constants stored <<1) initially made constants look odd (330 = 165 = 0xA5, 180 = 90 = 0x5A)
   and blutter's Array field offsets were ambiguous --- resolved by cross-checking several call sites.
6. **Empirical validation.** Sent `a5 33 33 5a` (get firmware version) as a Write Command: the clock replied `a5 33 00 "V1.0.3" 79 5a`. Checksum verified by hand; frame format confirmed.
7. **Time set.** Sent timestamp + GMT-offset frames; both ACKed with status
   00. Clock display updated to host local time.
8. **Scripting.** One-shot `gatttool` was unreliable at connection time, so `h401-set-time.sh` drives an interactive `gatttool` session through a pipe. Tested end-to-end: both frames ACKed.

## 5. Usage

```bash
./h401-set-time.sh
```

The script prompts for the clock's MAC address (no built-in default; find the address with `bluetoothctl scan on`). Requires: BlueZ `gatttool`, root not needed. Run it whenever the clock drifts or after a DST change; it reads the time and GMT offset from the system clock.

## 6. Caveats / open questions

- GATT handles (0x002d write, 0x002b CCCD) were discovered by enumeration on firmware V1.0.3. A firmware update may move them; re-enumerate with `gatttool -b <MAC> -I` -> `characteristics`.
- The clock must not be connected to the phone app simultaneously; the phone app holds the connection exclusively in practice.
- `getBatteryMsg` (0xB4) produced no response on this unit, despite being sent by the app right after connect --- possibly only answered in some device state.
- 12/24h format (cmd 0x57) was not exercised; the clock keeps its current mode.
- The quarter-hour GMT offset means half-hour timezones (e.g. India +5:30) truncate cleanly (330/15 = 22), but the app's truncation toward zero would corrupt offsets that are not multiples of 15 minutes.

## 7. Tooling used (all ephemeral, under /tmp)

- `jadx` 1.5.1 --- Java/dex decompiler (classes.dex was a dead end for Flutter)
- `blutter` (worawit/blutter) + `pyelftools` + `libcapstone-dev` (apt) --- Dart AOT snapshot decompiler; output in `/tmp/ipstube/blutter_out/asm/`
- `gatttool` --- all BLE exchanges
- App XAPK and extracted artifacts: `/tmp/ipstube/` (not persisted)

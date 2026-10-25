# h401-ipstube-hack

Reverse-engineering of the **IPSTube H401** nixie-style clock's Bluetooth Low Energy protocol, and a small companion script to set the clock's time from a Linux host without the vendor app.

The stock device exposes no public protocol documentation and there is no open-source client for its stock firmware (existing community projects such as EleksTubeHAX replace the firmware entirely and use a different protocol). This project closes that gap: the BLE protocol was recovered from the official Android companion app and validated against the live clock.

## Authorship

All work in this repository — the BLE investigation, the companion-app decompilation, the protocol extraction, the writing of these documents, and the script itself — was performed by **Mistral Vibe**, an AI coding agent (using GLM 5.3), not by a human. The repository owner supplied the hardware and directed the effort through conversational requests; every technical step was executed by the agent.

## What was done

1. **BLE discovery** — scanned for the clock with BlueZ, enumerated its GATT profile, and identified a single application service: the Nordic UART Service (NUS), with a write characteristic (app to clock) and a notify characteristic (clock to app).
2. **Transport quirks found empirically** — the clock only processes ATT Write Commands (write-without-response); writes-with-response are silently ignored. Responses require subscribing to notifications first (CCCD write).
3. **Companion app analysis** — downloaded the official app XAPK (a Flutter app), unpacked it, and decompiled the Dart AOT snapshot with `blutter` (after `jadx` showed the BLE logic was not in the Java layer). This yielded the full frame format, checksum algorithm, and the complete command table.
4. **Live protocol validation** — confirmed the recovered protocol against the actual clock, e.g. a firmware-version query round-trip verified the frame format and checksum end to end.
5. **Time-setting script** — wrote `h401-set-time.sh`, which reads the host's clock and timezone and sets the clock's time and GMT offset over BLE. Tested end-to-end; the clock acknowledges both commands and updates its display.

## Repository layout

| File | Purpose |
| --- | --- |
| `h401-set-time.sh` | Set the clock's time + GMT offset over BLE (interactive `gatttool` session) |
| `H401-BLE-REVERSE-ENGINEERING.md` | Full investigation notes: GATT profile, frame format, command table, validation log, caveats |
| `.panache.toml` | Markdown formatting style for the notes |

## Protocol summary

```text
Request:  A5 <cmd> <payload...> <checksum> 5A
Response: A5 <cmd> <status> <payload...> <checksum> 5A    (status 00 = OK)
checksum = (cmd + sum(payload bytes)) & 0xFF
```

Transported over the Nordic UART Service (RX `6E400002` for writes, TX `6E400003` for notifications). Command IDs are echoed in responses, making frames self-identifying.

Commands used by the script:

| Cmd | Function | Payload |
| --- | --- | --- |
| `0x59` | set timestamp | Unix epoch seconds, big-endian |
| `0x53` | set GMT offset (phone-sync mode) | GMT offset in quarter-hours (15-minute units), 1 byte |

See `H401-BLE-REVERSE-ENGINEERING.md` for the full recovered command table (battery, brightness, clock style, 12/24h format, stock ticker, and more) and details of each investigation step.

## Usage

Requires BlueZ `gatttool` on a Linux host with Bluetooth; no root needed. The clock must not be connected to the phone app at the same time.

```bash
./h401-set-time.sh
```

The script takes no arguments; it prompts for the clock's MAC address on startup and keeps no built-in default, so nothing device-specific is stored in this repository. Input is validated and re-prompted if it doesn't look like a MAC. The clock's address can be found with `bluetoothctl scan on` — it advertises as `IPSTube_XXXXXX`.

Run it whenever the clock drifts or after a DST change; it reads both the time and the GMT offset from the system clock.

## Caveats

- GATT attribute handles were discovered by enumeration on firmware V1.0.3; a firmware update may move them. Re-enumerate with `gatttool -b <MAC> -I` -> `characteristics` if the script stops working.
- Some recovered commands were validated only statically (not exercised on the live clock); see the notes file for which are marked empirical.
- The quarter-hour GMT offset truncates cleanly for timezones that are multiples of 15 minutes (including half-hour zones like UTC+5:30), but would be lossy for others.

## Tools used (all ephemeral)

- `jadx` — Java/dex decompiler (useful for confirming the app is Flutter-based)
- `blutter` (worawit/blutter) — Dart AOT snapshot decompiler; source of the command table
- `gatttool` — all BLE exchanges

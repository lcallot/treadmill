# WalkingPad Z1 Bluetooth protocol (as implemented here)

This is the reference for any port, Android included. It is condensed from
[slandau3/z1-walkingpad-mcp/docs/protocol.md](https://github.com/slandau3/z1-walkingpad-mcp/blob/main/docs/protocol.md),
which was verified on a KS-HD-Z1D with firmware V0.0.6.

## Device

- BLE name: `KS-HD-Z1D`. The app matches names that start with `KS-HD-` or `KS-Z1`.
- One connection at a time. No pairing or bonding: do **not** pair it in the
  OS Bluetooth settings.
- Speed range: 1.6–6.4 km/h, read from characteristic `2AD4`.

## GATT

| UUID | Use |
|---|---|
| `1826` | FTMS service |
| `2ACD` notify | Treadmill data (about 1 frame per second while the belt runs) |
| `2ADA` notify | Machine status: `04` started, `01`/`02` stopped/paused, `FF` control lost |
| `2AD9` write + indicate | FTMS control point |
| `2AD4` read | Supported speed range, u16 LE min/max, km/h × 100 |
| `24E2521C-F63B-48ED-85BE-C5330A00FDF7` | KingSmith supplement service |
| `…C5330B00FDF7` notify | Vendor replies |
| `…C5330D00FDF7` write-without-response | Vendor requests |

Never touch the `FFC0`/`FFF0`/`FF00` services, and never send a frame
starting with `E8`. Those belong to the chip's firmware-update mode.

## Vendor frames

`[cmd0, cmd1, len, data…, checksum]`, where checksum = sum of all previous
bytes & 0xFF. The reply uses the same `cmd0` and `cmd1 | 0x80`.

Space writes **at least 400 ms apart** on each channel. The pad silently drops
faster writes.

## Connect sequence

1. Connect, then discover the FTMS and supplement services.
2. Enable notifications on `…B00FDF7` **before** writing anything.
3. Unlock: `71 00 05 01 <T LE32> CC`, where `T = LE32(last 4 bytes of name) + 1`.
   For `KS-HD-Z1D` the frame is `71 00 05 01 2E 5A 31 44 74`. Wait for `71 80`.
4. Enable notifications on `2ACD` and `2ADA`, and indications on `2AD9`.
5. (Optional, mirrors the official app) Send SYS_INFO
   `71 01 08 <unix LE32> <0 LE32> CC`, then read all properties with `72 00 01 00 73`.

## Belt control: FTMS control point `2AD9`

Write with response. Each command gets the indication `80 <op> <result>`.

| Command | Bytes |
|---|---|
| Request control (once) | `00` |
| Start / resume | `07` (refused with result 4 if the belt is already moving) |
| Set speed | `02 <u16 LE km/h×100>` |
| Pause | `08 02` |
| Stop (ends session, resets counters) | `08 01` |

Results: 1 = OK, 4 = failed (retry once, then use the vendor tunnel), 5 = not
permitted (send `00` again).

The vendor tunnel is `77 01 <len> <op> <params…> CC`, with the same op codes as
FTMS. The reply is `77 81 … [op, status]`, where status 0 or 0x81 = OK.

## Settings: vendor properties

Read all with `72 00 01 00 73`. The reply `72 80` holds 4-byte records
`[id, err, lo, hi]`. Write one with `72 01 03 <id> <lo> <hi> CC`; the reply is
`72 81` with data[1] = 0 on success. The pad also pushes changes on its own
as `72 50` with 3-byte records `[id, lo, hi]`.

| id | meaning |
|---|---|
| 1 | bit 1: display in miles |
| 2 | bit 15: auto-stop enabled; low bits: seconds |
| 6 | child lock (0/1) |
| 8 | bit 1: beep, bit 3: indicator light |
| 10 | bits 5–7: mode (0 manual, 2 standby). The Z1 refuses 1 (auto) with error 8, and answers 9 when the value is unchanged. |

## Telemetry `2ACD`

The standard FTMS treadmill data layout: u16 LE flags, followed by fields in
flag order. The Z1 sends flags `0x2404`: speed (u16, km/h×100), distance (u24,
m), elapsed time (u16, s), and steps (u16, flag bit 13, a KingSmith extension).
Our Z1 actually sends flags `0x2484`: the above plus expended energy (bit 7:
total kcal u16, per hour u16, per minute u8), and one trailing byte the spec
doesn't define. When energy is missing, the app estimates calories with the
ACSM walking equation: `VO2 = 0.1 × m/min + 3.5`, and `kcal/min = VO2 × kg / 200`.

Machine status `02 xx`: `02 01` = stopped, `02 02` = paused.

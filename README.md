# StarPrinter Emulator: a Star receipt printer emulator for macOS

A Mac app (and CLI) that **shows up on your LAN as a Star Micronics receipt printer**: an **mC-Print3** or a **TSP100IIIW**. When a POS app prints to it, the emulator renders the receipt as you'd see it on paper, shows it in a preview, and saves it as a PNG. No hardware or paper needed, and no walking to the printer.

It emulates the printer's **protocol**, not its hardware. That's the same idea as [zebra-emulator](https://github.com/brianzinn/zebra-emulator), but for Star / StarPRNT.

> **Unofficial.** Not affiliated with or endorsed by Star Micronics. "Star Micronics", "StarPRNT", "StarIO" and "mC-Print" are their trademarks.

## What works

| | |
|---|---|
| **Models** | **mC-Print3** (StarPRNT) and **TSP100IIIW** (StarGraphic: raster only, so StarIO10 sends it images and QR codes but no text or barcodes). Pick one in Settings or with `--model` |
| **Discovery** | Answers StarIO10 LAN discovery (UDP 22222). The SDK lists it as `mC_Print3 / starPRNT` or `tsp100IIIW / starGraphic`, and uses the emulator's MAC as the printer identifier |
| **Printing** | TCP 9100 with the handshake the SDK expects (`ESC ACK SOH` → ASB, ETB counter, `ESC GS ) I` printer information). TCP 9101 status polls |
| **Rendering** | Text (Font A/B cells, bold, invert, underline, 1–6× magnification, alignment, tabs, UTF-8), feeds, full/partial cuts (one page per cut), `ESC GS S` raster images (StarXpand `actionPrintImage` bitmap receipts), QR codes, Code128 with HRI, drawer kicks. Also Star **raster mode** as used by older StarIO apps (e.g. Shopify POS) |
| **Fault simulation** | Cover open, paper empty, paper near end, offline, unreachable. The SDK reports each one as a real printer would (`Device has error.`) |
| **Output** | Live preview with zoom, Save PNG (203 dpi, 1 dot = 1 pixel), copy, drag-out, auto-save to a folder, raw `.bin` of every job, command list and hex view |

All of this was verified **end to end with the real StarIO10 SDK** (2.9.1 on an iPad, 2.10.0 in the iOS Simulator), and key replies were checked against a physical mC-Print3 and a physical TSP100IIIW.

## Quick start

### App

```bash
brew install xcodegen
xcodegen generate
open StarEmu.xcodeproj        # ⌘R
```

The app starts the emulator right away. The sidebar shows the address (`Listening on 192.168.x.y:9100`) and the identifier StarIO10 will report.

### CLI (headless)

```bash
swift run staremu serve --png ~/Desktop/receipts
```

`serve` options: `--model mcprint3|tsp100iiiw`, `--port 9100`, `--status-port 9101` (0 = off), `--no-discovery`, `--mac 02:53:54:41:52:01`, `--fault cover-open,paper-empty,paper-near-end,offline`, `--idle 1.0`, `--out DIR`, `--verbose`.

Other commands:

```bash
swift run staremu render job.bin -o receipt.png [--page 2]   # render a saved job
swift run staremu parse job.bin                              # list the StarPRNT commands
swift run staremu hexdump job.bin
```

## Using it with a StarIO10 app

Any app built on Star's StarIO10 / StarXpand SDK (iOS, Android, or React Native via `react-native-star-io10`) can print to it.

1. Put the Mac and the device running the app (or the iOS Simulator on the same Mac) on the **same network/subnet**.
2. Start the emulator. On first run, macOS may ask to allow incoming connections and Local Network access. Allow both.
3. Search for LAN printers in the app (`StarDeviceDiscoveryManager`). The emulated model (**mC-Print3** or **TSP100IIIW**) appears with identifier = the emulator's MAC. Select it, or connect directly with `StarConnectionSettings(interfaceType: .lan, identifier: "<MAC or IP>")`.
4. Print. The receipt appears in the emulator within a second.
5. Use **Simulate** in the sidebar (or the menu bar icon) to test error handling: cover open, paper out, near end, offline, unreachable.

Raw TCP also works: `nc <mac-ip> 9100 < job.bin`. Without SDK framing, a job ends when the connection closes or after 1 s of silence.

## How it works

```
Client (StarIO10) ──UDP 22222 STR_BCAST/RQ1──▶ DiscoveryResponder ──302-byte RS1.0.1 reply (model MCP31L (STR-001), MAC, IP)
                  ──TCP 9100──▶ PrintServer ─▶ StarPRNTParser ─┬─▶ StatusEngine ──status replies──▶ client
                                                               └─▶ JobAssembler (ends at ETB + ESC GS ETX 4) ─▶ JobStore (.bin)
                  ──TCP 9101 (0x32 query)──▶ 2 × ASB, close                       └─▶ Renderer ─▶ PaperBitmap ─▶ preview / PNG
```

- `Sources/StarEmuCore`: everything except UI. Network, parser, renderer, status, jobs. No AppKit.
- `Sources/staremu`: the CLI. `App/`: the SwiftUI app (sandboxed).
- `Tests/StarEmuCoreTests/Fixtures/`: captured SDK documents and golden PNGs the tests run against.

## Development

```bash
swift test                     # ~100 tests: parser (SDK fixtures, fuzz), renderer, goldens, sockets, emulator
UPDATE_GOLDENS=1 swift test    # after an intended rendering change; review the PNG diffs
scripts/release.sh 0.1.0       # CLI + app + DMG (set SIGN_IDENTITY / NOTARY_PROFILE to sign and notarize)
```

Signing and shipping (team setup, TestFlight, notarized DMG): see [DEPLOYMENT.md](DEPLOYMENT.md).

## Known limitations

- Glyph shapes come from Menlo, not the printer's ROM font. Cell sizes match, so line breaks and columns are exact, but letterforms differ.
- Barcodes other than Code128 render as a labelled placeholder. PDF417, logos and page mode aren't supported (they show up as warnings).
- Partly compared with **physical** printers: the discovery reply matches a real mC-Print3 and TSP100IIIW, and their status frames and handshakes were captured. The fault bits still come from reference captures (`THIRD_PARTY_NOTICES.md`) and are SDK-verified only.
- Bluetooth and USB aren't emulated (iOS Star Bluetooth printers use MFi, which a Mac can't emulate).

## Roadmap

Possible next steps: more Star models, a CUPS queue for macOS/browser printing, ESC/POS mode, CloudPRNT.

# Gameboy_MiSTer — RetroAchievements Fork

This is a fork of the official [Gameboy_MiSTer](https://github.com/MiSTer-devel/Gameboy_MiSTer) core with **RetroAchievements** support for Game Boy and Game Boy Color on MiSTer FPGA.

> **Status:** Experimental / Proof of Concept — requires the modified [Main_MiSTer binary](https://github.com/odelot/Main_MiSTer) to function.

## How to Test

Pre-built core binaries are available on the [Releases](https://github.com/odelot/Gameboy_MiSTer/releases) page — no compilation or Quartus needed.

1. Download the `.rbf` core file from the latest release.
2. Copy the core file to the `/media/fat/_Console` folder on your MiSTer SD card.
3. You will also need the modified Main_MiSTer binary from [odelot/Main_MiSTer](https://github.com/odelot/Main_MiSTer) (see its README for setup instructions, including RetroAchievements credentials).

## What's Different from the Original

The [upstream Gameboy_MiSTer](https://github.com/MiSTer-devel/Gameboy_MiSTer) core emulates the Game Boy, Game Boy Color, and Super Game Boy. This fork adds the FPGA-side infrastructure needed to expose emulated RAM to the ARM binary for RetroAchievements evaluation. All original core features are preserved.

### Files Added

| File | Purpose |
|------|--------|
| `rtl/ra_ram_mirror_gb.sv` | State machine that reads targeted byte addresses from WRAM, ZPRAM (HRAM), and Cart RAM, then writes values to the RA DDRAM mirror region using the Selective Address protocol |

### Files Modified

| File | Change |
|------|--------|
| `Gameboy.sv` | RA mirror module instantiated, SDRAM ch2 wired for Cart RAM reads, LED_DISK shows RA activity |
| `rtl/gb.v` | WRAM and ZPRAM BRAMs: Port B multiplexed between savestate access, RA reads and the power-on RAM fill; RA interface ports added; `ra_vblank` exported as the RA sampling point |
| `rtl/ddram.sv` | Channel 2 documentation updated for RA read/write operations |
| `files.qip` | Added `ra_ram_mirror_gb.sv` to the Quartus build |

### How the RAM Mirroring Works

The Game Boy has a Z80-derived 8-bit architecture with a compact but banked memory map (especially on GBC). This core uses the **Selective Address protocol** with the **RTQuery mailbox** (FPGA protocol v2): the ARM binary writes a list of addresses it needs to evaluate, the FPGA reads only those values once per frame and writes them back to DDRAM, and between frames it serves on-demand reads for addresses that are not on the list yet.

**Memory regions exposed:**

| RA Address Range | Region | Size | FPGA Interface |
|-----------------|--------|------|----------------|
| `$A000–$BFFF` | Cart RAM bank 0 | 8 KB | SDRAM ch2 |
| `$C000–$CFFF` | WRAM bank 0 | 4 KB | BRAM dual-port (Port B) |
| `$D000–$DFFF` | WRAM bank 1 | 4 KB | BRAM dual-port (Port B) |
| `$E000–$FDFF` | Echo RAM (mirrors $C000–$DDFF) | — | BRAM dual-port (Port B) |
| `$FF80–$FFFE` | HRAM / ZPRAM | 127 bytes | BRAM dual-port (Port B) |
| `$10000–$15FFF` | WRAM banks 2–7 (GBC only) | 24 KB | BRAM dual-port (Port B) |
| `$16000–$33FFF` | Cart RAM banks 1–15 | up to 120 KB | SDRAM ch2 |

**Key implementation details:**

- **BRAM Port B multiplexing** — The existing dual-port WRAM (32 KB) and ZPRAM BRAMs already have Port B used for savestate access. The RA mirror shares Port B by asserting `ra_wram_req` / `ra_zpram_req` signals, which mux the address and disable writes. When RA is not active, savestate access continues normally. This avoids adding extra memory and ensures zero disruption to gameplay on Port A.

- **Cart RAM via SDRAM ch2** — Cart RAM (battery-backed SRAM for game saves) lives in SDRAM. The RA mirror accesses it through a dedicated SDRAM channel 2 interface with busy handshaking, separate from the main game logic. All Cart RAM reads are read-only.

- **GBC WRAM banking** — Game Boy Color has 8 WRAM banks (32 KB total). The RA mirror uses rcheevos extended addressing: `$C000–$CFFF` for bank 0, `$D000–$DFFF` for bank 1, and `$10000–$15FFF` for banks 2–7. The bank index is computed from the address (`(addr - $10000) / $1000 + 2`) and combined with the 12-bit intra-bank offset.

- **Echo RAM translation** — Addresses in the `$E000–$FDFF` range are automatically translated to `$C000–$DDFF` (hardware mirroring behavior).

- **2-cycle BRAM read path** — BRAM reads require two clock cycles (address latch on cycle N, output valid on cycle N+2), which the state machine handles explicitly with `S_FETCH_WRAM → S_WRAM_WAIT → S_WRAM_READ` states.

- **DDRAM arbitration** — The core's `ddram.sv` module provides channel-based arbitration. Channel 1 is for savestates, channel 2 is for the RA mirror (read + write). The RA mirror uses 64-bit DDRAM transactions with byte enables.

- **VBlank gating** — The mirror only triggers when savestates and backup save operations are idle (`ra_vblank & ~sleep_savestate & ~bk_state`).

- **Activity LED** — `LED_DISK[0]` indicates RA mirror activity.

- **Smart Cache and the RTQuery mailbox** — The address list is not static. The ARM binary bootstraps it from the achievement set, then grows it at runtime: when a condition reads an address that is not in the list (typically an `AddAddress` pointer target), the read is answered live through the RTQuery mailbox at DDRAM offset `0x50000` and the address is added to the list for the next frame. The mailbox holds 16 request slots (`0x50008`) and 16 response slots (`0x50088`), and the mirror polls it roughly every 2000 clocks while idle, gated by a config bit the ARM sets so the polling costs nothing when RTQuery is unused. Multi-byte queries (16/32-bit reads) are served by re-dispatching each byte through the same region routing as the batch path, so a query may span WRAM, HRAM and Cart RAM.

- **VBlank sampling point** — The mirror samples on the rising edge of `vblank_irq`, which is the `LY 143 → 144` transition, i.e. the exact moment the Game Boy raises the VBlank interrupt and before the game's VBlank handler runs. This matches where RAVBA (the emulator Game Boy achievement sets are authored against) evaluates achievements, alongside its `register_IF |= 1`. 

- **Power-on RAM contents** — WRAM and HRAM are filled at reset with the pattern the reference emulator produces, not with zeros:

  | Region | Fill |
  |--------|------|
  | HRAM (`$FF80–$FFFE`) | `0xFF` |
  | WRAM (all banks) | 8-byte blocks alternating `0x0F` / `0xFF`, polarity inverting every `0x800` bytes |

  This reproduces RAVBA's `gbReset()`, whose own comment notes it is "way closer to the reality than filling it with 00es or FFes" and that "the starting data are important for some 'buggy' games". It matters beyond fidelity: achievement conditions are written against these values, so a guard such as `$FF9F == 0` is meant to be *false* on a fresh boot. Filling with zeros makes such guards pass and unlocks achievements that never trigger on an emulator.

  The fill is a sweep over Port B while the core is held in reset (~0.7 ms), so the CPU cannot write RAM before it completes, and it also removes any leftovers from a previous game or reset. Cartridge RAM is deliberately untouched, since that is battery-backed save data.

**Per-VBlank flow:**
1. At the VBlank interrupt (`LY 143 → 144`), the RA mirror writes the header with `busy=1`.
2. It reads the address request list from DDRAM at offset `0x40000`.
3. For each address, it dispatches to the appropriate memory source (WRAM/ZPRAM via BRAM Port B, or Cart RAM via SDRAM ch2).
4. Values are collected 8 bytes at a time into 64-bit words and written to the response cache at offset `0x48000`.
5. A response header with the current frame counter is written so the ARM can detect new data.
6. The header `busy` flag is cleared and debug counters are updated.
7. Between frames, the mirror polls the RTQuery mailbox and answers any on-demand read the ARM binary posts there.

---

## Original Features (preserved from upstream)

* Original Gameboy & Gameboy Color Support
* Super Gameboy Support - Borders, Palettes and Multiplayer
* MegaDuck Handheld & Laptop Support
* Custom Borders
* SaveStates
* Fastforward 
* Rewind - Allows you to rewind up to 40 seconds of gameplay
* Frameblending - Prevents flicker in some games (e.g. "Chikyuu Kaihou Gun Zas") 
* Custom Palette Loading
* Real-Time Clock Support
* Gameboy Link Port Support - Requires USERIO adapter
* Workboy
* Cheats
* Fast boot
* GBA mode for GBC games

## Open Source Bootstrap roms
Open source roms are included in the core, adapted from the SameBoy project [https://github.com/LIJI32/SameBoy/](https://github.com/LIJI32/SameBoy/). These roms have MiSTer-specific enhancements, allowing fast booting and GBA mode to be controlled by the on-screen display.

 For maximum compatibility/authenticity you can still place the Gameboy bios/bootroms into the Gameboy folder and load them in the menu with `Bootroms->Load GBC/DMG/SGB boot`. 

For more information see the [BootROM README](./BootROMs/README.md)  

## Palettes
This core supports custom palettes (*.gbp) which should be placed into the Gameboy folder. Some examples are available in the palettes folder.

## Custom Borders
This core supports custom borders (*.sgb) which should be placed into the Gameboy folder. Some examples are available in the borders folder.

## Autoload
To autoload your favorite game at startup rename it to `boot2.rom`.

## Video output
The Gameboy can disable video output at any time which causes problems with vsync_adjust=2 or analog video during screen transitions. Enabling the Stabilize video option may fix this at the cost of some increased latency.

## Savestates
This core provides 4 slots to save and restore the memory state which means you can save at any point in the game. These can be saved to your SD Card or they can reside only in memory for temporary use (OSD Option). Save states can be performed with the Keyboard, a mapped button to a gamepad, or through the OSD.

Keyboard Hotkeys for save states:
- <kbd>ALT</kbd>+<kbd>F1</kbd>/<kbd>F2</kbd>/<kbd>F3</kbd>/<kbd>F4</kbd> – save state  
- <kbd>F1</kbd>/<kbd>F2</kbd>/<kbd>F3</kbd>/<kbd>F4</kbd> – restore state


Gamepad:

- <kbd>SAVESTATEBUTTON</kbd>+<kbd>LEFT</kbd>/<kbd>RIGHT</kbd> prev/next savestate slot
- <kbd>SAVESTATEBUTTON</kbd>+<kbd>START</kbd>+<kbd>DOWN</kbd> saves to the selected slot
- <kbd>SAVESTATEBUTTON</kbd>+<kbd>START</kbd>+<kbd>UP</kbd> loads from the selected slot

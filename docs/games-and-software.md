# Games, tools & toys for the Eee PC 701 (deeebian)

A curated catalogue of software that **actually runs at usable speed** on an ASUS Eee PC 701 4G:
Celeron M ULV 353 @ **900 MHz** (single core, downclocks to ~630 MHz on battery), **Intel 915GM**
graphics (GMA 900 — *no usable 3D; roughly a GeForce2 MX / Radeon 7000*), **800×480** panel,
**2 GB** RAM shared with the GPU, booting from a slow SD card under Openbox + tint2.

Everything here was checked against **packages.debian.org / bookworm, architecture i386**
against the authoritative `dists/bookworm/*/binary-i386/Packages` index; the "bookworm" column
gives the exact version and **installed size** apt reports. A packaged game is one signed
`apt install` line with its dependencies solved — that is why the package column matters most.

## How to read this / hard rules

* **Package** = verified present in bookworm **i386**. `—` means *not packaged*; then a source
  and a **verified** license are given.
* **Size** is the **installed** size (KiB or MiB), from the Debian index. Add ~30–60 % for
  dependencies unless a metapackage is named.
* **License discipline.** Nothing under copyright is committed to this repo. Where a game's
  *engine* is free but its *data* is not (Doom WADs, Quake PAKs), the repo ships the **engine**
  plus freely-redistributable data (**Freedoom**), and the catalogue tells the user where to
  legally obtain the rest. ROMs are never shipped — see the licensing assessment at the end.
* **Do the one thing first:** install the small `core` set and try it on real hardware before
  buying into the big categories. `sudo eeepc-games --install core` installs **25 packages /
  ~8 MiB** and gives you an evening of play.

```bash
eeepc-games                 # menu; right-click menu > "Games & software"
sudo eeepc-games --install core
sudo eeepc-games --list-all
sudo eeepc-games --offline /media/usb/debs --install core,arcade,emulation
```

---

## The performance reality, honestly

Established by [a month-long test of a 701 as a daily driver (2025)](https://pspodcasting.net/dan/blog/2025/asus_eee.html),
the [DOSBox performance wiki](https://www.dosbox.com/wiki/Performance), SNES9x/ZSNES upstream
requirements, the [Debian games task descriptions](https://blends.debian.org/games/tasks/) and
the DOSBox compatibility list:

| Class | Verdict on this hardware | Why |
|---|---|---|
| 2D text roguelikes, IF, card/board, puzzles | **Excellent** — instant | ncurses text; no emulation |
| Native 2D SDL/X11 arcade & action | **Good** | 2D blitting, 800×480, 16-bit-ish |
| **Doom / Quake / Duke3D** source ports | **Good at reduced settings** | The original games ran on a 486/Pentium; a 900 MHz P6 is far faster. Doom specifically confirmed playable on a 701 |
| **DOSBox** (8086/286/early-386 DOS) | **Good** if you keep `cycles` low (~1500–6000) | DOSBox's own table: a ~1 GHz host ≈ a **486/66**; enough for Wolf3D/Commander Keen/prince of persia-class, *not* protected-mode DOS4GW titles |
| **ScummVM** | **Good**, incl. later 2D adventures | ScummVM interprets 2D engines; no CPU emulation of the target |
| **NES, Game Boy / GBC, Atari 2600, SMS/GG** | **Yes** | 8-bit CPUs emulated cheaply; light video |
| **SNES, Genesis, GBA, PS1, N64** | **No, realistically** | This is the user's "basically a no go" — confirmed. Snes9x's own readme wants **800 MHz–1 GHz minimum and faster for Super-FX**; on a single 900 MHz core (shared with the GPU) it is not a good time |
| Modern 3D, Steam, Java Minecraft, LibreOffice, GIMP, Audacity | **No** | CPU + driver + memory; 915GM has no usable 3D and Audacity is WebKitGTK-heavy |
| **ClassiCube** (Minecraft-Classic-compatible, written in C) | **Yes — ~20–30 FPS** | Confirmed by the same independent 701 test. Not packaged in Debian; see §Modern |

A useful intuition: **the 701 is roughly a Pentium III with 2000-era graphics, 2007-era RAM and
1997-era storage.** Target software written for a Pentium or slower, and it flies.

---

## 1. Roguelikes & dungeon crawls

The single best category for this machine: pure text, zero graphics load, deep games.

| Name | What it is | Package (bookworm i386) | Size | Why it runs |
|---|---|---|---|---|
| **NetHack** | The canonical dungeon crawl, 1987→ | `nethack-console` (+`nethack-common`) | 3.2 MiB | ncurses text |
| NetHack, X11 | Tile/graphics interface | `nethack-x11` | 3.3 MiB | 2D tiles; fine |
| **Dungeon Crawl Stone Soup** | The best modern traditional roguelike | `crawl` | 11.1 MiB | ncurses; heavier map but still text |
| **Angband** | Tolkien dungeon simulation | `angband` | 2.9 MiB | Text; huge depth |
| **SLASH'EM** | NetHack variant | `slashem` | 2.7 MiB | ncurses |
| **umoria** (=Moria) | The great-granddaddy of them all | `moria` | 833 KiB | Text |
| **Omega** | Sprawling 1980s roguelike | `omega-rpg` | 1.3 MiB | Text |
| **Boohu** | Modern, fast, small traditional roguelike (Go source) | `boohu` | 3.5 MiB | ncurses; tiny turn cost |
| **Gearhead** | Mecha roguelike RPG | `gearhead` | 1.0 MiB | ncurses |
| **Meritous** | Action-adventure dungeon crawler | `meritous` | 335 KiB | Light 2D |
| **Cataclysm: Dark Days Ahead** | Vast post-apocalyptic survival roguelike | `cataclysm-dda-sdl` | 17.9 MiB | **Try it** — turn-based so even a slow redraw is usable; SDL2 2D. Heaviest of the good ones. |
| **HyperRogue** | Non-Euclidean roguelike; genuinely obscure & brilliant | `hyperrogue` | 9.8 MiB | 2D; fine |
| **LambdaHack / Allure** | ASCII squad roguelike engine + a game | `lambdahack`, `allure` | 75–76 MiB ea. | Haskell; big install, but text-mode play is cheap. **Size is the only warning.** |

> Skip: `dungeon` (not packaged). For a *modern* graphical roguelike that still fits, see
> **HyperRogue**; for purists, **DCSS** and **NetHack** are the two to install.

## 2. Interactive fiction & text adventures

Interpreters are featherweights and there are thousands of legal, free IF works (IF Archive,
Inform, Z-machine/Glulx).

| Name | What it is | Package | Size | Why |
|---|---|---|---|---|
| **Frotz** | Reference Z-machine interpreter | `frotz` | 343 KiB | Text |
| fizmo (console/ncurses/sdl2) | Another Z-machine, 3 flavours | `fizmo-console` / `-ncursesw` / `-sdl2` | 192–279 KiB | Text / light SDL |
| **Glulxe** | Glulx interpreter (modern IF) | `glulxe` | 371 KiB | Text |
| **Jzip / Xzip** | Classic Z-code interpreters | `jzip`, `xzip` | 153/138 KiB | Text |
| **Gargoyle** | All-in-one graphical IF player (Z/Glulx/TADS/ADRIFT…) | `gargoyle-free` | 15.4 MiB | 2D fonts; heavier but convenient |
| **Zoom** | Z-code player, X11 | `zoom-player` | 695 KiB | Light X11 |
| **ScottFree** | Scott Adams adventures | `scottfree` | 50 KiB | Text |
| **dmagnetic** | Magnetic Scrolls games, *in ANSI art* | `dmagnetic` | 169 KiB | Text |
| **open-adventure** | Colossal Cave, 1995 430-point version | `open-adventure` | 202 KiB | Text |
| **INSTEAD** | Simple text-adventure / visual-novel engine (Russian scene) | `instead` | 591 KiB | 2D / text |
| **Ren'Py (The Question)** | A complete free Ren'Py game (demo of the engine) | `renpy-thequestion` | 10.1 MiB | 2D; playable |

## 3. Point-and-click adventures (ScummVM + freeware classics)

| Name | What it is | Package | Size | Why |
|---|---|---|---|---|
| **ScummVM** | Runs hundreds of 2D adventure engines (SCUMM, AGI, SCI…) | `scummvm` | 83.5 MiB | **Independently confirmed to work well on a 701**, incl. Monkey Island 3 and Grim Fandango. The engine interprets; it does not emulate a PC. |
| **Beneath a Steel Sky** | Cyberpunk classic, **freeware (Revolution released it)** | `beneath-a-steel-sky` | 71.2 MiB | ScummVM content, legally redistributed by Debian |
| **Flight of the Amazon Queen** | Comedy adventure, **freeware** | `flight-of-the-amazon-queen` | 52.9 MiB | ditto |
| **Lure of the Temptress** | Revolution's first, **freeware** | `lure-of-the-temptress` | 18.1 MiB | ditto |
| **Dráscula** | Comedy adventure, **released free** | `drascula` | 60.1 MiB | ditto |
| **FreeDink** | Dink Smallwood engine (the original data is free) | `freedink` | 73 KiB | Light 2D |

> These four freeware adventures are the *only* commercial-era game content Debian ships in
> `main` for this genre, and they ship it because the rights-holders freed it. That is exactly
> the standard this repo holds itself to. Note the sizes are large (tens of MiB each) — install
> the ones you want, not all four.

## 4. Card, board & abstract strategy

| Name | What it is | Package | Size | Why |
|---|---|---|---|---|
| **XMahjongg** | Mahjongg solitaire | `xmahjongg` | 627 KiB | Tiny 2D |
| **GNOME Mahjongg** | Polished Mahjongg | `gnome-mahjongg` | 4.6 MiB | GTK; fine |
| **GNU Backgammon** | Strong backgammon + analysis, **console & GUI** | `gnubg` | 2.9 MiB | Runs text or X |
| **GNU Go** | Go engine/board | `gnugo` | 8.5 MiB | Text or X |
| **GNU Chess + XBoard** | Chess engine + board | `gnuchess`, `xboard` | 796 KiB / 3.8 MiB | Very light |
| **eboard** | GTK chessboard | `eboard` | 2.3 MiB | GTK2 |
| **Fairymax** | xboard chess-variant engine | `fairymax` | 239 KiB | Tiny |
| **Pente / Reversi / Shogi** | Five-in-a-row, Othello, shogi | `pente`, `grhino`, `xshogi` | ~0.2–0.4 MiB | Tiny |
| **GTKboard** | Many board games in one | `gtkboard` | 1.2 MiB | GTK |
| **Filler / Dossizola / Xvier** | Abstract board games | `filler`, `dossizola`, `xchain` | small | Tiny 2D |
| **GtkAtlantic** | Monopoly-like | `gtkatlantic` | 468 KiB | GTK |
| **GtkPool** | Pool/billiards | `gtkpool` | 3.1 MiB | 2D |
| **3dchess / Xgammon** | Chess across 3 boards; backgammon | `3dchess`, `xgammon` | 107 KiB / 2.0 MiB | 2D-ish |
| **Ace of Penguins** | 12 games incl. solitaire, **text or X** | `ace-of-penguins` | 640 KiB | Tiny; excellent |
| **TTY Solitaire** | Klondike in the terminal | `tty-solitaire` | 45 KiB | Text |
| **KDE games** (optional) | `kpat` solitaire, `kshisen`, `kmines`, `kiriki`, `bovo`, `kajongg`, `kfourinline` | `kpat` etc. | 0.4–9 MiB | 2D but **pull in KDE libs**; install only if you want them |

## 5. Puzzles & logic

| Name | What it is | Package | Size | Why |
|---|---|---|---|---|
| **Simon Tatham's Portable Puzzle Collection** | ~40 polished puzzles in one binary | `sgt-puzzles` | 10.8 MiB | 2D; the single best puzzle value here |
| **Ace of Penguins** | (see above) | `ace-of-penguins` | 640 KiB | text/X |
| **2048** | The sliding-add puzzle, **text mode** | `2048` | 44 KiB | ncurses |
| **Enigma** | Marble/puzzle game (Oxyd clone) | `enigma` | 2.9 MiB | 2D |
| **Tetzle** | Jigsaw | `tetzle` | 1.1 MiB | 2D |
| **Tile World** | Chip's Challenge engine | `tworld` | 297 KiB | 2D |
| **Black Box** | Deduce the hidden atoms | `black-box` | 345 KiB | tiny 2D |
| **XDemineur** | Minesweeper | `xdemineur` | 70 KiB | tiny |
| **Xshisen / Xsok / Xye / Zaz / Wizznic / Berusky / Biniax-2 / Blockattack** | Shisen-sho, Sokoban, gem-collect, Puzznic clone, etc. | as named | 70 KiB–6.9 MiB | all tiny 2D |
| **Colorcode / PipeWalker / Hexalate** | Mastermind, pipe-connection, colour-match | as named | 121 KiB–1.2 MiB | tiny 2D |
| **XBubble** | Puzzle Bobble clone | `xbubble` | 2.9 MiB | 2D |
| **Sudoku (console) / Nudoku** | Sudoku in the terminal | `sudoku`, `nudoku` | 122/66 KiB | text |
| **Vitetris / Petris / Tint / Bastet** | Tetris variants, all text | `vitetris`, `petris`, `tint`, `bastet` | 57–220 KiB | ncurses; Bastet even plays *against* you |
| **NInvaders / Pacman4Console / Snake / Greed / Moon-Buggy** | terminal arcade classics | `ninvaders`, `pacman4console`, `nsnake`, `greed`, `moon-buggy` | 59–416 KiB | ncurses |
| **ASCIIJump** | Ski jumping, ASCII art | `asciijump` | 177 KiB | ncurses |
| **Robot Finds Kitten** | The loveliest non-game ever | `robotfindskitten` | 135 KiB | text |
| **GNOME casual set** | `gnome-mines`, `gnome-sudoku`, `quadrapassel`, `gnome-2048`, `lightsoff`, `gnome-tetravex` | as named | 0.7–5 MiB | GTK; light enough |

## 6. Arcade & action (native 2D and source ports)

| Name | What it is | Package | Size | Why it runs |
|---|---|---|---|---|
| **xgalaga++** | Galaga, single-screen vertical shooter | `xgalaga++` | 144 KiB | Extremely light; a 701 classic |
| **xgalaga** | Older Galaga | `xgalaga` | 808 KiB | light |
| **Chromium B.S.U.** | Scrolling space shooter | `chromium-bsu` | 425 KiB (+data 1.6 MiB) | 2D; fine |
| **Xonix / XSoldier / XBill / XEvil** | carve-the-field, shoot-'em-up, virus swatting, gore platformer | `xonix`, `xsoldier`, `xbill`, `xevil` | 91 KiB–2.4 MiB | tiny X11 2D |
| **BurgerSpace** | BurgerTime clone | `burgerspace` | 618 KiB | 2D |
| **LBreakout2** | Breakout with power-ups | `lbreakout2` | 855 KiB (+data 3.9 MiB) | 2D |
| **Jump 'n Bump** | Local multiplayer bunnies | `jumpnbump` | 698 KiB | tiny 2D |
| **Kobo Deluxe** | Space battle | `kobodeluxe` | 648 KiB | 2D |
| **Rock Dodger / Tumiki Fighters / Vectoroids** | vector/particle shooters | as named | 0.5–1.6 MiB | 2D |
| **Icebreaker / CriticalMass / Circus Linux / Ceferino / Penguin Command / SDL-Ball / LTris** | arcade & puzzle-arcade | as named | 111 KiB–1.3 MiB | tiny 2D |
| **Blob Wars / SuperTux / Xscavenger / Gnurobbo** | 2D platformers | `blobwars`, `supertux`, `xscavenger`, `gnurobbo` | 315 KiB–6.6 MiB | 2D; SuperTux is confirmed working on a 701 |
| **OpenTyrian** | Open-source port of DOS shoot-'em-up **Tyrian** | `opentyrian` (contrib) | 677 KiB | 2D; engine is GPL (data freeware) |

### Doom family — engines shipped, commercial WADs *not*

| Name | What it is | Package | Size | Why |
|---|---|---|---|---|
| **Chocolate Doom** | Bit-exact vanilla Doom engine | `chocolate-doom` | 4.2 MiB | Doom ran on a 486; **independently confirmed playable on a 701**. Bring `doom.wad`/`doom2.wad` (you own them) or use Freedoom |
| **DSDA-Doom** (was PrBoom+) | Higher-res Boom/MBF port; the `prboom-plus` name is now a dummy | `dsda-doom` | 3.1 MiB | Same engine family; runs |
| **Freedoom** | **Free** Doom-compatible game data (Phase 1 & 2) | `freedoom` | 56.0 MiB | BSD-style licensed content; installs with the engines |
| **Freedoom: FreeDM** | Free deathmatch WADs | `freedm` | 22.8 MiB | ditto |
| **doom-wad-shareware** | Doom **shareware episode 1** (`doom1.wad`) | `doom-wad-shareware` (**non-free**) | 4.1 MiB | Debian ships it in non-free *because id Software granted redistribution*: the package copyright file quotes John Carmack (1999): *"The DOOM shareware wad is freely distributable."* Safe to install on the user's own machine; **not** committed to this repo |

### Quake family — engine shipped, PAK *not*

| Name | What it is | Package | Size | Why |
|---|---|---|---|---|
| **QuakeSpasm** | Accurate software/OpenGL Quake engine | `quakespasm` | 1.4 MiB | Quake ran on a Pentium; with `-width 640 -height 480` and a modest `r_maxsurfs`, playable. Bring `pak0.pak` (commercial) |
| **Yamagi Quake II** | Quake II client | `yamagi-quake2` (contrib) | 1.6 MiB | Heavier than Quake but 2D-free rendering is light; expect to tune |
| **DarkPlaces** | Quake engine, prettier & heavier | `darkplaces` | 4.4 MiB | Only if you accept low res |

> **Doom/Quake data cannot go in the repo.** id Software has never freed the *registered* Doom
> WADs or the Quake PAKs; they are sold today (Steam, GOG, the official Doom re-releases). The
> repo ships engines + Freedoom (free), and the catalogue tells the user to supply their own
> commercial data. See the licensing assessment.

## 7. Emulation — what is actually viable

The honest split. **8-bit is fine; 16-bit and up is not.**

| Name | Emulates | Package | Size | Verdict on a 900 MHz 701 |
|---|---|---|---|---|
| **DOSBox** | x86/DOS PCs | `dosbox` | 2.8 MiB | **Good for 8086/286/early-386 DOS.** Set `cycles=1500`–`6000`; DOSBox's own table puts a ~1 GHz host at ≈ a **486/66**. Wolfenstein 3D/Commander Keen/prince-of-persia-class: yes. Protected-mode DOS4GW: no |
| **GNGb** | Game Boy / Color | `gngb` | 242 KiB | **Yes** — an LR35902 (4 MHz Z80-ish) is cheap to emulate |
| **FCEUX** | NES / Famicom | `fceux` | 5.0 MiB | **Yes** — a 1.79 MHz 6502 is cheap; this is the lightest good NES emulator here |
| **Nestopia** | NES (very accurate) | `nestopia` | 3.8 MiB | Yes, slightly heavier than FCEUX |
| **Stella** | Atari 2600 | `stella` | 8.3 MiB | **Yes** — 1.19 MHz 6507 |
| **Osmose** | Sega Master System / Game Gear | `osmose-emulator` | 722 KiB | **Probably yes** — Z80 @ 3.58 MHz; lighter than a Genesis |
| **Mednafen** | Multi-system (NES, GB/GBA, Lynx, PCE, …) | `mednafen` | 12.6 MiB | **Mixed** — set it to the 8-bit cores only; its SNES/PCE cores will crawl |
| **ZSNES** | SNES | `zsnes` | 5.5 MiB | **No** for real play. Snes9x's own readme asks for **800 MHz–1 GHz minimum**, more for Super-FX; this is the user's confirmed "no go" |
| **VisualBoyAdvance / mGBA** | Game Boy Advance | `visualboyadvance`, `mgba-sdl` | 1.2 MiB / 104 KiB | **No** — a 16.8 MHz ARM7 is too much here |
| **BlastEm** | Sega Genesis | `blastem` | 1.3 MiB | **No** — 68000 + Z80 + VDP |
| **Hatari / VICE** | Atari ST / Commodore 64 & 128 | `hatari`, `vice` | 20.1 MiB / 43.8 MiB | **C64/128 (VICE) is plausible** (6510 ≈ 1 MHz); Atari ST (68000) is not. Both are big installs — try VICE, skip Hatari |
| **atari800 / xtrs** | Atari 8-bit; TRS-80 | `atari800`, `xtrs` | 1.0 MiB / 1.0 MiB | **Yes** — 8-bit machines |

> **ROMs are never shipped.** Emulators are legal and packaged; the games are not. The
> catalogue points at the legal sources (homebrew, public-domain, and your own cartridges).

## 8. Strategy & simulation

| Name | What it is | Package | Size | Why |
|---|---|---|---|---|
| **Freeciv** | Civilization II-style; **client + server + data** | `freeciv-client-sdl` + `freeciv-data` (+`-server`) | 3.0 + 46.1 MiB | Turn-based; **confirmed working on a 701**, avoid huge maps |
| **OpenTTD** | Transport Tycoon Deluxe, free engine + free graphics | `openttd` + `openttd-opengfx` + `-opensfx` + `-openmsx` | 10.4 + 5.2 + 13.0 + 0.8 MiB | **Confirmed playable on a 701 once sound is muted** (graphics driver quirk) |
| **Micropolis** | The original SimCity (open-sourced) | `micropolis` + `micropolis-data` | 1.1 + 9.1 MiB | Light 2D |
| **LinCity / LinCity-NG** | City/country sim | `lincity`, `lincity-ng` | 1.6 MiB each | 2D |
| **Seven Kingdoms: Ancient Adversaries** | Classic RTS, open-sourced | `7kaa` | 2.1 MiB | 2D RTS; light |
| **Dopewars** | Drug-trading, **text or GTK** | `dopewars` | 444 KiB | Tiny |
| **XScorch** | Scorched Earth clone | `xscorch` | 697 KiB | 2D |
| **Empire** (vms-empire) | Classic war game | `empire` | 205 KiB | Text or X |
| **TEG** | Risk-like turn-based strategy | `teg` | 3.3 MiB | GTK2; light |
| **Crimson Fields** | Hex tactical wargame | `crimson` | 2.2 MiB | 2D |
| **Netrek (COW)** | The 1988 multiplayer game that invented the modern internet-play idiom | `netrek-client-cow` | 1.9 MiB | Light |
| **Bos Wars** | 2D RTS | `boswars` | 2.0 MiB | 2D |
| **Curse of War** | Fast ncurses strategy | `curseofwar` | 86 KiB | **text — perfect fit** |
| **Widelands / Battle for Wesnoth / Unknown Horizons / ASC** | Bigger free RTS/TBS | `widelands`, `wesnoth`, `unknown-horizons`, `asc` | 11.9 MiB–360 MiB | **Wesnoth confirmed "technically playable" but sluggish with UI issues on 800×480**; the others are heavy. Put these behind a "try it" wall |

---

## 9. Tools, toys & software (the "cool stuff" section)

### 9.1 Terminal toys & ASCII demos

| Name | What it is | Package | Size |
|---|---|---|---|
| **cmatrix** | The Matrix rain | `cmatrix` | 48 KiB |
| **cbonsai** | Grows an ASCII bonsai | `cbonsai` | 39 KiB |
| **cowsay / cowthink** | Talking cow | `cowsay` | 92 KiB |
| **figlet / toilet** | Big ASCII banners (toilet does colour) | `figlet`, `toilet` | 736 KiB / 53 KiB |
| **sl** | The train that punishes `sl` for `ls` | `sl` | 51 KiB |
| **fortune-mod + fortunes** | Cookies + data | `fortune-mod`, `fortunes` | 107 KiB / 2.6 MiB |
| **lolcat** | Rainbow cat | `lolcat` | 44 KiB |
| **nyancat** | Nyan cat, in a terminal | `nyancat` | 62 KiB |
| **pipes.sh** | Animated terminal pipes screensaver | `pipes-sh` | 21 KiB |
| **hollywood** | Fills the console with technobabble | `hollywood` | 2.4 MiB |
| **wallstreet** | Wall-Street-style ticker from real data | `wallstreet` | 42 KiB |
| **filters** | B1FF, Swedish Chef, ken, cockney… | `filters` | 443 KiB |
| **dadadodo** | "Exterminates all rational thought" | `dadadodo` | 61 KiB |
| **an / wordplay** | Anagram generators | `an`, `wordplay` | 34 / 259 KiB |
| **geekcode / polygen** | Geek Code generator; random-grammar sentences | `geekcode`, `polygen` | 180 / 604 KiB |
| **typespeed** | Falling-words typing game | `typespeed` | 221 KiB |
| **bucklespring** | **IBM-model-M keyboard sounds** as you type (needs ALSA; delightful) | `bucklespring` | 30 KiB |
| **bb** | AA-lib ASCII-art demo | `bb` | 1.8 MiB |
| **caca-utils / libcaca0 / aa3d / aview** | `img2txt`, ASCII stereograms, image/video→ASCII | as named | 34 KiB–903 KiB |
| **asciiquarium** | (not packaged — one-file Perl; see §10) | — | ~15 KB |

### 9.2 Desktop toys & gimmicks (X11)

`oneko` (cat chases the cursor), `xpenguins` (penguins walk on your windows),
`xteddy`, `xsnow`, `xfireworks`, `xfishtank` (root-window aquarium), `xmountains`,
`xphoon` (moon phase on your desktop), `xplanet` + `xplanet-images` (render the solar system
with real imagery), `xaos` (interactive fractal zoomer), `xdesktopwaves` (water on the desktop),
`xcowsay`, `animals`, `macopix`, `ninix-aya`, `kawari8` (anime desktop mascots / Ukagaka ghosts),
`floatbg`, `xflip`. All are **tiny** (21 KiB–2 MiB) and 2D.

### 9.3 Screensavers

`xscreensaver` + `xscreensaver-data` + `xscreensaver-data-extra` (`~11 MiB` incl. deps) gives the
classic 1990s–2000s screensaver collection (BSOD, GLSlideshow-lite, etc.). **Skip
`xscreensaver-gl`** (23 MiB) — it is OpenGL and the 915GM will disappoint. Lock now with
`xscreensaver-command -lock`.

### 9.4 Files, browsers, editors, mail, terminal

| Name | What it is | Package | Size |
|---|---|---|---|
| **Midnight Commander** | The classic two-pane file manager | `mc` | 1.7 MiB |
| **ranger / nnn / vifm** | Modern terminal file managers | `ranger`, `nnn`, `vifm` | 173 KiB–1.2 MiB |
| **w3m / elinks / lynx / links2** | Text browsers (w3m does inline images in a framebuffer term) | as named | 1.7–4.9 MiB |
| **irssi / weechat-curses / epic5 / ii / tintin++** | IRC and MUD clients | as named | 46 KiB–7.3 MiB |
| **inetutils-telnet / c3270 / minicom** | telnet/BBS-ish, IBM mainframe, serial | as named | 260 KiB–1.2 MiB |
| **vim / ne / joe / jed / mg / nano / micro** | Editors (micro is a modern, friendly one) | as named | 133 KiB–11.6 MiB |
| **hexcurse / bless / xxd / ht** | Hex editors / binary viewer | as named | 78 KiB–1.9 MiB |
| **Emacs (nox)** | GNU Emacs, no GUI | `emacs-nox` | 38.3 MiB |
| **zim / dict + dictd + wordnet** | Offline wiki-notebook; offline dictionary | as named | 165 KiB–5.0 MiB |
| **claws-mail / sylpheed / mutt / alpine** | Light mail clients (a 701 test: Claws Mail recommended, *not* Thunderbird) | as named | 2.6–8.4 MiB |
| **tree / ncdu / jq / most / unzip / p7zip / atool** | Everyday CLI | as named | 74 KiB–6.0 MiB |
| **cool-retro-term** | CRT-phosphor terminal emulator | `cool-retro-term` | 2.0 MiB (+Qt) |
| **fbterm / fbi / fim** | Framebuffer terminal + image viewer | as named | 152 KiB–1.1 MiB |

### 9.5 Music, synths & trackers (the Eee has *good speakers*)

| Name | What it is | Package | Size |
|---|---|---|---|
| **Schism Tracker** | Impulse Tracker clone — compose MODs | `schism` | 1.0 MiB |
| **MilkyTracker** | FastTracker II-inspired tracker | `milkytracker` | 3.0 MiB |
| **MikMod** | Tracked-music player | `mikmod` | 218 KiB |
| **SoX** | The Swiss-army knife of audio (the 701 test's only sane audio tool) | `sox` | 210 KiB |
| **Timidity / FluidSynth** | MIDI renderers | `timidity`, `fluidsynth` | 1.6 MiB / 109 KiB |
| **Pure Data** | Realtime music/graphics patching | `puredata` | 27 KiB (+docs) |
| **eSpeak / eSpeak-ng / flite** | Small speech synthesizers (fun to *make* the 701 talk) | as named | 213 KiB–3.8 MiB |
| **cmus / moc / mpg123 / mplayer** | Console music & video (mplayer for 480p) | as named | 542 KiB–4.8 MiB |
| **cava** | Console audio visualizer | `cava` | 162 KiB |
| **lame** | MP3 encoding | `lame` | 360 KiB |

### 9.6 Programming & tools

| Name | What it is | Package | Size |
|---|---|---|---|
| **TCC** | Tiny C compiler (compiles in seconds here) | `tcc` | 534 KiB |
| **PCC** | Portable C compiler | `pcc` | 1.1 MiB |
| **NASM / YASM** | Assemblers (write 16-bit DOS code!) | `nasm`, `yasm` | 2.5 / 1.9 MiB |
| **Gforth / Guile / Lua / Python 3** | Interpreters, all fine | `gforth`, `guile-3.0`, `lua5.4`, `python3` | 45 KiB–584 KiB |
| **Python + Tk + pygame + PIL** | Make small games/graphics | `python3-tk`, `python3-pygame`, `python3-pil` | 455 KiB–4.0 MiB |
| **make / gdb / git / sqlite3** | Everyday dev | as named | 580 KiB–50.7 MiB |
| **gcc / g++ / clang / SBCL / Chicken** | Heavier toolchains | as named | tens of MiB |

> The 701 test: **programming is not a challenge** — `nextvi` and `neatroff` compile in ~30–40 s.
> Big things (DOSBox 18.5 min, ScummVM 13.5 *hours*) are the exceptions.

### 9.7 Retro computing & vintage emulation

`dosbox` (DOS), `mtools` (read/write DOS floppy images), `bochs` (full IA-32 PC emulator — slow
but usable for very old OSes), `atari800`, `xtrs`, `basilisk2` (68k Mac), and — heavier —
`hatari` (Atari ST), `vice` (C64/128). SIMH-class retro is a build-it-yourself affair.

---

## 10. Modern lightweight software that still runs (2015→now)

| Name | What it is | Availability | Size | Why |
|---|---|---|---|---|
| **ClassiCube** | Minecraft-Classic-compatible client, **written in C** | **Not in Debian.** Official 32-bit Linux build from `cdn.classicube.net/client/release/nix32/ClassiCube.tar.gz` (v1.3.8, ~1.2 MB download). License: **modified BSD (3-clause)**, verified from `license.txt`; the archive ships `audio/` and `texpacks/` which are *not* covered by that license — supply your own assets or use the client's built-in ones | ~1.8 MB unpacked | **Independently confirmed ~20–30 FPS on a 701.** Needs `libcurl4`, `libopenal1` (already present). This is the headline "modern game that runs" |
| **Minetest / Luanti** | Free voxel sandbox in C++ | `minetest` | 10.8 MiB | 2D-ish block rendering; expect low view distance and low FPS — **try it**, but ClassiCube is the safer bet |
| **Simon Tatham's Puzzles** | Modern (~2004→) yet featherweight | `sgt-puzzles` | 10.8 MiB | Thousands of puzzles |
| **OpenTyrian, Schism, MilkyTracker, cmus, ranger, nnn, cb0nsai…** | All actively developed today | packaged | tiny | The modern terminal-tool ecosystem *is* a retro toy |

---

## 11. Legal acquisition paths for everything **not** in the repo

The repo ships **packages only** (engines, free data). For everything else the user runs a
script or follows a documented path. These are the sources that are *actually* legally
redistributable — checked, not assumed.

| Source | What it legally is | How to use it | What to avoid |
|---|---|---|---|
| **Debian packages** (this repo's mechanism) | Signed, licensed for Debian distribution | `sudo eeepc-games --install …` | — |
| **Freedoom** (in Debian) | Free Doom-compatible game data, **BSD-style** | `apt install freedoom` | — |
| **Doom shareware WAD** (Debian `doom-wad-shareware`, non-free) | id granted redistribution (Carmack, 1999) | `apt install doom-wad-shareware` | Do **not** upload `doom1.wad` to a public repo you control; Debian already redistributes it lawfully |
| **Your own Doom/Quake data** | Commercial — you own a licence | Copy `doom.wad` / `pak0.pak` from your own copy into `~/.local/share/games/` | Never commit it |
| **RGB Classic Games** (`classicdosgames.com`) | Explicitly categorises **shareware / freeware / public-domain ("abandonware" = copyright officially abandoned)**; hosts only those | Download individual games; run under DOSBox | The site's *red*-marked titles are the only true public-domain ones — check the colour key per game |
| **DOS Games Archive** (`dosgamesarchive.com`) | "Not an abandonware site"; **shareware, freeware, playable demos, and full versions released as freeware or into the public domain** | Download + DOSBox | Nothing commercial |
| **DOSGames.com / DOS Games Archive / dosgames.com** | Same policy: shareware/freeware/demos/public domain | Download + DOSBox | — |
| **Internet Archive — `The [Shareware] DOS Collection`** | All **shareware** games from The DOS Collection, 1981–1992 | Download + DOSBox; it is *shareware*, so it is redistributable as shareware (keep the notices) | — |
| **Internet Archive — MS-DOS Games / Software Library** | Mixed. The Archive has a **DMCA exemption for preservation** and complies with takedowns, but its own **Rights page states it cannot guarantee copyright status** of items | Browse/play freely; treat as *use*, not *redistribution* | Do **not** bulk-copy these into a repo or redistribution channel |
| **eXoDOS / Total DOS Collection** | **Not legally redistributable.** Predominantly commercial games still under copyright, many still sold; a preservation community member's own words: *"eXo is an openly piracy project."* eXoDOS's own note: many titles remain on sale | Fine to *run locally* if you choose; **never** to relabel as free or to vend | Do not bundle, mirror, or cite as a "legal" source. Named here only so the distinction is explicit |
| **itch.io `free` + `MS-DOS` / `opensource` tags** | Per-game; many are genuinely free / open-source homebrew | Download per licence on each game page | Read each page's licence |
| **IF Archive** (`ifarchive.org`) | Most hosted IF is freeware with explicit permission or open licences | Download story files for `frotz`/`glulxe` | — |

---

## 12. Deliberately excluded (and why)

* **ROMs of any kind** (NES/SNES/GB/Mega Drive/PS1/…). Emulators are legal; ROMs are not
  unless they are homebrew/public-domain. Never shipped; the catalogue points at legal sources.
* **Registered Doom/Quake/Doom II/Quake II commercial data.** Still sold; not free.
* **eXoDOS / Total DOS Collection content.** Copyrighted commercial games. Documented above as
  a *non*-source.
* **MAME + ROM sets** (`mame`, 325 MiB + ROMs). ROMs dominate; the full set is huge and the
  legal ROMs (homebrew) are a tiny niche. Offer only if asked.
* **3D games** (`openarena`, `nexuiz`, `sauerbraten`, `0ad`, `supertuxkart`, `warzone2100`,
  `pink-pony`, `openclonk`, `xmoto`, `hedgewars`). 915GM has no usable 3D. Hedgewars runs but its
  dependencies are heavy; Xmoto runs but does not fit 800×480.
* **GNOME/KDE metapackages**, LibreOffice, GIMP, Audacity, Thunderbird, Steam, Java Minecraft —
  CPU/driver/RAM. (A 701 test found even Audacity unusable: WebKitGTK-based UI.)
* **`xscreensaver-gl`** (OpenGL), **`hatari`/`blastem`/`visualboyadvance`/`zsnes`** — see §7.

---

## 13. Install cheat-sheet by mood

```bash
# An evening of text games in 8 MiB
sudo eeepc-games --install core

# The classics: Doom, Quake engines, ScummVM adventures, chess, mahjongg
sudo eeepc-games --install doom,quake,adventure,board,puzzle

# The "what can this thing actually emulate?" experiment (8-bit only)
sudo eeepc-games --install emulation

# Show it off: trackers, toys, screensavers, mascots
sudo eeepc-games --install music,toys,screensaver

# Make it a tiny dev machine
sudo eeepc-games --install programming,tools

# Retro-computing playground
sudo eeepc-games --install retro
```

Sizes are what `apt` reports; **nothing downloads until you confirm**. Re-running any command is
safe (idempotent). Offline: stage `.deb` files and use `--offline DIR`.

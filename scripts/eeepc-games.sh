#!/bin/bash
# eeepc-games.sh — curated games, tools & toys for the ASUS Eee PC 701 (deeebian).
#
# Runs ON the device (or from a chroot). Installs a hand-curated selection of
# Debian bookworm packages that are actually usable on a 900 MHz single-core
# Celeron M with Intel 915GM graphics, no usable 3D, an 800x480 panel and 2 GB
# of RAM sharing with the GPU.
#
# Design rules (why it looks like this):
#   * PACKAGES FIRST.  A Debian package is a one-line, signed, dependency-solved
#     install.  Anything in bookworm is preferred over a tarball.  See
#     docs/games-and-software.md for the full catalogue and the performance
#     reasoning behind every entry.
#   * NO COPYRIGHTED GAME DATA.  This script installs engines and free content
#     only.  Doom/Quake WADs/PAKs are the user's to supply (see "doom"/"quake"
#     categories — engine + Freedoom, not commercial data).  The one non-free
#     package offered (doom-wad-shareware) is the id-licensed shareware episode,
#     which Debian ships in non-free precisely because id granted
#     redistribution (verified in the package copyright file).
#   * IDEMPOTENT.  Re-running is safe: only missing packages are requested, apt
#     itself is idempotent, and every generated file is rewritten from scratch.
#   * DEGRADES GRACEFULLY.  No root -> it explains sudo and exits.  No network
#     -> it offers the offline .deb path instead of failing.  Missing optional
#     tools it would like (update-desktop-database, ...) are skipped, not fatal.
#   * DISCOVERABLE.  Installs a .desktop launcher and an Openbox *pipe menu*
#     ("Games & software") so new games show up in the desktop menu without
#     anyone hand-editing menu.xml.  See --openbox-pipe.
#
# Usage:
#   eeepc-games                     interactive category menu
#   eeepc-games --list              list categories + sizes (no install)
#   eeepc-games --list-all          list every category with its packages
#   eeepc-games --install CAT[,CAT] install one or more categories
#   eeepc-games --install core      install the small, safe starting set
#   eeepc-games --everything        install every category (big; ~1.5 GB)
#   eeepc-games --offline DIR       install from a directory of .deb files
#   eeepc-games --search TERM       grep the catalogue
#   eeepc-games --openbox-pipe      print Openbox pipe-menu XML (used by menu.xml)
#   eeepc-games --desktop           (re)install launchers only, no apt
#   eeepc-games --dry-run           with --install: show what apt would do
#   eeepc-games -y                  don't ask for confirmation
#
# Exit codes: 0 ok, 1 usage error, 2 needs root, 3 apt/network failure.
set -u

# Guarantee a sane PATH regardless of who calls us.  Openbox root-menu / pipe
# menus and `sh -c` from a login-less session inherit a minimal PATH that does
# NOT include /usr/games (where bsdgames et al. live) — so the "is it installed"
# probes below would wrongly report games as missing.  Pin it.
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games${PATH:+:$PATH}"
export PATH

PIPEMENU_DIR=/usr/local/share/applications
OFFLINE_DIR="${EEEPC_GAMES_OFFLINE:-/opt/eeepc-games/debs}"
LOG=/var/log/eeepc-games.log
STATE=/var/lib/eeepc-games/installed

DRY_RUN=0
ASSUME_YES=0

# ---------------------------------------------------------------------------
# Catalogue.  One line per category:  key|label|group|packages
#   key    short id used on the command line
#   label  human label for the menu
#   group  section heading in the menu
#   pkgs   space-separated Debian bookworm package names (all verified to
#          exist for i386 — see docs/games-and-software.md)
# ---------------------------------------------------------------------------
CATALOGUE='
core|Small starting set (text + a few classics)|Start here|nethack-console bsdgames 2048 moon-buggy vitetris ninvaders bastet asciijump robotfindskitten nudoku tty-solitaire petris sudoku nsnake pacman4console greed tint tetrinet-client bombardier curseofwar cmatrix cbonsai cowsay sl fortune-mod
roguelike|Roguelikes|Games|angband crawl slashem moria omega-rpg boohu gearhead nethack-x11
roguelike-heavy|Bigger roguelikes (Cataclysm-DDA, LambdaHack, HyperRogue)|Games|cataclysm-dda-sdl lambdahack allure hyperrogue meritous
if|Interactive fiction / text adventures|Games|frotz jzip glulxe fizmo-console fizmo-ncursesw scottfree dmagnetic open-adventure instead zoom-player gargoyle-free
adventure|ScummVM + freeware point-and-click classics|Games|scummvm beneath-a-steel-sky flight-of-the-amazon-queen lure-of-the-temptress drascula freedink
puzzle|Puzzles|Games|ace-of-penguins sgt-puzzles tetzle enigma tworld black-box xdemineur xshisen xsok xye zaz berusky biniax2 blockattack wizznic colorcode pipewalker hexalate xpat2 xbubble
board|Board & card games|Games|xmahjongg gtkboard gtkatlantic gnubg gnugo gnuchess xboard eboard fairymax grhino pente xshogi 3dchess dossizola filler gtkpool
arcade|Arcade / action|Games|xgalaga++ xonix xsoldier xbill xevil burgerspace lbreakout2 jumpnbump kobodeluxe rockdodger tumiki-fighters vectoroids chromium-bsu criticalmass icebreaker sdl-ball ltris penguin-command ceferino circuslinux blobwars supertux xscavenger opentyrian gnurobbo
doom|Doom engines + Freedoom (bring your own WADs)|Games|chocolate-doom dsda-doom freedoom freedm
shareware|Doom shareware episode (id-licensed, Debian non-free)|Games|doom-wad-shareware
quake|Quake engines (bring your own PAK)|Games|quakespasm yamagi-quake2 darkplaces
emulation|Emulators that actually run (NES, GB, Atari, DOS)|Games|dosbox gngb fceux nestopia stella osmose-emulator
emulation-heavy|Heavier emulators (Mednafen, ZSNES) — try, expect slowdown|Games|mednafen zsnes
strategy|Strategy & simulation|Games|freeciv-client-sdl freeciv-data openttd openttd-opengfx openttd-opensfx openttd-openmsx micropolis micropolis-data lincity 7kaa dopewars xscorch empire teg crimson netrek-client-cow boswars
strategy-heavy|Bigger strategy (Widelands, Wesnoth, Unknown Horizons)|Games|widelands wesnoth unknown-horizons asc
toys|Terminal toys & desktop gimmicks|Toys & tools|cmatrix cbonsai cowsay figlet toilet sl fortune-mod fortunes lolcat nyancat pipes-sh hollywood wallstreet filters dadadodo an wordplay geekcode polygen typespeed oneko xpenguins xteddy xsnow xfireworks xfishtank xmountains xphoon xplanet xplanet-images xaos xdesktopwaves xcowsay animals bucklespring bb libcaca0 caca-utils aa3d aview
screensaver|Screensavers|Toys & tools|xscreensaver xscreensaver-data xscreensaver-data-extra
tools|Files, browsers, mail, editors, hex|Toys & tools|mc ranger nnn vifm w3m elinks lynx links2 irssi weechat-curses epic5 ii tintin++ inetutils-telnet c3270 minicom tree ncdu jq most file unzip p7zip-full atool vim ne joe jed mg nano micro hexcurse bless xxd zim dict dictd wordnet hexchat claws-mail
tools-heavy|Bigger editors/desktop tools (Emacs, Thunar-ish)|Toys & tools|emacs-nox
music|Music, synths & trackers|Toys & tools|sox mikmod timidity fluidsynth schism milkytracker puredata espeak espeak-ng flite cmus moc mpg123 mplayer cava lame
programming|Programming languages & tooling|Toys & tools|tcc pcc nasm gforth guile-3.0 lua5.4 python3 python3-tk python3-pygame python3-pil make gdb git sqlite3
programming-heavy|Bigger toolchains (gcc, clang, SBCL, NumPy)|Toys & tools|gcc g++ clang sbcl chicken-bin python3-numpy
retro|Retro computing (DOS/Atari/mtools/bochs)|Toys & tools|dosbox mtools bochs atari800 xtrs basilisk2
retro-heavy|Bigger vintage emulators (Atari ST, C64)|Toys & tools|hatari vice
'

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------
say()  { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }

have()  { command -v "$1" >/dev/null 2>&1; }
is_root() { [ "$(id -u)" = "0" ]; }

cat_field() { # key field(1..4)
  printf '%s\n' "$CATALOGUE" | awk -F'|' -v k="$1" -v f="$2" '
    $1==k { print $f; exit }'
}
cat_keys() { printf '%s\n' "$CATALOGUE" | awk -F'|' 'NF>=4{print $1}'; }

# Expand a category key to its package list; supports comma/comma-space lists.
expand_pkgs() {
  local out="" k
  for k in $(printf '%s' "$1" | tr ',' ' '); do
    [ -z "$k" ] && continue
    local line
    line=$(cat_field "$k" 4)
    if [ -z "$line" ]; then
      warn "eeepc-games: unknown category '$k' (try --list)"
      return 1
    fi
    out="$out $line"
  done
  # de-duplicate, preserve order
  printf '%s\n' $out | awk '!seen[$0]++' | tr '\n' ' '
}

pkg_installed() { # pkg -> 0 if installed & configured
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'
}

missing_pkgs() { # pkgs -> prints those not installed
  local p
  for p in $1; do pkg_installed "$p" || printf '%s ' "$p"; done
}

# Estimate the download/disk cost and whether anything is actually needed.
# Uses a local `apt-get --simulate` so it is correct and works with cached
# indexes; never touches the network.
estimate() { # pkgs
  local pkgs="$1"
  if [ -z "$(missing_pkgs "$pkgs")" ]; then
    say "  (all packages already installed — nothing to do)"
    return 0
  fi
  local out
  if out=$(apt-get -s -y install $pkgs 2>/dev/null); then
    local dl inst
    dl=$(printf '%s\n' "$out"   | sed -n 's/^Need to get \(.*\)\.$/\1/p' | tail -1)
    inst=$(printf '%s\n' "$out" | sed -n 's/^After this operation, \(.*\) of additional disk space will be used.*/\1/p' | tail -1)
    [ -n "$inst" ] && say "  estimated additional disk use: $inst"
    [ -n "$dl" ]   && say "  estimated download:           $dl"
  else
    say "  (could not simulate — apt index may be missing; run 'sudo apt update')"
  fi
}

do_update_desktop() {
  if have update-desktop-database; then
    update-desktop-database "$PIPEMENU_DIR" >/dev/null 2>&1 || true
  fi
}

# ---------------------------------------------------------------------------
# Launchers / discoverability
# ---------------------------------------------------------------------------
# Write .desktop files for installed GUI games so they appear in any XDG menu,
# the tint2 launcher and pcmanfm.  Only for apps that are actually present.
write_desktop_files() {
  install -d -m 0755 "$PIPEMENU_DIR"
  local made=0
  # name|Exec|Icon|Categories|Terminal
  local entries='
NetHack|nethack-console|nethack|Game;RolePlaying;|true
Dungeon Crawl Stone Soup|crawl|dcss|Game;RolePlaying;|true
Angband|angband|angband|Game;RolePlaying;|true
Doom (Chocolate)|chocolate-doom|doom|Game;ActionGame;|false
Doom (DSDA/prboom)|dsda-doom -iwad /usr/share/games/doom/freedoom1.wad|doom|Game;ActionGame;|false
Quake|quakespasm|quake|Game;ActionGame;|false
DOSBox|dosbox|dosbox|Game;Emulator;|false
FCEUX (NES)|fceux|fceux|Game;Emulator;|false
GNGb (Game Boy)|gngb|gngb|Game;Emulator;|false
Stella (Atari 2600)|stella|stella|Game;Emulator;|false
Freeciv|freeciv-client-sdl|freeciv|Game;StrategyGame;|false
OpenTTD|openttd|openttd|Game;StrategyGame;|false
GNOME Chess board (XBoard)|xboard|xboard|Game;BoardGame;|false
GNU Go|gnugo|gnugo|Game;BoardGame;|true
GNU Backgammon|gnubg|gnubg|Game;BoardGame;|false
ScummVM|scummvm|scummvm|Game;AdventureGame;|false
Midnight Commander|mc|mc|Utility;FileManager;|true
Ranger|ranger|ranger|Utility;FileManager;|true
'
  local IFS=$'\n'
  local line name exec_cmd icon cats term
  for line in $entries; do
    [ -z "$line" ] && continue
    IFS='|' read -r name exec_cmd icon cats term <<EOF
$line
EOF
    # only emit if the *binary* (first word of Exec) exists
    local bin="${exec_cmd%% *}"
    have "$bin" || continue
    cat > "$PIPEMENU_DIR/eeepc-$(printf '%s' "$name" | tr 'A-Z ' 'a-z-').desktop" <<DESK
[Desktop Entry]
Type=Application
Version=1.0
Name=$name
Comment=Installed by eeepc-games for the Eee PC 701
Exec=$exec_cmd
Icon=$icon
Terminal=$term
Categories=$cats
DESK
    made=$((made+1))
  done
  unset IFS
  say "  wrote $made launcher(s) to $PIPEMENU_DIR"
  do_update_desktop
}

# Openbox pipe menu: printed on demand, lists what is actually installed.
# This is the "discoverable, not just runnable from a terminal" mechanism.
openbox_pipe() {
  local IFS=$'\n' line name exec_cmd
  say '<openbox_pipe_menu>'
  say '  <item label="Games &amp; software (install more)">'
  say '    <action name="Execute"><execute>lxterminal -e /usr/local/bin/eeepc-games</execute></action>'
  say '  </item>'
  say '  <separator/>'

  local entries='
NetHack|nethack-console
Dungeon Crawl Stone Soup|crawl
Angband|angband
SLASHEM (NetHack variant)|slashem
Doom (Freedoom)|chocolate-doom -iwad /usr/share/games/doom/freedoom1.wad
Quake|quakespasm
DOSBox|dosbox
FCEUX (NES)|fceux
GNGb (Game Boy)|gngb
Stella (Atari 2600)|stella
Freeciv|freeciv-client-sdl
OpenTTD|openttd
ScummVM|scummvm
XBoard (chess)|xboard
GNU Backgammon|gnubg
xgalaga++|xgalaga++
Chromium B.S.U.|chromium-bsu
LBreakout2|lbreakout2
GNOME Mahjongg|gnome-mahjongg
Simon Tatham puzzles|sgt-puzzles
XMinesweeper|xdemineur
Screensaver (lock now)|xscreensaver-command -lock
'
  for line in $entries; do
    [ -z "$line" ] && continue
    name="${line%%|*}"; exec_cmd="${line#*|}"
    have "${exec_cmd%% *}" || continue
    say "  <item label=\"$(printf '%s' "$name" | sed 's/&/\&amp;/g')\"><action name=\"Execute\"><execute>$(printf '%s' "$exec_cmd" | sed 's/&/\&amp;/g')</execute></action></item>"
  done
  say '  <separator/>'
  say '  <item label="Terminal"><action name="Execute"><execute>lxterminal</execute></action></item>'
  say '</openbox_pipe_menu>'
}

# ---------------------------------------------------------------------------
# Installation
# ---------------------------------------------------------------------------
apt_available() {
  have apt-get || { warn "eeepc-games: apt-get not found — this image is not Debian-based?"; return 1; }
  return 0
}

network_ok() {
  # Cheap liveness probe; never blocks for long.
  if have getent; then getent hosts deb.debian.org >/dev/null 2>&1 && return 0; fi
  return 1
}

# Offline path: install from a directory of .deb files.  Packages listed in the
# category that are not present as .debs are reported and skipped, so a partial
# offline set still installs what it can.
install_from_offline() {
  local dir="$1" pkgs="$2"
  if [ ! -d "$dir" ]; then
    warn "eeepc-games: offline dir '$dir' does not exist"
    return 1
  fi
  local debs
  debs=$(find "$dir" -maxdepth 1 -name '*.deb' 2>/dev/null)
  if [ -z "$debs" ]; then
    warn "eeepc-games: no .deb files in $dir"
    return 1
  fi
  install -d -m 0755 /var/cache/apt/archives 2>/dev/null || true
  if ! cp -f "$dir"/*.deb /var/cache/apt/archives/ 2>/dev/null; then
    warn "  could not copy .deb files into /var/cache/apt/archives (need root?)"
    return 1
  fi
  say "  copied $(printf '%s\n' $debs | wc -l | tr -d ' ') .deb file(s) into /var/cache/apt/archives"
  # --no-download: fail rather than silently reaching the network, so the user
  # knows exactly which packages the offline set was missing.
  if apt-get install -y --no-download $pkgs; then
    say "  offline install OK"
  else
    warn "  offline install incomplete — some packages were not in $dir."
    warn "  On a connected machine, stage them with:"
    warn "    sudo apt-get install --download-only -o Dir::Cache::archives=$dir <packages>"
    return 1
  fi
  return 0
}

install_categories() {
  local keys="$1"
  local pkgs
  pkgs=$(expand_pkgs "$keys") || return 1
  if [ -z "$(printf '%s' "$pkgs" | tr -d ' ')" ]; then
    warn "eeepc-games: nothing to install"; return 1
  fi

  say "Selected: $keys"
  say "Packages: $pkgs"
  say ""

  # Dry run needs neither root nor the network — show the plan and stop.
  if [ "$DRY_RUN" = "1" ]; then
    apt_available || { say "  (apt-get not present; cannot estimate)"; }
    estimate "$pkgs"
    say ""
    say "== dry run: the command that would run =="
    say "  apt-get install -y --no-install-recommends $pkgs"
    return 0
  fi

  # Everything past here actually changes the system, so it needs root.
  if ! is_root; then
    warn "eeepc-games: installing needs root.  Re-run with:  sudo eeepc-games --install $keys"
    return 2
  fi

  # Offline first if the user pointed us at a cache that has files.
  if [ -n "${OFFLINE_DIR:-}" ] && [ -d "$OFFLINE_DIR" ] && \
     [ -n "$(find "$OFFLINE_DIR" -maxdepth 1 -name '*.deb' 2>/dev/null | head -1)" ]; then
    say "== offline mode: using $OFFLINE_DIR =="
    install_from_offline "$OFFLINE_DIR" "$pkgs" || true
    write_desktop_files
    return 0
  fi

  apt_available || return 3
  estimate "$pkgs"

  if [ "$ASSUME_YES" != "1" ]; then
    printf 'Proceed with the install? [y/N] '
    read -r ans </dev/tty 2>/dev/null || ans=n
    case "$ans" in y|Y|yes|YES) ;; *) say "cancelled."; return 0 ;; esac
  fi

  # Refresh indexes only if we have no cached ones, and only when the network
  # is up — otherwise go straight to install and let apt report the problem.
  if ! ls /var/lib/apt/lists/*Packages* >/dev/null 2>&1; then
    say "== apt update (first run) =="
    if ! apt-get update; then
      warn "eeepc-games: 'apt update' failed."
      warn "  If you have no network, stage .debs and run:"
      warn "    sudo eeepc-games --offline /path/to/debs --install $keys"
      return 3
    fi
  fi

  say "== installing =="
  if ! apt-get install -y --no-install-recommends $pkgs; then
    warn "eeepc-games: apt install failed."
    if ! network_ok; then
      warn "  Looks like there is no network.  Offline path:"
      warn "    sudo eeepc-games --offline $OFFLINE_DIR --install $keys"
    fi
    return 3
  fi

  # Record what we touched (informational; the catalogue in docs/ is canonical).
  install -d -m 0755 "$(dirname "$STATE")"
  { date -u '+%Y-%m-%dT%H:%M:%SZ'; printf '%s\n' $pkgs; } >> "$STATE" 2>/dev/null || true

  write_desktop_files
  say ""
  say "Done.  Games appear under 'Games & software' in the Openbox root menu"
  say "(right-click the desktop) and in the tint2 launcher."
  say "Log: $LOG   State: $STATE"
}

# ---------------------------------------------------------------------------
# Informational output
# ---------------------------------------------------------------------------
list_categories() {
  printf '%-18s %-46s %s\n' "KEY" "WHAT" "PACKAGES"
  printf '%s\n' "$CATALOGUE" | awk -F'|' 'NF>=4 && $1!="" {
    n=split($4,a," ");
    printf "%-18s %-46s %d\n", $1, $2, n
  }'
  say ""
  say "Run 'eeepc-games --list-all' for the package lists, or just 'eeepc-games'."
}

list_all() {
  printf '%s\n' "$CATALOGUE" | awk -F'|' 'NF>=4 && $1!="" {
    printf "\n[%s] %s\n  %s\n", $1, $2, $4
  }'
}

search_catalogue() {
  local term="$1"
  printf '%s\n' "$CATALOGUE" | awk -F'|' -v t="$term" 'NF>=4 && $1!="" &&
    (index($1,t)||index($2,t)||index($4,t)) { printf "[%s] %s\n  %s\n", $1,$2,$4 }'
}

do_desktop_only() {
  if ! is_root; then
    warn "eeepc-games: writing launchers needs root:  sudo eeepc-games --desktop"
    return 2
  fi
  write_desktop_files
}

# ---------------------------------------------------------------------------
# Interactive menu
# ---------------------------------------------------------------------------
menu() {
  while true; do
    clear 2>/dev/null || true
    say "============================================================"
    say " deeebian games, tools & toys  —  Eee PC 701"
    say "============================================================"
    say " Packages that run on a 900 MHz Celeron M, 2D graphics only."
    say " Sizes are what apt reports; nothing is downloaded until you pick."
    say "------------------------------------------------------------"
    local keys; keys=$(cat_keys)
    local i=1 key label
    local -a K=()
    local lastgroup=""
    for key in $keys; do
      label=$(cat_field "$key" 2)
      local group; group=$(cat_field "$key" 3)
      if [ "$group" != "$lastgroup" ]; then
        say ""
        say "  -- $group --"
        lastgroup="$group"
      fi
      printf '  %2d) %-52s [%s]\n' "$i" "$label" "$key"
      K+=("$key")
      i=$((i+1))
    done
    say ""
    say "  a) install the small starting set (core)"
    say "  d) dry run: show what would be installed"
    say "  q) quit"
    say ""
    printf 'Pick a number, or a comma list (e.g. 4,5,9): '
    local sel
    read -r sel </dev/tty 2>/dev/null || { say ""; return 0; }
    case "$sel" in
      q|Q|'') return 0 ;;
      a|A) install_categories core; _pause ;;
      d|D) DRY_RUN=1; install_categories core; DRY_RUN=0; _pause ;;
      *)
        local idx keysel="" bad=0
        for idx in $(printf '%s' "$sel" | tr ',' ' '); do
          case "$idx" in
            ''|*[!0-9]*) bad=1; continue ;;
          esac
          if [ "$idx" -ge 1 ] && [ "$idx" -le "${#K[@]}" ]; then
            keysel="$keysel ${K[$((idx-1))]}"
          else
            bad=1
          fi
        done
        if [ "$bad" = "1" ] || [ -z "$keysel" ]; then
          warn "Invalid selection."; sleep 1; continue
        fi
        install_categories "$(printf '%s' "$keysel" | tr -s ' ' ',')"
        _pause
        ;;
    esac
  done
}

_pause() { printf '\nPress Enter to return to the menu... '; read -r _ </dev/tty 2>/dev/null || true; }

usage() {
  sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
ACTION=""
INSTALL_KEYS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --list)        ACTION=list ;;
    --list-all)    ACTION=list_all ;;
    --openbox-pipe) ACTION=pipe ;;
    --desktop)     ACTION=desktop ;;
    --everything)  ACTION=install; INSTALL_KEYS="$(printf '%s' "$(cat_keys)" | tr '\n' ' ' | tr ' ' ',')" ;;
    --dry-run)     DRY_RUN=1 ;;
    -y|--yes)      ASSUME_YES=1 ;;
    --search)      shift; ACTION=search; SEARCH_TERM="${1:-}" ;;
    --offline)     shift; OFFLINE_DIR="${1:-}" ;;
    --install)     shift; ACTION=install; INSTALL_KEYS="${1:-}" ;;
    -h|--help)     usage; exit 0 ;;
    *)             warn "eeepc-games: unknown argument '$1' (--help)"; exit 1 ;;
  esac
  shift
done

case "$ACTION" in
  list)      list_categories ;;
  list_all)  list_all ;;
  pipe)      openbox_pipe ;;
  desktop)   do_desktop_only ;;
  search)    search_catalogue "${SEARCH_TERM:-}" ;;
  install)   install_categories "$INSTALL_KEYS" ;;
  "")        menu ;;
esac

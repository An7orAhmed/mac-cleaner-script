#!/usr/bin/env bash
#==============================================================================
# cleanup.sh — scan, report, confirm, then clean.  (macOS, no sudo required)
#
#   ./cleanup.sh                 interactive explorer (same as --explore)
#   ./cleanup.sh --classic       tier scan + report, then offer to clean Tier 1
#   ./cleanup.sh --scan          scan + report only, delete nothing
#   ./cleanup.sh --pick          interactive: tick individual items to delete
#   ./cleanup.sh --tier 1,3      pick tiers explicitly
#   ./cleanup.sh --all           all three tiers
#   ./cleanup.sh --yes           don't prompt (use with --tier / --all)
#   ./cleanup.sh --explore       interactive explorer: scans every large folder,
#                                rates each one (SAFE / REGEN / RISKY / KEEP / ?)
#                                with advice, then lets you mark and delete
#   ./cleanup.sh --min 500M      explorer, listing folders down to 500 MB
#                                (default 1G)
#   With no terminal attached (cron, pipes) the no-argument run falls back to
#   --classic, since the explorer needs a keyboard.
#
#   The explorer needs python3 (standard library only, no pip packages). If it
#   is missing the script installs it first — via Homebrew when available,
#   otherwise Apple's Command Line Tools.
#
#   Explorer keys:  ↑↓ move · space mark · → open folder · ← back
#                   a mark all SAFE · n clear marks · f filter · s sort
#                   o show in Finder · d delete marked · r rescan · ? help · q quit
#
#   TIER 1  caches & build output that regenerate automatically. No settings,
#           projects or logins lost.
#   TIER 2  regenerable, but costs re-download / re-index time on next use.
#   TIER 3  real data behind it — emulators, app logins, browser site data.
#
# "SYSTEM DATA" in Storage settings is mostly things this script also covers:
#   Chrome code-sign clones   (tier 1)  stale copies of Chrome.app, ~2 GB each
#   leftover build-* temp dirs(tier 1)  e.g. an abandoned Homebrew wine build
#   CoreSimulator caches      (tier 1)  root-owned; needs sudo
#   older simulator runtimes  (tier 2)  every runtime but the newest per OS
#   simulator device data     (tier 3)  apps + data inside every simulator
# The report also prints a read-only "System Data breakdown" (temp folders,
# Preboot, swap, simulator runtimes, Chrome profile) so you can see where the
# rest of it lives.
#
# LIVE (AERIAL) WALLPAPER — the one cache that grows back on its own
#   Apple's Aerial screen savers stream 4K video and cache it in two places:
#       ~/Library/Application Support/com.apple.wallpaper/aerials/videos
#       /Library/Application Support/com.apple.idleassetsd/Customer/4KSDR240FPS
#   "Shuffle All Aerials" downloads *every* aerial Apple offers — about 47 GB —
#   and keeps pulling more as it rotates, so deleting the caches alone only
#   buys you a few minutes.  This script detects that setting, explains it, and
#   offers to point the screen saver at a still image before it clears the
#   caches.  Related flags:
#
#   ./cleanup.sh --fix-wallpaper      only disable aerials, then exit
#   ./cleanup.sh --no-fix-wallpaper   report it, but leave the setting alone
#   ./cleanup.sh --restore-wallpaper  undo it from the newest backup, then exit
#
#   The edit is per-user and needs no sudo; the previous config is copied to
#   ~/.cleanup-backups/wallpaper/ first.  The 41 GB system-wide copy of the
#   videos does need sudo — the script prints that command rather than asking
#   for a password.
#
# Safety rules baked in:
#   * Never touches  node_modules/  or Python  site-packages/  when hunting
#     for "build" directories (pip ships a real source dir named build/).
#   * Refuses to delete data belonging to an app that is currently running.
#   * Prints every target with its size and waits for confirmation per tier.
#   * Backs up the wallpaper config before touching it, restores that backup
#     if the rewrite fails, and never changes any setting under --scan.
#==============================================================================
set -uo pipefail

PROJECT_DIRS=( "$HOME/MyWork" )     # where to hunt for build artifacts

SCAN_ONLY=0; ASSUME_YES=0; TIERS="1"; FIX_WP="ask"; WP_ONLY=0; PICK=0
EXPLORE=0; MIN_SIZE="1G"
# no arguments → the explorer, when there's a terminal to drive it
[ $# -eq 0 ] && [ -t 0 ] && [ -t 1 ] && EXPLORE=1
while [ $# -gt 0 ]; do
  case "$1" in
    --scan|-n)  SCAN_ONLY=1 ;;
    --pick|-i)  PICK=1 ;;
    --explore|-e) EXPLORE=1 ;;
    --min)      shift; MIN_SIZE="${1:-1G}"; EXPLORE=1 ;;
    --classic|-c) EXPLORE=0 ;;
    --yes|-y)   ASSUME_YES=1 ;;
    --all|-a)   TIERS="1,2,3" ;;
    --tier|-t)  shift; TIERS="${1:-1}" ;;
    --fix-wallpaper)     FIX_WP="force";   WP_ONLY=1 ;;
    --no-fix-wallpaper)  FIX_WP="never" ;;
    --restore-wallpaper) FIX_WP="restore"; WP_ONLY=1 ;;
    --help|-h)  awk 'NR<3{next} /^#=+$/{exit} {print}' "$0" \
                  | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1  (try --help)"; exit 1 ;;
  esac
  shift
done
# --yes covers the wallpaper prompt too, unless it was explicitly waived
[ "$ASSUME_YES" -eq 1 ] && [ "$FIX_WP" = "ask" ] && FIX_WP="force"

bold=$(tput bold 2>/dev/null || true); dim=$(tput dim 2>/dev/null || true)
red=$(tput setaf 1 2>/dev/null || true); grn=$(tput setaf 2 2>/dev/null || true)
ylw=$(tput setaf 3 2>/dev/null || true); rst=$(tput sgr0 2>/dev/null || true)

TMP=$(mktemp -d "${TMPDIR:-/tmp}/cleanup.XXXXXX"); trap 'rm -rf "$TMP"' EXIT
PLAN="$TMP/plan"; : > "$PLAN"

# ---------- helpers ----------------------------------------------------------
kb_of()  { du -sk "$@" 2>/dev/null | awk '{s+=$1} END{printf "%d", s+0}'; }
human()  { awk -v k="${1:-0}" 'BEGIN{
             if (k>=1048576) printf "%.1f GB", k/1048576;
             else if (k>=1024) printf "%.0f MB", k/1024;
             else printf "%d KB", k }'; }
free_kb() { df -k /System/Volumes/Data 2>/dev/null | awk 'NR==2{print $4}'; }
running() { pgrep -x "$1" >/dev/null 2>&1 || pgrep -f "$1" >/dev/null 2>&1; }
wants()   { case ",$TIERS," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }

# add TIER|LABEL|PATH  — size is measured now, deletion happens later
add() {
  local tier="$1" label="$2" path="$3"
  [ -e "$path" ] || return 0
  local kb; kb=$(kb_of "$path"); [ "${kb:-0}" -lt 1024 ] && return 0
  printf '%s\t%s\t%s\t%s\n' "$tier" "$kb" "$label" "$path" >> "$PLAN"
}

skipped_notes=""
note_skip() { skipped_notes="${skipped_notes}    ${ylw}!${rst} $1\n"; }

# ---------- live (aerial) wallpaper ------------------------------------------
WP_INDEX="$HOME/Library/Application Support/com.apple.wallpaper/Store/Index.plist"
WP_BACKUPS="$HOME/.cleanup-backups/wallpaper"
WP_STILL="/System/Library/Desktop Pictures/Solid Colors/Black.png"

# how many wallpaper/screen-saver slots currently point at an Aerial video
aerials_count() {
  [ -f "$WP_INDEX" ] || { echo 0; return 0; }
  plutil -p "$WP_INDEX" 2>/dev/null | grep -c 'choice.aerials' || true
}

wp_restart_agent() {
  killall WallpaperAerialsExtension 2>/dev/null
  killall WallpaperAgent            2>/dev/null
  sleep 3
}

# Rewrites every Idle (screen saver) slot that plays an Aerial video so it
# shows a still instead — reusing whatever still the desktop already displays,
# and only falling back to a system image if there isn't one.
cat > "$TMP/fix_aerials.py" <<'PYFIX'
import copy, pathlib, plistlib, sys

target, still = sys.argv[1], sys.argv[2]
with open(target, "rb") as f:
    doc = plistlib.load(f)

def is_aerial(content):
    if not isinstance(content, dict):
        return False
    return any(isinstance(c, dict)
               and str(c.get("Provider", "")).endswith("aerials")
               for c in content.get("Choices", []))

def usable(content):
    return (isinstance(content, dict) and content.get("Choices")
            and not is_aerial(content))

def find_still(node):
    """First non-aerial Content anywhere in the tree — i.e. a still the user
    already picked, which keeps the screen saver looking deliberate."""
    if isinstance(node, dict):
        for slot in ("Desktop", "Idle"):
            entry = node.get(slot)
            if isinstance(entry, dict) and usable(entry.get("Content")):
                return copy.deepcopy(entry["Content"])
        for value in node.values():
            found = find_still(value)
            if found:
                return found
    return None

fallback = find_still(doc) or {
    "Choices": [{
        "Configuration": plistlib.dumps(
            {"type": "imageFile",
             "url": {"relative": pathlib.Path(still).as_uri()}},
            fmt=plistlib.FMT_BINARY),
        "Files": [],
        "Provider": "com.apple.wallpaper.choice.image",
    }],
    "EncodedOptionValues": plistlib.dumps(
        {"values": {"placement": {"picker": {"_0": {"id": "Crop"}}}}},
        fmt=plistlib.FMT_BINARY),
    "Shuffle": "$null",
}

changed = 0
def fix(node):
    global changed
    if not isinstance(node, dict):
        return
    idle = node.get("Idle")
    if isinstance(idle, dict) and is_aerial(idle.get("Content")):
        sibling = node.get("Desktop", {}).get("Content") \
                  if isinstance(node.get("Desktop"), dict) else None
        idle["Content"] = copy.deepcopy(sibling if usable(sibling) else fallback)
        changed += 1
    for key, value in node.items():
        if key in ("Idle", "Desktop", "Content"):
            continue
        fix(value)
        if isinstance(value, dict):
            for inner in value.values():
                fix(inner)

fix(doc)
if changed:
    with open(target, "wb") as f:
        plistlib.dump(doc, f, fmt=plistlib.FMT_BINARY)
print(changed)
PYFIX

disable_aerials() {
  if ! command -v python3 >/dev/null 2>&1; then
    printf '    %s python3 not found — change it by hand in System Settings >\n' "${ylw}!${rst}"
    printf '      Screen Saver (avoid Landscape, Cityscape, Underwater and\n'
    printf '      Earth — those are all aerials).\n'
    return 1
  fi
  mkdir -p "$WP_BACKUPS" 2>/dev/null
  local bak="$WP_BACKUPS/Index.plist.$(date +%Y%m%d-%H%M%S).bak"
  if ! cp -p "$WP_INDEX" "$bak" 2>/dev/null; then
    printf '    %s could not back up the wallpaper config — leaving it alone.\n' "${red}x${rst}"
    return 1
  fi

  local n; n=$(python3 "$TMP/fix_aerials.py" "$WP_INDEX" "$WP_STILL" 2>/dev/null)
  if ! [ "${n:-0}" -gt 0 ] 2>/dev/null; then
    cp -p "$bak" "$WP_INDEX" 2>/dev/null
    printf '    %s could not rewrite the wallpaper config — backup restored.\n' "${red}x${rst}"
    return 1
  fi

  wp_restart_agent
  local left; left=$(aerials_count)
  if [ "${left:-1}" -eq 0 ]; then
    printf '    %s screen saver switched off Aerial video (%s slot(s))\n' "${grn}✓${rst}" "$n"
    printf '      %sbackup: %s%s\n' "$dim" "$bak" "$rst"
    return 0
  fi
  printf '    %s rewrote %s slot(s), but %s still reference aerials — finish in\n' "${ylw}!${rst}" "$n" "$left"
  printf '      System Settings > Screen Saver.\n'
  return 1
}

restore_aerials() {
  local bak; bak=$(ls -1t "$WP_BACKUPS"/Index.plist.*.bak 2>/dev/null | head -1)
  if [ -z "$bak" ]; then
    printf '  %s no wallpaper backup in %s\n' "${red}x${rst}" "$WP_BACKUPS"
    return 1
  fi
  cp -p "$bak" "$WP_INDEX" || return 1
  wp_restart_agent
  printf '  %s restored %s\n' "${grn}✓${rst}" "$bak"
  printf '  %saerial slots now: %s%s\n' "$dim" "$(aerials_count)" "$rst"
  return 0
}

# --restore-wallpaper / --fix-wallpaper do their one job and stop
if [ "$FIX_WP" = "restore" ]; then
  echo ""; restore_aerials; rc=$?; echo ""; exit $rc
fi
if [ "$WP_ONLY" -eq 1 ]; then
  echo ""
  if [ "$(aerials_count)" -eq 0 ]; then
    echo "  ${grn}Screen saver already uses no Aerial video — nothing to do.${rst}"
    echo ""; exit 0
  fi
  echo "  ${bold}Disabling the Apple Aerial screen saver…${rst}"
  disable_aerials; rc=$?
  echo ""
  echo "  ${dim}Now run ./cleanup.sh to clear the videos it already downloaded.${rst}"
  echo ""; exit $rc
fi

# ---------- dependencies -----------------------------------------------------
# python3 + its built-in curses module is all the explorer needs. macOS ships
# /usr/bin/python3 as a stub that only works once Command Line Tools exist.
ensure_python() {
  python3 -c 'import curses' >/dev/null 2>&1 && return 0
  echo ""
  echo "  ${bold}python3 (with curses) is needed — installing it first…${rst}"
  if command -v brew >/dev/null 2>&1; then
    brew install python3 && hash -r
    python3 -c 'import curses' >/dev/null 2>&1 && return 0
  fi
  if ! xcode-select -p >/dev/null 2>&1; then
    echo "  Opening Apple's Command Line Tools installer (includes python3)…"
    xcode-select --install >/dev/null 2>&1
    printf '  Press Enter once the installer has finished… '
    read -r _ </dev/tty || true
    python3 -c 'import curses' >/dev/null 2>&1 && return 0
  fi
  echo "  ${red}x${rst} could not install python3 — install it from https://www.python.org and re-run."
  return 1
}

# ---------- --explore : interactive large-folder explorer --------------------
if [ "$EXPLORE" -eq 1 ]; then
  { [ -t 0 ] && [ -t 1 ]; } || { echo "--explore needs an interactive terminal"; exit 1; }
  ensure_python || exit 1
  cat > "$TMP/explore.py" <<'PYEXPLORE'
import curses, fnmatch, os, shutil, subprocess, sys, textwrap, time

HOME = os.path.expanduser("~")
VF = os.environ.get("CLEANUP_USER_VF", "")        # /var/folders/xx/…/  (per-user)
EXCL = ["-I", "CloudStorage", "-I", "Mobile Documents"]   # never walk cloud drives

def parse_size(s):
    s = s.strip().upper().rstrip("B")
    mult = {"K": 1, "M": 1024, "G": 1024 ** 2, "T": 1024 ** 3}
    try:
        if s and s[-1] in mult:
            return int(float(s[:-1]) * mult[s[-1]])
        return int(float(s) * 1024 ** 2)
    except ValueError:
        return 1024 ** 2

MIN_KB = parse_size(sys.argv[1] if len(sys.argv) > 1 else "1G")

ROOTS = [(HOME, 7), (VF, 5), ("/Library/Developer", 4),
         ("/Library/Application Support", 4), ("/Library/Caches", 2),
         ("/Applications", 1), ("/opt", 3), ("/usr/local", 3)]
ROOTS = [(r, d) for r, d in ROOTS if r and os.path.isdir(r)]

SAFE, REGEN, RISKY, KEEP, UNK = "SAFE", "REGEN", "RISKY", "KEEP", "?"
LONG = {SAFE:  "Safe to delete: regenerates automatically",
        REGEN: "Safe, but costs a re-download or rebuild",
        RISKY: "Real data: delete only if you're sure",
        KEEP:  "Don't delete here: manage it another way",
        UNK:   "Not recognised: review before deleting"}

# (patterns, rating, advice, options)   first match wins
#   contents  delete what's inside, keep the folder itself
#   app       refuse while this process is running
#   descend   keep looking for big folders inside it
#   project   only matches outside ~/Library (project build dirs)
CS = "~/Library/Application Support/"
RULES = [
 (["~/Library/CloudStorage*", "~/Library/Mobile Documents*"], KEEP,
  "Cloud-synced files. Deleting here deletes them on every device.", {}),
 (["*/.git"], KEEP, "Git history of a repo. Delete the whole repo instead if unused.", {}),
 (["*.photoslibrary"], KEEP, "Photos library. Use Photos > Settings > Optimize Mac Storage.", {}),
 (["~/Library/Mail", "~/Library/Messages"], KEEP,
  "Mail / Messages data. Remove big attachments from inside the app.", {}),
 ([CS + "MobileSync/Backup*"], RISKY,
  "iPhone/iPad backups. Remove old ones in Finder > device > Manage Backups.", {}),
 # per-user temp (/var/folders) — where "System Data" often hides
 (["$VF/X/com.google.Chrome.code_sign_clone"], SAFE,
  "Stale copies of Chrome.app left behind by updates (~2 GB each).",
  {"contents": True, "app": "Google Chrome"}),
 (["$VF/T/build-*"], SAFE, "Leftover build scratch folder. Safe once that build has finished.", {}),
 (["$VF/C/*"], SAFE, "Per-app system cache. Rebuilt as needed.", {}),
 (["$VF/T/*", "$VF/X/*"], REGEN,
  "Temp data of an app. Safe when that app is closed; macOS also clears it on reboot.", {}),
 (["$VF", "$VF/T", "$VF/X", "$VF/C"], KEEP,
  "Per-user system temp folder. Open it (→) and delete items inside instead.", {"descend": True}),
 # caches & logs
 (["~/Library/Caches"], SAFE, "App caches. Apps rebuild them as needed.", {"contents": True}),
 (["~/Library/Caches/*"], SAFE, "App cache. Rebuilt as needed.", {}),
 (["~/Library/Logs"], SAFE, "Log files.", {"contents": True}),
 (["~/Library/Logs/*"], SAFE, "Log files.", {}),
 (["~/.Trash"], SAFE, "Trash. Emptying it frees this space for good.", {"contents": True}),
 (["~/.cache/huggingface*", "~/.ollama/models*", "~/.lmstudio/models*"], REGEN,
  "Downloaded AI models. Re-downloaded on next use (large).", {}),
 (["~/.cache", "~/.cache/*"], SAFE, "Tool caches (pip, uv, pre-commit, …). Rebuilt as needed.", {}),
 (["~/.npm", "~/.npm/*"], SAFE, "npm download cache (same as `npm cache clean --force`).", {}),
 (["~/Library/pnpm*", "~/.pnpm-store*"], REGEN, "pnpm package store. Re-downloaded on next install.", {}),
 (["~/.gradle/caches", "~/.gradle/daemon", "~/.gradle/native"], SAFE,
  "Gradle caches. Rebuilt on next build (first build is slower).", {}),
 (["~/.gradle/wrapper"], REGEN, "Gradle distributions. Re-downloaded by projects on next build.", {}),
 (["~/.gradle"], REGEN,
  "Gradle caches + distributions. Rebuilt / re-downloaded on next build.", {"descend": True}),
 (["*/flutter/bin/cache*"], REGEN, "Flutter SDK cache. `flutter precache` re-downloads it.", {}),
 (["*/AndroidSDK/system-images*", "*/Android/sdk/system-images*"], REGEN,
  "Emulator system images. Remove unused ones in Android Studio > SDK Manager.", {}),
 (["*/AndroidSDK/ndk/*", "*/Android/sdk/ndk/*"], REGEN,
  "One NDK version. Remove versions no project uses in SDK Manager > SDK Tools.", {}),
 (["*/AndroidSDK", "*/AndroidSDK/*", "*/Android/sdk", "*/Android/sdk/*"], KEEP,
  "Android SDK. Manage it with Android Studio > SDK Manager.", {"descend": True}),
 (["*/lib/python*/site-packages*"], REGEN,
  "Packages inside a Python virtualenv. Recreate the venv and `pip install -r requirements.txt`.",
  {"project": True}),
 (["~/.m2/repository"], REGEN, "Maven packages. Re-downloaded on next build.", {}),
 (["~/.pub-cache"], REGEN, "Dart/Flutter packages. `flutter pub get` restores them.", {}),
 (["~/.dartServer"], SAFE, "Dart analyzer cache.", {}),
 (["~/.cargo/registry", "~/go/pkg/mod"], REGEN, "Downloaded Rust/Go packages.", {}),
 (["~/.cocoapods*"], REGEN, "CocoaPods specs repo. Re-downloaded by `pod install`.", {}),
 (["~/.vscode/extensions", "~/.antigravity/extensions", "~/.cursor/extensions"], REGEN,
  "Editor extensions. Reinstall them from the marketplace.", {}),
 (["~/.platformio/packages"], REGEN, "PlatformIO toolchains. Re-downloaded when you build.", {}),
 (["~/.android/avd", "~/.android/avd/*"], RISKY,
  "Android emulators and their data. Prefer Android Studio > Device Manager.", {"app": "qemu-system"}),
 (["~/Library/Android/sdk/system-images*"], REGEN,
  "Emulator system images. Remove unused ones in Android Studio > SDK Manager.", {}),
 (["~/Library/Android/sdk"], KEEP, "Android SDK. Manage it with Android Studio > SDK Manager.",
  {"descend": True}),
 # Xcode & simulators
 (["~/Library/Developer/Xcode/DerivedData*"], SAFE, "Xcode build output. Rebuilt on next build.", {}),
 (["~/Library/Developer/Xcode/*DeviceSupport*"], SAFE,
  "Debug symbols for devices. Re-copied when you plug a device in.", {}),
 (["~/Library/Developer/Xcode/Archives*"], RISKY,
  "App archives. Needed to symbolicate crash reports for builds you shipped.", {}),
 (["~/Library/Developer/CoreSimulator/Caches*"], SAFE, "Simulator caches.", {}),
 (["~/Library/Developer/CoreSimulator*"], RISKY,
  "Simulators and the apps installed in them. Try `xcrun simctl delete unavailable` "
  "first; `xcrun simctl erase all` wipes the rest.", {"app": "Simulator.app"}),
 (["/Library/Developer/CoreSimulator/Caches*"], SAFE,
  "Simulator dyld caches (root-owned, needs sudo).", {}),
 (["/Library/Developer/CoreSimulator*"], KEEP,
  "Simulator runtimes. Remove old ones in Xcode > Settings > Components "
  "or with `xcrun simctl runtime delete <id>`.", {}),
 (["/Library/Developer/CommandLineTools*"], KEEP,
  "Command Line Tools (git, clang, python3). Needed for development.", {}),
 # editors
 ([CS + e + "/" + c for e in ("Code", "Cursor", "Antigravity", "VSCodium")
   for c in ("Cache", "CachedData", "CachedExtensionVSIXs", "GPUCache", "Crashpad",
             "Code Cache", "CachedProfilesData", "logs")], SAFE, "Editor cache.", {}),
 (["*/User/workspaceStorage"], REGEN,
  "Per-project editor state (AI indexes, etc.). Rebuilt when you reopen a project.", {}),
 (["*/User/History"], REGEN, "Local edit history (Timeline). Old undo history is lost.", {}),
 # browsers
 (["*/Google/Chrome/OptGuideOnDeviceModel", "*/Google/Chrome/*/OptGuideOnDeviceModel"], REGEN,
  "Chrome's on-device AI model. Chrome may re-download it.", {"app": "Google Chrome"}),
 (["*/Chrome/*/Cache", "*/Chrome/*/Code Cache", "*/Chrome/*/GPUCache",
   "*/BraveSoftware/*/*/Cache", "*/BraveSoftware/*/*/Code Cache"], SAFE,
  "Browser cache.", {"app": "Google Chrome"}),
 (["*/Chrome/*/Service Worker", "*/BraveSoftware/*/*/Service Worker"], RISKY,
  "Website offline data. You stay logged in; sites lose offline caches.", {"app": "Google Chrome"}),
 (["*/Chrome/*/IndexedDB", "*/BraveSoftware/*/*/IndexedDB"], RISKY,
  "Website databases (offline docs, WhatsApp Web, …). Some sites must re-sync.",
  {"app": "Google Chrome"}),
 ([CS + "Google/Chrome", CS + "Google/Chrome/*", CS + "BraveSoftware*"], KEEP,
  "Browser profile (history, logins, extensions). Clear it via the browser's "
  "Settings > Privacy > Delete browsing data.", {"descend": True}),
 ([CS + "Google/DriveFS*"], REGEN,
  "Google Drive local cache. Lower the cache size in Drive preferences.", {"app": "Google Drive"}),
 ([CS + "Google/AndroidStudio*"], REGEN,
  "Android Studio settings for one version. Folders of old versions are safe to delete.", {}),
 # Apple
 ([CS + "com.apple.wallpaper/aerials*", "/Library/Application Support/com.apple.idleassetsd*"], SAFE,
  "Aerial screen-saver videos. They come back if an Aerial screen saver is selected; "
  "run ./cleanup.sh --fix-wallpaper first.", {}),
 ([CS + "com.apple.mobileAssetDesktop*"], REGEN,
  "Downloaded Apple assets (wallpapers, voices). Re-downloaded on demand.", {}),
 (["~/Library/Metadata/CoreSpotlight*"], KEEP, "Spotlight index. Rebuild with `mdutil -E /` instead.", {}),
 (["~/Library/Biome*", "~/Library/DuetExpertCenter*", "~/Library/IntelligencePlatform*",
   "~/Library/Daemon Containers*"], KEEP,
  "macOS system data (Siri, suggestions). Managed by macOS.", {}),
 (["~/Library/Containers/com.docker.docker*", "~/Library/Group Containers/group.com.docker*"], RISKY,
  "Docker's disk image with every image/container. Use `docker system prune -a` "
  "or Docker > Settings > Resources instead.", {"app": "Docker"}),
 (["~/Library/Containers/*", "~/Library/Group Containers/*"], RISKY,
  "Sandboxed app data. Delete only for apps you've uninstalled.", {"descend": True}),
 ([CS + "*"], RISKY, "App data (settings, databases). Delete only for apps you've uninstalled.",
  {"descend": True}),
 (["/Library/Application Support/*"], RISKY,
  "System-wide app data. Delete only for uninstalled apps (usually needs sudo).", {}),
 # project folders
 (["*/node_modules"], REGEN, "npm packages. `npm install` restores them.", {"project": True}),
 (["*/.venv", "*/venv"], REGEN, "Python virtualenv. Recreate it from requirements.", {"project": True}),
 (["*/Pods"], REGEN, "CocoaPods dependencies. `pod install` restores them.", {"project": True}),
 (["*/build", "*/.dart_tool", "*/.next", "*/.gradle", "*/.turbo", "*/.parcel-cache", "*/.expo"],
  SAFE, "Build output. Rebuilt on next build.", {"project": True}),
 (["*/dist", "*/target", "*/out"], REGEN,
  "Probably build output. Rebuilt on next build, but check it isn't a release you need.",
  {"project": True}),
 # personal
 (["~/Downloads/*.dmg", "~/Downloads/*.pkg", "~/Downloads/*.iso"], REGEN,
  "Installer in Downloads. Usually safe once the app is installed.", {}),
 (["~/Downloads*", "~/Documents*", "~/Desktop*", "~/Pictures*", "~/Movies*", "~/Music*",
   "~/Public*"], RISKY,
  "Your personal files. Review by hand, or move big items to an external drive.",
  {"descend": True}),
 (["/Applications/*.app"], RISKY,
  "An application. Uninstall it if unused (drag to Trash).", {}),
 (["/Applications/*"], RISKY,
  "Installed software folder. Use its own uninstaller if it has one.", {}),
 (["/opt/homebrew*", "/usr/local*", "/opt/*"], KEEP,
  "Homebrew / installed packages. Use `brew uninstall <pkg>` and `brew cleanup`.", {}),
]

def expand(p):
    if p.startswith("~"):
        return HOME + p[1:]
    return p.replace("$VF", VF)

COMPILED = []
for pats, rating, advice, opts in RULES:
    pats = [expand(p) for p in pats if VF or "$VF" not in p]
    COMPILED.append((pats, rating, advice, opts))

LIB = HOME + "/Library"
_match_cache = {}
def match(path):
    if path in _match_cache:
        return _match_cache[path]
    hit = None
    for pats, rating, advice, opts in COMPILED:
        if opts.get("project") and (not path.startswith(HOME + "/") or path.startswith(LIB + "/")
                                    or os.path.dirname(path) == HOME):
            continue
        if any(fnmatch.fnmatchcase(path, p) for p in pats):
            hit = (rating, advice, opts)
            break
    _match_cache[path] = hit
    return hit

def rate(path):
    hit = match(path)
    if hit:
        rating, advice, opts = hit
        parent = os.path.dirname(path)
        if parent == HOME + "/Library/Application Support":
            name = os.path.basename(path)
            if not any(os.path.exists(d + "/" + name + ".app")
                       for d in ("/Applications", HOME + "/Applications")):
                advice += " (No " + name + ".app installed; may be left over.)"
        return rating, advice, opts
    if os.path.isfile(os.path.join(path, "pyvenv.cfg")):
        return REGEN, "Python virtualenv. Recreate it and `pip install -r requirements.txt`.", {}
    name = os.path.basename(path).lower()
    if any(w in name for w in ("cache", "tmp", "temp", "log")):
        return UNK, ("Not in the rule list, but the name suggests cache/temp/log data. "
                     "Probably safe; look inside (→) first."), {}
    return UNK, "Not in the rule list. Look inside (→) to judge it by its contents.", {}

PROTECTED = {"/", HOME, LIB, LIB + "/Application Support", LIB + "/Containers",
             LIB + "/Group Containers", LIB + "/Developer", "/Applications", "/Library",
             "/Library/Application Support", "/Library/Developer", "/opt", "/usr/local",
             VF, VF + "/T", VF + "/X", VF + "/C"} | {r for r, _ in ROOTS} | \
            {HOME + "/" + d for d in ("Documents", "Desktop", "Downloads", "Pictures",
                                      "Movies", "Music", "Public", "Applications")}

# ---------- data -------------------------------------------------------------
sizes, kids, files, incomplete, listed = {}, {}, set(), set(), set()

def short(p):
    if VF and p.startswith(VF):
        return "/var/folders/(you)" + p[len(VF):]
    return "~" + p[len(HOME):] if p == HOME or p.startswith(HOME + "/") else p

def human(kb):
    if kb >= 1024 ** 2:
        return "%.1f GB" % (kb / 1024 ** 2)
    if kb >= 1024:
        return "%.0f MB" % (kb / 1024)
    return "%d KB" % kb

def free_kb():
    try:
        return shutil.disk_usage("/System/Volumes/Data").free // 1024
    except OSError:
        return shutil.disk_usage("/").free // 1024

def scan():
    sizes.clear(); kids.clear(); files.clear(); incomplete.clear(); listed.clear()
    _match_cache.clear()
    n, last = 0, 0.0
    for root, depth in ROOTS:
        base = root.rstrip("/").count("/")
        p = subprocess.Popen(["du", "-k", "-x", "-d", str(depth)] + EXCL + [root],
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                             text=True, errors="replace")
        for line in p.stdout:
            kb, _, path = line.rstrip("\n").partition("\t")
            if not path or not kb.isdigit():
                continue
            sizes[path] = int(kb)
            if path.count("/") - base >= depth:
                incomplete.add(path)
            n += 1
            now = time.time()
            if now - last > 0.1:
                last = now
                sys.stderr.write("\r\033[K  scanning %s  %s folders" % (short(path)[:60], format(n, ",")))
                sys.stderr.flush()
        p.wait()
    sys.stderr.write("\r\033[K")
    for path in sizes:
        par = os.path.dirname(path)
        if par != path and par in sizes:
            kids.setdefault(par, []).append(path)

def ensure_listed(path, status):
    """Children of `path` (folders and files ≥ 1 MB), measuring on demand."""
    if path in listed or path in files:
        return
    if path in incomplete or path not in sizes:
        status("Measuring " + short(path) + " …")
        out = subprocess.run(["du", "-k", "-x", "-d", "1"] + EXCL + [path],
                             capture_output=True, text=True, errors="replace").stdout
        found = []
        for line in out.splitlines():
            kb, _, p = line.partition("\t")
            if p and kb.isdigit():
                sizes[p] = int(kb)
                if p != path:
                    found.append(p); incomplete.add(p)
        kids[path] = found
        incomplete.discard(path)
    ch = kids.setdefault(path, [])
    try:
        for e in os.scandir(path):
            if e.is_file(follow_symlinks=False):
                kb = e.stat(follow_symlinks=False).st_blocks // 2
                if kb >= 1024 and e.path not in sizes:
                    sizes[e.path] = kb; files.add(e.path); ch.append(e.path)
    except OSError:
        pass
    listed.add(path)

class Item:
    def __init__(self, path, kb, partial=False):
        self.path, self.kb, self.partial = path, kb, partial
        self.rating, self.advice, self.opts = rate(path)
        if partial:
            self.advice = ("Other contents of this folder, spread over items smaller than "
                           "the listing threshold. Open it (→) to pick items. " + self.advice)

def findings():
    out = []
    def walk(p, is_root=False):
        kb = sizes.get(p, 0)
        if kb < MIN_KB:
            return
        hit = match(p)
        big = [c for c in kids.get(p, ()) if sizes.get(c, 0) >= MIN_KB]
        stop = hit is not None and not hit[2].get("descend")
        if not is_root and (stop or not big):
            out.append(Item(p, kb)); return
        for c in big:
            walk(c)
        rest = kb - sum(sizes[c] for c in big)
        if rest >= MIN_KB:
            out.append(Item(p, rest, partial=True))
    for root, _ in ROOTS:
        walk(root, True)
    return out

def browse(path):
    return [Item(c, sizes.get(c, 0)) for c in kids.get(path, ()) if c in sizes]

def can_mark(it):
    if it.partial:
        return False, "This row is the rest of a folder. Open it (→) and mark items inside."
    if it.path in PROTECTED:
        return False, "Top-level folder. Open it (→) and mark items inside instead."
    if it.rating == KEEP:
        return False, "Rated KEEP. " + it.advice
    return True, ""

def app_running(name):
    return subprocess.run(["pgrep", "-f", name], capture_output=True).returncode == 0

def kb_of(p):
    out = subprocess.run(["du", "-sk", p], capture_output=True, text=True).stdout.split()
    return int(out[0]) if out and out[0].isdigit() else 0

def forget(p, removed):
    a = os.path.dirname(p)
    while True:
        if a in sizes:
            sizes[a] = max(0, sizes[a] - removed)
        if a in ("/", ""):
            break
        a = os.path.dirname(a)
    pre = p + "/"
    for k in [k for k in sizes if k.startswith(pre)]:
        del sizes[k]; files.discard(k); kids.pop(k, None); listed.discard(k)
    kids.pop(p, None); listed.discard(p)

def delete(paths, to_trash):
    """Returns (log lines, sudo commands)."""
    log, sudo = [], []
    for p in paths:
        rating, advice, opts = rate(p)
        app = opts.get("app")
        if app and app_running(app):
            log.append(("!", short(p), "skipped: %s is running, quit it first" % app)); continue
        before = sizes.get(p, 0)
        contents = opts.get("contents") and os.path.isdir(p)
        target_dir = p if contents else os.path.dirname(p)
        if not os.access(target_dir, os.W_OK):
            cmd = "sudo rm -rf %s" % ("'%s'/*" % p if contents else "'%s'" % p)
            sudo.append(cmd)
            log.append(("!", short(p), "needs sudo: " + cmd)); continue
        try:
            if contents:
                for e in os.listdir(p):
                    subprocess.run(["rm", "-rf", "--", os.path.join(p, e)],
                                   stderr=subprocess.DEVNULL)
            elif to_trash:
                dest = os.path.join(HOME, ".Trash", os.path.basename(p))
                if os.path.exists(dest):
                    dest += time.strftime(" %H.%M.%S")
                os.rename(p, dest)
            else:
                subprocess.run(["rm", "-rf", "--", p], stderr=subprocess.DEVNULL)
        except OSError as e:
            log.append(("x", short(p), str(e))); continue
        left = kb_of(p) if os.path.exists(p) else 0
        forget(p, before - left)
        if os.path.exists(p):
            sizes[p] = left
            if contents:
                incomplete.add(p)
            else:
                log.append(("!", short(p), "partly deleted; some files need sudo or are in use"))
                continue
        else:
            sizes.pop(p, None); files.discard(p)
            par = os.path.dirname(p)
            if par in kids and p in kids[par]:
                kids[par].remove(p)
        log.append(("✓", short(p), "moved to Trash" if to_trash and not contents else human(before - left)))
    return log, sudo

# ---------- UI ---------------------------------------------------------------
FILTERS = [None, SAFE, REGEN, RISKY, KEEP, UNK]
COLOR = {SAFE: 1, REGEN: 2, RISKY: 3, KEEP: 4, UNK: 6}

class View:
    def __init__(self, title, build):
        self.title, self.build = title, build
        self.cur = self.top = 0
        self.items = build()

HELP = """\
 RATINGS
   SAFE   regenerates by itself: caches, logs, build output, stale copies
   REGEN  safe, but you pay a re-download / rebuild the next time
   RISKY  real data (app data, emulators, personal files): only if you're sure
   KEEP   can't be marked; the advice says how to shrink it properly
   ?      not in the rule list; open it and judge by contents

 KEYS
   ↑ ↓  PgUp PgDn  Home End   move          space   mark / unmark
   → / Enter                  open folder   ← / Backspace   go back
   a   mark every SAFE item in this view    n   clear all marks
   f   filter by rating       s   sort by size / name
   o   show in Finder         d   delete marked (asks first)
   r   rescan                 q   quit (nothing is deleted without asking)

 Deleting asks for y (permanent) or t (move to Trash). RISKY items need Y.
 Apps that are still running are skipped. Root-owned items print a sudo
 command instead of asking for your password.

 Press any key to go back."""

def main(scr):
    curses.curs_set(0)
    curses.start_color()
    try:
        curses.use_default_colors(); bg = -1
    except curses.error:
        bg = curses.COLOR_BLACK
    for n, c in ((1, curses.COLOR_GREEN), (2, curses.COLOR_YELLOW), (3, curses.COLOR_RED),
                 (4, curses.COLOR_MAGENTA), (5, curses.COLOR_CYAN), (6, curses.COLOR_WHITE)):
        curses.init_pair(n, c, bg)
    marks = set()
    stack = [View("Large folders (≥ %s), biggest first" % human(MIN_KB), findings)]
    state = {"filter": 0, "sort": "size", "msg": "", "freed": 0}
    sudo_all = []

    def put(y, x, s, attr=0):
        h, w = scr.getmaxyx()
        if 0 <= y < h and x < w:
            try:
                scr.addnstr(y, x, s, max(0, w - x - (1 if y == h - 1 else 0)), attr)
            except curses.error:
                pass

    def status(text):
        h, w = scr.getmaxyx()
        put(h - 1, 0, (" " + text).ljust(w), curses.A_REVERSE)
        scr.refresh()

    def visible(v):
        f = FILTERS[state["filter"]]
        items = [i for i in v.items if f is None or i.rating == f]
        if state["sort"] == "name":
            items.sort(key=lambda i: i.path.lower())
        else:
            items.sort(key=lambda i: -i.kb)
        return items

    def effective_marks():
        out = []
        for p in sorted(marks):
            if not any(p.startswith(q + "/") for q in out):
                out.append(p)
        return out

    def refresh_all():
        for v in stack:
            v.items = v.build()
        marks.intersection_update(sizes.keys())

    def draw():
        scr.erase()
        h, w = scr.getmaxyx()
        if h < 14 or w < 60:
            put(0, 0, "Make the terminal bigger (at least 60×14).")
            scr.refresh(); return []
        v = stack[-1]
        items = visible(v)
        em = effective_marks()
        mkb = sum(sizes.get(p, 0) for p in em)
        f = FILTERS[state["filter"]] or "all"
        hdr = " cleanup explore │ free %s │ marked %d · %s │ filter: %s │ sort: %s " % (
            human(free_kb()), len(em), human(mkb), f, state["sort"])
        put(0, 0, hdr.ljust(w), curses.A_REVERSE | curses.A_BOLD)
        put(1, 1, v.title[: w - 2], curses.A_BOLD | curses.color_pair(5))
        put(2, 1, "     SIZE  RATING  PATH", curses.A_DIM)
        detail_h, top = 6, 3
        list_h = h - top - detail_h - 1
        if items:
            v.cur = max(0, min(v.cur, len(items) - 1))
            if v.cur < v.top:
                v.top = v.cur
            if v.cur >= v.top + list_h:
                v.top = v.cur - list_h + 1
        else:
            v.cur = v.top = 0
            put(top + 1, 3, "(nothing here%s)" % ("" if f == "all" else " with rating " + f), curses.A_DIM)
        in_findings = len(stack) == 1
        for row, it in enumerate(items[v.top: v.top + list_h]):
            y = top + row
            sel = v.top + row == v.cur
            ok, _ = can_mark(it)
            box = "[x]" if it.path in marks else ("[ ]" if ok else " · ")
            name = short(it.path) if in_findings else os.path.basename(it.path)
            if os.path.isdir(it.path) and not in_findings:
                name += "/"
            if it.partial:
                name += "  (other contents)"
            base = curses.A_REVERSE if sel else 0
            put(y, 0, " " * w, base)
            put(y, 1, box, base | (curses.color_pair(1) | curses.A_BOLD if it.path in marks else 0))
            put(y, 5, "%9s" % human(it.kb), base)
            put(y, 16, "%-6s" % it.rating, base | curses.color_pair(COLOR[it.rating]) | curses.A_BOLD)
            put(y, 24, name[: w - 25], base | (curses.A_DIM if it.partial else 0))
        dy = h - detail_h - 1
        put(dy, 0, "─" * w, curses.A_DIM)
        if items:
            it = items[v.cur]
            put(dy + 1, 1, short(it.path)[: w - 2], curses.A_BOLD)
            put(dy + 2, 1, "%-6s" % it.rating, curses.color_pair(COLOR[it.rating]) | curses.A_BOLD)
            put(dy + 2, 8, LONG[it.rating])
            text = state["msg"] or it.advice
            for i, line in enumerate(textwrap.wrap(text, w - 2)[:3]):
                put(dy + 3 + i, 1, line, curses.color_pair(2) if state["msg"] else 0)
        keys = " ↑↓ move  space mark  → open  ← back  a all SAFE  f filter  d delete  r rescan  ? help  q quit"
        put(h - 1, 0, keys.ljust(w), curses.A_REVERSE)
        scr.refresh()
        return items

    def popup(lines, title=""):
        h, w = scr.getmaxyx()
        bw = min(w - 4, max([len(l) for l in lines] + [len(title)]) + 4)
        bh = min(h - 2, len(lines) + 2)
        win = curses.newwin(bh, bw, max(0, (h - bh) // 2), max(0, (w - bw) // 2))
        win.box()
        if title:
            try: win.addnstr(0, 2, " %s " % title, bw - 4, curses.A_BOLD)
            except curses.error: pass
        for i, l in enumerate(lines[: bh - 2]):
            try: win.addnstr(1 + i, 2, l, bw - 4)
            except curses.error: pass
        win.refresh()
        return win.getch()

    def confirm_delete():
        em = effective_marks()
        if not em:
            state["msg"] = "Nothing marked. Press space on an item to mark it."; return
        total = sum(sizes.get(p, 0) for p in em)
        risky = [p for p in em if rate(p)[0] in (RISKY, UNK)]
        lines = ["%9s  %-5s  %s" % (human(sizes.get(p, 0)), rate(p)[0], short(p)) for p in em]
        h, _ = scr.getmaxyx()
        if len(lines) > h - 12:
            lines = lines[: h - 13] + ["… and %d more" % (len(em) - (h - 13))]
        lines += ["", "Total: %s in %d item(s)" % (human(total), len(em))]
        if risky:
            lines += ["%d item(s) are RISKY or unrecognised." % len(risky),
                      "Y = delete permanently   t = move to Trash   any other key = cancel"]
        else:
            lines += ["y = delete permanently   t = move to Trash   any other key = cancel"]
        k = popup(lines, "Delete these?")
        ok = k == ord("Y") or (k == ord("y") and not risky)
        trash = k == ord("t")
        if not (ok or trash):
            state["msg"] = "Cancelled. Nothing was deleted."; return
        status("Deleting …")
        before = free_kb()
        log, sudo = delete(em, trash)
        sudo_all.extend(sudo)
        freed = max(0, free_kb() - before)
        state["freed"] += freed
        marks.clear()
        refresh_all()
        out = ["%s %s  %s" % (s, p, d) for s, p, d in log]
        out += ["", "Freed %s%s" % (human(freed), "  (Trash still holds moved items; empty it to free them)" if trash else ""),
                "", "Press any key."]
        popup(out, "Done")
        state["msg"] = ""

    while True:
        items = draw()
        k = scr.getch()
        state["msg"] = ""
        v = stack[-1]
        if k == ord("q"):
            break
        elif k in (curses.KEY_UP, ord("k")):
            v.cur = max(0, v.cur - 1)
        elif k in (curses.KEY_DOWN, ord("j")):
            v.cur = min(max(0, len(items) - 1), v.cur + 1)
        elif k == curses.KEY_PPAGE:
            v.cur = max(0, v.cur - (scr.getmaxyx()[0] - 10))
        elif k == curses.KEY_NPAGE:
            v.cur = min(max(0, len(items) - 1), v.cur + (scr.getmaxyx()[0] - 10))
        elif k in (curses.KEY_HOME, ord("g")):
            v.cur = 0
        elif k in (curses.KEY_END, ord("G")):
            v.cur = max(0, len(items) - 1)
        elif k == ord(" ") and items:
            it = items[v.cur]
            ok, why = can_mark(it)
            if not ok:
                state["msg"] = why
            else:
                marks.symmetric_difference_update({it.path})
                v.cur = min(len(items) - 1, v.cur + 1)
        elif k == ord("a"):
            n = 0
            for it in items:
                if it.rating == SAFE and can_mark(it)[0]:
                    marks.add(it.path); n += 1
            state["msg"] = "Marked %d SAFE item(s)." % n
        elif k == ord("n"):
            marks.clear()
        elif k in (curses.KEY_RIGHT, ord("l"), 10, 13) and items:
            it = items[v.cur]
            if os.path.isdir(it.path) and not os.path.islink(it.path):
                ensure_listed(it.path, status)
                p = it.path
                stack.append(View(short(p) + "  (" + human(sizes.get(p, 0)) + ")", lambda p=p: browse(p)))
            else:
                state["msg"] = "That's a file, not a folder."
        elif k in (curses.KEY_LEFT, ord("h"), curses.KEY_BACKSPACE, 127, 8):
            if len(stack) > 1:
                stack.pop()
        elif k == ord("f"):
            state["filter"] = (state["filter"] + 1) % len(FILTERS)
            v.cur = v.top = 0
        elif k == ord("s"):
            state["sort"] = "name" if state["sort"] == "size" else "size"
        elif k == ord("o") and items:
            subprocess.run(["open", "-R", items[v.cur].path], stderr=subprocess.DEVNULL)
        elif k == ord("d"):
            confirm_delete()
        elif k == ord("r"):
            curses.endwin()
            print("\n  Rescanning…")
            scan()
            del stack[1:]
            refresh_all()
            scr.refresh()
        elif k == ord("?"):
            popup(HELP.splitlines(), "Help")
    return state["freed"], sudo_all

print("\n  Scanning large folders (≥ %s). Cloud drives are skipped." % human(MIN_KB))
scan()
try:
    freed, sudo_cmds = curses.wrapper(main)
except KeyboardInterrupt:
    freed, sudo_cmds = 0, []
print("\n  Freed %s this session. Free space now %s." % (human(freed), human(free_kb())))
if sudo_cmds:
    print("\n  These need sudo. Run them yourself if you want them gone:")
    for c in sudo_cmds:
        print("    " + c)
print()
PYEXPLORE
  CLEANUP_USER_VF=$(dirname "$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || echo /nonexistent/T/)") \
    python3 "$TMP/explore.py" "$MIN_SIZE"
  exit $?
fi

# ---------- scan -------------------------------------------------------------
echo ""
echo "${bold}Scanning…${rst} ${dim}(this walks your home directory, give it a moment)${rst}"

# ---- TIER 1 : regenerates itself -------------------------------------------
add 1 "Apple aerial wallpaper videos"      "$HOME/Library/Application Support/com.apple.wallpaper/aerials/videos"

# System-wide aerial cache — root-owned, so deletion needs sudo. Reported either
# way; purge() only removes it when sudo is already unlocked.
SYS_AERIALS="/Library/Application Support/com.apple.idleassetsd/Customer/4KSDR240FPS"
if [ -d "$SYS_AERIALS" ]; then
  sakb=$(kb_of "$SYS_AERIALS")
  [ "${sakb:-0}" -gt 1024 ] && printf '%s\t%s\t%s\t%s\n' 1 "$sakb" \
    "Apple aerial videos, system-wide (sudo)" "@SYSAERIALS" >> "$PLAN"
fi
add 1 "Wallpaper partial downloads (tmp)"  "$HOME/Library/Containers/com.apple.wallpaper.extension.aerials/Data/tmp"
add 1 "Wallpaper agent cache"              "$HOME/Library/Containers/com.apple.wallpaper.agent/Data/Library/Caches"
add 1 "Gradle build cache"                 "$HOME/.gradle/caches"
add 1 "Gradle daemon logs"                 "$HOME/.gradle/daemon"
add 1 "Dart analysis server cache"         "$HOME/.dartServer"
add 1 "Xcode DerivedData"                  "$HOME/Library/Developer/Xcode/DerivedData"
add 1 "Xcode archives"                     "$HOME/Library/Developer/Xcode/Archives"
add 1 "User caches"                        "$HOME/Library/Caches"
add 1 "User logs"                          "$HOME/Library/Logs"
add 1 "Trash"                              "$HOME/.Trash"
# Chrome copies its whole app bundle into the per-user X/ folder when it
# updates, and doesn't always remove the old copies (15 of them hit 31 GB).
USER_T=$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null); USER_T="${USER_T%/}"
USER_VF=$(dirname "${USER_T:-/nonexistent/T}")
if running "Google Chrome"; then
  note_skip "Chrome is running — skipped its code-sign clones (quit Chrome and re-run)."
else
  add 1 "Chrome code-sign clones"          "$USER_VF/X/com.google.Chrome.code_sign_clone"
fi

# Abandoned build-* scratch dirs in the per-user temp folder. Only ones
# untouched for an hour and not held open by any process.
if [ -d "$USER_T" ]; then
  find "$USER_T" -mindepth 1 -maxdepth 1 -type d -name 'build-*' -mmin +60 2>/dev/null \
    | while IFS= read -r d; do lsof +D "$d" >/dev/null 2>&1 || echo "$d"; done \
    > "$TMP/tmpbuilds"
  if [ -s "$TMP/tmpbuilds" ]; then
    tkb=0; while IFS= read -r d; do tkb=$(( tkb + $(kb_of "$d") )); done < "$TMP/tmpbuilds"
    [ "$tkb" -gt 1024 ] && printf '%s\t%s\t%s\t%s\n' 1 "$tkb" \
      "Leftover build temp dirs ($(wc -l < "$TMP/tmpbuilds" | tr -d ' '))" "@TMPBUILDS" >> "$PLAN"
  fi
fi

# Simulator dyld caches — root-owned, rebuilt on next simulator boot.
SIM_CACHES="/Library/Developer/CoreSimulator/Caches"
if [ -d "$SIM_CACHES" ]; then
  sckb=$(kb_of "$SIM_CACHES")
  [ "${sckb:-0}" -gt 1024 ] && printf '%s\t%s\t%s\t%s\n' 1 "$sckb" \
    "CoreSimulator caches (sudo)" "@SIMCACHES" >> "$PLAN"
fi

for ed in Code VSCodium; do
  for c in Cache CachedData CachedExtensionVSIXs GPUCache Crashpad; do
    add 1 "$ed / $c" "$HOME/Library/Application Support/$ed/$c"
  done
done

# project build artifacts — excluding node_modules and Python site-packages
BUILDS="$TMP/builds"; : > "$BUILDS"
for root in "${PROJECT_DIRS[@]}"; do
  [ -d "$root" ] || continue
  find "$root" -type d \( -name build -o -name .dart_tool -o -name .next \) \
       -not -path "*/node_modules/*" -not -path "*/site-packages/*" \
       -prune -print >> "$BUILDS" 2>/dev/null
done
if [ -s "$BUILDS" ]; then
  bkb=0
  while IFS= read -r d; do bkb=$(( bkb + $(kb_of "$d") )); done < "$BUILDS"
  [ "$bkb" -gt 1024 ] && printf '%s\t%s\t%s\t%s\n' 1 "$bkb" \
    "Project build artifacts ($(wc -l < "$BUILDS" | tr -d ' ') dirs)" "@BUILDS" >> "$PLAN"
fi

# unavailable iOS simulators
if command -v xcrun >/dev/null 2>&1; then
  xcrun simctl list devices 2>/dev/null | awk '/^-- Unavailable/{f=1;next} /^--/{f=0} f' \
    | grep -o '[0-9A-F]\{8\}-[0-9A-F-]\{27\}' > "$TMP/deadsims" 2>/dev/null
  if [ -s "$TMP/deadsims" ]; then
    skb=0
    while IFS= read -r id; do
      skb=$(( skb + $(kb_of "$HOME/Library/Developer/CoreSimulator/Devices/$id") ))
    done < "$TMP/deadsims"
    [ "$skb" -gt 1024 ] && printf '%s\t%s\t%s\t%s\n' 1 "$skb" \
      "Unavailable iOS simulators ($(wc -l < "$TMP/deadsims" | tr -d ' '))" "@SIMS" >> "$PLAN"
  fi
fi

# leftovers from apps that are no longer installed
check_orphan() {   # app-name  /Applications/Foo.app  path…
  local name="$1" app="$2"; shift 2
  [ -e "$app" ] && return 0
  for p in "$@"; do add 1 "Leftovers: $name (uninstalled)" "$p"; done
}
check_orphan "Cursor"  "/Applications/Cursor.app"  "$HOME/Library/Application Support/Cursor" "$HOME/.cursor"
check_orphan "Atom"    "/Applications/Atom.app"    "$HOME/.atom"
check_orphan "Docker"  "/Applications/Docker.app"  "$HOME/Library/Containers/com.docker.docker"

# ---- TIER 2 : regenerable, but slow to rebuild ------------------------------
add 2 "Chrome on-device AI model"     "$HOME/Library/Application Support/Google/Chrome/OptGuideOnDeviceModel"
add 2 "Dart/Flutter package cache"    "$HOME/.pub-cache"
add 2 "Gradle wrapper distributions"  "$HOME/.gradle/wrapper"
add 2 "VS Code workspace storage"     "$HOME/Library/Application Support/Code/User/workspaceStorage"
add 2 "VS Code file history"          "$HOME/Library/Application Support/Code/User/History"
add 2 "CocoaPods cache"               "$HOME/Library/Caches/CocoaPods"
add 2 "Maven repository"              "$HOME/.m2/repository"

# Simulator runtimes other than the newest one per platform (~8-18 GB each).
# Xcode > Settings > Components re-downloads them if you need one back.
if command -v xcrun >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  if running "Simulator.app"; then
    note_skip "Simulator is running — skipped old simulator runtimes."
  else
    xcrun simctl runtime list -j 2>/dev/null | python3 -c '
import json, sys
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
ver = lambda v: tuple(int(x) for x in str(v).split(".") if x.isdigit())
rts = [(k, v) for k, v in d.items() if v.get("state") == "Ready"]
newest = {}
for k, v in rts:
    p = v.get("platformIdentifier", "?")
    if p not in newest or ver(v.get("version")) > ver(newest[p]):
        newest[p] = v.get("version")
for k, v in rts:
    if v.get("version") != newest[v.get("platformIdentifier", "?")]:
        name = v.get("runtimeIdentifier", "").split(".")[-1].split("-")[0] or "sim"
        print("%s\t%d\t%s %s" % (k, int(v.get("sizeBytes", 0)) // 1024, name, v.get("version")))
' > "$TMP/oldruntimes" 2>/dev/null
    while IFS=$'\t' read -r id kb name; do
      [ -n "${id:-}" ] && [ "${kb:-0}" -gt 1024 ] && printf '%s\t%s\t%s\t%s\n' 2 "$kb" \
        "Simulator runtime $name (older)" "@RUNTIME:$id" >> "$PLAN"
    done < "$TMP/oldruntimes"
  fi
fi
NM="$TMP/nodemods"; : > "$NM"
for root in "${PROJECT_DIRS[@]}"; do
  [ -d "$root" ] && find "$root" -type d -name node_modules -prune -print >> "$NM" 2>/dev/null
done
if [ -s "$NM" ]; then
  nkb=0; while IFS= read -r d; do nkb=$(( nkb + $(kb_of "$d") )); done < "$NM"
  [ "$nkb" -gt 1024 ] && printf '%s\t%s\t%s\t%s\n' 2 "$nkb" \
    "node_modules ($(wc -l < "$NM" | tr -d ' ') projects)" "@NODEMODULES" >> "$PLAN"
fi

# ---- TIER 3 : real data behind it -------------------------------------------
if running "qemu-system"; then
  note_skip "Android emulator is running — skipped its AVD disk images."
else
  add 3 "Android emulator AVDs"       "$HOME/.android/avd"
fi
add 3 "PlatformIO toolchains"         "$HOME/.platformio/packages"
# erases the installed apps and data inside every simulator (devices stay)
if command -v xcrun >/dev/null 2>&1; then
  if running "Simulator.app"; then
    note_skip "Simulator is running — skipped erasing simulator device data."
  else
    # minus the unavailable ones — tier 1 already counts those
    sdkb=$(( $(kb_of "$HOME/Library/Developer/CoreSimulator/Devices") - ${skb:-0} ))
    [ "${sdkb:-0}" -gt 1048576 ] && printf '%s\t%s\t%s\t%s\n' 3 "$sdkb" \
      "Simulator device data (erase all)" "@SIMERASE" >> "$PLAN"
  fi
fi
for app in Notion Postman Slack; do
  if running "$app"; then
    note_skip "$app is running — skipped its cached data (quit it and re-run)."
  else
    add 3 "$app cached web data"      "$HOME/Library/Application Support/$app/Partitions"
  fi
done
if running "Google Chrome"; then
  note_skip "Chrome is running — skipped its site data (quit Chrome and re-run)."
else
  for prof in "$HOME/Library/Application Support/Google/Chrome/"*/; do
    case "$(basename "$prof")" in
      Default|Profile*) 
        add 3 "Chrome $(basename "$prof") — service workers" "${prof}Service Worker"
        add 3 "Chrome $(basename "$prof") — IndexedDB"       "${prof}IndexedDB" ;;
    esac
  done
fi

# ---------- root cause: is an aerial screen saver still configured? ----------
AERIALS=$(aerials_count)
if [ "${AERIALS:-0}" -gt 0 ]; then
  note_skip "Screen saver plays Apple Aerial video ($AERIALS slot(s)) — that is what"
  note_skip "  refills the caches within minutes of deleting them. See below."
fi

# ---------- report -----------------------------------------------------------
if [ ! -s "$PLAN" ]; then
  echo ""; echo "${grn}Nothing worth cleaning — you're already tidy.${rst}"; echo ""; exit 0
fi

sort -k1,1n -k2,2nr -o "$PLAN" "$PLAN"
echo ""
printf '%s\n' "${bold}Found the following:${rst}"
cur=""; grand=0
while IFS=$'\t' read -r tier kb label path; do
  if [ "$tier" != "$cur" ]; then
    cur="$tier"; sub=$(awk -F'\t' -v t="$tier" '$1==t{s+=$2} END{print s+0}' "$PLAN")
    case "$tier" in
      1) hdr="${grn}TIER 1${rst}  regenerates itself — safe" ;;
      2) hdr="${ylw}TIER 2${rst}  regenerates, but costs re-download time" ;;
      3) hdr="${red}TIER 3${rst}  real data behind it" ;;
    esac
    printf "\n  %s   ${bold}%s${rst}\n" "$hdr" "$(human "$sub")"
    printf '  %s\n' "$(printf '%.0s─' $(seq 1 62))"
  fi
  printf '    %-42s %10s\n' "$(echo "$label" | cut -c1-42)" "$(human "$kb")"
  grand=$(( grand + kb ))
done < "$PLAN"
printf "\n  %-42s ${bold}%10s${rst}\n" "TOTAL RECOVERABLE" "$(human "$grand")"
[ -n "$skipped_notes" ] && { echo ""; printf "$skipped_notes"; }

# ---------- read-only: where "System Data" lives ------------------------------
apfs_role_kb() {   # role name -> KB consumed by that APFS volume
  diskutil apfs list 2>/dev/null | awk -v r="($1)" '
    index($0, "(Role)") { cur = ($NF == r) }
    cur && /Capacity Consumed/ { for (i = 1; i <= NF; i++) if ($i == "B") { printf "%d", $(i-1) / 1024; exit } }'
}
sysrow() { [ "${2:-0}" -gt 1024 ] && printf '    %-42s %10s\n' "$1" "$(human "$2")"; return 0; }
echo ""
printf '  %sSystem Data breakdown%s %s(info only — nothing here is deleted)%s\n' "$bold" "$rst" "$dim" "$rst"
printf '  %s\n' "$(printf '%.0s─' $(seq 1 62))"
[ -d "$USER_VF" ] && sysrow "Per-user temp + caches (/var/folders)" "$(kb_of "$USER_VF")"
sysrow "Preboot volume (macOS, not removable)" "$(apfs_role_kb Preboot)"
sysrow "VM volume (swap / sleep image)"        "$(apfs_role_kb VM)"
if command -v xcrun >/dev/null 2>&1; then
  rtkb=$(xcrun simctl runtime list -j 2>/dev/null | python3 -c '
import json, sys
try: print(sum(int(v.get("sizeBytes", 0)) for v in json.load(sys.stdin).values()) // 1024)
except Exception: print(0)' 2>/dev/null)
  sysrow "Simulator runtimes (all)"            "${rtkb:-0}"
fi
sysrow "Simulator devices"                     "$(kb_of "$HOME/Library/Developer/CoreSimulator")"
sysrow "Chrome profile (your browser data)"    "$(kb_of "$HOME/Library/Application Support/Google/Chrome")"

echo ""
echo "  ${dim}Free now: $(human "$(free_kb)")${rst}"
echo ""

if [ "${AERIALS:-0}" -gt 0 ]; then
  printf '  %s%sWhy the aerial videos keep coming back%s\n' "$bold" "$ylw" "$rst"
  printf '  %s\n' "$(printf '%.0s─' $(seq 1 62))"
  cat <<'TXT'
    Your screen saver streams Apple's Aerial 4K videos and caches them on
    disk. Set to "Shuffle All Aerials" it pulls every aerial Apple offers —
    about 47 GB — and keeps pulling as it rotates, which is why clearing the
    caches on its own only buys a few minutes.

    The fix that lasts is to point the screen saver at a still image. This
    script will do it (per-user, no sudo, previous config backed up first),
    or set it yourself in System Settings > Screen Saver — avoiding
    Landscape, Cityscape, Underwater and Earth, which are all aerials.
TXT
  echo ""
fi

if [ "$SCAN_ONLY" -eq 1 ]; then
  echo "${dim}--scan given, nothing deleted and no settings changed.${rst}"
  [ "${AERIALS:-0}" -gt 0 ] && \
    echo "${dim}Run ./cleanup.sh --fix-wallpaper to disable the aerials only.${rst}"
  echo ""; exit 0
fi

# ---------- delete -----------------------------------------------------------
before=$(free_kb); did_any=0

# Do this first: clearing the video caches while an aerial screen saver is
# still configured just starts the downloads again, sometimes before this
# script has even finished running.
if [ "${AERIALS:-0}" -gt 0 ] && [ "$FIX_WP" != "never" ]; then
  do_fix=0
  if [ "$FIX_WP" = "force" ]; then
    do_fix=1
  else
    echo ""
    printf "  Point the screen saver at a still image instead of Aerial video? [Y/n] "
    read -r ans </dev/tty || ans=y
    case "${ans:-y}" in [Nn]*) ;; *) do_fix=1 ;; esac
  fi
  if [ "$do_fix" -eq 1 ]; then
    echo ""; echo "  ${bold}Disabling the Apple Aerial screen saver…${rst}"
    disable_aerials || true
    echo "    ${dim}undo any time with: $0 --restore-wallpaper${rst}"
  else
    echo "    ${dim}left as-is — expect the video caches to refill${rst}"
  fi
fi

# delete_one LABEL PATH -- performs the deletion for a single plan row
delete_one() {
  local label="$1" path="$2"
  case "$path" in
    @BUILDS)      tr '\n' '\0' < "$BUILDS" | xargs -0 rm -rf 2>/dev/null ;;
    @NODEMODULES) tr '\n' '\0' < "$NM" | xargs -0 rm -rf 2>/dev/null ;;
    @SIMS)        xcrun simctl delete unavailable >/dev/null 2>&1 ;;
    @TMPBUILDS)   tr '\n' '\0' < "$TMP/tmpbuilds" | xargs -0 rm -rf 2>/dev/null ;;
    @RUNTIME:*)   xcrun simctl runtime delete "${path#@RUNTIME:}" >/dev/null 2>&1 ;;
    @SIMERASE)    xcrun simctl shutdown all >/dev/null 2>&1
                  xcrun simctl erase all    >/dev/null 2>&1 ;;
    @SIMCACHES)   if sudo -n true 2>/dev/null; then
                    sudo find "$SIM_CACHES" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null
                  else
                    printf '    %s %s\n' "${ylw}!${rst}" "$label — needs sudo, run:"
                    printf '      %ssudo rm -rf "%s"/*%s\n' "$dim" "$SIM_CACHES" "$rst"
                    return 0
                  fi ;;
    @SYSAERIALS)  if sudo -n true 2>/dev/null; then
                    sudo find "$SYS_AERIALS" -name '*.mov' -delete 2>/dev/null
                  else
                    printf '    %s %s\n' "${ylw}!${rst}" "$label — needs sudo, run:"
                    printf '      %ssudo find "%s" -name "*.mov" -delete%s\n' \
                      "$dim" "$SYS_AERIALS" "$rst"
                    return 0
                  fi ;;
    *)            if [ "$label" = "User caches" ] || [ "$label" = "User logs" ] \
                     || [ "$label" = "Trash" ] \
                     || [ "$label" = "Chrome code-sign clones" ]; then
                    find "$path" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null
                  else
                    rm -rf "$path" 2>/dev/null
                  fi ;;
  esac
  printf '    %s %s\n' "${grn}✓${rst}" "$label"
}

purge() {  # tier -> delete everything registered under it
  local tier="$1"
  while IFS=$'\t' read -r t kb label path; do
    [ "$t" = "$tier" ] || continue
    delete_one "$label" "$path"
  done < "$PLAN"
}

# Interactive picker: choose individual items instead of whole tiers.
pick_and_purge() {
  local -a P_T=() P_KB=() P_LBL=() P_PATH=() P_SEL=()
  local t kb label path i n ans tok lo hi total

  while IFS=$'\t' read -r t kb label path; do
    [ -n "${t:-}" ] || continue
    wants "$t" || continue
    P_T[${#P_T[@]}]="$t"; P_KB[${#P_KB[@]}]="$kb"
    P_LBL[${#P_LBL[@]}]="$label"; P_PATH[${#P_PATH[@]}]="$path"
    P_SEL[${#P_SEL[@]}]=1
  done < "$PLAN"

  n=${#P_T[@]}
  if [ "$n" -eq 0 ]; then echo "  nothing to clean"; return 0; fi

  while :; do
    total=0
    echo ""
    printf '  %-2s %-3s %-5s %-10s %s\n' "#" "" "TIER" "SIZE" "ITEM"
    i=0
    while [ "$i" -lt "$n" ]; do
      if [ "${P_SEL[$i]}" -eq 1 ]; then
        printf '  %2d %s[x]%s %-5s %-10s %s\n' "$(( i + 1 ))" "$grn" "$rst" "${P_T[$i]}" "$(human "${P_KB[$i]}")" "${P_LBL[$i]}"
        total=$(( total + ${P_KB[$i]} ))
      else
        printf '  %2d %s[ ]%s %-5s %-10s %s%s%s\n' "$(( i + 1 ))" "$dim" "$rst" "${P_T[$i]}" "$(human "${P_KB[$i]}")" "$dim" "${P_LBL[$i]}" "$rst"
      fi
      i=$(( i + 1 ))
    done
    printf '\n  %sselected: %s%s\n' "$bold" "$(human "$total")" "$rst"
    printf '  %s1 3 5 or 2-6 toggle · a all · n none · d delete · q quit%s\n' "$dim" "$rst"
    printf '  > '
    read -r ans </dev/tty || ans=q
    case "$ans" in
      q|Q) echo "  cancelled"; return 0 ;;
      a|A) i=0; while [ "$i" -lt "$n" ]; do P_SEL[$i]=1; i=$(( i + 1 )); done ;;
      n|N) i=0; while [ "$i" -lt "$n" ]; do P_SEL[$i]=0; i=$(( i + 1 )); done ;;
      d|D) break ;;
      *)
        for tok in $(printf '%s' "$ans" | tr ',' ' '); do
          case "$tok" in
            *-*) lo=${tok%%-*}; hi=${tok##*-} ;;
            *)   lo=$tok; hi=$tok ;;
          esac
          case "$lo$hi" in *[!0-9]*) continue ;; esac
          [ "$lo" -ge 1 ] 2>/dev/null || continue
          [ "$hi" -le "$n" ] 2>/dev/null || continue
          i=$lo
          while [ "$i" -le "$hi" ]; do
            if [ "${P_SEL[$(( i - 1 ))]}" -eq 1 ]; then P_SEL[$(( i - 1 ))]=0; else P_SEL[$(( i - 1 ))]=1; fi
            i=$(( i + 1 ))
          done
        done ;;
    esac
  done

  total=0; i=0
  while [ "$i" -lt "$n" ]; do
    [ "${P_SEL[$i]}" -eq 1 ] && total=$(( total + ${P_KB[$i]} ))
    i=$(( i + 1 ))
  done
  if [ "$total" -eq 0 ]; then echo "  nothing selected"; return 0; fi

  printf '\n  Delete %s%s%s of selected items? [y/N] ' "$bold" "$(human "$total")" "$rst"
  read -r ans </dev/tty || ans=n
  case "$ans" in [Yy]*) ;; *) echo "  cancelled"; return 0 ;; esac

  echo ""; echo "  ${bold}Cleaning selected…${rst}"
  i=0
  while [ "$i" -lt "$n" ]; do
    [ "${P_SEL[$i]}" -eq 1 ] && delete_one "${P_LBL[$i]}" "${P_PATH[$i]}"
    i=$(( i + 1 ))
  done
  did_any=1
}

if [ "$PICK" -eq 1 ]; then
  pick_and_purge
fi

for tier in 1 2 3; do
  [ "$PICK" -eq 1 ] && break
  grep -q "^$tier	" "$PLAN" || continue
  wants "$tier" || continue
  sub=$(awk -F'\t' -v t="$tier" '$1==t{s+=$2} END{print s+0}' "$PLAN")
  if [ "$ASSUME_YES" -eq 0 ]; then
    echo ""
    printf "  Delete ${bold}TIER %s${rst} (%s)? [y/N] " "$tier" "$(human "$sub")"
    read -r ans </dev/tty || ans=n
    case "$ans" in [Yy]*) ;; *) echo "    ${dim}skipped${rst}"; continue ;; esac
  fi
  echo ""; echo "  ${bold}Cleaning tier ${tier}…${rst}"
  purge "$tier"; did_any=1
done

# command-driven cleanups (tier 1 only, safe)
if wants 1 && [ "$did_any" -eq 1 ]; then
  echo ""; echo "  ${bold}Package manager caches…${rst}"
  command -v npm  >/dev/null 2>&1 && { npm cache clean --force >/dev/null 2>&1; echo "    ${grn}✓${rst} npm cache"; }
  command -v pip3 >/dev/null 2>&1 && { pip3 cache purge      >/dev/null 2>&1; echo "    ${grn}✓${rst} pip cache"; }
  command -v brew >/dev/null 2>&1 && { brew cleanup --prune=all >/dev/null 2>&1; echo "    ${grn}✓${rst} Homebrew cache"; }
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    docker system prune -f --volumes >/dev/null 2>&1; echo "    ${grn}✓${rst} Docker (dangling images/volumes)"
  fi
  qlmanage -r cache >/dev/null 2>&1
  # Prune cloud-synced and network trees before matching. Walking them blocks on
  # the file provider (Google Drive, iCloud, Dropbox, OneDrive) for hours, and a
  # -delete inside one would propagate the deletion to the cloud for every device.
  # -xdev keeps the walk on the boot volume.
  find "$HOME" -xdev \
       \( -path "$HOME/Library/CloudStorage" \
          -o -path "$HOME/Library/Mobile Documents" \
          -o -path "$HOME/Library/Containers" \
          -o -path "$HOME/Library/Group Containers" \
          -o -name "node_modules" \
          -o -name ".git" \
          -o -name ".Trash" \
          -o -name "Dropbox" \
          -o -name "OneDrive*" \
          -o -name "*.photoslibrary" \
          -o -name "*.sparsebundle" -o -name "*.sparseimage" -o -name "*.dmg" \
          -o -name "*.pvm" -o -name "*.hdd" -o -name "*.vmwarevm" -o -name "*.vmdk" \
          -o -name "*.vdi" -o -name "*.vbox*" -o -name "*.utm" -o -name "*.qcow2" \
          -o -name "VirtualBox VMs" -o -name "Parallels" -o -name "Virtual Machines*" \
          -o -name "DeveloperDiskImages" \
       \) -prune -o \
       -name ".DS_Store" -type f -print0 2>/dev/null > "$TMP/dsfiles"
  # NOT -delete: it implies -depth, which silently disables every -prune above
  # and sends the walk into Google Drive / iCloud. Delete via xargs instead.
  dscount=$(tr -dc '\0' < "$TMP/dsfiles" | wc -c | tr -d " ")
  xargs -0 rm -f < "$TMP/dsfiles" 2>/dev/null
  echo "    ${grn}✓${rst} .DS_Store files removed: ${dscount:-0}"
  echo "    ${grn}✓${rst} QuickLook thumbnails + .DS_Store files"
fi

# ---------- result -----------------------------------------------------------
after=$(free_kb); freed=$(( after - before ))
echo ""
printf '  %s\n' "$(printf '%.0s─' $(seq 1 62))"
if [ "$freed" -gt 0 ]; then
  echo "  ${bold}${grn}Freed $(human "$freed")${rst}   free space now $(human "$after")"
else
  echo "  ${bold}Done.${rst}   free space now $(human "$after")"
fi
echo "  ${dim}Some space may take a minute to show up while apps release files.${rst}"
echo ""

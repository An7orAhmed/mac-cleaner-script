# cleanup.sh — macOS disk cleaner

A single script that finds out where your disk space went, especially the
mysterious **"System Data"** in *System Settings → General → Storage*. It tells
you what is safe to delete and deletes only what you pick.

- macOS only. **No sudo needed.** Anything owned by root gets a printed
  `sudo` command that you can run yourself.
- Nothing is deleted without showing you the list and asking first.
- Two ways to use it:
  - an **interactive explorer** (the default)
  - a **classic tier cleaner** for quick or scripted runs

---

## Contents

1. [Quick start](#quick-start)
2. [Requirements](#requirements)
3. [The explorer (default)](#the-explorer-default)
4. [The classic tier cleaner](#the-classic-tier-cleaner)
5. [What it can clean](#what-it-can-clean)
6. [Understanding "System Data"](#understanding-system-data)
7. [Aerial wallpaper fix](#aerial-wallpaper-fix)
8. [Safety rules](#safety-rules)
9. [All options](#all-options)
10. [Recipes](#recipes)
11. [Troubleshooting](#troubleshooting)
12. [Customising](#customising)

---

## Quick start

```bash
cd ~/Public/Software
chmod +x cleanup.sh          # once
./cleanup.sh                 # opens the interactive explorer
```

1. Wait for the scan. It takes 30–90 seconds, and cloud drives are skipped.
2. Move with `↑` `↓` and read the advice panel at the bottom.
3. Press `space` to mark items. `a` marks every **SAFE** item in view.
4. Press `d`, check the list, then press `y` to delete or `t` to move to Trash.
5. Press `q` to quit. The script prints how much space was freed.

To look without any risk, use `./cleanup.sh --scan`. It reports only and never
deletes anything.

---

## Requirements

| Needs | Why | Installed automatically? |
|---|---|---|
| macOS (Apple Silicon or Intel) | uses `du`, `diskutil`, `xcrun`, `pgrep`, `lsof` | built in |
| `python3` with `curses` | the explorer UI and the wallpaper fix | **yes**, see below |
| Xcode / `xcrun` | simulator checks | optional; skipped if missing |
| Homebrew, npm, pip, Docker | package-cache cleanup | optional; skipped if missing |

The explorer uses only Python's standard library, so no `pip install` is ever
needed. If `python3` is missing or broken, the script installs it before the
explorer starts:

1. With `brew install python3`, if Homebrew is installed.
2. Otherwise with Apple's **Command Line Tools** installer (`xcode-select --install`).
   Press Enter in the terminal when the installer finishes.

---

## The explorer (default)

```bash
./cleanup.sh                 # same as ./cleanup.sh --explore
./cleanup.sh --min 500M      # also list folders down to 500 MB (default 1G)
```

The explorer scans these places:

- your home folder
- your per-user temp folder (`/var/folders/…`)
- `/Library/Developer`
- `/Library/Application Support`
- `/Library/Caches`
- `/Applications`
- `/opt`
- `/usr/local`

It then lists every large folder, **biggest first**, with a safety rating and
advice for each.

### The screen

```
 cleanup explore │ free 236.9 GB │ marked 2 · 7.6 GB │ filter: all │ sort: size
 Large folders (≥ 1.0 GB), biggest first
      SIZE  RATING  PATH
 [ ]   9.2 GB  RISKY   /Applications/microchip
 [x]   4.0 GB  REGEN   ~/Library/Application Support/Google/Chrome/OptGuideOnDeviceModel
 [x]   3.6 GB  REGEN   ~/.pub-cache
  ·    3.5 GB  KEEP    /opt/homebrew
  ·    3.1 GB  ?       ~/Library  (other contents)
──────────────────────────────────────────────────────────────────────────────
 ~/.pub-cache
 REGEN  Safe, but costs a re-download or rebuild
 Dart/Flutter packages. `flutter pub get` restores them.
 ↑↓ move  space mark  → open  ← back  a all SAFE  f filter  d delete  r rescan  ? help  q quit
```

- **`[ ]` / `[x]`**: can be marked / is marked.
- **`·`**: can't be marked. This covers KEEP items, top-level folders and
  "other contents" rows. Press `space` on one to see why.
- **"(other contents)"**: space inside that folder spread over items smaller
  than the threshold. Open it with `→` to pick items inside.
- **The bottom panel** shows the full path, the rating and what to do about
  the item.

### Keys

| Key | Action |
|---|---|
| `↑` `↓` / `j` `k` | move |
| `PgUp` `PgDn`, `Home` `End` / `g` `G` | jump |
| `space` | mark / unmark (then moves down) |
| `a` | mark every **SAFE** item in the current view |
| `n` | clear all marks |
| `→` / `Enter` / `l` | open the folder: shows its sub-folders **and files ≥ 1 MB** |
| `←` / `Backspace` / `h` | go back |
| `f` | filter: all → SAFE → REGEN → RISKY → KEEP → ? |
| `s` | sort by size / name |
| `o` | reveal in Finder |
| `d` | delete marked items (asks first) |
| `r` | rescan everything |
| `?` | help screen |
| `q` | quit. Nothing is deleted unless you confirmed it. |

### Ratings

| Rating | Meaning | Markable? | Confirm with |
|---|---|---|---|
| **SAFE** | Regenerates automatically: caches, logs, build output, stale copies | yes | `y` |
| **REGEN** | Safe, but costs a re-download or rebuild next time | yes | `y` |
| **RISKY** | Real data: app data, emulators, personal files, apps | yes | `Y` (capital) |
| **KEEP** | Don't delete directly; the advice says how to shrink it properly | **no** | — |
| **?** | Not in the rule list; open it and judge by contents | yes | `Y` (capital) |

Extra hints in the advice panel:

- **Leftover app data.** For folders in `~/Library/Application Support`, if no
  matching `.app` is installed, the advice adds *"may be left over"*. That is a
  hint, not proof, because some folders are named after the company rather than
  the app.
- **Python virtualenvs.** Any folder containing `pyvenv.cfg` is recognised as a
  virtualenv, wherever it lives.
- **Cache-like names.** Unknown folders with *cache*, *tmp*, *temp* or *log* in
  their name get a "probably safe, check first" hint.

### Deleting

Pressing `d` shows every marked item with its size and rating, plus the total.
You then choose:

| Key | Result |
|---|---|
| `y` | delete permanently. Needs `Y` if any item is RISKY or `?`. |
| `t` | move to `~/.Trash` (undoable). The space is freed only when you empty the Trash. |
| anything else | cancel |

Marking a folder and something inside it counts the size only once.

A results window then lists each item:

| Mark | Meaning |
|---|---|
| `✓` | deleted, with the space freed |
| `!` | skipped: the app is running, it needs sudo, or it was only partly deleted |
| `x` | error |

When you quit, the script prints the total freed and any `sudo` commands for
root-owned items.

---

## The classic tier cleaner

For a quick, non-browsing cleanup, or for scripting:

```bash
./cleanup.sh --classic       # scan, report, then offer to delete Tier 1
./cleanup.sh --scan          # report only, nothing deleted, no settings changed
./cleanup.sh --pick          # checklist: toggle individual items, then delete
./cleanup.sh --tier 1,2      # offer the tiers you name
./cleanup.sh --all           # offer tiers 1, 2 and 3
./cleanup.sh --all --yes     # no prompts at all (careful)
```

Everything it finds is sorted into three tiers:

| Tier | What | Cost of deleting |
|---|---|---|
| **1** | caches and build output that regenerate automatically | none; no settings, projects or logins lost |
| **2** | regenerable, but re-downloaded or re-indexed on next use | time and bandwidth |
| **3** | real data: emulators, app web data, browser site data | may lose emulator state, offline data, cached logins |

Without `--yes`, each tier is confirmed separately (`[y/N]`).

### `--pick` checklist

```
  #     TIER  SIZE       ITEM
   1 [x] 1     6.8 GB     Unavailable iOS simulators (11)
   2 [x] 1     413 MB     User caches
   3 [x] 2     4.0 GB     Chrome on-device AI model
  selected: 11.2 GB
  1 3 5 or 2-6 toggle · a all · n none · d delete · q quit
```

Type numbers or ranges to toggle items. `d` deletes the selected items (after
one more `y`), and `q` cancels.

### Extra Tier-1 cleanups

After any Tier-1 delete, these extra cleanups run:

- `npm cache clean --force`
- `pip3 cache purge`
- `brew cleanup --prune=all`
- `docker system prune -f --volumes` (only if Docker is running)
- reset the QuickLook thumbnail cache
- remove `.DS_Store` files in your home folder. Cloud drives, VM images, Photos
  libraries, `.git` and `node_modules` are skipped.

---

## What it can clean

### Classic tiers

**Tier 1: regenerates by itself**

| Item | Path |
|---|---|
| Apple Aerial wallpaper videos | `~/Library/Application Support/com.apple.wallpaper/aerials/videos` |
| Aerial videos, system-wide *(sudo)* | `/Library/Application Support/com.apple.idleassetsd/Customer/4KSDR240FPS` |
| Wallpaper partial downloads / agent cache | `~/Library/Containers/com.apple.wallpaper.*` |
| **Chrome code-sign clones** | `/var/folders/…/X/com.google.Chrome.code_sign_clone` |
| **Leftover `build-*` temp dirs** | `/var/folders/…/T/build-*` (idle > 1 h, not open by any process) |
| **CoreSimulator caches** *(sudo)* | `/Library/Developer/CoreSimulator/Caches` |
| Gradle build cache + daemon logs | `~/.gradle/caches`, `~/.gradle/daemon` |
| Dart analyzer cache | `~/.dartServer` |
| Xcode DerivedData, Archives | `~/Library/Developer/Xcode/…` |
| User caches, logs, Trash | `~/Library/Caches`, `~/Library/Logs`, `~/.Trash` (contents only) |
| VS Code / VSCodium caches | `…/Code/{Cache,CachedData,GPUCache,…}` |
| Project build output | `build/`, `.dart_tool/`, `.next/` under `PROJECT_DIRS` |
| Unavailable iOS simulators | via `xcrun simctl delete unavailable` |
| Leftovers of uninstalled Cursor / Atom / Docker | their support folders |

**Tier 2: regenerable, slower to rebuild**

| Item | Path / method |
|---|---|
| Chrome on-device AI model | `…/Google/Chrome/OptGuideOnDeviceModel` |
| Dart/Flutter packages | `~/.pub-cache` |
| Gradle wrapper distributions | `~/.gradle/wrapper` |
| VS Code workspace storage, file history | `…/Code/User/workspaceStorage`, `…/History` |
| CocoaPods cache, Maven repository | `~/Library/Caches/CocoaPods`, `~/.m2/repository` |
| `node_modules` | under `PROJECT_DIRS` |
| **Older simulator runtimes** | all but the newest per platform, via `xcrun simctl runtime delete` |

**Tier 3: real data behind it**

| Item | Path / method |
|---|---|
| Android emulator AVDs | `~/.android/avd` (skipped while an emulator runs) |
| PlatformIO toolchains | `~/.platformio/packages` |
| Notion / Postman / Slack web data | `…/<App>/Partitions` (skipped while the app runs) |
| Chrome service workers + IndexedDB | per profile (skipped while Chrome runs) |
| **Simulator device data** | `xcrun simctl erase all` (listed only if > 1 GB) |

### Explorer rules (highlights)

The explorer knows about **80+ folder patterns**. The main groups:

| Group | Examples | Rating |
|---|---|---|
| Caches & logs | `~/Library/Caches`, `~/Library/Logs`, `~/.cache`, `~/.npm`, Trash | SAFE |
| Per-user temp | Chrome code-sign clones, `build-*` dirs, `/var/folders/…/C/*` | SAFE |
| | other temp in `T/`, `X/` | REGEN |
| Build output | `build`, `.dart_tool`, `.next`, `.gradle`, `.turbo`, `.expo` in projects | SAFE |
| | `dist`, `target`, `out` | REGEN |
| Package stores | `node_modules`, venvs / `site-packages`, `Pods`, `~/.pub-cache`, `~/.m2`, pnpm, Cargo, Go | REGEN |
| Xcode | DerivedData, DeviceSupport | SAFE |
| | Archives | RISKY |
| | simulator runtimes, Command Line Tools | KEEP |
| Simulators | CoreSimulator caches | SAFE |
| | devices | RISKY |
| Android | SDK system images, NDK versions | REGEN |
| | emulator AVDs | RISKY |
| | the SDK itself | KEEP |
| Flutter | `flutter/bin/cache` | REGEN |
| Editors | VS Code / Cursor / Antigravity caches | SAFE |
| | workspaceStorage, History, extensions | REGEN |
| Browsers | Chrome cache | SAFE |
| | AI model | REGEN |
| | service workers, IndexedDB | RISKY |
| | the profile itself | KEEP |
| Apple | Aerial videos | SAFE |
| | mobile assets | REGEN |
| | Spotlight index, Biome, Mail, Messages, Photos library | KEEP |
| App data | `Application Support/*`, `Containers/*`, Docker disk image | RISKY |
| AI models | `~/.cache/huggingface`, `~/.ollama/models`, LM Studio | REGEN |
| Personal | Downloads, Documents, Desktop, Pictures, Movies, Music, Public | RISKY |
| | installers (`.dmg`/`.pkg`/`.iso`) in Downloads | REGEN |
| Apps & packages | `/Applications/*` | RISKY |
| | Homebrew (`/opt/homebrew`, `/usr/local`) | KEEP |
| Cloud & git | iCloud Drive, CloudStorage, `.git` | KEEP |

---

## Understanding "System Data"

macOS lumps a lot into "System Data". These are the usual culprits, and how
the script handles each:

| Culprit | Typical size | How the script handles it |
|---|---|---|
| Chrome code-sign clones | 2 GB per copy; 31 GB seen | Tier 1 / explorer SAFE (quit Chrome first) |
| iOS simulator runtimes | 8–18 GB each | Tier 2 removes all but the newest |
| Simulator devices | several GB | Tier 1 removes unavailable ones; Tier 3 erases all |
| Abandoned build temp (e.g. a Homebrew build) | 1–10 GB | Tier 1 / explorer SAFE |
| Aerial screen-saver videos | up to ~47 GB | Tier 1, plus the [wallpaper fix](#aerial-wallpaper-fix) |
| Preboot volume | ~10 GB | **not removable**; shown for information only |
| VM volume (swap / sleep image) | 1–10 GB | not removable; shrinks after a reboot |

The classic report ends with a read-only **System Data breakdown** that shows
these numbers, so you can see what is left after cleaning.

---

## Aerial wallpaper fix

Apple's Aerial screen savers stream 4K video and cache it on disk. With
**"Shuffle All Aerials"** selected they can pull ~47 GB and keep downloading,
so deleting the cache alone buys you a few minutes at most.

```bash
./cleanup.sh --fix-wallpaper      # point the screen saver at a still image, then exit
./cleanup.sh --restore-wallpaper  # undo it from the newest backup
./cleanup.sh --no-fix-wallpaper   # clean caches but leave the setting alone
```

- The classic run detects this setting and offers the fix before clearing the
  video caches.
- The current config is backed up to `~/.cleanup-backups/wallpaper/` first.
  If the rewrite fails, the backup is restored.
- The ~41 GB system-wide copy needs sudo. The script prints the command instead
  of asking for your password.

---

## Safety rules

- **Always shows before it deletes.** You see every item and its size, and
  nothing goes without a keypress. RISKY and unknown items need a capital `Y`.
- **Running apps are protected.** Items tied to an app are skipped while it
  runs: Chrome, Simulator, Docker, the Android emulator, Notion, Postman,
  Slack and Google Drive.
- **Folders in use are left alone.** `build-*` temp folders are only offered
  once they have been idle for over an hour and no process has them open.
- **No sudo prompts.** Root-owned items get a printed command instead.
- **Protected folders can't be marked in the explorer:** `~`, `~/Library`,
  `Application Support`, `Containers`, `/Applications`, `/Library`, `/opt`,
  `/usr/local`, the temp roots, and your Documents / Desktop / Downloads /
  Pictures / Movies / Music / Public folders. Open them and pick items inside.
- **Cloud drives are never walked.** iCloud Drive, Google Drive, Dropbox and
  OneDrive are skipped, so nothing syncs a deletion to your other devices.
- **Build-folder hunting skips real code.** `node_modules` and Python
  `site-packages` are never searched for `build/`, because pip ships real
  source folders named `build`.
- **Some folders are emptied, not removed.** For `Caches`, `Logs`, Trash and
  the Chrome clone folder, only the contents are deleted and the folder
  itself stays.
- **Trash option.** In the explorer, `t` moves items to the Trash instead of
  deleting them for good.

---

## All options

| Option | Short | Description |
|---|---|---|
| *(none)* | | interactive explorer; falls back to `--classic` with no terminal |
| `--explore` | `-e` | interactive explorer |
| `--min SIZE` | | explorer threshold, e.g. `500M`, `2G` (default `1G`); implies `--explore` |
| `--classic` | `-c` | tier scan and report, then offer Tier 1 |
| `--scan` | `-n` | report only; deletes nothing and changes no settings |
| `--pick` | `-i` | checklist picker for tier items |
| `--tier LIST` | `-t` | tiers to offer, e.g. `1,3` |
| `--all` | `-a` | offer tiers 1, 2 and 3 |
| `--yes` | `-y` | don't prompt (with `--tier` / `--all`); also applies the wallpaper fix |
| `--fix-wallpaper` | | switch off the Aerial screen saver, then exit |
| `--no-fix-wallpaper` | | never touch the wallpaper setting |
| `--restore-wallpaper` | | restore the newest wallpaper backup, then exit |
| `--help` | `-h` | usage |

---

## Recipes

**"System Data is huge. What is it?"**
```bash
./cleanup.sh --scan          # tier report + System Data breakdown, no changes
./cleanup.sh                 # then browse and delete in the explorer
```

**Safe monthly tidy-up (no thinking required)**
```bash
./cleanup.sh --tier 1 --yes
```

**Free a lot of space fast, but choose each item**
```bash
./cleanup.sh --all --pick
```

**Find big personal files**

Run `./cleanup.sh --min 200M`, press `f` until the filter shows `RISKY`, then
open Downloads or Movies with `→`. Large files appear individually.

**Run from cron / launchd (report only)**
```bash
./cleanup.sh --scan > ~/cleanup-report.txt 2>&1
```

**Clean up after Xcode**

Run `./cleanup.sh --tier 1,2`. This removes unavailable simulators, older
runtimes, DerivedData and simulator caches.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `--explore needs an interactive terminal` | Run it in Terminal/iTerm, not through a pipe. Use `--classic` or `--scan` for scripts. |
| "Make the terminal bigger" | The explorer needs at least 60×14 characters. |
| Item shows `! skipped: X is running` | Quit that app (Cmd+Q) and delete again. |
| Item shows `! needs sudo: …` | Run the printed command yourself if you're sure. |
| `partly deleted` | Some files are in use or protected. Reboot and retry, or use the sudo command. |
| Space didn't go up after `t` | Items moved to Trash still take space until you empty the Trash. |
| Chrome clones keep coming back | Normal after Chrome updates. Re-run occasionally with Chrome quit. |
| Aerial videos keep coming back | Run `./cleanup.sh --fix-wallpaper`. |
| Scan feels slow | The first run walks your whole home folder (~30–90 s). Later runs are faster thanks to the file cache. |
| python3 install prompt appears | Let it install (Homebrew or Command Line Tools), then the explorer starts. |

---

## Customising

Edit the top of `cleanup.sh`:

```bash
PROJECT_DIRS=( "$HOME/MyWork" )     # where the classic mode hunts for build/ and node_modules
```

Add more folders, for example `( "$HOME/MyWork" "$HOME/Projects" )`.

**Explorer rules** live in the `RULES = [...]` list inside the embedded Python
(search for `RULES =`). Each rule is:

```python
(["glob/pattern", "~/another/*"], RATING, "Advice shown in the panel.", {options})
```

- **`RATING`**: one of `SAFE`, `REGEN`, `RISKY`, `KEEP`.
- **Order**: the first matching rule wins, so put specific rules above general
  ones.
- **Options**:

| Option | Effect |
|---|---|
| `"contents": True` | empty the folder but keep it |
| `"app": "Name"` | refuse while that process runs |
| `"descend": True` | keep looking for big folders inside it |
| `"project": True` | only match outside `~/Library` |

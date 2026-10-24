#!/bin/bash
# mac_storage_audit.sh — READ-ONLY storage audit for macOS (Apple Silicon / Intel).
#
# GUARANTEES
#   - Deletes, moves, renames, or modifies NOTHING. Only du / df / find / stat / ls /
#     tmutil list / mdls / mdfind / sysctl / osascript (capacity query) / git log (read).
#   - Never opens personal documents. The only file *contents* read are:
#       * Ollama manifest JSON (layer sizes)
#       * source code in your protected projects, grep-only, to see which AI models they
#         reference (.env*, keys, certs, lockfiles excluded)
#   - Only files written: the report (~/Projects/storage-audit-claude-<date>.md) and a
#     temp workdir under $TMPDIR that is removed on exit.
#   - Every command in the report is printed as text. NONE are executed.
#
# RUN:   bash mac_storage_audit.sh          (no sudo; expect 5–20 min on a full drive)
# If macOS asks "Terminal would like to access …", Allow or Don't Allow — the report
# records what was denied and which permission is needed. It does not work around it.

set -u
export LC_ALL=C
[ "$(uname -s)" = "Darwin" ] || { echo "This audit is for macOS only." >&2; exit 1; }

H="$HOME"
DATE=$(date +%Y-%m-%d)
OUT="$H/Projects/storage-audit-claude-$DATE.md"
W=$(mktemp -d "${TMPDIR:-/tmp}/storage-audit.XXXXXX") || exit 1
trap 'rm -rf "$W"' EXIT
R="$W/report.md"; ROWS="$W/rows.tsv"; ERR="$W/errors.log"; NOTES="$W/notes.txt"
PROT="$W/protected_projects.txt"; KV="$W/kv.txt"
: > "$R"; : > "$ROWS"; : > "$ERR"; : > "$NOTES"; : > "$KV"
NOW=$(date +%s)
STALE_DAYS=60

# ---------- helpers ----------
log()   { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
p()     { printf '%s\n' "$*" >> "$R"; }
note()  { printf -- '- %s\n' "$*" >> "$NOTES"; }
kv()    { printf '%s\t%s\n' "$1" "${2:-0}" >> "$KV"; }
kvget() { awk -F'\t' -v k="$1" '$1==k{v=$2} END{print v+0}' "$KV"; }
kb()    { [ -e "$1" ] || { echo 0; return; }; du -skx "$1" 2>>"$ERR" | awk 'END{print $1+0}'; }
akb()   { [ -e "$1" ] || { echo 0; return; }; du -skxA "$1" 2>>"$ERR" | awk 'END{print $1+0}'; }
hum()   { awk -v k="${1:-0}" 'BEGIN{ if(k>=1048576) printf "%.2f GB",k/1048576; else if(k>=1024) printf "%.0f MB",k/1024; else printf "%d KB",k }'; }
hb()    { awk -v b="${1:-0}" 'BEGIN{ printf "%.2f GB", b/1073741824 }'; }
mtime() { stat -f '%m' "$1" 2>/dev/null || echo 0; }
e2d()   { [ "${1:-0}" -gt 0 ] 2>/dev/null && date -r "$1" +%Y-%m-%d || echo "?"; }
mdate() { e2d "$(mtime "$1")"; }
days()  { [ "${1:-0}" -gt 0 ] 2>/dev/null && echo $(( (NOW - $1) / 86400 )) || echo 99999; }
tl()    { case "$1" in "$H"|"$H/"*) printf '~%s' "${1#"$H"}";; *) printf '%s' "$1";; esac; }   # display path
qp()    { case "$1" in "$H"|"$H/"*) printf '"$HOME%s"' "${1#"$H"}";; *) printf '"%s"' "$1";; esac; } # command path

# newest file mtime (epoch) inside a dir, depth<=3, ignoring build folders; git commit date wins if newer
lastused() {
  local d="$1" n g
  n=$(find "$d" -maxdepth 3 \( -name node_modules -o -name .git -o -name .next -o -name .venv -o -name venv -o -name dist -o -name build -o -name .turbo \) -prune -o -type f -exec stat -f '%m' {} + 2>/dev/null | sort -rn | head -1)
  g=0; [ -e "$d/.git" ] && g=$(git -C "$d" log -1 --format=%ct 2>/dev/null || echo 0)
  n=${n:-0}; g=${g:-0}; [ "$g" -gt "$n" ] && n=$g
  echo "$n"
}

is_prot() {
  case "$1" in
    "$H/.codex"|"$H/.codex/"*|"$H/.claude"*|"$H/.cursor"|"$H/.cursor/"*|"$H/.nvm"|"$H/.nvm/"*|"$H/.npm-global"|"$H/.npm-global/"*) return 0;;
    "$H/Library/Keychains"*|"$H/Library/Messages"*|"$H/Library/Mail"*|*.photoslibrary|*.photoslibrary/*|"$H/.ssh"*|"$H/.gnupg"*) return 0;;
    "$H/Library/LaunchAgents/com.caldwell."*|"$H/Library/LaunchAgents/com.domcaldwell."*) return 0;;
  esac
  local d
  while IFS= read -r d; do case "$1" in "$d"|"$d/"*) return 0;; esac; done < "$PROT"
  return 1
}
prot_name() { local d; while IFS= read -r d; do case "$1" in "$d"|"$d/"*) printf '%s' "${d##*/}"; return;; esac; done < "$PROT"; }

# add a candidate row. Skips zero sizes and paths nested inside/around an existing row (no double counting).
# fields: kb path lastused category tier action command
add() {
  local k="${1:-0}" path="$2"
  case "$k" in ''|*[!0-9]*) return 0;; esac
  [ "$k" -gt 0 ] || return 0
  if awk -F'\t' -v p="$path" 'index(p"/",$2"/")==1 || index($2"/",p"/")==1 {f=1; exit} END{exit f?0:1}' "$ROWS"; then return 0; fi
  local tier="$5" act="$6" cmd="$7"
  if is_prot "$path" && [ "$tier" != "T3 NEVER" ]; then tier="T3 NEVER"; act="KEEP"; cmd="# protected path — not a candidate"; fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$k" "$path" "$3" "$4" "$tier" "$act" "$cmd" >> "$ROWS"
}
# convenience for regenerable caches
addc() { # path category command [tier]
  local k; k=$(kb "$1"); add "$k" "$1" "$(mdate "$1")" "$2" "${4:-T1 SAFE}" "DELETE" "$3"
}

app_installed() { ls /Applications "$H/Applications" /System/Applications 2>/dev/null | grep -qi -- "$1"; }

GREP_EXCL=(--exclude-dir=node_modules --exclude-dir=.next --exclude-dir=.git --exclude-dir=.venv --exclude-dir=venv --exclude-dir=dist --exclude-dir=build --exclude-dir=.turbo --exclude-dir=__pycache__ --exclude='.env*' --exclude='*.pem' --exclude='*.key' --exclude='*.p12' --exclude='*.lock' --exclude='package-lock.json')
GREP_INC=(--include='*.ts' --include='*.tsx' --include='*.js' --include='*.jsx' --include='*.mjs' --include='*.cjs' --include='*.py' --include='*.json' --include='*.yaml' --include='*.yml' --include='*.toml' --include='*.sh' --include='*.swift' --include='*.rs' --include='*.go')
used_by() { # token -> space-separated protected project names referencing it in source
  local tok="$1" d hits=""
  [ -s "$PROT" ] || { echo ""; return; }
  while IFS= read -r d; do
    grep -rIqiF "${GREP_EXCL[@]}" "${GREP_INC[@]}" -- "$tok" "$d" 2>/dev/null && hits="$hits ${d##*/}"
  done < "$PROT"
  echo "$hits" | sed 's/^ //'
}

# ======================================================================
log "Locating protected projects"
if [ -d "$H/Projects" ]; then
  find "$H/Projects" -maxdepth 3 -type d \( -iname '*content-studio*' -o -iname '*content_studio*' -o -iname '*cutroom*' -o -iname '*dmt*clip*' \) -print -prune 2>>"$ERR" > "$PROT"
else
  note "~/Projects does not exist — report written to ~ instead."; OUT="$H/storage-audit-claude-$DATE.md"
fi
[ -s "$PROT" ] || note "No protected project folders matched (content-studio / cutroom / dmt*clip) under ~/Projects (depth ≤3). Model 'used by' checks are therefore empty — verify names."

p "# Storage Audit — $(scutil --get ComputerName 2>/dev/null || hostname) — $DATE"
p ""
p "> Read-only run. **Nothing was deleted, moved or modified. Every command below is NOT executed** — review each before running it."
p "> macOS $(sw_vers -productVersion 2>/dev/null) · $(uname -m) · sizes = on-disk allocated (\`du -k\`) unless noted · 1 GB = 1024³ bytes."
p "> Protected projects detected: $( [ -s "$PROT" ] && sed "s|^$H|~|" "$PROT" | paste -sd ',' - | sed 's/,/, /g' || echo 'NONE FOUND')"
p ""

# ======================================================================
log "A: disk state"
p "## A. Current disk state"
p ""
p "| Volume | Size | Used | Free | Capacity |"
p "|---|---|---|---|---|"
for v in / /System/Volumes/Data; do
  df -k "$v" 2>/dev/null | awk -v v="$v" 'NR==2{printf "| %s | %.2f GB | %.2f GB | %.2f GB | %s |\n", v,$2/1048576,$3/1048576,$4/1048576,$5}' >> "$R"
done
DATA_USED_KB=$(df -k /System/Volumes/Data 2>/dev/null | awk 'NR==2{print $3+0}')
FREE_KB=$(df -k / 2>/dev/null | awk 'NR==2{print $4+0}')
kv free "$FREE_KB"
CAP=$(osascript -l JavaScript -e 'ObjC.import("Foundation");var ks=["NSURLVolumeTotalCapacityKey","NSURLVolumeAvailableCapacityKey","NSURLVolumeAvailableCapacityForImportantUsageKey","NSURLVolumeAvailableCapacityForOpportunisticUsageKey"];var r=$.NSURL.fileURLWithPath("/").resourceValuesForKeysError($(ks),null);ks.map(function(k){var v=r.objectForKey(k);return (v.isNil&&v.isNil())?0:v.js}).join(" ")' 2>>"$ERR")
read -r C_TOT C_AV C_IMP C_OPP <<< "${CAP:-0 0 0 0}"
p ""
if [ "${C_IMP:-0}" != 0 ]; then
  PURG=$(awk -v a="$C_AV" -v i="$C_IMP" 'BEGIN{d=i-a; if(d<0)d=0; printf "%.0f", d}')
  p "| Metric (APFS container, via NSURL) | Value |"
  p "|---|---|"
  p "| Total capacity | $(hb "$C_TOT") |"
  p "| Free right now (hard) | $(hb "$C_AV") |"
  p "| Available for important usage (free + purgeable) | $(hb "$C_IMP") |"
  p "| **Purgeable (≈ important − free)** | **$(hb "$PURG")** |"
  p "| Available for opportunistic usage | $(hb "$C_OPP") |"
else
  p "_Purgeable query failed (osascript). Check Finder → Get Info on Macintosh HD and compare 'Available' to df Free._"
fi
p ""
SNAPS=$(tmutil listlocalsnapshots / 2>>"$ERR" | grep -c 'com.apple')
p "**Local Time Machine snapshots:** ${SNAPS:-0}"
if [ "${SNAPS:-0}" -gt 0 ]; then
  p '```'; tmutil listlocalsnapshots / 2>/dev/null >> "$R"; p '```'
  p "_APFS does not expose per-snapshot size through tmutil; space returns to df/free after deletion. Not guessed._"
  note "**${SNAPS} local Time Machine snapshot(s)** present. They pin deleted data — deleting caches will NOT free space until these are thinned. Command (NOT executed): \`tmutil thinlocalsnapshots / 999999999999 4\` or per snapshot \`sudo tmutil deletelocalsnapshots <YYYY-MM-DD-HHMMSS>\`."
fi
SWAP=$(sysctl -n vm.swapusage 2>/dev/null)
VM_KB=$(ls -ln /private/var/vm 2>/dev/null | awk '{s+=$5} END{print int(s/1024)}')
p ""
p "**Swap / VM files (/private/var/vm):** $(hum "$VM_KB") on disk — \`$SWAP\`"
kv swap "$VM_KB"
[ "${VM_KB:-0}" -gt 3145728 ] && note "Swap/sleepimage in /private/var/vm = $(hum "$VM_KB"). A reboot with fewer apps open releases it; low disk + heavy swap = risk of kernel-panic/freeze during video renders."
p ""

# ======================================================================
log "Walking home directory (du depth 3) — slowest step, be patient"
du -kx -d 3 -I CloudStorage "$H" 2>>"$ERR" | sort -t$'\t' -k1,1nr > "$W/du3.txt"
HOME_KB=$(awk -F'\t' -v h="$H" '$2==h{print $1+0}' "$W/du3.txt")
kv home "$HOME_KB"

log "Scanning for large files (>50 MB) and build folders"
find -x "$H" \( -path "$H/Library/Keychains" -o -path "$H/Library/Messages" -o -path "$H/Library/Mail" -o -path "$H/Library/CloudStorage" -o -path "$H/Library/Containers/com.apple.mail" -o -path "$H/.ssh" -o -path "$H/.gnupg" -o -path "$H/.Trash" -o -name '*.photoslibrary' \) -prune \
  -o -type d \( -name node_modules -o -name .next -o -name .venv -o -name venv -o -name .turbo \) -exec printf 'D\t%s\n' {} + -prune \
  -o -type d \( -name dist -o -name build \) -exec printf 'd\t%s\n' {} + \
  -o -type f -size +50M -exec stat -f 'F%t%z%t%b%t%m%t%f%t%N' {} + 2>>"$ERR" > "$W/scan.tsv"
# F rows: F size_bytes blocks512 mtime flags path   (flag 0x40000000 = dataless/cloud-only)
awk -F'\t' '$1=="F"' "$W/scan.tsv" | sort -t$'\t' -k2,2nr > "$W/files.tsv"

# ======================================================================
log "Section 2: top dirs / files"
p "## Top 40 directories under ~ (depth ≤3, on-disk)"
p ""
p "_Home total: **$(hum "$HOME_KB")** of $(hum "$DATA_USED_KB") used on the Data volume. Nested rows overlap by design (parent includes children)._"
p ""
p "| # | Size | Last modified | Path |"
p "|---|---|---|---|"
awk -F'\t' -v h="$H" '$2!=h' "$W/du3.txt" | head -40 | while IFS=$'\t' read -r k path; do
  i=$((${i:-0}+1)); printf '| %s | %s | %s | %s |\n' "$i" "$(hum "$k")" "$(mdate "$path")" "$(tl "$path")" >> "$R"
done
p ""
p "## Top 40 single files > 200 MB"
p ""
p "| # | Logical size | On disk | Modified | Cloud-only? | Path |"
p "|---|---|---|---|---|---|"
awk -F'\t' '$2>209715200' "$W/files.tsv" | head -40 | while IFS=$'\t' read -r _ sz bl mt fl path; do
  i=$((${i:-0}+1))
  dl=$(awk -v f="$fl" -v b="$bl" -v s="$sz" 'BEGIN{ if (int(f/1073741824)%2==1) print "yes (dataless)"; else if (b*512 < s*0.5) print "partial/sparse"; else print "no" }')
  printf '| %s | %s | %s | %s | %s | %s |\n' "$i" "$(hum $((sz/1024)))" "$(hum $((bl/2)))" "$(e2d "$mt")" "$dl" "$(tl "$path")" >> "$R"
done
p ""

# ======================================================================
log "Section 3: caches"
p "## Measured detail"
p ""
p "### 3. Regenerable caches"
p ""
# tool-specific first (so generic ~/Library/Caches/<x> rows don't swallow them)
BREW_CACHE=$(command -v brew >/dev/null 2>&1 && brew --cache 2>/dev/null || echo "$H/Library/Caches/Homebrew")
addc "$BREW_CACHE" "Homebrew cache" "brew cleanup --prune=all -s"
PIPC=$(command -v pip3 >/dev/null 2>&1 && pip3 cache dir 2>/dev/null || echo "$H/Library/Caches/pip")
addc "$PIPC" "pip cache" "pip3 cache purge"
NPMC=$(command -v npm >/dev/null 2>&1 && npm config get cache 2>/dev/null || echo "$H/.npm")
addc "$NPMC/_cacache" "npm cache" "npm cache clean --force"
addc "$H/.npm/_npx" "npx cache" "rm -rf $(qp "$H/.npm/_npx")"
addc "$H/Library/Caches/Yarn" "yarn cache" "yarn cache clean"
addc "$H/.yarn/berry/cache" "yarn berry cache" "yarn cache clean --all"
addc "$H/Library/pnpm/store" "pnpm store" "pnpm store prune"
addc "$H/.pnpm-store" "pnpm store" "pnpm store prune"
addc "$H/.bun/install/cache" "bun cache" "bun pm cache rm"
addc "$H/Library/Caches/ms-playwright" "Playwright browsers" "npx playwright uninstall --all" "T2 CONFIRM"
addc "$H/Library/Caches/Cypress" "Cypress binaries" "npx cypress cache clear"
addc "$H/.cache/puppeteer" "Puppeteer browsers" "rm -rf $(qp "$H/.cache/puppeteer")"
addc "$H/.gradle/caches" "Gradle cache" "rm -rf $(qp "$H/.gradle/caches")"
addc "$H/.m2/repository" "Maven repo" "rm -rf $(qp "$H/.m2/repository")"
addc "$H/.cargo/registry" "Cargo registry" "rm -rf $(qp "$H/.cargo/registry")"
addc "$H/Library/Caches/go-build" "Go build cache" "go clean -cache"
addc "$H/go/pkg/mod" "Go module cache" "go clean -modcache"
addc "$H/Library/Caches/CocoaPods" "CocoaPods cache" "pod cache clean --all"
addc "$H/.cache/pre-commit" "pre-commit cache" "pre-commit clean"
addc "$H/.cache/uv" "uv cache" "uv cache clean"
addc "$H/.cache/torch" "PyTorch hub cache" "rm -rf $(qp "$H/.cache/torch")" "T2 CONFIRM"
for c in "$H/.conda/pkgs" "$H/.mamba/pkgs" "$H/miniconda3/pkgs" "$H/anaconda3/pkgs" "$H/miniforge3/pkgs" "$H/mambaforge/pkgs" "$H/opt/anaconda3/pkgs"; do
  addc "$c" "conda/mamba pkgs" "conda clean --all -y"
done
# Xcode / Swift
X="$H/Library/Developer"
addc "$X/Xcode/DerivedData" "Xcode DerivedData" "rm -rf $(qp "$X/Xcode/DerivedData")"
addc "$X/Xcode/iOS DeviceSupport" "Xcode iOS DeviceSupport" "rm -rf $(qp "$X/Xcode/iOS DeviceSupport")"
addc "$X/Xcode/watchOS DeviceSupport" "Xcode watchOS DeviceSupport" "rm -rf $(qp "$X/Xcode/watchOS DeviceSupport")"
addc "$X/CoreSimulator/Caches" "Simulator caches" "rm -rf $(qp "$X/CoreSimulator/Caches")"
k=$(kb "$X/Xcode/Archives");     add "$k" "$X/Xcode/Archives" "$(mdate "$X/Xcode/Archives")" "Xcode Archives" "T2 CONFIRM" "DELETE" "rm -rf $(qp "$X/Xcode/Archives")"
k=$(kb "$X/CoreSimulator/Devices"); add "$k" "$X/CoreSimulator/Devices" "$(mdate "$X/CoreSimulator/Devices")" "iOS Simulators" "T2 CONFIRM" "DELETE" "xcrun simctl delete unavailable   # then: xcrun simctl erase all"
addc "$H/.swiftpm" "SwiftPM" "rm -rf $(qp "$H/.swiftpm")"
addc "$H/Library/Caches/org.swift.swiftpm" "SwiftPM cache" "rm -rf $(qp "$H/Library/Caches/org.swift.swiftpm")"

# Browser caches (Chromium family: per-profile cache dirs + on-device AI model)
for root in "Google/Chrome" "BraveSoftware/Brave-Browser" "Microsoft Edge" "Arc/User Data" "Vivaldi" "Chromium" "com.operasoftware.Opera" "Comet"; do
  B="$H/Library/Application Support/$root"; [ -d "$B" ] || continue
  for prof in "$B"/Default "$B"/Profile* "$B"/"Guest Profile" "$B"/"System Profile"; do
    [ -d "$prof" ] || continue
    for sub in "Cache" "Code Cache" "GPUCache" "Service Worker/CacheStorage" "Service Worker/ScriptCache" "DawnGraphiteCache" "DawnWebGPUCache"; do
      addc "$prof/$sub" "Browser cache ($root)" "rm -rf $(qp "$prof/$sub")   # quit browser first"
    done
  done
  for sub in GrShaderCache ShaderCache GraphiteDawnCache component_crx_cache Crashpad; do
    addc "$B/$sub" "Browser cache ($root)" "rm -rf $(qp "$B/$sub")   # quit browser first"
  done
  if [ -d "$B/OptGuideOnDeviceModel" ]; then
    k=$(kb "$B/OptGuideOnDeviceModel"); kv chrome_ai "$k"
    add "$k" "$B/OptGuideOnDeviceModel" "$(mdate "$B/OptGuideOnDeviceModel")" "Browser on-device AI model" "T2 CONFIRM" "DELETE" "rm -rf $(qp "$B/OptGuideOnDeviceModel")   # disable at chrome://flags/#optimization-guide-on-device-model or it re-downloads"
    [ "$k" -gt 1048576 ] && note "$root has an on-device AI model (Gemini Nano) using $(hum "$k") — silently downloaded, re-downloads unless disabled."
  fi
done
# Electron / app caches in Application Support (Slack, Discord, VS Code, Cursor, Notion, etc.)
for A in "$H/Library/Application Support"/*; do
  [ -d "$A" ] || continue
  n="${A##*/}"
  case "$n" in Google|BraveSoftware|"Microsoft Edge"|Arc|Vivaldi|Chromium|com.operasoftware.Opera|Comet|MobileSync|AddressBook|CallHistoryDB|Knowledge|com.apple.*) continue;; esac
  t="T1 SAFE"; case "$n" in *[Cc]laude*) t="T2 CONFIRM";; esac
  for sub in "Cache" "Code Cache" "GPUCache" "CachedData" "CachedExtensionVSIXs" "Service Worker/CacheStorage" "Crashpad" "logs"; do
    [ -d "$A/$sub" ] && addc "$A/$sub" "App cache ($n)" "rm -rf $(qp "$A/$sub")   # quit $n first" "$t"
  done
done
# generic ~/Library/Caches children
awk -F'\t' -v pre="$H/Library/Caches/" 'index($2,pre)==1 && substr($2,length(pre)+1) !~ /\//' "$W/du3.txt" | while IFS=$'\t' read -r k path; do
  n="${path##*/}"
  case "$n" in com.apple.*|CloudKit|com.apple|FamilyCircle|GeoServices|*.photolibrary*) t="T2 CONFIRM"; c="# managed by macOS — leave unless huge; reboot clears some";;
                *) t="T1 SAFE"; c="rm -rf $(qp "$path")   # quit the app first";; esac
  add "$k" "$path" "$(mdate "$path")" "~/Library/Caches" "$t" "DELETE" "$c"
done
kv lib_caches "$(kb "$H/Library/Caches")"
# ~/.cache children (except AI model stores, handled in section 5)
for c in "$H/.cache"/*; do
  [ -d "$c" ] || continue
  case "${c##*/}" in huggingface|whisper|lm-studio|torch) continue;; esac
  addc "$c" "~/.cache" "rm -rf $(qp "$c")"
done
# per-user temp/cache under /private/var/folders
for c in "$(getconf DARWIN_USER_CACHE_DIR 2>/dev/null)" "$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null)"; do
  [ -n "$c" ] && [ -d "$c" ] || continue
  k=$(kb "$c"); add "$k" "${c%/}" "$(mdate "$c")" "macOS per-user temp/cache" "T2 CONFIRM" "DELETE" "# do not rm — reboot clears what is safe to clear"
done
p "| Item | Size |"
p "|---|---|"
for item in "$H/Library/Caches" "$H/.cache" "$H/.npm" "$BREW_CACHE" "$PIPC" "$X/Xcode/DerivedData" "$X/Xcode/Archives" "$X/Xcode/iOS DeviceSupport" "$X/CoreSimulator" "$H/.swiftpm" "$H/.conda" "$H/.mamba"; do
  [ -e "$item" ] && printf '| %s | %s |\n' "$(tl "$item")" "$(hum "$(kb "$item")")" >> "$R"
done
if command -v xcrun >/dev/null 2>&1 && [ -d /Library/Developer/CoreSimulator ]; then
  k=$(kb /Library/Developer/CoreSimulator); printf '| /Library/Developer/CoreSimulator (simulator runtimes, system-level) | %s |\n' "$(hum "$k")" >> "$R"
  add "$k" "/Library/Developer/CoreSimulator" "$(mdate /Library/Developer/CoreSimulator)" "Simulator runtimes" "T2 CONFIRM" "DELETE" "xcrun simctl runtime list   # then: xcrun simctl runtime delete <id>"
fi
p ""

# ======================================================================
log "Section 4: dev bloat"
p "### 4. Dev build folders (node_modules / .next / dist / build / .venv / venv / .turbo)"
p ""
p "| Size | Project last active | Folder | Status |"
p "|---|---|---|---|"
awk -F'\t' '$1=="D"||$1=="d"' "$W/scan.tsv" | while IFS=$'\t' read -r typ path; do
  case "$path" in "$H/."*|"$H/Library/"*) continue;; esac
  par="${path%/*}"
  if [ "$typ" = d ]; then
    [ -e "$par/package.json" ] || [ -e "$par/pyproject.toml" ] || [ -e "$par/setup.py" ] || [ -e "$par/Cargo.toml" ] || [ -e "$par/tsconfig.json" ] || continue
  fi
  k=$(kb "$path"); [ "$k" -ge 10240 ] || continue   # ignore < 10 MB
  lu=$(lastused "$par"); age=$(days "$lu"); nm="${path##*/}"
  if is_prot "$path"; then
    st="PROTECTED ($(prot_name "$path"))"; add "$k" "$path" "$(e2d "$lu")" "Dev build ($nm)" "T3 NEVER" "KEEP" "# protected project — only after you confirm it's dead"
  elif [ "$nm" = .venv ] || [ "$nm" = venv ]; then
    st="python env, ${age}d idle"; add "$k" "$path" "$(e2d "$lu")" "Python venv" "T2 CONFIRM" "DELETE" "rm -rf $(qp "$path")   # recreate: python3 -m venv .venv && pip install -r requirements.txt"
  elif [ "$age" -gt "$STALE_DAYS" ]; then
    st="stale ${age}d"; add "$k" "$path" "$(e2d "$lu")" "Dev build ($nm)" "T1 SAFE" "DELETE" "rm -rf $(qp "$path")"
  else
    st="active ${age}d"; add "$k" "$path" "$(e2d "$lu")" "Dev build ($nm)" "T2 CONFIRM" "DELETE" "rm -rf $(qp "$path")   # active project: reinstall cost"
  fi
  printf '| %s | %s | %s | %s |\n' "$(hum "$k")" "$(e2d "$lu")" "$(tl "$path")" "$st" >> "$R"
done
p ""

# ======================================================================
log "Section 5: AI / model stores"
p "### 5. AI / model stores"
p ""
# whisper/model references in protected projects (grep only, no secrets)
: > "$W/refs.txt"
if [ -s "$PROT" ]; then
  while IFS= read -r d; do
    grep -rIohiE "${GREP_EXCL[@]}" "${GREP_INC[@]}" \
      -e 'ggml-[a-z0-9._-]+\.bin' \
      -e '[a-z0-9_-]+/[a-z0-9._-]*whisper[a-z0-9._-]*' -e 'distil-whisper/[a-z0-9._-]+' \
      -e 'whisper[-_. :/]*(tiny|base|small|medium|large|turbo)[a-z0-9._-]*' \
      -e "(load_model|WhisperModel)\\([\"'][a-z0-9._-]+" "$d" 2>/dev/null | sed "s|^|${d##*/}: |"
  done < "$PROT" | tr 'A-Z' 'a-z' | sort | uniq -c | sort -rn > "$W/refs.txt"
fi
p "**Whisper/model strings referenced in protected project source** (heuristic grep, .env/keys excluded):"
p ""
if [ -s "$W/refs.txt" ]; then p '```'; head -40 "$W/refs.txt" >> "$R"; p '```'; else p "_none found_"; fi
p ""
# Ollama
OM="${OLLAMA_MODELS:-$H/.ollama/models}"
p "**Ollama** (\`$(tl "$OM")\`, blobs total on disk: $(hum "$(kb "$OM/blobs")"))"
p ""
p "| Model | Size (manifest) | Pulled/updated | Referenced by protected project |"
p "|---|---|---|---|"
if [ -d "$OM/manifests" ]; then
  find "$OM/manifests" -type f 2>/dev/null | while IFS= read -r mf; do
    rel=${mf#"$OM/manifests/"}; host=${rel%%/*}; rest=${rel#*/}; ns=${rest%%/*}; rest2=${rest#*/}; model=${rest2%/*}; tag=${rest2##*/}
    name="$model:$tag"; [ "$ns" = library ] || name="$ns/$name"; [ "$host" = registry.ollama.ai ] || name="$host/$name"
    bytes=$(grep -o '"size":[0-9]*' "$mf" | awk -F: '{s+=$2} END{printf "%.0f", s}')
    u=$(used_by "$name"); [ -z "$u" ] && u=$(used_by "$model")
    k=$((bytes/1024))
    if [ -n "$u" ]; then t="T3 NEVER"; a="KEEP"; c="# referenced by $u"; else t="T2 CONFIRM"; a="DELETE"; c="ollama rm $name"; fi
    printf '| %s | %s | %s | %s |\n' "$name" "$(hum "$k")" "$(mdate "$mf")" "${u:-—}" >> "$R"
    printf '%s\t%s\t%s\tOllama model %s\t%s\t%s\t%s\n' "$k" "$OM/manifests/$rel" "$(mdate "$mf")" "$name" "$t" "$a" "$c" >> "$W/ollama_rows.tsv"
  done
  [ -f "$W/ollama_rows.tsv" ] && cat "$W/ollama_rows.tsv" >> "$ROWS"
  kv ollama "$(kb "$OM/blobs")"
else
  p "| _no Ollama store found_ | | | |"
fi
command -v ollama >/dev/null 2>&1 && ollama list >/dev/null 2>&1 && { p ""; p '```'; ollama list 2>/dev/null >> "$R"; p '```'; }
p ""
p "_Ollama manifest sizes can share blobs; the blobs total above is the true on-disk figure._"
p ""
# Hugging Face
HF="${HF_HOME:-$H/.cache/huggingface}/hub"
p "**Hugging Face hub** (\`$(tl "$HF")\`, total $(hum "$(kb "${HF%/hub}")"))"
p ""
p "| Repo | Size | Last modified | Referenced by |"
p "|---|---|---|---|"
for m in "$HF"/models--* "$HF"/datasets--*; do
  [ -d "$m" ] || continue
  b="${m##*/}"; kind="${b%%--*}"; repo="${b#*--}"; repo="${repo/--//}"
  k=$(kb "$m"); u=$(used_by "$repo"); [ -z "$u" ] && grep -qiF -- "$repo" "$W/refs.txt" && u="(ref list)"
  printf '| %s (%s) | %s | %s | %s |\n' "$repo" "$kind" "$(hum "$k")" "$(mdate "$m")" "${u:-—}" >> "$R"
  if [ -n "$u" ]; then add "$k" "$m" "$(mdate "$m")" "HF model $repo" "T3 NEVER" "KEEP" "# referenced by $u"
  else add "$k" "$m" "$(mdate "$m")" "HF $kind $repo" "T2 CONFIRM" "DELETE" "rm -rf $(qp "$m")   # or: huggingface-cli delete-cache"; fi
done
kv hf "$(kb "${HF%/hub}")"
p ""
# Whisper weights (openai-whisper .pt + whisper.cpp ggml + other model files found in scan)
p "**Whisper & other model weight files (>50 MB)**"
p ""
p "| File | Size | Modified | Likely used by protected project? |"
p "|---|---|---|---|"
{ for f in "$H/.cache/whisper"/*.pt; do [ -f "$f" ] && stat -f 'F%t%z%t%b%t%m%t%f%t%N' "$f"; done
  awk -F'\t' '{n=tolower($6)} n ~ /(ggml|gguf|whisper)/ || n ~ /\.(gguf|safetensors|pt|pth|ckpt|onnx|mlmodel|mlpackage)$/ || n ~ /\.mlmodelc\// {print}' "$W/files.tsv"; } | sort -u | while IFS=$'\t' read -r _ sz bl mt fl path; do
  case "$path" in "$HF"/*|"$OM"/*) continue;; esac
  b="${path##*/}"; key="${b%.*}"; key="${key%.en}"
  u=""; is_prot "$path" && u="inside $(prot_name "$path")"
  [ -z "$u" ] && grep -qiF -- "$key" "$W/refs.txt" && u="name matches ref list"
  [ -z "$u" ] && u=$(used_by "$b")
  k=$((bl/2))
  printf '| %s | %s | %s | %s |\n' "$(tl "$path")" "$(hum "$k")" "$(e2d "$mt")" "${u:-no}" >> "$R"
  if [ -n "$u" ] || is_prot "$path"; then add "$k" "$path" "$(e2d "$mt")" "Model file" "T3 NEVER" "KEEP" "# $u"
  else add "$k" "$path" "$(e2d "$mt")" "Model file" "T2 CONFIRM" "DELETE" "rm $(qp "$path")"; fi
done
p ""
p "| Other AI store | Size |"
p "|---|---|"
for s in "$H/.lmstudio" "$H/.cache/lm-studio" "$H/Library/Application Support/MacWhisper" "$H/Library/Application Support/com.pais.superwhisper" "$H/.diffusionbee" "$H/.u2net" "$H/.insightface" "$H/.cache/torch" "$H/Library/Application Support/Pinokio" "$H/pinokio" "$H/.cache/whisper"; do
  [ -e "$s" ] || continue; k=$(kb "$s"); printf '| %s | %s |\n' "$(tl "$s")" "$(hum "$k")" >> "$R"
  case "$s" in *whisper*|*torch*) ;; *) add "$k" "$s" "$(mdate "$s")" "AI app store" "T2 CONFIRM" "DELETE" "# remove models inside the app UI, or: rm -rf $(qp "$s")";; esac
done
p ""

# ======================================================================
log "Section 6: Adobe"
p "### 6. Adobe"
p ""
p "| Folder | On disk | Logical | Files | Cloud-only files | Newest file | Status |"
p "|---|---|---|---|---|---|---|"
ADOBE_N=0
for d in "$H"/Creative\ Cloud\ Files*; do
  [ -d "$d" ] || continue; ADOBE_N=$((ADOBE_N+1))
  pk=$(kb "$d"); ak=$(akb "$d")
  find "$d" -type f -exec stat -f '%m %f' {} + 2>>"$ERR" > "$W/adobe.txt"
  nf=$(wc -l < "$W/adobe.txt" | tr -d ' ')
  ndl=$(awk '{if(int($2/1073741824)%2==1)c++} END{print c+0}' "$W/adobe.txt")
  nw=$(sort -rn "$W/adobe.txt" | head -1 | awk '{print $1+0}')
  st=$(awk -v n="$nf" -v d="$ndl" -v p="$pk" -v a="$ak" 'BEGIN{ if(n==0) print "empty"; else if(d==n) print "all cloud-only"; else if(d>0 || p < a*0.5) print "partly cloud-only"; else print "fully local" }')
  printf '| %s | %s | %s | %s | %s | %s | %s |\n' "$(tl "$d")" "$(hum "$pk")" "$(hum "$ak")" "$nf" "$ndl" "$(e2d "$nw")" "$st" >> "$R"
  add "$pk" "$d" "$(e2d "$nw")" "Adobe CC Files ($st)" "T2 CONFIRM" "MOVE TO GOOGLE DRIVE" "# upload via drive.google.com (browser) then verify, THEN: rm -rf $(qp "$d")"
done
[ "$ADOBE_N" -gt 0 ] && note "**Adobe: $ADOBE_N 'Creative Cloud Files' folders.** Only the account currently signed into Creative Cloud syncs. For that one, deleting locally can delete in the cloud — sign out first. The others are orphaned local copies: if that account's plan lapsed, Adobe may have purged the cloud copy, so the local folder could be the ONLY copy. Archive them; don't just delete."
for c in "$H/Library/Application Support/Adobe/Common/Media Cache Files" "$H/Library/Application Support/Adobe/Common/Media Cache" "$H/Library/Application Support/Adobe/Common/Peak Files" "$H/Library/Application Support/Adobe/Common/Team Projects Cache" "$H/Library/Caches/Adobe"; do
  addc "$c" "Adobe media/app cache" "rm -rf $(qp "$c")   # or Premiere → Settings → Media Cache → Delete"
done
kv adobe_mc "$(( $(kb "$H/Library/Application Support/Adobe/Common/Media Cache Files") + $(kb "$H/Library/Application Support/Adobe/Common/Peak Files") ))"
p ""
p "| Adobe app/cache area | Size |"
p "|---|---|"
for c in "$H/Library/Application Support/Adobe" "$H/Library/Application Support/Adobe/Common/Media Cache Files" "$H/Library/Application Support/Adobe/Common/Peak Files" "$H/Library/Caches/Adobe" "/Applications/Adobe Creative Cloud" "/Library/Application Support/Adobe"; do
  [ -e "$c" ] && printf '| %s | %s |\n' "$(tl "$c")" "$(hum "$(kb "$c")")" >> "$R"
done
p ""

# ======================================================================
log "Section 7: app leftovers"
p "### 7. App leftovers"
p ""
p "| Path | Size | Last modified | Matching app installed? |"
p "|---|---|---|---|"
for pair in ".thinkorswim:thinkorswim" ".ScreamingFrogSEOSpider:Screaming Frog" ".grokbot:grok" ".cagent:cagent" ".openjfx:-" ".docker:docker" ".android:Android Studio" ".expo:-" ".vscode:Visual Studio Code" ".rustup:-" ".pyenv:-" ".gem:-" ".local/share/virtualenvs:-" ".ollama:Ollama" ".deno:-" ".orbstack:OrbStack"; do
  dname="${pair%%:*}"; app="${pair#*:}"; path="$H/$dname"; [ -e "$path" ] || continue
  k=$(kb "$path"); inst="n/a"; [ "$app" != "-" ] && { app_installed "$app" && inst=yes || inst=NO; }
  printf '| %s | %s | %s | %s |\n' "$(tl "$path")" "$(hum "$k")" "$(mdate "$path")" "$inst" >> "$R"
  case "$dname" in .ollama) continue;; .openjfx) t="T1 SAFE";; *) t="T2 CONFIRM";; esac
  [ "$inst" = NO ] && act="DELETE" || act="KEEP"
  [ "$t" = "T1 SAFE" ] && act="DELETE"
  add "$k" "$path" "$(mdate "$path")" "App leftover ($dname, app installed: $inst)" "$t" "$act" "rm -rf $(qp "$path")"
done
DOCKER_RAW=$(ls "$H/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw" 2>/dev/null)
if [ -n "$DOCKER_RAW" ]; then
  k=$(kb "$DOCKER_RAW"); ak=$(akb "$DOCKER_RAW"); kv docker "$k"
  add "$k" "$DOCKER_RAW" "$(mdate "$DOCKER_RAW")" "Docker VM disk (sparse)" "T2 CONFIRM" "DELETE" "docker system prune -a --volumes   # or Docker Desktop → Settings → Resources → shrink disk limit"
  note "Docker.raw: $(hum "$k") on disk (sparse, logical cap $(hum "$ak")). It grows silently with images/volumes."
fi
p ""
for area in "Application Support:15" "Containers:15" "Group Containers:10"; do
  a="${area%%:*}"; n="${area#*:}"; pre="$H/Library/$a/"
  p "**~/Library/$a — top $n**"
  p ""
  p "| Size | Last modified | Name | App installed? |"
  p "|---|---|---|---|"
  awk -F'\t' -v pre="$pre" 'index($2,pre)==1 && substr($2,length(pre)+1) !~ /\//' "$W/du3.txt" | head -"$n" | while IFS=$'\t' read -r k path; do
    nm="${path##*/}"; inst="?"
    if [ "$a" = Containers ]; then
      case "$nm" in com.apple.*) inst="system";; *) [ -n "$(mdfind "kMDItemCFBundleIdentifier == '$nm'" 2>/dev/null | head -1)" ] && inst=yes || inst=NO;; esac
      [ "$inst" = NO ] && add "$k" "$path" "$(mdate "$path")" "Orphaned app container" "T2 CONFIRM" "DELETE" "rm -rf $(qp "$path")   # app $nm not found"
    fi
    case "$nm" in *[Cc]laude*) [ "$k" -gt 3145728 ] && note "$(tl "$path") is $(hum "$k") (Claude desktop app data / VM bundles). Treated as protected — flagged only.";; esac
    printf '| %s | %s | %s | %s |\n' "$(hum "$k")" "$(mdate "$path")" "$nm" "$inst" >> "$R"
  done
  p ""
done
DRIVEFS="$H/Library/Application Support/Google/DriveFS"
if [ -d "$DRIVEFS" ]; then
  k=$(kb "$DRIVEFS"); kv drivefs "$k"
  add "$k" "$DRIVEFS" "$(mdate "$DRIVEFS")" "Google Drive local cache" "T2 CONFIRM" "KEEP" "# Drive → Settings → gear → Preferences: keep 'Stream files'; clear cache via quitting Drive (don't rm while running)"
  [ "$k" -gt 2097152 ] && note "Google Drive for desktop cache (DriveFS) = $(hum "$k"). 'Streamed' files still cache locally — and anything you copy INTO Drive stages here first, which needs free space."
fi
p "**Applications (top 15, with Spotlight last-used date)**"
p ""
p "| Size | Last used | App |"
p "|---|---|---|"
du -sk /Applications/*.app "$H/Applications"/*.app 2>>"$ERR" | sort -rn | head -15 | while IFS=$'\t' read -r k path; do
  lu=$(mdls -name kMDItemLastUsedDate -raw "$path" 2>/dev/null | cut -c1-10); [ "$lu" = "(null)" ] && lu="never/unknown"
  printf '| %s | %s | %s |\n' "$(hum "$k")" "$lu" "${path##*/}" >> "$R"
  case "$path" in /Applications/Safari.app|*/Xcode.app) ;; *)
    add "$k" "$path" "$lu" "Application bundle" "T2 CONFIRM" "OFFLOAD" "# uninstall (reinstall later from source/App Store): drag to Trash or use vendor uninstaller";; esac
done
p ""
p "| System-level area | Size |"
p "|---|---|"
kv apps "$(kb /Applications)"
for s in /Applications "/Library/Application Support" "/Library/Audio/Apple Loops" "/Library/Application Support/GarageBand" "/Library/Application Support/Logic" /Users/Shared /private/var/vm; do
  [ -e "$s" ] && printf '| %s | %s |\n' "$s" "$(hum "$(kb "$s")")" >> "$R"
done
LOOPS=$(( $(kb "/Library/Audio/Apple Loops") + $(kb "/Library/Application Support/GarageBand") ))
[ "$LOOPS" -gt 1048576 ] && add "$LOOPS" "/Library/Audio/Apple Loops" "$(mdate "/Library/Audio/Apple Loops")" "GarageBand/Logic sound library" "T2 CONFIRM" "DELETE" "# if you don't use GarageBand: delete GarageBand.app, then sudo rm -rf \"/Library/Application Support/GarageBand\" \"/Library/Audio/Apple Loops\""
p ""

# ======================================================================
log "Section 8: media"
p "### 8. Media (Movies / Music / Pictures)"
p ""
p "| Size | Last modified | Path |"
p "|---|---|---|"
for m in "$H/Movies" "$H/Music" "$H/Pictures"; do
  [ -d "$m" ] || continue
  for c in "$m"/*; do
    [ -e "$c" ] || continue; k=$(kb "$c"); [ "$k" -ge 51200 ] || continue
    printf '| %s | %s | %s |\n' "$(hum "$k")" "$(mdate "$c")" "$(tl "$c")" >> "$R"
  done
done
p ""
for pl in "$H/Pictures"/*.photoslibrary; do
  [ -d "$pl" ] && add "$(kb "$pl")" "$pl" "$(mdate "$pl")" "Photos Library" "T3 NEVER" "KEEP" "# protected — use Photos → Settings → iCloud → Optimize Mac Storage instead"
done
# regenerable editor caches
addc "$H/Movies/CacheClip" "DaVinci Resolve cache" "rm -rf $(qp "$H/Movies/CacheClip")"
for c in "$H/Movies/CapCut/User Data/Cache" "$H/Library/Containers/com.lemon.lvoverseas/Data/Movies/CapCut/User Data/Cache"; do addc "$c" "CapCut cache" "rm -rf $(qp "$c")   # or CapCut → Settings → Clear cache"; done
find "$H/Movies" -maxdepth 3 -name '*.fcpbundle' -type d 2>/dev/null | while IFS= read -r lib; do
  find "$lib" -maxdepth 3 -type d \( -name 'Render Files' -o -name 'Transcoded Media' -o -name 'Analysis Files' \) 2>/dev/null | while IFS= read -r g; do
    addc "$g" "Final Cut generated files" "# FCP → select library → File → Delete Generated Library Files"
  done
done
find "$H/Pictures" -maxdepth 4 -name '*Previews.lrdata' -type d 2>/dev/null | while IFS= read -r g; do addc "$g" "Lightroom previews" "rm -rf $(qp "$g")   # Lightroom rebuilds previews"; done
p "**Large media files (>200 MB) in Movies / Music / Pictures / Projects exports**"
p ""
p "| Size | Modified | Path |"
p "|---|---|---|"
awk -F'\t' -v h="$H" '$2>209715200 && (index($6,h"/Movies/")==1 || index($6,h"/Music/")==1 || index($6,h"/Pictures/")==1) && tolower($6) ~ /\.(mov|mp4|m4v|mkv|avi|mxf|braw|r3d|wav|aif|aiff|mp3|m4a|heic|dng|cr3|arw|psd|psb|zip)$/' "$W/files.tsv" | head -40 | while IFS=$'\t' read -r _ sz bl mt fl path; do
  printf '| %s | %s | %s |\n' "$(hum $((bl/2)))" "$(e2d "$mt")" "$(tl "$path")" >> "$R"
  add $((bl/2)) "$path" "$(e2d "$mt")" "Media file" "T2 CONFIRM" "MOVE TO GOOGLE DRIVE" "# upload via drive.google.com, verify, then: rm $(qp "$path")"
done
p ""

# ======================================================================
log "Section 9: trash / backups / installers"
p "### 9. Trash, device backups, installers"
p ""
if ls "$H/.Trash" >/dev/null 2>&1; then
  k=$(kb "$H/.Trash"); kv trash "$k"
  p "- **~/.Trash:** $(hum "$k")"
  add "$k" "$H/.Trash" "$(mdate "$H/.Trash")" "Trash" "T1 SAFE" "DELETE" "osascript -e 'tell application \"Finder\" to empty trash'"
else
  p "- **~/.Trash: ACCESS DENIED** — needs Full Disk Access for Terminal (System Settings → Privacy & Security → Full Disk Access)."
fi
MS="$H/Library/Application Support/MobileSync/Backup"
if ls "$MS" >/dev/null 2>&1; then
  p "- **iOS/iPadOS backups** ($(tl "$MS")): $(hum "$(kb "$MS")")"
  for b in "$MS"/*; do
    [ -d "$b" ] || continue; k=$(kb "$b")
    p "  - \`${b##*/}\` — $(hum "$k"), last modified $(mdate "$b")"
    add "$k" "$b" "$(mdate "$b")" "iOS device backup" "T2 CONFIRM" "DELETE" "# Finder → select device → Manage Backups → Delete (keeps it tidy) — or move folder to Google Drive"
  done
elif [ -d "$H/Library/Application Support/MobileSync" ]; then
  p "- **MobileSync backups: ACCESS DENIED** — needs Full Disk Access for Terminal."
else
  p "- No MobileSync backups folder."
fi
p ""
p "**Installers / archives > 100 MB anywhere in ~**"
p ""
p "| Size | Modified | Path |"
p "|---|---|---|"
awk -F'\t' '$2>104857600 && tolower($6) ~ /\.(dmg|pkg|zip|iso|xip|7z|rar|tar|tgz|gz)$/' "$W/files.tsv" | while IFS=$'\t' read -r _ sz bl mt fl path; do
  is_prot "$path" && continue
  printf '| %s | %s | %s |\n' "$(hum $((bl/2)))" "$(e2d "$mt")" "$(tl "$path")" >> "$R"
  case "$(echo "$path" | tr 'A-Z' 'a-z')" in *.dmg|*.pkg|*.xip|*.iso) t="T1 SAFE"; a="DELETE";; *) t="T2 CONFIRM"; a="DELETE";; esac
  add $((bl/2)) "$path" "$(e2d "$mt")" "Installer/archive" "$t" "$a" "rm $(qp "$path")"
done
p ""

# ======================================================================
log "Section 10: Downloads / Desktop / Documents"
p "### 10. Downloads / Desktop / Documents"
p ""
for x in Downloads Desktop Documents; do
  d="$H/$x"
  if ls "$d" >/dev/null 2>&1; then
    k=$(kb "$d"); p "**~/$x — $(hum "$k")** (top 15 entries)"; p ""
    p "| Size | Last modified | Entry |"; p "|---|---|---|"
    for c in "$d"/* "$d"/.[!.]*; do [ -e "$c" ] && printf '%s\t%s\n' "$(kb "$c")" "$c"; done | sort -t$'\t' -k1,1nr | head -15 | while IFS=$'\t' read -r ck c; do
      printf '| %s | %s | %s |\n' "$(hum "$ck")" "$(mdate "$c")" "${c##*/}" >> "$R"
    done
    p ""
  else
    p "- **~/$x: ACCESS DENIED.** Grant Terminal access: System Settings → Privacy & Security → **Files and Folders → Terminal → $x Folder** (or Full Disk Access → Terminal), then re-run. Not worked around."
    note "~/$x was not measured (permission denied)."
  fi
done
if [ -d "$H/Library/Mobile Documents/com~apple~CloudDocs" ]; then
  p "- iCloud Drive local footprint: $(hum "$(kb "$H/Library/Mobile Documents")") on disk (logical $(hum "$(akb "$H/Library/Mobile Documents")"))"
fi
p ""

# ======================================================================
log "Building ranked table and totals"
sort -t$'\t' -k1,1nr "$ROWS" > "$W/rows_sorted.tsv"
p "## B. Ranked candidates (largest first)"
p ""
p "> Tiers: **T1 SAFE** regenerable · **T2 CONFIRM** judgment call · **T3 NEVER** protected/needed. Commands are **NOT executed**."
p ""
p "| # | Path | Size | Last used | Category | Risk tier | Recommended action | Exact command (NOT executed) |"
p "|---|---|---|---|---|---|---|---|"
awk -F'\t' -v h="$H" '{
  path=$2; if (index(path,h)==1) path="~" substr(path, length(h)+1)
  k=$1; if (k>=1048576) s=sprintf("%.2f GB",k/1048576); else if (k>=1024) s=sprintf("%.0f MB",k/1024); else s=k" KB"
  cmd=$7; gsub(/\|/,"\\|",cmd); gsub(/\|/,"\\|",path)
  printf "| %d | %s | %s | %s | %s | %s | %s | `%s` |\n", NR, path, s, $3, $4, $5, $6, cmd
}' "$W/rows_sorted.tsv" >> "$R"
p ""
p "## C. Recoverable totals by tier"
p ""
p "| Tier | Items | Total |"
p "|---|---|---|"
for t in "T1 SAFE" "T2 CONFIRM" "T3 NEVER"; do
  awk -F'\t' -v t="$t" '$5==t{n++; s+=$1} END{ if(s>=1048576) z=sprintf("%.2f GB",s/1048576); else z=sprintf("%.0f MB",s/1024); printf "| %s | %d | %s |\n", t, n, z }' "$W/rows_sorted.tsv" >> "$R"
done
T1=$(awk -F'\t' '$5=="T1 SAFE"{s+=$1} END{print s+0}' "$W/rows_sorted.tsv")
T2=$(awk -F'\t' '$5=="T2 CONFIRM"{s+=$1} END{print s+0}' "$W/rows_sorted.tsv")
p ""
p "- Free now: **$(hum "$FREE_KB")** → after T1: **$(hum $((FREE_KB+T1)))** → after T1+T2: **$(hum $((FREE_KB+T1+T2)))** (upper bound; snapshots can delay reclaim)."
p "- Rows are de-duplicated by path nesting (a child already covered by a listed parent is skipped), so totals don't double count."
p ""
p "**Top 10 T1 quick wins**"
p ""
awk -F'\t' -v h="$H" '$5=="T1 SAFE"{path=$2; if(index(path,h)==1) path="~" substr(path,length(h)+1); printf "%d. %s — %.2f GB\n", ++n, path, $1/1048576; if(n==10) exit}' "$W/rows_sorted.tsv" >> "$R"
p ""

p "## D. Fast regrowers (set limits)"
p ""
p "| Item | Current | Why it regrows | Guardrail |"
p "|---|---|---|---|"
p "| Browser caches (Chrome/Brave/Arc) | see B | Every page/video cached; Chrome caps loosely | Clear monthly; disable on-device AI model in chrome://flags ($(hum "$(kvget chrome_ai)") now) |"
p "| ~/Library/Caches | $(hum "$(kvget lib_caches)") | Every app writes here | Monthly sweep of non-Apple entries |"
p "| npm / pip / brew caches | see B | Grow on every install | \`brew cleanup\` weekly (set \`HOMEBREW_CLEANUP_MAX_AGE_DAYS=7\`), \`npm cache clean --force\` monthly |"
p "| node_modules / .next | see §4 | Every \`npm install\` / build | Consider pnpm (global content-addressed store) for new projects |"
p "| Adobe Media Cache + Peak Files | $(hum "$(kvget adobe_mc)") | Premiere/AE conform every imported clip | Premiere → Settings → Media Cache → auto-delete older than 14 days / cap 10 GB |"
p "| Video editor caches (Resolve CacheClip, CapCut, FCP renders) | see B | Proxies/renders per project | Point caches to Google-Drive-free folder you purge after export |"
p "| Ollama / Hugging Face models | $(hum "$(kvget ollama)") / $(hum "$(kvget hf)") | Each pull = 2–40 GB | One model per job; \`ollama rm\` after testing |"
p "| Docker.raw | $(hum "$(kvget docker)") | Images/volumes; sparse file never shrinks on its own | Docker Desktop → Resources → disk limit 16–24 GB; prune monthly |"
p "| Google Drive DriveFS cache | $(hum "$(kvget drivefs)") | Opened/streamed files cached locally | Keep 'Stream'; upload big archives via web, not Finder |"
p "| Swap / sleepimage | $(hum "$(kvget swap)") | Memory pressure | Fewer concurrent Electron apps; reboot weekly |"
p "| Time Machine local snapshots | $SNAPS snapshots | Hourly when backup disk absent | They auto-thin under pressure, but pin space you just freed |"
p ""

p "## E. Surprises & risks"
p ""
if [ -s "$NOTES" ]; then cat "$NOTES" >> "$R"; else p "- None flagged automatically."; fi
GAP=$(( ${DATA_USED_KB:-0} - ${HOME_KB:-0} - $(kvget apps) ))
p "- Space used outside ~ and /Applications (system data, other users, /Library, /private/var, snapshots): **$(hum "$GAP")**. If this is large, it's mostly snapshots, swap, simulator runtimes, and /Library content."
DENIED_N=$(grep -c 'Operation not permitted\|Permission denied' "$ERR")
if [ "$DENIED_N" -gt 0 ]; then
  p "- **$DENIED_N paths were not readable** (TCC/permissions). Top denied areas:"
  p '```'
  grep -o "$H/[^:]*" "$ERR" | sed "s|^$H/||" | awk -F/ '{print "~/"$1"/"$2}' | sort | uniq -c | sort -rn | head -12 >> "$R"
  p '```'
  p "  Fix (optional): System Settings → Privacy & Security → Full Disk Access → enable Terminal, then re-run for full coverage."
fi
p ""
p "---"
p "_Generated $(date '+%Y-%m-%d %H:%M') by mac_storage_audit.sh (read-only)._"

cp "$R" "$OUT" && log "Report written: $OUT" || { log "Could not write $OUT — printing to stdout"; cat "$R"; }

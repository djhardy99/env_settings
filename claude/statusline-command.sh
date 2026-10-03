#!/usr/bin/env bash
# Status line, up to five rows (GPU and limits rows are omitted when unavailable):
#   1. where:    path, git branch, time
#   2. host:     CPU | RAM | DISK
#   3. gpu:      GPU | VRAM
#   4. session:  model | context + cost
#   5. limits:   5h | 7d
# Colour rule: bright green/yellow/orange on bars = severity; path/branch/model use warm accents.

export LC_NUMERIC=C

# --- Config ---
readonly WARN=50 CRIT=80          # severity thresholds (%)
readonly BAR_W=8 BAR_W_HW=6       # bar widths: session rows / hardware row
readonly GPU_TTL_MIN=0.083        # nvidia-smi cache lifetime (~5s)
readonly CACHE_DIR="${XDG_RUNTIME_DIR:-/tmp}"

# --- Palette (256-colour) ---
readonly C_RST=$'\033[0m'
readonly C_DIM=$'\033[38;5;245m'
readonly C_LABEL=$'\033[38;5;252m'
readonly C_TRACK=$'\033[38;5;240m'
readonly C_OK=$'\033[38;5;83m'
readonly C_WARN=$'\033[38;5;220m'
readonly C_CRIT=$'\033[38;5;208m'
readonly C_PATH=$'\033[38;5;222m'
readonly C_BRANCH=$'\033[38;5;214m'
readonly C_MODEL=$'\033[38;5;156m'

readonly GAP='  '
readonly SEP="${C_DIM} │ ${C_RST}"

# --- Helpers ---
# round <out_var> <number>
round() { printf -v "$1" '%.0f' "${2:-0}"; }

# bar <out_var> <pct> [width]: severity-coloured ▰▰▰▱▱▱
bar() {
  local out=$1 p=${2%.*} w=${3:-$BAR_W} color filled i s
  [[ $p =~ ^[0-9]+$ ]] || p=0
  (( p > 100 )) && p=100
  if   (( p >= CRIT )); then color=$C_CRIT
  elif (( p >= WARN )); then color=$C_WARN
  else                       color=$C_OK; fi
  filled=$(( (p * w + 50) / 100 ))
  s=$color
  for ((i = 0; i < filled; i++)); do s+='▰'; done
  s+=$C_TRACK
  for ((; i < w; i++)); do s+='▱'; done
  printf -v "$out" '%s' "$s$C_RST"
}

# segment <out_var> <LABEL> <pct> <width> [detail]: "LABEL ▰▰▱▱  42% detail"
segment() {
  local out=$1 label=$2 pct=$3 w=$4 detail=${5:-} b pp
  bar b "$pct" "$w"
  printf -v pp '%3s%%' "$pct"
  printf -v "$out" '%s' "${C_LABEL}${label}${C_RST} ${b} ${pp}${detail:+ ${C_DIM}${detail}${C_RST}}"
}

# fmt_reset <out_var> <epoch>: time until reset, e.g. 2h10m or 3d11h
fmt_reset() {
  local d=$(( $2 - NOW ))
  (( d < 0 )) && d=0
  if (( d >= 86400 )); then
    printf -v "$1" '%dd%dh' $((d / 86400)) $((d % 86400 / 3600))
  else
    printf -v "$1" '%dh%02dm' $((d / 3600)) $((d % 3600 / 60))
  fi
}

# render_limit <out_var> <LABEL> <pct|-> <reset_epoch|->: empty if not reported
render_limit() {
  local out=$1 label=$2 pct=$3 reset=$4 p detail=''
  if [[ $pct == - ]]; then printf -v "$out" ''; return; fi
  round p "$pct"
  if [[ $reset =~ ^[0-9]+$ ]]; then fmt_reset detail "$reset"; detail="↻${detail}"; fi
  segment "$out" "$label" "$p" "$BAR_W" "$detail"
}

# --- Input (one jq call) ---
input=$(cat)
IFS=$'\t' read -r model_name ctx_pct cost_usd rl5_pct rl5_reset rl7_pct rl7_reset cwd < <(printf '%s' "$input" | jq -r '[
  (.model.display_name // "?"),
  (.context_window.used_percentage // 0),
  (.cost.total_cost_usd // 0),
  (.rate_limits.five_hour.used_percentage // "-"),
  (.rate_limits.five_hour.resets_at // "-"),
  (.rate_limits.seven_day.used_percentage // "-"),
  (.rate_limits.seven_day.resets_at // "-"),
  (.workspace.current_dir // .cwd // "")
] | @tsv')
[[ -n $cwd ]] && cd "$cwd" 2>/dev/null

# --- Where: path, branch, time ---
tilde='~'
dir=${PWD/#"$HOME"/$tilde}
branch=$(git --no-optional-locks branch --show-current 2>/dev/null)
[[ -z $branch ]] && branch=$(git --no-optional-locks rev-parse --short HEAD 2>/dev/null)
printf -v NOW '%(%s)T' -1
printf -v time_now '%(%H:%M:%S)T' -1

# --- CPU % (delta vs. previous run's /proc/stat sample, cached) ---
cpu_cache="$CACHE_DIR/statusline-cpu"
cpu_line2=$(grep '^cpu ' /proc/stat)
if [[ -r $cpu_cache ]]; then
  cpu_line1=$(<"$cpu_cache")
else
  cpu_line1=$cpu_line2
  sleep 0.15
  cpu_line2=$(grep '^cpu ' /proc/stat)
fi
printf '%s\n' "$cpu_line2" > "$cpu_cache"
cpu_pct=$(awk -v l1="$cpu_line1" -v l2="$cpu_line2" 'BEGIN{
  split(l1,a," "); split(l2,b," ");
  idle1=a[5]+a[6]; idle2=b[5]+b[6];
  nonidle1=a[2]+a[3]+a[4]+a[7]+a[8]+a[9]; nonidle2=b[2]+b[3]+b[4]+b[7]+b[8]+b[9];
  total1=idle1+nonidle1; total2=idle2+nonidle2;
  dtotal=total2-total1; didle=idle2-idle1;
  if (dtotal > 0) printf "%.0f", (dtotal-didle)*100/dtotal; else print "0";
}')

# --- RAM ---
read -r ram_pct ram < <(free -m | awk '/^Mem:/{printf "%.0f %.1f/%.0fG", $3*100/$2, $3/1024, $2/1024}')

# --- Disk (root filesystem) ---
read -r disk_pct disk < <(df -h --output=used,size,pcent / | awk 'NR==2{print $3+0, $1"/"$2}')

# --- GPU (nvidia only; silently omitted if unavailable) ---
have_gpu=0
if command -v nvidia-smi >/dev/null 2>&1; then
  gpu_cache="$CACHE_DIR/statusline-gpu"
  if [[ -n $(find "$gpu_cache" -mmin -"$GPU_TTL_MIN" 2>/dev/null) ]]; then
    gpu_raw=$(<"$gpu_cache")
  else
    gpu_raw=$(nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total --format=csv,noheader,nounits 2>/dev/null | head -1)
    [[ -n $gpu_raw ]] && printf '%s\n' "$gpu_raw" > "$gpu_cache"
  fi
  if [[ $gpu_raw =~ ^[0-9]+,\ [0-9]+,\ [0-9]+$ ]]; then
    have_gpu=1
    gpu_pct=${gpu_raw%%,*}
    read -r vram_pct vram < <(awk -F', ' '{printf "%.0f %.1f/%.0fG", $2*100/$3, $2/1024, $3/1024}' <<< "$gpu_raw")
  fi
fi

# --- Row 1: where ---
line1="${C_PATH}${dir}${C_RST}"
[[ -n $branch ]] && line1+="${GAP}${C_BRANCH}${branch}${C_RST}"
line1+="${GAP}${C_DIM}${time_now}${C_RST}"

# --- Row 2: host ---
segment cpu_seg  CPU  "$cpu_pct"  "$BAR_W_HW"
segment ram_seg  RAM  "$ram_pct"  "$BAR_W_HW" "$ram"
segment disk_seg DISK "$disk_pct" "$BAR_W_HW" "$disk"
line2="${cpu_seg}${SEP}${ram_seg}${SEP}${disk_seg}"

# --- Row 3: GPU (omitted without one) ---
line3=''
if (( have_gpu )); then
  segment gpu_seg  GPU  "$gpu_pct"  "$BAR_W_HW"
  segment vram_seg VRAM "$vram_pct" "$BAR_W_HW" "$vram"
  line3="${gpu_seg}${SEP}${vram_seg}"
fi

# --- Row 4: session ---
round ctx_fmt "$ctx_pct"
printf -v cost_fmt '$%.2f' "$cost_usd"
segment ctx_seg CTX "$ctx_fmt" "$BAR_W"
line4="${C_MODEL}${model_name}${C_RST}${SEP}${ctx_seg}${GAP}${cost_fmt}"

# --- Row 5: usage limits (omitted until the API reports them) ---
render_limit rl5_seg 5H "$rl5_pct" "$rl5_reset"
render_limit rl7_seg 7D "$rl7_pct" "$rl7_reset"
line5=''
[[ -n $rl5_seg ]] && line5=$rl5_seg
[[ -n $rl7_seg ]] && line5+="${line5:+$SEP}${rl7_seg}"

printf '%s\n' "$line1" "$line2"
for l in "$line3" "$line4" "$line5"; do
  [[ -n $l ]] && printf '%s\n' "$l"
done

#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Cell Observatory
# install-statusline.sh — set up the Claude Code usage status line on THIS host
# (e.g. a remote box you reach over SSH / VS Code Remote-SSH).
# Idempotent: re-running just refreshes the script and the statusLine setting.
# Honors $CLAUDE_CONFIG_DIR if you relocate ~/.claude.
set -euo pipefail
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
mkdir -p "$CLAUDE_DIR"

# --- dependency checks ---
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: 'jq' is required (the status line parses its JSON input with it)." >&2
  echo "  Debian/Ubuntu: sudo apt-get install -y jq" >&2
  echo "  RHEL/Fedora:   sudo dnf install -y jq" >&2
  echo "  macOS:         brew install jq" >&2
  exit 1
fi
command -v git >/dev/null 2>&1 || echo "NOTE: 'git' not found — branch segment is just skipped (harmless)." >&2
command -v python3 >/dev/null 2>&1 || echo "NOTE: 'python3' not found — the ~token estimate on the 5h/wk bars is skipped (percentages still show)." >&2
if ! locale charmap 2>/dev/null | grep -qi utf && ! locale -a 2>/dev/null | grep -qiE 'utf-?8'; then
  echo "NOTE: no UTF-8 locale found — the bar glyphs may not render, but everything else works." >&2
fi

# --- write the status line script (verbatim copy of the working one) ---
cat > "$CLAUDE_DIR/statusline.sh" <<'STATUSLINE_EOF'
#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Cell Observatory
# Claude Code status line.
#   Line 1: dir | branch | model
#   Line 2: context% | 5h usage% (resets) | week usage% (resets)
# rate_limits.* fields are sent only for Claude.ai subscription plans (Pro/Max/Team)
# and only after the first API response in a session, so line 2's usage may be empty
# in a fresh session. Schema: https://code.claude.com/docs/en/statusline.md

# Bar glyphs are multibyte; slicing them counts CHARACTERS only under a UTF-8 locale.
# Over SSH the locale is often C/POSIX (byte-counting), which would corrupt the bars,
# so pick a UTF-8 locale when the current one isn't already UTF-8.
if ! locale charmap 2>/dev/null | grep -qi 'utf'; then
  for L in C.UTF-8 en_US.UTF-8 C.utf8 en_US.utf8; do
    if locale -a 2>/dev/null | grep -qix "$L"; then export LC_ALL="$L"; break; fi
  done
fi

input=$(cat)
j() { printf '%s' "$input" | jq -r "$1"; }

dir=$(j '.workspace.current_dir // .cwd // ""')
model=$(j '.model.display_name // ""')
ctx=$(j '.context_window.used_percentage // empty')
ctx_in=$(j '.context_window.total_input_tokens // 0')
ctx_out=$(j '.context_window.total_output_tokens // 0')
ctx_size=$(j '.context_window.context_window_size // empty')
branch=$(git -C "$dir" --no-optional-locks rev-parse --abbrev-ref HEAD 2>/dev/null)

five_pct=$(j '.rate_limits.five_hour.used_percentage // empty')
five_reset=$(j '.rate_limits.five_hour.resets_at // empty')
week_pct=$(j '.rate_limits.seven_day.used_percentage // empty')
week_reset=$(j '.rate_limits.seven_day.resets_at // empty')

DIM=$'\033[2m'; R=$'\033[0m'
# color a usage percentage: green <50, yellow 50-79, red >=80
uc() { local p=${1%.*}; [ -z "$p" ] && p=0
  if [ "$p" -ge 80 ]; then printf '\033[31m'; elif [ "$p" -ge 50 ]; then printf '\033[33m'; else printf '\033[32m'; fi; }
# bar pct,width,color -> "███████─": solid blocks throughout; used portion in COLOR,
# remainder dim, then restores COLOR so the trailing percentage stays colored.
# Substring-slices fixed strings instead of loop-concat: bash 3.2 mangles multibyte
# glyphs when appended in an arithmetic for-loop.
BAR_FULL="████████████████████"
BAR_EMPTY="████████████████████"
bar() { local p=${1%.*}; [ -z "$p" ] && p=0; local w=${2:-8} col="$3" f
  f=$(( (p * w + 50) / 100 )); [ "$f" -gt "$w" ] && f=$w; [ "$f" -lt 0 ] && f=0
  printf '%s%s%s%s%s' "$col" "${BAR_FULL:0:$f}" "$DIM" "${BAR_EMPTY:0:$((w-f))}" "$col"; }
# seconds-until-epoch -> "Xd Yh" / "Xh Ym" / "Xm" / "now"
until_str() { local e="$1" now d; now=$(date +%s); d=$(( e - now ))
  if [ "$d" -le 0 ]; then echo now
  elif [ "$d" -ge 86400 ]; then echo "$((d/86400))d $(((d%86400)/3600))h"
  elif [ "$d" -ge 3600 ]; then echo "$((d/3600))h $(((d%3600)/60))m"
  else echo "$((d/60))m"; fi; }
# integer token count -> compact "49k" / "1.2M" (matches /context's readout)
human() { local n=${1%.*}; [ -z "$n" ] && n=0
  if [ "$n" -ge 1000000 ]; then local d=$(((n%1000000)/100000))
    if [ "$d" -eq 0 ]; then printf '%dM' $((n/1000000)); else printf '%d.%dM' $((n/1000000)) "$d"; fi
  elif [ "$n" -ge 1000 ]; then printf '%dk' $((n/1000))
  else printf '%d' "$n"; fi; }

# Line 1
line1="$(basename "$dir")"
[ -n "$branch" ] && line1="$line1 $DIM|$R $branch"
[ -n "$model" ]  && line1="$line1 $DIM|$R $model"
printf '%b\n' "$line1"

# --- account-wide token ESTIMATE for the 5h/wk windows (rough, self-calibrating) ---
# Those windows expose ONLY a percentage, never tokens. We approximate absolute tokens as
#   est = used_percentage * tokens_per_percent
# where tokens_per_percent is LEARNED over time: each scan compares this machine's transcript
# throughput within the window against the account %. Because the % is account-wide, the max
# ratio seen converges on the true budget-per-percent, so est starts at this machine's floor
# and climbs toward the real account figure as your OTHER machines move the %. State + a
# throttled (<=10 min), cached scan live in statusline-usage.json. Needs python3; if it is
# absent, or nothing has calibrated yet, the ~estimate is simply omitted. Delete the state
# file to recalibrate. python returns "<e5> <e7>" (0 = none); we treat 0 as "don't show".
est5=""; est7=""
if command -v python3 >/dev/null 2>&1 && { [ -n "$five_pct" ] || [ -n "$week_pct" ]; }; then
  CFG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  read -r est5 est7 <<<"$(python3 - "$CFG_DIR/statusline-usage.json" "$CFG_DIR/projects" \
      "${five_pct:-0}" "${five_reset:-0}" "${week_pct:-0}" "${week_reset:-0}" 2>/dev/null <<'PYEOF'
import sys, os, json, glob, time, datetime, signal
sp, proj = sys.argv[1], sys.argv[2]
def f(x):
    try: return float(x)
    except Exception: return 0.0
p5, r5, p7, r7 = f(sys.argv[3]), f(sys.argv[4]), f(sys.argv[5]), f(sys.argv[6])
now, W5, W7, THR = time.time(), 5*3600, 7*86400, 600
try: st = json.load(open(sp))
except Exception: st = {}
tpp5 = st.get('tpp5', 0.0); tpp7 = st.get('tpp7', 0.0)
L5 = st.get('L5', 0.0); L7 = st.get('L7', 0.0)
fc = st.get('fc', {}); last = st.get('last_scan', 0)
def ep(s):
    try:
        s = s.strip()
        if s.endswith('Z'): s = s[:-1] + '+00:00'
        return datetime.datetime.fromisoformat(s).timestamp()
    except Exception: return None
def scan(path, since):
    t = 0
    try:
        for ln in open(path, errors='ignore'):
            if '"usage"' not in ln: continue
            try: o = json.loads(ln)
            except Exception: continue
            u = (o.get('message') or {}).get('usage')
            if not u: continue
            e = ep(o.get('timestamp', '') or '')
            if e is None or e < since: continue
            t += (u.get('input_tokens', 0) or 0) + (u.get('output_tokens', 0) or 0) + (u.get('cache_creation_input_tokens', 0) or 0)
    except Exception: pass
    return t
if ((now - last) >= THR or not st) and (r5 or r7):
    class TO(Exception): pass
    try: signal.signal(signal.SIGALRM, lambda *a: (_ for _ in ()).throw(TO())); signal.alarm(12)
    except Exception: pass
    ws5 = (r5 - W5) if r5 else now - W5
    ws7 = (r7 - W7) if r7 else now - W7
    try:
        nL5 = nL7 = 0.0; nfc = {}
        for path in glob.glob(os.path.join(proj, '**', '*.jsonl'), recursive=True):
            try: m = os.path.getmtime(path)
            except Exception: continue
            if m < ws7: continue
            if m >= ws5:                                   # active in last 5h: parse precisely
                nL5 += scan(path, ws5); nL7 += scan(path, ws7)
            else:                                          # older-but-in-week: cache by (mtime, ws7)
                c = fc.get(path)
                e7 = c['e7'] if (c and c.get('mtime') == m and c.get('ws7') == ws7) else scan(path, ws7)
                nfc[path] = {'mtime': m, 'ws7': ws7, 'e7': e7}; nL7 += e7
        L5, L7, fc, last = nL5, nL7, nfc, now
        if p5 >= 5 and L5 > 0: tpp5 = max(tpp5, L5 / p5)   # calibrate only above the noise floor
        if p7 >= 5 and L7 > 0: tpp7 = max(tpp7, L7 / p7)
        try:
            tmp = sp + '.tmp'
            json.dump({'v': 1, 'last_scan': last, 'L5': L5, 'L7': L7, 'tpp5': tpp5, 'tpp7': tpp7, 'fc': fc}, open(tmp, 'w'))
            os.replace(tmp, sp)
        except Exception: pass
    except TO: pass
    try: signal.alarm(0)
    except Exception: pass
e5 = int(p5 * tpp5) if (p5 and tpp5) else 0
e7 = int(p7 * tpp7) if (p7 and tpp7) else 0
print(f"{e5} {e7}")
PYEOF
)"
fi

# Line 2
parts=()
# Each segment shows a dim "label —" placeholder until its value arrives, so a fresh
# session reads as "loading", not "missing" (ctx is null and rate_limits are absent
# until the first API response of the session).
if [ -n "$ctx" ]; then c=$(uc "$ctx"); ct=""
  # append absolute token count "used/size" when the context_window token fields are present
  [ -n "$ctx_size" ] && ct=" ${DIM}· $(human $(( ${ctx_in%.*} + ${ctx_out%.*} )))/$(human "$ctx_size")${R}"
  parts+=("${c}ctx [$(bar "$ctx" 8 "$c")] ${ctx%.*}%${R}${ct}")
else parts+=("${DIM}ctx —${R}"); fi
if [ -n "$five_pct" ]; then c=$(uc "$five_pct"); s=""; [ -n "$five_reset" ] && s=" ${DIM}·$(until_str "$five_reset")${R}"
  [ "${est5:-0}" != 0 ] && s="$s ${DIM}~$(human "$est5")${R}"
  parts+=("${c}5h [$(bar "$five_pct" 8 "$c")] $(printf '%.0f' "$five_pct")%${R}${s}")
else parts+=("${DIM}5h —${R}"); fi
if [ -n "$week_pct" ]; then c=$(uc "$week_pct"); s=""; [ -n "$week_reset" ] && s=" ${DIM}·$(until_str "$week_reset")${R}"
  [ "${est7:-0}" != 0 ] && s="$s ${DIM}~$(human "$est7")${R}"
  parts+=("${c}wk [$(bar "$week_pct" 8 "$c")] $(printf '%.0f' "$week_pct")%${R}${s}")
else parts+=("${DIM}wk —${R}"); fi
out=""
for p in "${parts[@]}"; do
  if [ -z "$out" ]; then out="$p"; else out="$out $DIM|$R $p"; fi
done
[ -n "$out" ] && printf '%b\n' "$out"
exit 0
STATUSLINE_EOF
chmod +x "$CLAUDE_DIR/statusline.sh"

# --- merge statusLine into settings.json, preserving any existing settings ---
SETTINGS="$CLAUDE_DIR/settings.json"
CMD="bash $CLAUDE_DIR/statusline.sh"
if [ -f "$SETTINGS" ]; then
  if ! jq -e . "$SETTINGS" >/dev/null 2>&1; then
    echo "ERROR: $SETTINGS is not valid JSON — leaving it untouched. Fix it and re-run." >&2
    exit 1
  fi
else
  echo '{}' > "$SETTINGS"
fi
tmp="$(mktemp)"
jq --arg cmd "$CMD" '.statusLine = {type:"command", command:$cmd, refreshInterval:60}' "$SETTINGS" > "$tmp"
mv "$tmp" "$SETTINGS"

echo "OK installed status line on this host:"
echo "    script:   $CLAUDE_DIR/statusline.sh"
echo "    settings: $SETTINGS  (statusLine -> $CMD)"
echo "  Open a fresh 'claude' session here; usage appears after the first reply."

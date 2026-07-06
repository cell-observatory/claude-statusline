# claude-statusline
![claude-statusline](docs/statusline.svg)

A two-line status line for the [Claude Code](https://code.claude.com) CLI that shows your
context-window fill and your Claude.ai plan usage (with reset countdowns) at a glance:


<sub>Plain-text rendering — bar color tracks usage: green &lt;50%, yellow 50–79%, red ≥80%.</sub>

```
my-project | main | Opus 4.8
ctx [███─────] 32% · 320k/1M | 5h [█████───] 63% ·2h10m ~4.8M | wk [███████─] 88% ·4d6h ~14M
```

- **Line 1** — current dir · git branch · model
- **Line 2** — `ctx` context-window used % **and absolute tokens used / window size**; `5h`
  rolling-5-hour plan usage %; `wk` 7-day plan usage %. Each bar is green < 50%,
  yellow 50–79%, red ≥ 80%, and shows time until reset.
  - The `5h`/`wk` bars also carry a `~` **token estimate** (e.g. `~2.1M`). Claude Code exposes
    only a *percentage* for those windows — never a token count — so this is a rough,
    self-calibrating figure: the script learns your tokens-per-percent from your own
    transcripts and multiplies by the account-wide `%`. It starts near this machine's usage and
    climbs toward your true account total as your other machines move the `%`. See below.

## Install

**One-liner** — installs into `~/.claude` and merges a `statusLine` entry into your
`settings.json`, preserving your other settings:

```bash
curl -fsSL https://raw.githubusercontent.com/cell-observatory/claude-statusline/main/install-statusline.sh | bash
```

Prefer to look before you leap? Open [`install-statusline.sh`](install-statusline.sh) (or the raw
URL) first — it's a short, self-contained script that does exactly what's described here.

**Or clone and run:**

```bash
git clone https://github.com/cell-observatory/claude-statusline.git
cd claude-statusline
./install-statusline.sh
```

**On remote hosts (over SSH).** The installer is self-contained, so you can stream it to a box
that has no clone of this repo and no internet access — it just needs SSH + bash (+ jq):

```bash
# ad hoc, one host
ssh user@host 'bash -s' < install-statusline.sh

# one or more hosts, via the helper
./remote-install.sh user@host [user@host2 ...]
```

`remote-install.sh` runs the ad-hoc command above for each host. Set `CLAUDE_CONFIG_DIR=…` to
target a relocated config dir on the remote, or `SSH="ssh -p 2222 -i key"` (or `-J bastion`) to
customize the connection.

Then open a **fresh** `claude` session. The context bar shows immediately; the `5h`/`wk` usage
bars fill in after the first reply and only appear on Claude.ai subscription plans
(Pro/Max/Team) — until then they render a dim `—` placeholder.

The installer is idempotent — re-run it any time to refresh. It honors `$CLAUDE_CONFIG_DIR`
if you keep your Claude config somewhere other than `~/.claude` (handy on a remote/SSH box).

## Requirements

- **`jq`** (required — the script parses Claude Code's JSON input with it)
  - macOS: `brew install jq`
  - Debian/Ubuntu: `sudo apt-get install -y jq`
  - RHEL/Fedora: `sudo dnf install -y jq`
- **`git`** (optional — without it the branch segment is just skipped)
- **`python3`** (optional — powers the `~` token estimate on the `5h`/`wk` bars; without it the
  bars still show their percentage. No third-party packages needed.)
- A **UTF-8 locale** for the bar glyphs (without one everything still works, the bars just may
  not render). The script auto-selects a UTF-8 locale over SSH when it can.

## The `~` token estimate (5h / wk)

Anthropic only ever tells the client a **percentage** for the 5-hour and weekly windows — never
a token count, and it doesn't publish the token budget behind them. So `~N` is a deliberate
back-of-envelope estimate, computed locally:

- On a throttled schedule (≤ every 10 min) the script sums the tokens in your own Claude Code
  transcripts (`~/.claude/projects/…`) that fall inside the current window and divides by the
  account-wide `%` to learn **tokens-per-percent**; the largest ratio it sees converges on the
  real budget.
- It then displays `est = % × tokens-per-percent`, marked `~`. Because the `%` is account-wide,
  the estimate **starts at roughly this machine's usage and climbs toward your true account
  total** as sessions on your other machines (or the web) push the `%` up.
- It's rough — model mix makes tokens-per-percent wobble, and it needs a few hours of use to
  calibrate. State lives in `~/.claude/statusline-usage.json`; **delete that file to
  recalibrate** (e.g. after a plan change). The scan is cached, so it adds well under a second.

## Files

- `statusline.sh` — the status line itself. This is the source of truth.
- `install-statusline.sh` — self-contained installer. It **embeds a verbatim copy** of
  `statusline.sh` so the one-liner above works with a single file.
- `remote-install.sh` — install on one or more remote hosts over SSH (streams the installer to
  each; no clone/internet needed on the remote).
- `LICENSE` — Apache-2.0.

## Development

`statusline.sh` is the source of truth; `install-statusline.sh` carries a verbatim copy inside a
`STATUSLINE_EOF` heredoc. **If you edit `statusline.sh`, regenerate the embedded copy** so the
two don't drift:

```bash
# replace the heredoc body in install-statusline.sh with the current statusline.sh
python3 - <<'PY'
new = open('statusline.sh').read().rstrip('\n').split('\n')
lines = open('install-statusline.sh').read().split('\n'); out=[]; i=0
while i < len(lines):
    out.append(lines[i])
    if lines[i].startswith('cat > ') and lines[i].rstrip().endswith("<<'STATUSLINE_EOF'"):
        j=i+1
        while lines[j] != 'STATUSLINE_EOF': j+=1
        out += new + ['STATUSLINE_EOF']; i=j+1; continue
    i+=1
open('install-statusline.sh','w').write('\n'.join(out))
PY
# sanity: the embedded copy must match
diff <(awk "/STATUSLINE_EOF'\$/{f=1;next}/^STATUSLINE_EOF\$/{f=0}f" install-statusline.sh) statusline.sh
```

## Uninstall

```bash
rm -f ~/.claude/statusline.sh ~/.claude/statusline-usage.json
tmp=$(mktemp); jq 'del(.statusLine)' ~/.claude/settings.json > "$tmp" && mv "$tmp" ~/.claude/settings.json
```

## License

[Apache-2.0](LICENSE) © Cell Observatory

---

<sub>Unofficial and not affiliated with Anthropic. "Claude" and "Claude Code" are trademarks of Anthropic, PBC.</sub>

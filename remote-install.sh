#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Cell Observatory
#
# remote-install.sh — install the Claude Code status line on one or more remote hosts over SSH.
#
# It streams the self-contained install-statusline.sh over the SSH connection and runs it on the
# remote, so the remote needs NO clone of this repo and NO internet access — just SSH access plus
# bash and jq (python3/git are optional, exactly like a local install).
#
# Usage:
#   ./remote-install.sh user@host [user@host2 ...]
#
# Options (environment variables):
#   CLAUDE_CONFIG_DIR=/path   Install into a relocated config dir on the remote (default ~/.claude)
#   SSH="ssh -p 2222 -i key"  Override the ssh command (custom port, key, jump host, etc.)
#
# Examples:
#   ./remote-install.sh gpu-box
#   ./remote-install.sh alice@node1 alice@node2
#   SSH="ssh -J bastion" ./remote-install.sh node-behind-bastion
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
installer="$here/install-statusline.sh"
[ -f "$installer" ] || { echo "ERROR: install-statusline.sh not found next to this script ($installer)." >&2; exit 1; }

if [ "$#" -lt 1 ]; then
  echo "Usage: $0 user@host [user@host2 ...]" >&2
  exit 2
fi

ssh_cmd=${SSH:-ssh}
# Forward CLAUDE_CONFIG_DIR to the remote installer if it is set locally.
prefix=""
[ -n "${CLAUDE_CONFIG_DIR:-}" ] && prefix="CLAUDE_CONFIG_DIR=$(printf %q "$CLAUDE_CONFIG_DIR") "

rc=0
for host in "$@"; do
  echo "==> installing on $host"
  if $ssh_cmd "$host" "${prefix}bash -s" < "$installer"; then
    :
  else
    echo "    FAILED on $host" >&2
    rc=1
  fi
done
[ "$rc" -eq 0 ] && echo "All done." || echo "Completed with errors." >&2
exit $rc

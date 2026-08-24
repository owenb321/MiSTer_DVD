#!/usr/bin/env bash
# notify.sh "<message>" — push a short message to the configured notifier.
#
# Endpoint resolution (first hit wins):
#   $NOTIFY_URL env var, else tools/.notify_url (gitignored — keep the secret out of git).
# Supports a Discord webhook URL (posts {"content":...}) or an ntfy topic/URL (posts raw).
# Silent no-op if no endpoint is configured, so it's safe to call unconditionally from
# build scripts. Honors $NOTIFY_SILENT=1 to suppress (used when a wrapper will send its
# own summary instead).
set -u
msg="${1:-(no message)}"
[ "${NOTIFY_SILENT:-0}" = "1" ] && exit 0

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
url="${NOTIFY_URL:-}"
[ -z "$url" ] && [ -f "$here/.notify_url" ] && url="$(head -1 "$here/.notify_url")"
[ -z "$url" ] && exit 0    # not configured

case "$url" in
  *discord.com/api/webhooks/*|*discordapp.com/api/webhooks/*)
    # JSON-escape the message robustly (quotes/newlines) via python3.
    payload="$(printf '%s' "$msg" | python3 -c 'import json,sys; print(json.dumps({"content": sys.stdin.read()[:1900]}))')"
    curl -sS -m 15 -H "Content-Type: application/json" -X POST -d "$payload" "$url" >/dev/null 2>&1 || true
    ;;
  *)
    # ntfy (or any endpoint that accepts a raw body)
    curl -sS -m 15 -d "$msg" "$url" >/dev/null 2>&1 || true
    ;;
esac
exit 0

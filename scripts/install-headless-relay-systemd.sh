#!/usr/bin/env sh
set -eu

SOURCE_ROOT="${1:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"
BIND_ADDRESS="${AI_WORKER_NOTIFIER_RELAY_BIND:-127.0.0.1}"
PORT="${AI_WORKER_NOTIFIER_RELAY_PORT:-8771}"
CONFIG_ROOT="${XDG_CONFIG_HOME:-$HOME/.config}/ai-worker-notifier"
SYSTEMD_ROOT="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
TOKEN_FILE="$CONFIG_ROOT/relay-token"
WEBHOOK_FILE="$CONFIG_ROOT/discord-webhook.url"
ROLE_FILE="$CONFIG_ROOT/discord-role.id"
ENV_FILE="$CONFIG_ROOT/relay.env"
UNIT_FILE="$SYSTEMD_ROOT/ai-worker-notifier-relay.service"

mkdir -p "$CONFIG_ROOT" "$SYSTEMD_ROOT"
chmod 700 "$CONFIG_ROOT"

if [ ! -s "$TOKEN_FILE" ]; then
  umask 077
  python3 -c 'import secrets; print("awnr_" + secrets.token_urlsafe(32))' > "$TOKEN_FILE"
fi
chmod 600 "$TOKEN_FILE"
{
  printf 'AI_WORKER_NOTIFIER_RELAY_TOKEN_FILE=%s\n' "$TOKEN_FILE"
  if [ -s "$WEBHOOK_FILE" ]; then
    chmod 600 "$WEBHOOK_FILE"
    printf 'AI_WORKER_NOTIFIER_WEBHOOK_FILE=%s\n' "$WEBHOOK_FILE"
  fi
  if [ -s "$ROLE_FILE" ]; then
    chmod 600 "$ROLE_FILE"
    printf 'AI_WORKER_NOTIFIER_MENTION_ROLE_FILE=%s\n' "$ROLE_FILE"
  fi
  printf 'AI_WORKER_NOTIFIER_RELAY_RATE_LIMIT=30\n'
  printf 'AI_WORKER_NOTIFIER_RELAY_RATE_WINDOW_SECONDS=60\n'
  printf 'AI_WORKER_NOTIFIER_MAX_SEND_ATTEMPTS=2\n'
} > "$ENV_FILE"
chmod 600 "$ENV_FILE"

cat > "$UNIT_FILE" <<EOF
[Unit]
Description=AIWorkerNotifier Headless Notification Relay
After=network-online.target tailscaled.service
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$SOURCE_ROOT
EnvironmentFile=$ENV_FILE
ExecStart=/usr/bin/python3 -m relay.server --bind $BIND_ADDRESS --port $PORT
Restart=on-failure
RestartSec=3
NoNewPrivileges=yes
PrivateTmp=yes

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now ai-worker-notifier-relay.service

printf '%s\n' "AIWorkerNotifier relay installed"
printf '%s\n' "bind=$BIND_ADDRESS port=$PORT"
printf '%s\n' "token_file=$TOKEN_FILE"
if [ ! -s "$WEBHOOK_FILE" ]; then
  printf '%s\n' "provider=unconfigured (create $WEBHOOK_FILE with mode 0600, then rerun installer)"
fi

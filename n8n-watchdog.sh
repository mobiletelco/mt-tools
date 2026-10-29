#!/usr/bin/env bash
# n8n-watchdog.sh - MobileTelco n8n server watchdog
# Detects a stuck n8n and restarts ONLY the n8n container (n8n-n8n-1).
#
# Patterns covered:
#   1) Postgres connection stalls - n8n logs show "timeout exceeded when trying
#      to connect", "Database is not ready", "Database ping failed"
#   2) Telegram connectivity loss - api.telegram.org unreachable from INSIDE the
#      n8n container while the VPS itself can still reach it (sends time out,
#      webhook deliveries stop)
#   3) n8n health endpoint hung, docker exec broken, or container not running
#
# Guards: flock (no overlapping runs), cooldown between restarts, daily cap,
# log rotation, VPS-wide Telegram outage never triggers a restart.
# Load: one cron run per minute; a few short probes, all <= 15 s timeouts;
# one 5-minute docker-log tail. No n8n workflows involved.

set -u

VERSION="1.0.0"
CONTAINER="${WATCHDOG_CONTAINER:-n8n-n8n-1}"
BASE_DIR="${WATCHDOG_DIR:-$HOME/.n8n-watchdog}"
LOG="${WATCHDOG_LOG:-$HOME/n8n-watchdog.log}"
COOLDOWN_SEC="${WATCHDOG_COOLDOWN:-1200}"      # 20 min between restarts
DAILY_CAP="${WATCHDOG_DAILY_CAP:-12}"
DOCKER_BIN="${WATCHDOG_DOCKER:-docker}"
CURL_BIN="${WATCHDOG_CURL:-curl}"
WGET_BIN="${WATCHDOG_WGET:-wget}"
LOCK="$BASE_DIR/lock"
STATE="$BASE_DIR/state"
TG_ENV="$BASE_DIR/telegram.env"                # optional: BOT_TOKEN=... CHAT_ID=...

DB_PATTERN='timeout exceeded when trying to connect|Database is not ready|Database ping failed|Connection terminated unexpectedly'
DB_THRESHOLD=3          # matching log lines within the last 5 minutes
HEALTHZ_FAILS_NEEDED=2  # consecutive minutes
TG_FAILS_NEEDED=3       # consecutive minutes

mkdir -p "$BASE_DIR"
touch "$STATE" "$LOG" 2>/dev/null || true

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG"
  if [ "$(stat -c%s "$LOG" 2>/dev/null || echo 0)" -gt 524288 ]; then
    tail -n 2000 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
  fi
}

sget() { grep -E "^$1=" "$STATE" 2>/dev/null | tail -n1 | cut -d= -f2-; }
sgetn() { local v; v=$(sget "$1"); echo "${v:-0}"; }
sset() {
  grep -vE "^$1=" "$STATE" > "$STATE.tmp" 2>/dev/null || true
  echo "$1=$2" >> "$STATE.tmp"
  mv "$STATE.tmp" "$STATE"
}

dc() { timeout 30 "$DOCKER_BIN" "$@"; }

# --- probes ---------------------------------------------------------------

# 0 running, 1 not running, 2 cannot inspect (docker daemon problem)
container_running() {
  local r
  r=$(dc inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null) || return 2
  [ "$r" = "true" ] && return 0
  return 1
}

# 0 healthy, !=0 unhealthy (n8n hung or docker exec broken - both restart-worthy)
n8n_healthz() {
  dc exec "$CONTAINER" node -e \
    "fetch('http://127.0.0.1:5678/healthz',{signal:AbortSignal.timeout(8000)}).then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))" \
    >/dev/null 2>&1
}

# 0 Telegram reachable from inside the container, !=0 not
tg_container_ok() {
  dc exec "$CONTAINER" node -e \
    "fetch('https://api.telegram.org',{signal:AbortSignal.timeout(8000)}).then(()=>process.exit(0)).catch(()=>process.exit(1))" \
    >/dev/null 2>&1
}

# 0 Telegram reachable from the VPS itself, !=0 not
tg_host_ok() {
  "$CURL_BIN" -fsS -m 8 -o /dev/null https://api.telegram.org >/dev/null 2>&1 && return 0
  timeout 10 "$WGET_BIN" -q -T 8 -O /dev/null https://api.telegram.org >/dev/null 2>&1
}

db_stall_count() {
  dc logs --since 5m "$CONTAINER" 2>&1 | grep -Eic "$DB_PATTERN" || true
}

# --- restart with guards --------------------------------------------------

do_restart() {
  local reason="$1"
  local now today count last
  now=$(date +%s); today=$(date +%F)
  last=$(sgetn last_restart)
  if [ $((now - last)) -lt "$COOLDOWN_SEC" ]; then
    log "BLOCKED: restart needed ($reason) but cooldown active ($(( (COOLDOWN_SEC - (now - last)) / 60 )) min left)"
    return 1
  fi
  count=$(sgetn "restarts_$today")
  if [ "$count" -ge "$DAILY_CAP" ]; then
    log "BLOCKED: restart needed ($reason) but daily cap $DAILY_CAP reached"
    return 1
  fi
  log "RESTARTING $CONTAINER ($reason)"
  if dc restart "$CONTAINER" >/dev/null 2>&1; then
    log "restart OK ($reason)"
    sset last_restart "$now"
    sset "restarts_$today" $((count + 1))
    sset pending_notify "$reason"
    sset pending_notify_since "$now"
    sset healthz_fails 0
    sset tg_fails 0
  else
    log "restart FAILED ($reason) - docker returned an error"
  fi
}

# --- best-effort Telegram recovery notice ---------------------------------

maybe_notify() {
  local reason since now
  reason=$(sget pending_notify)
  [ -z "$reason" ] && return 0
  since=$(sgetn pending_notify_since)
  now=$(date +%s)
  if [ $((now - since)) -gt 1800 ]; then
    sset pending_notify ""
    log "notify: gave up after 30 min (n8n/Telegram still not healthy)"
    return 0
  fi
  [ -f "$TG_ENV" ] || return 0
  . "$TG_ENV"
  { [ -n "${BOT_TOKEN:-}" ] && [ -n "${CHAT_ID:-}" ]; } || return 0
  if n8n_healthz && tg_host_ok; then
    if "$CURL_BIN" -fsS -m 10 -o /dev/null -X POST \
        "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        -d chat_id="$CHAT_ID" \
        --data-urlencode "text=n8n watchdog: restarted ${CONTAINER} (${reason}) at $(date '+%H:%M, %d %b'). Health check passed - n8n is back."; then
      log "notify: recovery message sent to Telegram"
      sset pending_notify ""
    else
      log "notify: Telegram send failed, will retry"
    fi
  fi
}

# --- main check run --------------------------------------------------------

run_checks() {
  exec 9>"$LOCK"
  flock -n 9 || { log "skip: previous run still active"; exit 0; }

  maybe_notify

  if ! dc version >/dev/null 2>&1; then
    log "ERROR: docker daemon not reachable - cannot check or restart"
    exit 0
  fi

  container_running
  case $? in
    2) log "ERROR: cannot inspect $CONTAINER - docker daemon problem, not restarting"; exit 0 ;;
    1) do_restart "container-not-running"; exit 0 ;;
  esac

  if n8n_healthz; then
    sset healthz_fails 0
  else
    local n; n=$(( $(sgetn healthz_fails) + 1 ))
    sset healthz_fails "$n"
    log "healthz failed ($n/$HEALTHZ_FAILS_NEEDED)"
    if [ "$n" -ge "$HEALTHZ_FAILS_NEEDED" ]; then
      do_restart "healthz-failing"
      exit 0
    fi
  fi

  local dbc; dbc=$(db_stall_count)
  dbc="${dbc:-0}"
  if [ "$dbc" -ge "$DB_THRESHOLD" ]; then
    log "DB stall signatures in last 5 min: $dbc (threshold $DB_THRESHOLD)"
    do_restart "postgres-connection-stall"
    exit 0
  fi

  if tg_container_ok; then
    sset tg_fails 0
  else
    if tg_host_ok; then
      local n; n=$(( $(sgetn tg_fails) + 1 ))
      sset tg_fails "$n"
      log "Telegram unreachable from container (VPS can reach it) ($n/$TG_FAILS_NEEDED)"
      if [ "$n" -ge "$TG_FAILS_NEEDED" ]; then
        do_restart "telegram-unreachable-from-container"
        exit 0
      fi
    else
      log "Telegram unreachable from the VPS itself too - outage is not n8n's fault, restart skipped"
    fi
  fi
}

# --- self test (stubbed docker/curl, never touches the real system) --------

do_selftest() {
  local T; T=$(mktemp -d)
  local pass=0 fail=0

  cat > "$T/docker" <<'EOS'
#!/usr/bin/env bash
d="$WATCHDOG_STUB_DIR"
cmd="${1:-}"; shift || true
case "$cmd" in
  version) exit 0 ;;
  inspect)
    [ -f "$d/no_inspect" ] && exit 1
    if [ -f "$d/stopped" ]; then echo false; else echo true; fi
    exit 0 ;;
  exec)
    [ -f "$d/exec_broken" ] && exit 126
    case "$*" in
      *5678*)              [ -f "$d/healthz_fail" ] && exit 1; exit 0 ;;
      *api.telegram.org*)  [ -f "$d/tg_container_fail" ] && exit 1; exit 0 ;;
    esac
    exit 0 ;;
  logs)
    n=$(cat "$d/db_errors" 2>/dev/null || echo 0)
    i=0; while [ "$i" -lt "$n" ]; do echo "Database ping failed"; i=$((i+1)); done
    exit 0 ;;
  restart)
    date +%s >> "$d/restarted"
    exit 0 ;;
  *) exit 0 ;;
esac
EOS
  cat > "$T/curl" <<'EOS'
#!/usr/bin/env bash
case "$*" in
  *api.telegram.org*) [ -f "$WATCHDOG_STUB_DIR/tg_host_fail" ] && exit 1; exit 0 ;;
  *) exit 0 ;;
esac
EOS
  cat > "$T/wget" <<'EOS'
#!/usr/bin/env bash
case "$*" in
  *api.telegram.org*) [ -f "$WATCHDOG_STUB_DIR/tg_host_fail" ] && exit 1; exit 0 ;;
  *) exit 0 ;;
esac
EOS
  chmod +x "$T/docker" "$T/curl" "$T/wget"

  # run_case <name> <runs> <expected_restarts> <setup-flags...>
  run_case() {
    local name="$1" runs="$2" expect="$3"; shift 3
    local sd="$T/stub-$name" wd="$T/wd-$name"
    rm -rf "$sd" "$wd"; mkdir -p "$sd" "$wd"
    while [ $# -gt 0 ]; do
      case "$1" in
        db_errors=*) echo "${1#db_errors=}" > "$sd/db_errors" ;;
        cap_reached) echo "restarts_$(date +%F)=12" >> "$wd/state" ;;
        *) touch "$sd/$1" ;;
      esac
      shift
    done
    local i=0
    while [ "$i" -lt "$runs" ]; do
      WATCHDOG_STUB_DIR="$sd" WATCHDOG_DOCKER="$T/docker" WATCHDOG_CURL="$T/curl" WATCHDOG_WGET="$T/wget" \
      WATCHDOG_DIR="$wd" WATCHDOG_LOG="$wd.log" WATCHDOG_COOLDOWN=1200 \
      bash "$0" >/dev/null 2>&1
      i=$((i+1))
    done
    local got=0
    [ -f "$sd/restarted" ] && got=$(wc -l < "$sd/restarted")
    if [ "$got" -eq "$expect" ]; then
      echo "PASS  $name (restarts=$got, expected $expect)"
      pass=$((pass+1))
    else
      echo "FAIL  $name (restarts=$got, expected $expect)"
      fail=$((fail+1))
    fi
  }

  run_case healthy 1 0
  run_case container-stopped 1 1 stopped
  run_case db-stall 1 1 db_errors=5
  run_case healthz-hang 2 1 healthz_fail
  run_case telegram-container-only 3 1 tg_container_fail
  run_case telegram-vps-wide 3 0 tg_container_fail tg_host_fail
  run_case cooldown-blocks 2 1 db_errors=5
  run_case daily-cap-blocks 1 0 db_errors=5 cap_reached

  rm -rf "$T"
  echo "SELFTEST: $pass passed, $fail failed"
  [ "$fail" -eq 0 ]
}

# --- install / status ------------------------------------------------------

do_install() {
  local script_path
  script_path="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  echo "n8n watchdog installer v$VERSION"
  command -v docker >/dev/null 2>&1 || { echo "FAIL: docker not found in PATH"; exit 1; }
  if ! docker ps >/dev/null 2>&1; then
    echo "FAIL: 'docker ps' needs sudo for user $USER."
    echo "The watchdog needs passwordless docker. Fix once with:  sudo usermod -aG docker $USER"
    echo "Then log out of SSH, log back in, and run the install command again."
    exit 1
  fi
  docker inspect "$CONTAINER" >/dev/null 2>&1 || { echo "FAIL: container $CONTAINER not found on this server"; exit 1; }
  echo "container $CONTAINER found, docker access OK"
  echo "running self test..."
  if ! bash "$script_path" --selftest; then
    echo "FAIL: self test failed - cron NOT installed"
    exit 1
  fi
  chmod +x "$script_path" 2>/dev/null || true
  local marker="# n8n-watchdog"
  local line="* * * * * $script_path >/dev/null 2>&1 $marker"
  ( crontab -l 2>/dev/null | grep -vF "$marker"; echo "$line" ) | crontab -
  echo ""
  echo "INSTALL OK - watchdog is active (checks every minute)."
  echo "Log file: $LOG"
  echo "See what it is doing anytime:  bash $script_path --status"
  echo "Voluntary real restart test:   bash $script_path --force-restart"
}

do_status() {
  echo "n8n watchdog v$VERSION - container: $CONTAINER"
  echo "cron: $(crontab -l 2>/dev/null | grep -F '# n8n-watchdog' || echo 'NOT installed')"
  echo "restarts today: $(sgetn "restarts_$(date +%F)")  last restart: $(sgetn last_restart)"
  echo "--- last 15 log lines ---"
  tail -n 15 "$LOG"
}

case "${1:-}" in
  --install)       do_install ;;
  --selftest)      do_selftest ;;
  --status)        do_status ;;
  --force-restart) do_restart "manual-test" ;;
  "")              run_checks ;;
  *) echo "usage: $0 [--install|--selftest|--status|--force-restart]"; exit 1 ;;
esac

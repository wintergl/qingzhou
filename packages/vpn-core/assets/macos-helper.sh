#!/bin/sh
HELPER_VERSION="2026.08.15.3"
# Earlier clients check their exact line; the last assignment is the revision.
HELPER_SCRIPT_REVISION="2026.10.09.1"
HELPER_SCRIPT_REVISION="2026.10.09.2"
HELPER_SCRIPT_REVISION="2026.10.10.1"
HELPER_SCRIPT_REVISION="2026.10.11.1"
# Compatibility marker for installed 0.3.x clients, using the same IPC protocol:
# HELPER_SCRIPT_REVISION="2026.10.08.1"

if [ "${1:-}" != "daemon" ]; then
  exit 64
fi

APP_DATA="${2:-}"
if [ -z "$APP_DATA" ]; then
  exit 64
fi

HELPER_DIR="$APP_DATA/helper"
RESPONSES_DIR="$HELPER_DIR/responses"
FIFO="$HELPER_DIR/control.pipe"
MIHOMO="/Library/PrivilegedHelperTools/com.split-vpn.mihomo"
MIHOMO_DATA="$APP_DATA/mihomo"
MIHOMO_CONFIG="$MIHOMO_DATA/config.yaml"
MIHOMO_LOG="$APP_DATA/logs/mihomo.log"
PID_FILE="$MIHOMO_DATA/mihomo.pid"
IDENTITY_DIR="/var/db/com.split-vpn.helper"
IDENTITY_FILE="$IDENTITY_DIR/mihomo.identity"
DNS_STATE_FILE="$HELPER_DIR/dns-state"
DNS_STATE_DIR="$HELPER_DIR/dns-state.d"
APP_UID="$(stat -f '%u' "$APP_DATA" 2>/dev/null || true)"
HELPER_UID="$(/usr/bin/id -u)"

umask 022

# Every create, write and delete inside the user's data directory runs as its
# owner. A link swapped in after safe_user_path then only reaches files the
# user could already write, never system files.
as_user() {
  if [ "$HELPER_UID" = "$APP_UID" ]; then
    "$@"
  else
    /usr/bin/sudo -n -u "#$APP_UID" -- "$@"
  fi
}

user_write() {
  as_user /bin/sh -c 'cat > "$1"' sh "$1"
}

user_append() {
  as_user /bin/sh -c 'cat >> "$1"' sh "$1"
}

log_helper() {
  safe_user_path "$MIHOMO_LOG" || return 0
  printf '%s helper: %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$1" | user_append "$MIHOMO_LOG" 2>/dev/null || true
}

# Run a system command as root while its output goes to the user's log.
logged() {
  logged_output="$("$@" 2>&1)"
  logged_status=$?
  if [ -n "$logged_output" ] && safe_user_path "$MIHOMO_LOG"; then
    printf '%s\n' "$logged_output" | user_append "$MIHOMO_LOG" 2>/dev/null || true
  fi
  return "$logged_status"
}

flush_system_dns() {
  /usr/bin/dscacheutil -flushcache >/dev/null 2>&1 || true
  /usr/bin/killall -HUP mDNSResponder >/dev/null 2>&1 || true
}

service_exists() {
  service="$1"
  /usr/sbin/networksetup -listallnetworkservices 2>/dev/null | /usr/bin/awk -v svc="$service" '
    NR > 1 {
      sub(/^\*/, "", $0)
      if ($0 == svc) {
        found = 1
      }
    }
    END { exit found ? 0 : 1 }
  '
}

service_name_for_device() {
  device="$1"
  [ -n "$device" ] || return
  # Use -listnetworkserviceorder so we map a device (enX) to the real network
  # service name (e.g. "ORICO-2.5G"), not the hardware-port label.  The output
  # is pairs of lines:  "(N) ServiceName"  then  "(Hardware Port: ..., Device: enX)".
  /usr/sbin/networksetup -listnetworkserviceorder 2>/dev/null | /usr/bin/awk -v dev="$device" '
    function strip_name(s) {
      # Character classes survive the TypeScript template without escape loss.
      sub(/^[(][0-9]+[)] /, "", s)
      return s
    }
    function current_device(line,      d) {
      d = line
      sub(/.*Device: /, "", d)
      sub(/[),].*/, "", d)
      return d
    }
    {
      if (index($0, "Device: ") && current_device($0) == dev) {
        print strip_name(prev)
        exit
      }
      prev = $0
    }
  '
}

default_network_service() {
  default_if="$(/sbin/route -n get default 2>/dev/null | /usr/bin/awk '/interface:/{print $2; exit}')"
  service_name_for_device "$default_if"
}

candidate_dns_services() {
  default_service="$(default_network_service)"
  if [ -n "$default_service" ] && service_exists "$default_service"; then
    printf '%s\n' "$default_service"
  fi
  if service_exists "Wi-Fi"; then
    printf '%s\n' "Wi-Fi"
  fi
}

dns_services() {
  candidate_dns_services | /usr/bin/awk 'length($0) > 0 && !seen[$0]++ { print }'
}

dns_state_path() {
  service="$1"
  safe="$(printf '%s' "$service" | /usr/bin/sed 's/[^A-Za-z0-9_.-]/_/g')"
  checksum="$(printf '%s' "$service" | /usr/bin/cksum | /usr/bin/awk '{print $1}')"
  if [ -z "$safe" ]; then
    safe="service"
  fi
  printf '%s/%s-%s.state\n' "$DNS_STATE_DIR" "$safe" "$checksum"
}

save_dns_state() {
  service="$1"
  state_file="$(dns_state_path "$service")"
  as_user /bin/mkdir -p "$DNS_STATE_DIR"
  if [ -f "$state_file" ] && [ ! -L "$state_file" ]; then
    return 0
  fi
  safe_user_path "$state_file" || return 1

  dns_output="$(/usr/sbin/networksetup -getdnsservers "$service" 2>/dev/null || true)"
  if [ -z "$dns_output" ]; then
    log_helper "unable to read DNS servers for $service"
    return 1
  fi

  if printf '%s\n' "$dns_output" | grep -q "There aren't any DNS Servers"; then
    {
      printf '%s\n' "$service"
      printf 'EMPTY\n'
    } | user_write "$state_file" || return 1
  else
    {
      printf '%s\n' "$service"
      printf 'SERVERS\n'
      printf '%s\n' "$dns_output"
    } | user_write "$state_file" || return 1
  fi
  return 0
}

set_system_dns() {
  # Clear any leftover DNS transactions from a previous (possibly crashed) run
  # before starting a fresh one, so the restore set always matches this session.
  restore_system_dns

  services_file="${IDENTITY_DIR:-$HELPER_DIR}/dns-services.current"
  dns_services > "$services_file"

  if [ ! -s "$services_file" ]; then
    rm -f "$services_file"
    log_helper "no eligible network service found for DNS update"
    return
  fi

  while IFS= read -r service; do
    [ -n "$service" ] || continue
    if ! save_dns_state "$service"; then
      log_helper "skipping DNS update for $service: original state could not be saved"
      continue
    fi
    if logged /usr/sbin/networksetup -setdnsservers "$service" 127.0.0.1; then
      log_helper "set $service DNS to 127.0.0.1"
    else
      log_helper "failed to set $service DNS to 127.0.0.1"
      # Undo the state file so restore does not later clobber a never-applied change.
      as_user /bin/rm -f "$(dns_state_path "$service")"
    fi
  done < "$services_file"

  rm -f "$services_file"
  flush_system_dns
}

service_dns_is_local() {
  /usr/sbin/networksetup -getdnsservers "$1" 2>/dev/null | /usr/bin/awk '
    NF { count++; if ($0 != "127.0.0.1") bad=1 }
    END { exit count > 0 && !bad ? 0 : 1 }
  '
}

# Add newly active services to this session without restoring or overwriting
# earlier snapshots. A repeated refresh must never save 127.0.0.1 as original DNS.
refresh_system_dns() {
  services_file="${IDENTITY_DIR:-$HELPER_DIR}/dns-refresh.current"
  dns_services > "$services_file"
  if [ ! -s "$services_file" ]; then
    rm -f "$services_file"
    return 1
  fi
  dns_refresh_failed=0
  dns_refresh_changed=0
  while IFS= read -r service; do
    [ -n "$service" ] || continue
    if service_dns_is_local "$service"; then
      continue
    fi
    if ! save_dns_state "$service"; then
      dns_refresh_failed=1
      continue
    fi
    if logged /usr/sbin/networksetup -setdnsservers "$service" 127.0.0.1 && service_dns_is_local "$service"; then
      log_helper "refreshed $service DNS to 127.0.0.1"
      dns_refresh_changed=1
    else
      # Keep the original snapshot even if the update partially succeeded.
      log_helper "DNS refresh unconfirmed for $service; original snapshot retained"
      dns_refresh_failed=1
    fi
  done < "$services_file"
  rm -f "$services_file"
  if [ "$dns_refresh_changed" = 1 ]; then flush_system_dns; fi
  return "$dns_refresh_failed"
}

refresh_mihomo_dns() {
  request_id="$1"
  current_pid="$(read_pid)"
  RESPONSE_TARGET_PID="$current_pid"
  if ! is_pid_running "$current_pid" || ! verify_process_identity "$current_pid"; then
    write_response "$request_id" false "$current_pid" "identity_mismatch" "identity_mismatch"
    return
  fi
  RESPONSE_IDENTITY_VERIFIED=true
  if ! refresh_system_dns || ! verify_process_identity "$current_pid"; then
    write_response "$request_id" false "$current_pid" "dns_refresh_unconfirmed" "dns_refresh_unconfirmed"
    return
  fi
  RESPONSE_DNS_REFRESH_OK=true
  write_response "$request_id" true "$current_pid" "dns_refreshed" ""
}

# This also repairs network handoff for installed native clients which only
# reload Mihomo. Run in the command loop so refresh and stop cannot race.
poll_system_dns() {
  dns_now="$(date +%s)"
  if [ $((dns_now - DNS_LAST_POLL)) -lt 5 ]; then return; fi
  DNS_LAST_POLL="$dns_now"
  dns_pid="$(read_pid)"
  if ! is_pid_running "$dns_pid" || ! verify_process_identity "$dns_pid"; then
    DNS_PENDING_ROUTE=""
    restore_orphan_dns_when_idle
    return
  fi
  DNS_ORPHAN_SINCE=""
  dns_route="$(default_network_service)"
  if [ -z "$dns_route" ]; then DNS_PENDING_ROUTE=""; return; fi
  dns_key="$dns_pid:$dns_route"
  if [ "$DNS_PENDING_ROUTE" != "$dns_key" ]; then
    DNS_PENDING_ROUTE="$dns_key"
    return
  fi
  refresh_system_dns || true
}

# DNS points at 127.0.0.1 only while our engine runs. After a crash, forced
# shutdown or reboot, restore the snapshots once the engine stays absent.
restore_orphan_dns_when_idle() {
  orphan_pending=0
  for orphan_state in "$DNS_STATE_DIR"/*.state "$DNS_STATE_FILE"; do
    if [ -f "$orphan_state" ]; then orphan_pending=1; break; fi
  done
  if [ "$orphan_pending" = 0 ]; then DNS_ORPHAN_SINCE=""; return; fi
  if [ -z "$DNS_ORPHAN_SINCE" ]; then DNS_ORPHAN_SINCE="$dns_now"; return; fi
  if [ $((dns_now - DNS_ORPHAN_SINCE)) -lt 10 ]; then return; fi
  log_helper "engine absent; restoring original DNS"
  restore_system_dns || true
  DNS_ORPHAN_SINCE=""
}

restore_dns_state_file() {
  state_file="$1"
  service="$(sed -n '1p' "$state_file" 2>/dev/null || true)"
  mode="$(sed -n '2p' "$state_file" 2>/dev/null || true)"
  if [ -z "$service" ]; then
    as_user /bin/rm -f "$state_file"
    return 0
  fi

  applied=0
  if [ "$mode" = "EMPTY" ]; then
    logged /usr/sbin/networksetup -setdnsservers "$service" Empty && applied=1
  elif [ "$mode" = "SERVERS" ]; then
    # Snapshot files are user-writable: pass only address-shaped lines.
    servers="$(tail -n +3 "$state_file" | /usr/bin/awk '/^[0-9A-Fa-f:.]+$/' | tr '\n' ' ')"
    if [ -n "$servers" ]; then
      logged /usr/sbin/networksetup -setdnsservers "$service" $servers && applied=1
    else
      applied=1
    fi
  else
    applied=1
  fi

  # Only delete the snapshot when restore actually succeeded; on failure keep
  # it so a later retry can still recover the original value instead of losing
  # it forever (or worse, pinning 127.0.0.1 as the new "original").
  if [ "$applied" = "1" ]; then
    as_user /bin/rm -f "$state_file"
    log_helper "restored $service DNS"
    return 0
  fi
  log_helper "failed to restore $service DNS; keeping snapshot"
  return 1
}

restore_legacy_dns_state() {
  if [ ! -f "$DNS_STATE_FILE" ]; then
    return 1
  fi

  mode="$(sed -n '1p' "$DNS_STATE_FILE" 2>/dev/null || true)"
  applied=0
  if [ "$mode" = "EMPTY" ]; then
    logged /usr/sbin/networksetup -setdnsservers "Wi-Fi" Empty && applied=1
  elif [ "$mode" = "SERVERS" ]; then
    servers="$(tail -n +2 "$DNS_STATE_FILE" | /usr/bin/awk '/^[0-9A-Fa-f:.]+$/' | tr '\n' ' ')"
    if [ -n "$servers" ]; then
      logged /usr/sbin/networksetup -setdnsservers "Wi-Fi" $servers && applied=1
    else
      applied=1
    fi
  else
    applied=1
  fi

  if [ "$applied" = "1" ]; then
    as_user /bin/rm -f "$DNS_STATE_FILE"
    log_helper "restored legacy Wi-Fi DNS"
    return 0
  fi
  log_helper "failed to restore legacy Wi-Fi DNS; keeping snapshot"
  return 2
}

restore_system_dns() {
  restored=0
  failed=0
  if [ -d "$DNS_STATE_DIR" ]; then
    for state_file in "$DNS_STATE_DIR"/*.state; do
      [ -f "$state_file" ] || continue
      if restore_dns_state_file "$state_file"; then
        restored=1
      else
        failed=$((failed + 1))
      fi
    done
  fi
  legacy_rc="$(restore_legacy_dns_state; echo $?)"
  if [ "$legacy_rc" = "0" ]; then
    restored=1
  elif [ "$legacy_rc" = "2" ]; then
    failed=$((failed + 1))
  fi
  if [ "$restored" = "1" ]; then
    flush_system_dns
  fi
  return "$failed"
}

# The data directory belongs to the user. Root must not follow a link planted
# anywhere on that path (for example logs/mihomo.log -> /etc/sudoers).
path_is_trusted() {
  trusted_path="$1"
  while [ -n "$trusted_path" ] && [ "$trusted_path" != "/" ]; do
    if [ -L "$trusted_path" ] && [ "$(stat -f '%u' "$trusted_path" 2>/dev/null)" != 0 ]; then
      return 1
    fi
    trusted_path="${trusted_path%/*}"
  done
  return 0
}

# Prepare a path root is about to write: drop a planted link, refuse other
# non-regular files and untrusted parents.
safe_user_path() {
  path_is_trusted "${1%/*}" || return 1
  if [ -L "$1" ]; then as_user /bin/rm -f "$1" 2>/dev/null || return 1; fi
  [ ! -e "$1" ] || [ -f "$1" ]
}

helper_log() {
  if safe_user_path "$MIHOMO_LOG"; then printf '%s' "$MIHOMO_LOG"; else printf '/dev/null'; fi
}

clear_pid() {
  as_user /bin/rm -f "$PID_FILE"
  rm -f "$IDENTITY_FILE"
}

setup_paths() {
  [ -n "$APP_UID" ] || exit 78
  path_is_trusted "$APP_DATA" || exit 78
  for user_dir in "$HELPER_DIR" "$RESPONSES_DIR" "$MIHOMO_DATA" "$APP_DATA/logs" "$DNS_STATE_DIR"; do
    if [ -L "$user_dir" ]; then as_user /bin/rm -f "$user_dir"; fi
  done
  as_user /bin/mkdir -p "$HELPER_DIR" "$RESPONSES_DIR" "$MIHOMO_DATA" "$APP_DATA/logs" "$DNS_STATE_DIR"
  mkdir -p "$IDENTITY_DIR"
  chmod 700 "$IDENTITY_DIR" 2>/dev/null || true
  if [ -L "$FIFO" ] || [ ! -p "$FIFO" ]; then
    as_user /bin/rm -f "$FIFO"
    as_user /usr/bin/mkfifo "$FIFO"
  fi
  # Only the data directory's owner may send commands.
  as_user /bin/chmod 600 "$FIFO" 2>/dev/null || true
  as_user /bin/chmod 755 "$HELPER_DIR" "$RESPONSES_DIR" 2>/dev/null || true
}

is_pid_running() {
  pid="$1"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

read_pid() {
  if [ -f "$PID_FILE" ]; then
    read -r pid < "$PID_FILE"
    printf '%s' "$pid"
  fi
}

process_start_token() {
  start="$(TZ=UTC LC_ALL=C /bin/ps -p "$1" -o lstart= 2>/dev/null | /usr/bin/sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [ -n "$start" ] || return 1
  printf 'utc:%s' "$start"
}

legacy_start_matches() {
  # Preserve an old record when its original comparison still passes.
  local_start="$(/bin/ps -p "$1" -o lstart= 2>/dev/null | /usr/bin/sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [ -n "$local_start" ] && [ "$2" = "$local_start" ] && return 0
  # After a timezone change the old display is ambiguous. Anchor migration
  # to the root-owned record's write time, captured just after process launch.
  # Never adopt a stale PID merely because its executable has the same name.
  legacy_epoch="$(TZ=UTC LC_ALL=C /bin/date -j -f '%a %b %e %T %Y' "$2" +%s 2>/dev/null)" || return 1
  legacy_display="$(TZ=UTC LC_ALL=C /bin/date -r "$legacy_epoch" '+%a %b %e %T %Y' 2>/dev/null)" || return 1
  [ "$2" = "$legacy_display" ] || return 1
  utc_start="${3#utc:}"
  current_epoch="$(TZ=UTC LC_ALL=C /bin/date -j -f '%a %b %e %T %Y' "$utc_start" +%s 2>/dev/null)" || return 1
  record_epoch="$(/usr/bin/stat -f %m "$IDENTITY_FILE" 2>/dev/null)" || return 1
  case "$record_epoch" in ""|*[!0-9]*) return 1 ;; esac
  record_age=$((record_epoch - current_epoch))
  display_offset=$((legacy_epoch - current_epoch))
  [ "$record_age" -ge 0 ] && [ "$record_age" -le 5 ] &&
    [ "$display_offset" -ge -43200 ] && [ "$display_offset" -le 50400 ] &&
    [ $((display_offset % 900)) -eq 0 ]
}

write_process_identity() {
  pid="$1"
  start_token="$(process_start_token "$pid")"
  instance_token="$(/usr/bin/uuidgen 2>/dev/null || printf '%s-%s' "$pid" "$(date +%s)")"
  [ -n "$start_token" ] || return 1
  tmp_identity="$IDENTITY_FILE.tmp"
  {
    printf '%s\n' "$pid"
    printf '%s\n' "$MIHOMO"
    printf '%s\n' "$start_token"
    printf '%s\n' "$instance_token"
  } > "$tmp_identity"
  chmod 600 "$tmp_identity"
  mv "$tmp_identity" "$IDENTITY_FILE"
}

verify_process_identity() {
  pid="$1"
  [ -f "$IDENTITY_FILE" ] || return 1
  stored_pid="$(sed -n '1p' "$IDENTITY_FILE" 2>/dev/null || true)"
  stored_binary="$(sed -n '2p' "$IDENTITY_FILE" 2>/dev/null || true)"
  stored_start="$(sed -n '3p' "$IDENTITY_FILE" 2>/dev/null || true)"
  current_command="$(/bin/ps -p "$pid" -o command= 2>/dev/null || true)"
  current_start="$(process_start_token "$pid")"
  [ "$stored_pid" = "$pid" ] || return 1
  [ "$stored_binary" = "$MIHOMO" ] || return 1
  case "$current_command" in
    "$MIHOMO"|"$MIHOMO "*) ;;
    *) return 1 ;;
  esac
  [ -n "$stored_start" ] && [ -n "$current_start" ] || return 1
  case "$stored_start" in
    utc:*) [ "$stored_start" = "$current_start" ] ;;
    *)
      legacy_start_matches "$pid" "$stored_start" "$current_start" || return 1
      write_process_identity "$pid"
      ;;
  esac
}

reset_response_flags() {
  RESPONSE_TARGET_PID=""
  RESPONSE_IDENTITY_VERIFIED=false
  RESPONSE_PROCESS_EXIT_CONFIRMED=false
  RESPONSE_DNS_RESTORE_OK=false
  RESPONSE_DNS_REFRESH_OK=false
  RESPONSE_FORCED_KILL=false
}

write_response() {
  request_id="$1"
  ok="$2"
  pid="$3"
  message="$4"
  error="$5"
  tmp="$RESPONSES_DIR/$request_id.tmp"
  response="$RESPONSES_DIR/$request_id.json"
  safe_user_path "$tmp" && safe_user_path "$response" || return
  if [ -z "$pid" ]; then
    pid_json="null"
  else
    pid_json="$pid"
  fi
  if [ -z "$RESPONSE_TARGET_PID" ]; then
    target_pid_json="null"
  else
    target_pid_json="$RESPONSE_TARGET_PID"
  fi
  if [ "$ok" = "true" ]; then
    printf '{"ok":true,"pid":%s,"targetPid":%s,"identityVerified":%s,"processExitConfirmed":%s,"dnsRestoreOk":%s,"dnsRefreshOk":%s,"forcedKill":%s,"protocolVersion":"%s","message":"%s"}\n' "$pid_json" "$target_pid_json" "$RESPONSE_IDENTITY_VERIFIED" "$RESPONSE_PROCESS_EXIT_CONFIRMED" "$RESPONSE_DNS_RESTORE_OK" "$RESPONSE_DNS_REFRESH_OK" "$RESPONSE_FORCED_KILL" "$HELPER_VERSION" "$message" | user_write "$tmp"
  else
    printf '{"ok":false,"pid":%s,"targetPid":%s,"identityVerified":%s,"processExitConfirmed":%s,"dnsRestoreOk":%s,"dnsRefreshOk":%s,"forcedKill":%s,"protocolVersion":"%s","message":"%s","error":"%s"}\n' "$pid_json" "$target_pid_json" "$RESPONSE_IDENTITY_VERIFIED" "$RESPONSE_PROCESS_EXIT_CONFIRMED" "$RESPONSE_DNS_RESTORE_OK" "$RESPONSE_DNS_REFRESH_OK" "$RESPONSE_FORCED_KILL" "$HELPER_VERSION" "$message" "$error" | user_write "$tmp"
  fi
  as_user /bin/mv -f "$tmp" "$response"
}

start_mihomo() {
  request_id="$1"
  current_pid="$(read_pid)"
  if is_pid_running "$current_pid"; then
    RESPONSE_TARGET_PID="$current_pid"
    if ! verify_process_identity "$current_pid"; then
      write_response "$request_id" false "$current_pid" "identity_mismatch" "identity_mismatch"
      return
    fi
    RESPONSE_IDENTITY_VERIFIED=true
    set_system_dns
    write_response "$request_id" true "$current_pid" "already_running" ""
    return
  fi
  if [ ! -x "$MIHOMO" ]; then
    write_response "$request_id" false "" "missing_mihomo" "missing_mihomo"
    return
  fi
  if [ ! -f "$MIHOMO_CONFIG" ]; then
    write_response "$request_id" false "" "missing_config" "missing_config"
    return
  fi

  if ! safe_user_path "$PID_FILE" || ! path_is_trusted "$MIHOMO_DATA"; then
    write_response "$request_id" false "" "unsafe_data_path" "unsafe_data_path"
    return
  fi
  # The engine's output reaches the user's log through a writer running as
  # the user; the launch group reports the engine PID into the root-only dir.
  launch_file="$IDENTITY_DIR/launch.pid"
  rm -f "$launch_file"
  log_target="$(helper_log)"
  {
    "$MIHOMO" -d "$MIHOMO_DATA" -f "$MIHOMO_CONFIG" < /dev/null 2>&1 &
    printf '%s' "$!" > "$launch_file"
  } 3>&- | user_append "$log_target" 3>&- &
  pid=""
  count=0
  while [ "$count" -lt 30 ]; do
    if [ -s "$launch_file" ]; then
      read -r pid < "$launch_file"
      break
    fi
    count=$((count + 1))
    sleep 0.1
  done
  rm -f "$launch_file"
  if [ -z "$pid" ]; then
    write_response "$request_id" false "" "start_failed" "start_failed"
    return
  fi
  printf '%s' "$pid" | user_write "$PID_FILE"
  sleep 0.4
  if is_pid_running "$pid"; then
    RESPONSE_TARGET_PID="$pid"
    if ! write_process_identity "$pid" || ! verify_process_identity "$pid"; then
      write_response "$request_id" false "$pid" "identity_record_failed" "identity_record_failed"
      return
    fi
    RESPONSE_IDENTITY_VERIFIED=true
    set_system_dns
    write_response "$request_id" true "$pid" "started" ""
  else
    RESPONSE_TARGET_PID="$pid"
    RESPONSE_PROCESS_EXIT_CONFIRMED=true
    clear_pid
    restore_system_dns
    write_response "$request_id" false "$pid" "start_failed" "start_failed"
  fi
}

stop_mihomo() {
  request_id="$1"
  current_pid="$(read_pid)"
  RESPONSE_TARGET_PID="$current_pid"
  if ! is_pid_running "$current_pid"; then
    RESPONSE_PROCESS_EXIT_CONFIRMED=true
    clear_pid
    restore_system_dns
    dns_failed="$?"
    if [ "$dns_failed" -gt 0 ]; then
      write_response "$request_id" false "" "stopped_dns_partial" "stopped_dns_partial"
    else
      RESPONSE_DNS_RESTORE_OK=true
      write_response "$request_id" true "" "stopped" ""
    fi
    return
  fi

  if ! verify_process_identity "$current_pid"; then
    write_response "$request_id" false "$current_pid" "identity_mismatch" "identity_mismatch"
    return
  fi
  RESPONSE_IDENTITY_VERIFIED=true

  kill -TERM "$current_pid" 2>/dev/null || true
  # 5s grace period (50 x 0.1s) for graceful TUN/route teardown.
  count=0
  while [ "$count" -lt 50 ]; do
    if ! is_pid_running "$current_pid"; then
      RESPONSE_PROCESS_EXIT_CONFIRMED=true
      clear_pid
      restore_system_dns
      dns_failed="$?"
      if [ "$dns_failed" -gt 0 ]; then
        write_response "$request_id" false "" "stopped_dns_partial" "stopped_dns_partial"
      else
        RESPONSE_DNS_RESTORE_OK=true
        write_response "$request_id" true "" "stopped" ""
      fi
      return
    fi
    count=$((count + 1))
    sleep 0.1
  done

  kill -KILL "$current_pid" 2>/dev/null || true
  RESPONSE_FORCED_KILL=true
  # After SIGKILL, poll until the PID is reaped (up to 3s) so the kernel can
  # release the TUN device and routes before we delete the PID file and
  # restore DNS.  This mirrors the TS-side strict-stop protocol.
  count=0
  while [ "$count" -lt 30 ]; do
    if ! is_pid_running "$current_pid"; then
      break
    fi
    count=$((count + 1))
    sleep 0.1
  done

  if is_pid_running "$current_pid"; then
    # Process refused to die even after SIGKILL; keep the PID file so a later
    # start does not lose track of the survivor, but still attempt DNS restore.
    restore_system_dns
    write_response "$request_id" false "$current_pid" "stop_timeout" "stop_timeout"
    return
  fi

  RESPONSE_PROCESS_EXIT_CONFIRMED=true
  clear_pid
  restore_system_dns
  dns_failed="$?"
  if [ "$dns_failed" -gt 0 ]; then
    write_response "$request_id" false "" "killed_dns_partial" "killed_dns_partial"
  else
    RESPONSE_DNS_RESTORE_OK=true
    write_response "$request_id" true "" "killed" ""
  fi
}

status_mihomo() {
  request_id="$1"
  current_pid="$(read_pid)"
  if is_pid_running "$current_pid"; then
    RESPONSE_TARGET_PID="$current_pid"
    if verify_process_identity "$current_pid"; then
      RESPONSE_IDENTITY_VERIFIED=true
    fi
    write_response "$request_id" true "$current_pid" "running" ""
  else
    write_response "$request_id" true "" "stopped" ""
  fi
}

restore_orphan_dns() {
  request_id="$1"
  current_pid="$(read_pid)"
  if is_pid_running "$current_pid"; then
    RESPONSE_TARGET_PID="$current_pid"
    if verify_process_identity "$current_pid"; then
      RESPONSE_IDENTITY_VERIFIED=true
    fi
    write_response "$request_id" true "$current_pid" "skipped_running" ""
    return
  fi
  restore_system_dns
  failed="$?"
  if [ "$failed" -gt 0 ]; then
    write_response "$request_id" false "" "orphan_dns_partial" "orphan_dns_partial"
    return
  fi
  RESPONSE_DNS_RESTORE_OK=true
  write_response "$request_id" true "" "orphan_dns_restored" ""
}

setup_paths
DNS_LAST_POLL=0
DNS_PENDING_ROUTE=""
DNS_ORPHAN_SINCE=""
# macOS /bin/sh supports timed read. Opening both ends keeps an idle FIFO from
# blocking open(), and lets the same serial loop reconcile DNS between requests.
exec 3<> "$FIFO"
while :; do
  poll_system_dns
  if IFS= read -r -t 2 line <&3; then
    # No pathname expansion: a request is only split into words.
    set -f
    set -- $line
    set +f
    request_id="${1:-}"
    command="${2:-}"
    case "$request_id" in
      ""|*[!A-Za-z0-9_]*)
        continue
        ;;
    esac
    path_is_trusted "$APP_DATA" || continue

    case "$command" in
      start)
        reset_response_flags
        start_mihomo "$request_id"
        ;;
      stop)
        reset_response_flags
        stop_mihomo "$request_id"
        ;;
      status)
        reset_response_flags
        status_mihomo "$request_id"
        ;;
      refresh-dns)
        reset_response_flags
        refresh_mihomo_dns "$request_id"
        ;;
      restore-orphan-dns)
        reset_response_flags
        restore_orphan_dns "$request_id"
        ;;
      *)
        write_response "$request_id" false "" "unknown_command" "unknown_command"
        ;;
    esac
  fi
done

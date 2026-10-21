#!/bin/sh
# Invoked only after macOS grants administrator authorization. The core passes
# this script inline, never from the user-writable staging directory. Paths are
# passed explicitly so the same transaction can be tested without launchd.
set -eu
stage="$1"
binary="$2"
tools="$3"
daemons="$4"
backup_root="$5"
launchctl="$6"
install_command="$7"
expected_helper="$8"
expected_plist="$9"
expected_binary="${10}"
helper="$tools/com.split-vpn.helper"
mihomo="$tools/com.split-vpn.mihomo"
plist="$daemons/com.split-vpn.helper.plist"
job="system/com.split-vpn.helper"
mkdir -p "$tools" "$daemons" "$backup_root"
backup="$(mktemp -d "$backup_root/upgrade.XXXXXXXX")"
chmod 700 "$backup"
# Copy the staged files into a root-only directory once and verify those
# copies, so the user-writable staging area cannot swap them afterwards.
work="$(mktemp -d "$backup_root/stage.XXXXXXXX")"
chmod 700 "$work"
for path in "$helper" "$mihomo" "$plist"; do
  if [ -f "$path" ]; then cp -p "$path" "$backup/$(basename "$path")"; fi
done
changed=false
rollback() {
  result="$?"
  trap - EXIT HUP INT TERM
  if [ "$changed" = true ]; then
    "$launchctl" bootout system "$plist" >/dev/null 2>&1 || true
    for path in "$helper" "$mihomo" "$plist"; do
      original="$backup/$(basename "$path")"
      if [ -f "$original" ]; then
        cp -p "$original" "$path.rollback" && mv -f "$path.rollback" "$path" || true
      else
        rm -f "$path"
      fi
    done
    if [ -f "$plist" ]; then
      "$launchctl" bootstrap system "$plist" >/dev/null 2>&1 || true
      "$launchctl" kickstart "$job" >/dev/null 2>&1 || true
    fi
  fi
  rm -f "$helper.next" "$mihomo.next" "$plist.next"
  rm -rf "$work"
  printf '%s\n' "helper upgrade failed; recovery files: $backup" >&2
  exit "$result"
}
trap rollback EXIT
trap 'exit 1' HUP INT TERM
digest() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }
cp "$stage/helper.sh" "$work/helper.sh"
cp "$stage/helper.plist" "$work/helper.plist"
cp "$binary" "$work/mihomo"
if [ "$(digest "$work/helper.sh")" != "$expected_helper" ] ||
  [ "$(digest "$work/helper.plist")" != "$expected_plist" ] ||
  [ "$(digest "$work/mihomo")" != "$expected_binary" ]; then
  printf '%s\n' 'staged helper files changed before installation' >&2
  exit 1
fi
# Prepare every new file before stopping the old job; replace executables
# atomically so the running binary is never overwritten in place.
"$install_command" -o root -g wheel -m 755 "$work/helper.sh" "$helper.next"
"$install_command" -o root -g wheel -m 755 "$work/mihomo" "$mihomo.next"
"$install_command" -o root -g wheel -m 644 "$work/helper.plist" "$plist.next"
changed=true
"$launchctl" bootout system "$plist" >/dev/null 2>&1 || true
mv -f "$helper.next" "$helper"
mv -f "$mihomo.next" "$mihomo"
mv -f "$plist.next" "$plist"
"$launchctl" enable "$job"
"$launchctl" bootstrap system "$plist"
# bootstrap + RunAtLoad already starts the daemon; -k would kill it again.
"$launchctl" kickstart "$job"
trap - EXIT HUP INT TERM
# The new daemon runs; earlier rollback copies are no longer needed.
rm -rf "$work" "$backup_root"/upgrade.*
printf '%s\n' 'helper upgrade installed'

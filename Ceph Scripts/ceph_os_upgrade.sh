#!/bin/bash
set -uo pipefail

# ====================================================
# Ceph Rolling OS Upgrade
# Run in a 'screen' session on a Ceph gateway node.
#
# Author: LewsTherinSedai
# https://github.com/LewsTherinSedai/Public
# SPDX-License-Identifier: GPL-3.0-only
#
# Merges production-proven rolling upgrade logic with
# CLI features (dry-run, llama animation, interactive
# confirmations, configurable nodes).
# ====================================================

# ---------- Defaults ----------
DRY_RUN=true
LLAMA=false
AUTO_YES=false
NODES=()
SSH_USER="root"
REBOOT_WAIT=300
EXPECTED_OSDS=""
LOG_FILE="${LOG_FILE:-/var/log/ceph_update.log}"
OSD_WAIT_TIMEOUT="${OSD_WAIT_TIMEOUT:-7200}"        # max seconds waiting for OSDs up/in
HEALTH_WAIT_TIMEOUT="${HEALTH_WAIT_TIMEOUT:-7200}"  # max seconds waiting for cluster health

FLAGS=(noout norebalance norecover)

# ---------- Runtime state ----------
FLAGS_SET=false
STATUS_FILE=""
ANIM_PID=""
ALT_SCREEN=false
LOCAL_BOOT_ID=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)

# ---------- Colors ----------
RESET="\e[0m"
RED="\e[91m"
GREEN="\e[92m"
YELLOW="\e[93m"
CYAN="\e[96m"
MAGENTA="\e[95m"
WHITE="\e[97m"
BOLD="\e[1m"

if [[ ! -t 1 ]]; then
  RESET="" RED="" GREEN="" YELLOW="" CYAN="" MAGENTA="" WHITE="" BOLD=""
fi

# ---------- Alternate screen helpers ----------
enter_alt_screen() {
  tput smcup 2>/dev/null || printf '\e[?1049h'
  tput clear 2>/dev/null || printf '\e[2J\e[H'
  tput civis 2>/dev/null || true
  ALT_SCREEN=true
}

leave_alt_screen() {
  if $ALT_SCREEN; then
    tput cnorm 2>/dev/null || true
    tput clear 2>/dev/null || printf '\e[2J\e[H'
    tput rmcup 2>/dev/null || printf '\e[?1049l'
    ALT_SCREEN=false
  fi
}

# ---------- Cleanup (restores flags on crash) ----------
cleanup() {
  if [[ -n "${ANIM_PID:-}" ]]; then
    kill "$ANIM_PID" 2>/dev/null || true
    wait "$ANIM_PID" 2>/dev/null || true
    ANIM_PID=""
  fi
  leave_alt_screen
  if $FLAGS_SET && ! $DRY_RUN; then
    echo ""
    echo "WARNING: Restoring Ceph maintenance flags due to unexpected exit..."
    for flag in "${FLAGS[@]}"; do
      ceph osd unset "$flag" 2>/dev/null || true
    done
    echo "Flags restored. Verify cluster health: ceph -s"
  fi
  [[ -n "${STATUS_FILE:-}" ]] && rm -f "$STATUS_FILE"
  tput cnorm 2>/dev/null || true
  echo
}
trap cleanup EXIT

# ---------- Usage ----------
usage() {
  cat <<EOF
Ceph Rolling OS Upgrade
Run in a 'screen' session on a Ceph gateway node.

Usage: $(basename "$0") [OPTIONS]

Options:
  --nodes NODE1,NODE2,...   Comma-separated list of nodes (required)
  --execute                 Actually perform the upgrade (default: dry-run)
  --dry-run                 Simulate only - no changes made (default)
  --llama                   Walking llama animation while it runs
  --yes, -y                 Skip interactive confirmations
  --ssh-user USER           SSH user for remote commands (default: root)
  --expected-osds N         Expected OSD count (default: auto-detect)
  --reboot-wait SECS        Max seconds to wait for a node to reboot and return (default: 300)
  -h, --help                Show this help

Environment:
  LOG_FILE                  Log file path (default: /var/log/ceph_update.log)
  OSD_WAIT_TIMEOUT          Max seconds to wait for OSDs up/in (default: 7200)
  HEALTH_WAIT_TIMEOUT       Max seconds to wait for cluster health (default: 7200)

Examples:
  $(basename "$0") --nodes ceph01,ceph02,ceph03 --llama
  $(basename "$0") --nodes ceph01,ceph02,ceph03 --execute --yes
  $(basename "$0") --nodes ceph01,ceph02,ceph03 --execute --expected-osds 12
EOF
  exit "${1:-0}"
}

# ---------- Argument parsing ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --nodes)         IFS=',' read -ra NODES <<< "${2:?--nodes requires a value}"; shift 2 ;;
    --execute)       DRY_RUN=false; shift ;;
    --dry-run)       DRY_RUN=true; shift ;;
    --llama)         LLAMA=true; shift ;;
    --yes|-y)        AUTO_YES=true; shift ;;
    --ssh-user)      SSH_USER="${2:?--ssh-user requires a value}"; shift 2 ;;
    --expected-osds) EXPECTED_OSDS="${2:?--expected-osds requires a value}"; shift 2 ;;
    --reboot-wait)   REBOOT_WAIT="${2:?--reboot-wait requires a value}"; shift 2 ;;
    -h|--help)       usage 0 ;;
    *)               printf "${RED}Unknown option: %s${RESET}\n" "$1"; usage 1 ;;
  esac
done

if [[ ${#NODES[@]} -eq 0 ]]; then
  printf "${RED}Error: --nodes is required${RESET}\n"
  usage 1
fi

# ---------- IPC for llama animation ----------
STATUS_FILE=$(mktemp "${TMPDIR:-/tmp}/ceph-upgrade-status.XXXXXX")
echo "Initializing..." > "$STATUS_FILE"

# ---------- Remote upgrade script (shared by both passes) ----------
# Runs on each node: update, dist-upgrade, then reboot only if required.
read -r -d '' REMOTE_UPGRADE <<'REMOTE' || true
set -e
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=l
apt-get update
yes '' | apt-get -y -o Dpkg::Options::="--force-confdef" \
                 -o Dpkg::Options::="--force-confold" dist-upgrade
if [ -f /var/run/reboot-required ]; then
  echo "Reboot required by: $(cat /var/run/reboot-required.pkgs 2>/dev/null | tr '\n' ' ')"
  reboot
else
  echo "No reboot required; skipping reboot for this node"
fi
REMOTE

# ---------- Static llama (original art) ----------
draw_llama_banner() {
  printf "%b\n" "${CYAN}                __--_--_-"
  printf "%b\n" "               ( I wish I  )"
  printf "%b\n" "              ( were a real )"
  printf "%b\n" "              (    llama   )"
  printf "%b\n" "               ( in Peru! )"
  printf "%b\n" "              o (__--_--_)"
  printf "%b\n" "           , o"
  printf "%b\n" "${MAGENTA}          ~)"
  printf "%b\n" "           (_---;"
  printf "%b\n" "              /|~|\\"
  printf "%b\n" "${RESET}"
}

# ---------- Llama walking-in-place animation (alternate screen) ----------
# Draws a fixed dashboard at absolute rows on the alternate screen buffer.
# Never scrolls (no newlines, never writes the bottom-right cell), so the
# llama stays put and leaves nothing behind in the scrollback.
llama_walk() {
  local status_file="$1"
  local dry_run="$2"
  local frame=0
  local mode_tag="DRY-RUN"
  [[ "$dry_run" == "false" ]] && mode_tag="LIVE"

  tput civis 2>/dev/null || true

  while true; do
    local cols
    cols=$(tput cols 2>/dev/null || echo 80)

    local msg
    msg=$(cat "$status_file" 2>/dev/null || echo "...")
    if (( ${#msg} > cols - 12 )); then
      msg="${msg:0:$((cols - 15))}..."
    fi

    local feet
    if (( frame % 2 == 0 )); then
      feet='/ \/ \'
    else
      feet='\ /\ /'
    fi

    tput cup 0 0 2>/dev/null;  printf '\e[K%b' "${BOLD}${YELLOW}+======================================+${RESET}"
    tput cup 1 0 2>/dev/null;  printf '\e[K%b' "${BOLD}${YELLOW}|    Ceph Rolling OS Upgrade           |${RESET}"
    tput cup 2 0 2>/dev/null;  printf '\e[K%b' "${BOLD}${YELLOW}+======================================+${RESET}"
    tput cup 4 0 2>/dev/null;  printf '\e[K  %bMode: %s%b' "$WHITE" "$mode_tag" "$RESET"

    tput cup 6 0 2>/dev/null;  printf '\e[K%b' "${CYAN}                __--_--_-${RESET}"
    tput cup 7 0 2>/dev/null;  printf '\e[K%b' "${CYAN}               ( I wish I  )${RESET}"
    tput cup 8 0 2>/dev/null;  printf '\e[K%b' "${CYAN}              ( were a real )${RESET}"
    tput cup 9 0 2>/dev/null;  printf '\e[K%b' "${CYAN}              (    llama   )${RESET}"
    tput cup 10 0 2>/dev/null; printf '\e[K%b' "${CYAN}               ( in Peru! )${RESET}"
    tput cup 11 0 2>/dev/null; printf '\e[K%b' "${CYAN}              o (__--_--_)${RESET}"
    tput cup 12 0 2>/dev/null; printf '\e[K%b' "${CYAN}           , o${RESET}"
    tput cup 13 0 2>/dev/null; printf '\e[K%b' "${MAGENTA}          ~)${RESET}"
    tput cup 14 0 2>/dev/null; printf '\e[K%b' "${MAGENTA}           (_---;${RESET}"
    tput cup 15 0 2>/dev/null; printf '\e[K%b' "${MAGENTA}              /|~|\\\\${RESET}"
    tput cup 16 0 2>/dev/null; printf '\e[K%b' "${MAGENTA}              ${feet}${RESET}"

    tput cup 18 0 2>/dev/null; printf '\e[K  %b[%s]%b %s' "$WHITE" "$mode_tag" "$RESET" "$msg"

    # Park cursor on a clear line below the dashboard (used for prompts too)
    tput cup 19 0 2>/dev/null; printf '\e[K'

    frame=$((frame + 1))
    sleep 0.5
  done
}

# ---------- Logging ----------
log() {
  local msg="$1"
  if ! $DRY_RUN; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') $msg" >> "$LOG_FILE"
  fi
  if $LLAMA; then
    echo "$msg" > "$STATUS_FILE"
  else
    local prefix="DRY-RUN"
    $DRY_RUN || prefix="LIVE"
    printf "%b\n" "${WHITE}[${prefix}] ${msg}${RESET}"
  fi
}

log_ok() {
  local msg="$1"
  if ! $DRY_RUN; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') OK: $msg" >> "$LOG_FILE"
  fi
  if [[ -n "${ANIM_PID:-}" ]]; then
    echo "[OK] $msg" > "$STATUS_FILE"
  else
    printf "%b\n" "${GREEN} [OK] ${msg}${RESET}"
  fi
}

log_warn() {
  local msg="$1"
  if ! $DRY_RUN; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') WARN: $msg" >> "$LOG_FILE"
  fi
  if [[ -n "${ANIM_PID:-}" ]]; then
    echo "[WARN] $msg" > "$STATUS_FILE"
  else
    printf "%b\n" "${YELLOW} [WARN] ${msg}${RESET}"
  fi
}

log_err() {
  local msg="$1"
  if ! $DRY_RUN; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: $msg" >> "$LOG_FILE"
  fi
  if [[ -n "${ANIM_PID:-}" ]]; then
    echo "[ERROR] $msg" > "$STATUS_FILE"
  else
    printf "%b\n" "${RED} [ERROR] ${msg}${RESET}"
  fi
}

# ---------- Confirmation ----------
confirm() {
  if $AUTO_YES; then return 0; fi
  if [[ -n "${ANIM_PID:-}" ]]; then
    kill -STOP "$ANIM_PID" 2>/dev/null || true
  fi
  tput cnorm 2>/dev/null || true
  if $ALT_SCREEN; then
    tput cup 19 0 2>/dev/null || true
    printf '\e[K'
  fi
  printf "%b" "${YELLOW}$1 [y/N]: ${RESET}"
  read -r response
  tput civis 2>/dev/null || true
  if [[ -n "${ANIM_PID:-}" ]]; then
    kill -CONT "$ANIM_PID" 2>/dev/null || true
  fi
  [[ "$response" =~ ^[Yy]([Ee][Ss])?$ ]]
}

# ---------- Ceph flag management ----------
set_ceph_flags() {
  if $DRY_RUN; then
    for flag in "${FLAGS[@]}"; do
      log "Would: ceph osd set $flag"
    done
    FLAGS_SET=true
    return 0
  fi
  # Mark before setting so the cleanup trap restores a partial set too
  FLAGS_SET=true
  for flag in "${FLAGS[@]}"; do
    if ! ceph osd set "$flag"; then
      log_err "Failed to set Ceph flag '${flag}' - aborting before touching any node"
      exit 1
    fi
    log "Set flag $flag"
  done
}

unset_ceph_flags() {
  if $DRY_RUN; then
    for flag in "${FLAGS[@]}"; do
      log "Would: ceph osd unset $flag"
    done
    FLAGS_SET=false
    return 0
  fi
  for flag in "${FLAGS[@]}"; do
    if ! ceph osd unset "$flag"; then
      # Keep FLAGS_SET=true so the cleanup trap retries on exit
      log_err "Failed to unset Ceph flag '${flag}' - aborting (cleanup will retry)"
      exit 1
    fi
    log "Unset flag $flag"
  done
  FLAGS_SET=false
}

# ---------- Boot id helpers ----------
# /proc/sys/kernel/random/boot_id is unique per boot, so comparing it
# before and after an upgrade reliably detects whether a reboot happened.
get_boot_id() {
  local node="$1"
  ssh -o BatchMode=yes -o ConnectTimeout=5 "${SSH_USER}@${node}" \
    'cat /proc/sys/kernel/random/boot_id' 2>/dev/null
}

# ---------- Self-host guard ----------
# Never allow the node running this script into the upgrade list: it would
# reboot itself mid-run with maintenance flags still set.
is_this_host() {
  local node="${1,,}" name
  for name in "${LOCAL_NAMES[@]}"; do
    name="${name,,}"
    [[ -z "$name" ]] && continue
    if [[ "$node" == "$name" || "${node%%.*}" == "${name%%.*}" ]]; then
      return 0
    fi
  done
  return 1
}

# ---------- SSH pre-flight ----------
# Always tests real SSH connectivity, even in dry-run, verifies the remote
# user can run apt-get, and confirms the node is not the local host by
# comparing boot ids (catches IPs/aliases the hostname check misses).
check_ssh() {
  local node="$1"
  if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "${SSH_USER}@${node}" 'true' 2>/dev/null; then
    log_err "Cannot SSH to ${node} as ${SSH_USER}"
    return 1
  fi
  log "SSH to ${node}: connected"
  local remote_boot_id=""
  remote_boot_id=$(get_boot_id "$node") || true
  if [[ -n "$remote_boot_id" && -n "$LOCAL_BOOT_ID" && "$remote_boot_id" == "$LOCAL_BOOT_ID" ]]; then
    log_err "${node} is this host (same boot id) - run the script from a node that is not being upgraded"
    return 1
  fi
  local priv_check=""
  priv_check=$(ssh -o BatchMode=yes -o ConnectTimeout=5 "${SSH_USER}@${node}" \
    'whoami && apt-get --version >/dev/null 2>&1 && echo APT_OK || echo APT_FAIL' 2>/dev/null) || true
  if [[ "$priv_check" != *"APT_OK"* ]]; then
    log_err "${node}: apt-get not available or not permitted for ${SSH_USER}"
    return 1
  fi
  log "SSH to ${node}: privileges OK"
}

# ---------- Run one apt update + dist-upgrade pass on a node ----------
# Output always goes to $LOG_FILE; without --llama it is echoed to the
# terminal too. Returns the ssh exit code: 255 usually just means the
# connection dropped because the node started rebooting; anything else
# non-zero is a real remote failure (set -e aborts the remote script).
run_upgrade_pass() {
  local node="$1"
  local rc=0
  if $LLAMA; then
    ssh -o BatchMode=yes -o ConnectTimeout=10 "${SSH_USER}@${node}" bash -s \
      <<<"$REMOTE_UPGRADE" >>"$LOG_FILE" 2>&1 || rc=$?
  else
    ssh -o BatchMode=yes -o ConnectTimeout=10 "${SSH_USER}@${node}" bash -s \
      <<<"$REMOTE_UPGRADE" 2>&1 | tee -a "$LOG_FILE" || rc=$?
  fi
  return "$rc"
}

# ---------- Wait for node to return after an upgrade pass ----------
# Reboot-aware: succeeds when the boot id has changed (node rebooted and
# is back), or when the node is reachable on the same boot with no reboot
# pending. Avoids the race where SSH still answers because the node has
# not actually gone down yet.
wait_for_node_after_upgrade() {
  local host="$1"
  local pre_boot_id="$2"

  if $DRY_RUN; then
    sleep 2
    log "${host} is back (simulated)"
    return 0
  fi

  local start=$SECONDS
  while (( SECONDS - start < REBOOT_WAIT )); do
    local cur_boot_id=""
    cur_boot_id=$(get_boot_id "$host") || true
    if [[ -n "$cur_boot_id" ]]; then
      if [[ -n "$pre_boot_id" && "$cur_boot_id" != "$pre_boot_id" ]]; then
        log "${host} rebooted and is back (boot id changed)"
        return 0
      fi
      local rr_rc=0
      ssh -o BatchMode=yes -o ConnectTimeout=5 "${SSH_USER}@${host}" \
        'test -f /var/run/reboot-required' 2>/dev/null || rr_rc=$?
      if (( rr_rc == 1 )); then
        log "${host} reachable; no reboot was required"
        return 0
      elif (( rr_rc == 0 )); then
        log "Waiting for ${host} to reboot (reboot still pending)..."
      else
        log "Waiting for ${host} (connection unstable)..."
      fi
    else
      log "Waiting for ${host} to become reachable..."
    fi
    sleep 10
  done
  log_err "${host} did not come back within ${REBOOT_WAIT}s"
  return 1
}

# ---------- Wait for all OSDs up/in (JSON via python3) ----------
wait_for_osds() {
  if $DRY_RUN; then
    sleep 2
    log "OSDs up/in (simulated)"
    return 0
  fi

  local start=$SECONDS
  while (( SECONDS - start < OSD_WAIT_TIMEOUT )); do
    local counts=""
    counts=$(ceph osd stat -f json 2>/dev/null | \
      python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('num_osds',0), d.get('num_up_osds',0), d.get('num_in_osds',0))" 2>/dev/null) || true
    if [[ -z "$counts" ]]; then
      log "Waiting for OSD stats..."
      sleep 10
      continue
    fi
    local total up num_in
    read -r total up num_in <<< "$counts"
    local expected="${EXPECTED_OSDS:-$total}"
    if [[ -n "$expected" ]] && (( up >= expected && num_in >= expected )); then
      log "OSDs up/in: total=$total up=$up in=$num_in (expected=$expected)"
      return 0
    fi
    log "Waiting for OSDs: total=$total up=$up in=$num_in (need $expected)"
    sleep 10
  done
  log_err "Timed out after ${OSD_WAIT_TIMEOUT}s waiting for OSDs up/in"
  return 1
}

# ---------- Wait for consecutive HEALTH_OK (JSON via python3) ----------
# Treats HEALTH_WARN as OK if the only warnings are PG_NOT_SCRUBBED
# and/or PG_NOT_DEEP_SCRUBBED, since those are benign during rolling upgrades.
wait_for_health() {
  local required_ok=${1:-3}
  local consecutive_ok=0

  if $DRY_RUN; then
    sleep 2
    log "Cluster HEALTH_OK (simulated, ${required_ok}/${required_ok})"
    return 0
  fi

  local start=$SECONDS
  while (( SECONDS - start < HEALTH_WAIT_TIMEOUT )); do
    local health_result=""
    health_result=$(ceph status -f json 2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
status = d['health']['status']
if status == 'HEALTH_OK':
    print('OK')
elif status == 'HEALTH_WARN':
    checks = set(d['health'].get('checks', {}).keys())
    benign = {'PG_NOT_DEEP_SCRUBBED', 'PG_NOT_SCRUBBED'}
    if checks and checks.issubset(benign):
        print('OK_SCRUB_WARN:' + ','.join(sorted(checks)))
    else:
        other = checks - benign
        print('WARN:' + ','.join(sorted(other)))
else:
    print(status)
" 2>/dev/null) || health_result="UNKNOWN"

    if [[ "$health_result" == "OK" ]]; then
      consecutive_ok=$((consecutive_ok + 1))
      log "Cluster health: HEALTH_OK ($consecutive_ok/$required_ok)"
      if (( consecutive_ok >= required_ok )); then
        log "Cluster reached HEALTH_OK after $consecutive_ok consecutive checks"
        return 0
      fi
    elif [[ "$health_result" == OK_SCRUB_WARN:* ]]; then
      consecutive_ok=$((consecutive_ok + 1))
      local scrub_detail="${health_result#OK_SCRUB_WARN:}"
      log "Cluster health: HEALTH_WARN (benign: ${scrub_detail}) - continuing ($consecutive_ok/$required_ok)"
      if (( consecutive_ok >= required_ok )); then
        log "Cluster healthy (ignoring scrub warnings) after $consecutive_ok consecutive checks"
        return 0
      fi
    else
      if (( consecutive_ok > 0 )); then
        log_warn "Health not OK: $health_result (resetting count)"
      else
        log "Cluster health: $health_result"
      fi
      consecutive_ok=0
    fi
    sleep 10
  done
  log_err "Timed out after ${HEALTH_WAIT_TIMEOUT}s waiting for cluster health"
  return 1
}

# =====================================================
# Main
# =====================================================
echo
printf "%b\n" "${BOLD}${YELLOW}+======================================+${RESET}"
printf "%b\n" "${BOLD}${YELLOW}|    Ceph Rolling OS Upgrade           |${RESET}"
printf "%b\n" "${BOLD}${YELLOW}+======================================+${RESET}"

if $DRY_RUN; then
  printf "%b\n" "${CYAN}  Mode:  DRY RUN (no changes will be made)${RESET}"
else
  printf "%b\n" "${RED}${BOLD}  Mode:  *** LIVE EXECUTION ***${RESET}"
fi
printf "%b\n" "${WHITE}  Nodes: ${NODES[*]}${RESET}"
printf "%b\n" "${WHITE}  SSH:   ${SSH_USER}@<node>${RESET}"
if [[ -n "$EXPECTED_OSDS" ]]; then
  printf "%b\n" "${WHITE}  OSDs:  expecting ${EXPECTED_OSDS}${RESET}"
fi
if ! $DRY_RUN; then
  printf "%b\n" "${WHITE}  Log:   ${LOG_FILE}${RESET}"
fi
echo

# Pre-flight: log file writable (live runs log every step + apt output)
if ! $DRY_RUN; then
  if ! touch "$LOG_FILE" 2>/dev/null || [[ ! -w "$LOG_FILE" ]]; then
    printf "%b\n" "${RED} [ERROR] Cannot write to log file ${LOG_FILE} (run with sufficient privileges or set LOG_FILE=/path/you/can/write)${RESET}"
    exit 1
  fi
fi

# Pre-flight: refuse to include the host running this script
mapfile -t LOCAL_NAMES < <({ hostname; hostname -s; hostname -f; } 2>/dev/null | sort -u)
for node in "${NODES[@]}"; do
  if is_this_host "$node"; then
    log_err "Node list includes this host (${node}). Run the script from a node that is not being upgraded."
    exit 1
  fi
done

# Pre-flight: SSH connectivity
log "Pre-flight: checking SSH connectivity..."
ssh_ok=true
for node in "${NODES[@]}"; do
  if ! check_ssh "$node"; then
    ssh_ok=false
  fi
done
if ! $ssh_ok; then
  log_err "SSH pre-flight failed. Fix connectivity and retry."
  exit 1
fi
log_ok "SSH connectivity verified for all nodes"

# Pre-flight: Ceph cluster reachable
log "Pre-flight: checking Ceph cluster connectivity..."
if ! ceph -s &>/dev/null; then
  log_err "Cannot reach Ceph cluster (ceph -s failed). Check admin keyring."
  exit 1
fi
log_ok "Ceph cluster is reachable"
echo

# Confirm before starting
if ! $DRY_RUN; then
  if ! confirm "This will upgrade and reboot ${#NODES[@]} node(s). Proceed?"; then
    echo "Aborted."
    exit 0
  fi
fi

# Start llama animation on an alternate screen buffer (stable canvas)
if $LLAMA; then
  enter_alt_screen
  llama_walk "$STATUS_FILE" "$DRY_RUN" &
  ANIM_PID=$!
fi

total=${#NODES[@]}
current=0

for node in "${NODES[@]}"; do
  current=$((current + 1))

  if ! $LLAMA; then
    echo
    printf "%b\n" "${BOLD}${MAGENTA}--- Node ${current}/${total}: ${node} ---${RESET}"
  fi

  if ! $AUTO_YES && (( current > 1 )); then
    if ! confirm "Proceed with ${node} (${current}/${total})?"; then
      log_warn "Skipped ${node}"
      continue
    fi
  fi

  log "Starting update of ${node}"

  # -- Set maintenance flags --
  log "[${current}/${total}] ${node}: setting Ceph maintenance flags"
  set_ceph_flags

  # -- Update + reboot via SSH --
  log "[${current}/${total}] ${node}: running apt update + dist-upgrade"
  pre_boot_id=""
  if $DRY_RUN; then
    log "Would SSH to ${SSH_USER}@${node} and run:"
    log "  apt-get update"
    log "  apt-get dist-upgrade (NEEDRESTART_MODE=l, --force-confdef/confold)"
    log "  reboot if /var/run/reboot-required exists"
  else
    pre_boot_id=$(get_boot_id "$node") || true
    if [[ -z "$pre_boot_id" ]]; then
      log_warn "${node}: could not read boot id; falling back to reboot-required detection only"
    fi
    ssh_rc=0
    run_upgrade_pass "$node" || ssh_rc=$?
    if (( ssh_rc != 0 && ssh_rc != 255 )); then
      log_err "${node}: apt upgrade failed (remote exit code ${ssh_rc}); see ${LOG_FILE}. Aborting."
      exit 1
    fi
    log "Upgrade pass finished on ${node} (ssh exit code: ${ssh_rc})"
  fi

  # -- Wait for node to return (boot-id aware, no fixed-sleep race) --
  log "[${current}/${total}] ${node}: waiting for host to return"
  wait_for_node_after_upgrade "$node" "$pre_boot_id" || { log_err "${node} did not return after update; aborting"; exit 1; }

  # -- Wait for OSDs up/in --
  log "[${current}/${total}] ${node}: waiting for all OSDs up/in"
  wait_for_osds || exit 1

  # -- Stabilization pause + recheck --
  log "[${current}/${total}] ${node}: pausing for OSD state to stabilize"
  if $DRY_RUN; then sleep 2; else sleep 20; fi
  wait_for_osds || exit 1

  # -- Second update pass (catches packages needing post-reboot install; --
  # -- reboots again if that pass requires it) --
  log "[${current}/${total}] ${node}: second update pass"
  if $DRY_RUN; then
    log "Would run second apt-get update + dist-upgrade on ${node}"
  else
    pre_boot_id=$(get_boot_id "$node") || true
    ssh_rc=0
    run_upgrade_pass "$node" || ssh_rc=$?
    if (( ssh_rc != 0 && ssh_rc != 255 )); then
      log_err "${node}: second upgrade pass failed (remote exit code ${ssh_rc}); see ${LOG_FILE}. Aborting."
      exit 1
    fi
    wait_for_node_after_upgrade "$node" "$pre_boot_id" || { log_err "${node} did not return after second pass; aborting"; exit 1; }
    wait_for_osds || exit 1
  fi

  # -- Unset maintenance flags --
  log "[${current}/${total}] ${node}: unsetting Ceph maintenance flags"
  unset_ceph_flags

  # -- Wait for cluster health (3 consecutive OK) --
  log "[${current}/${total}] ${node}: waiting for cluster to become healthy"
  wait_for_health 3 || exit 1

  # -- Extra verification after pause --
  log "[${current}/${total}] ${node}: verifying health persists"
  if $DRY_RUN; then sleep 2; else sleep 20; fi
  wait_for_health 2 || exit 1

  log_ok "Completed update of ${node} (${current}/${total})"
done

# -- Stop animation and restore normal screen --
if [[ -n "${ANIM_PID:-}" ]]; then
  kill "$ANIM_PID" 2>/dev/null || true
  wait "$ANIM_PID" 2>/dev/null || true
  ANIM_PID=""
fi
leave_alt_screen

echo
printf "%b\n" "${BOLD}${GREEN}+======================================+${RESET}"
printf "%b\n" "${BOLD}${GREEN}|    Rolling upgrade complete!         |${RESET}"
printf "%b\n" "${BOLD}${GREEN}+======================================+${RESET}"
printf "%b\n" "${WHITE}  Upgraded ${total} node(s): ${NODES[*]}${RESET}"

if $LLAMA; then
  echo
  printf "%b\n" "${CYAN}                __--_--_-"
  printf "%b\n" "               ( All done! )"
  printf "%b\n" "              o (__--_--_)"
  printf "%b\n" "           , o"
  printf "%b\n" "${MAGENTA}          ~)"
  printf "%b\n" "           (_---;"
  printf "%b\n" "              /|~|\\"
  printf "%b\n" "${RESET}"
fi

log "All nodes updated successfully"
echo

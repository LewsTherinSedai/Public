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

FLAGS=(noout norebalance norecover)

# ---------- Runtime state ----------
FLAGS_SET=false
STATUS_FILE=""
ANIM_PID=""

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

# ---------- Cleanup (restores flags on crash) ----------
cleanup() {
  if $FLAGS_SET && ! $DRY_RUN; then
    echo ""
    echo "WARNING: Restoring Ceph maintenance flags due to unexpected exit..."
    for flag in "${FLAGS[@]}"; do
      ceph osd unset "$flag" 2>/dev/null || true
    done
    echo "Flags restored. Verify cluster health: ceph -s"
  fi
  if [[ -n "${ANIM_PID:-}" ]]; then
    kill "$ANIM_PID" 2>/dev/null || true
    wait "$ANIM_PID" 2>/dev/null || true
    ANIM_PID=""
  fi
  printf '\e[r' 2>/dev/null || true
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
  --reboot-wait SECS        Max seconds to wait after reboot (default: 300)
  -h, --help                Show this help

Examples:
  $(basename "$0") --nodes ceph01,ceph02,ceph03 --llama
  $(basename "$0") --nodes ceph01,ceph02,ceph03 --execute --yes
  $(basename "$0") --nodes ceph01,ceph02,ceph03 --execute --expected-osds 12
EOF
  exit 0
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
    -h|--help)       usage ;;
    *)               printf "${RED}Unknown option: %s${RESET}\n" "$1"; usage ;;
  esac
done

if [[ ${#NODES[@]} -eq 0 ]]; then
  printf "${RED}Error: --nodes is required${RESET}\n"
  usage
fi

# ---------- IPC for llama animation ----------
STATUS_FILE=$(mktemp "${TMPDIR:-/tmp}/ceph-upgrade-status.XXXXXX")
echo "Initializing..." > "$STATUS_FILE"

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

# ---------- Llama walking animation (background) ----------
llama_walk() {
  local status_file="$1"
  local dry_run="$2"
  local frame=0
  local pos=1
  local direction=1
  local cols
  cols=$(tput cols 2>/dev/null || echo 80)
  local max_pos=$(( cols - 30 ))
  (( max_pos < 10 )) && max_pos=10

  tput civis 2>/dev/null || true

  while true; do
    local msg
    msg=$(cat "$status_file" 2>/dev/null || echo "...")
    if (( ${#msg} > cols - 15 )); then
      msg="${msg:0:$((cols - 18))}..."
    fi

    local mode_tag="DRY-RUN"
    [[ "$dry_run" == "false" ]] && mode_tag="LIVE"

    local padding=""
    printf -v padding "%*s" "$pos" ""

    local feet
    if (( frame % 2 == 0 )); then
      feet='/ \/ \'
    else
      feet='\ /\ /'
    fi

    local bottom
    bottom=$(tput lines 2>/dev/null || echo 24)

    tput sc 2>/dev/null || printf '\e7'

    tput cup $((bottom - 12)) 0 2>/dev/null
    printf "\e[K%s${CYAN}              __--_--_-${RESET}" "$padding"
    tput cup $((bottom - 11)) 0 2>/dev/null
    printf "\e[K%s${CYAN}             ( I wish I  )${RESET}" "$padding"
    tput cup $((bottom - 10)) 0 2>/dev/null
    printf "\e[K%s${CYAN}            ( were a real )${RESET}" "$padding"
    tput cup $((bottom - 9)) 0 2>/dev/null
    printf "\e[K%s${CYAN}            (    llama   )${RESET}" "$padding"
    tput cup $((bottom - 8)) 0 2>/dev/null
    printf "\e[K%s${CYAN}             ( in Peru! )${RESET}" "$padding"
    tput cup $((bottom - 7)) 0 2>/dev/null
    printf "\e[K%s${CYAN}            o (__--_--_)${RESET}" "$padding"
    tput cup $((bottom - 6)) 0 2>/dev/null
    printf "\e[K%s${CYAN}         , o${RESET}" "$padding"
    tput cup $((bottom - 5)) 0 2>/dev/null
    printf "\e[K%s${MAGENTA}        ~)${RESET}" "$padding"
    tput cup $((bottom - 4)) 0 2>/dev/null
    printf "\e[K%s${MAGENTA}         (_---;${RESET}" "$padding"
    tput cup $((bottom - 3)) 0 2>/dev/null
    printf "\e[K%s${MAGENTA}            /|~|\\\\${RESET}" "$padding"
    tput cup $((bottom - 2)) 0 2>/dev/null
    printf "\e[K%s${MAGENTA}            %s${RESET}" "$padding" "$feet"
    tput cup $((bottom - 1)) 0 2>/dev/null
    printf "\e[K ${WHITE}[%s]${RESET} %s" "$mode_tag" "$msg"

    tput rc 2>/dev/null || printf '\e8'

    frame=$((frame + 1))
    pos=$((pos + direction * 2))
    if (( pos >= max_pos )); then direction=-1; fi
    if (( pos <= 1 )); then direction=1; fi

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
  printf "%b\n" "${GREEN} [OK] ${msg}${RESET}"
}

log_warn() {
  local msg="$1"
  if ! $DRY_RUN; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') WARN: $msg" >> "$LOG_FILE"
  fi
  printf "%b\n" "${YELLOW} [WARN] ${msg}${RESET}"
}

log_err() {
  local msg="$1"
  if ! $DRY_RUN; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: $msg" >> "$LOG_FILE"
  fi
  printf "%b\n" "${RED} [ERROR] ${msg}${RESET}"
}

# ---------- Confirmation ----------
confirm() {
  if $AUTO_YES; then return 0; fi
  if [[ -n "${ANIM_PID:-}" ]]; then
    kill -STOP "$ANIM_PID" 2>/dev/null || true
  fi
  printf "%b" "${YELLOW}$1 [y/N]: ${RESET}"
  read -r response
  if [[ -n "${ANIM_PID:-}" ]]; then
    kill -CONT "$ANIM_PID" 2>/dev/null || true
  fi
  [[ "$response" =~ ^[Yy]([Ee][Ss])?$ ]]
}

# ---------- Ceph flag management ----------
set_ceph_flags() {
  for flag in "${FLAGS[@]}"; do
    if $DRY_RUN; then
      log "Would: ceph osd set $flag"
    else
      ceph osd set "$flag"
      log "Set flag $flag"
    fi
  done
  FLAGS_SET=true
}

unset_ceph_flags() {
  for flag in "${FLAGS[@]}"; do
    if $DRY_RUN; then
      log "Would: ceph osd unset $flag"
    else
      ceph osd unset "$flag"
      log "Unset flag $flag"
    fi
  done
  FLAGS_SET=false
}

# ---------- SSH pre-flight ----------
# Always tests real SSH connectivity, even in dry-run, and verifies
# the remote user can run apt-get and read reboot-required.
check_ssh() {
  local node="$1"
  if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "${SSH_USER}@${node}" 'true' 2>/dev/null; then
    log_err "Cannot SSH to ${node} as ${SSH_USER}"
    return 1
  fi
  log "SSH to ${node}: connected"
  local priv_check=""
  priv_check=$(ssh -o BatchMode=yes -o ConnectTimeout=5 "${SSH_USER}@${node}" \
    'whoami && apt-get --version >/dev/null 2>&1 && echo APT_OK || echo APT_FAIL' 2>/dev/null) || true
  if [[ "$priv_check" != *"APT_OK"* ]]; then
    log_err "${node}: apt-get not available or not permitted for ${SSH_USER}"
    return 1
  fi
  log "SSH to ${node}: privileges OK"
}

# ---------- Wait for node to return after reboot ----------
wait_for_node() {
  local host="$1"
  local max_attempts=$(( REBOOT_WAIT / 10 ))
  (( max_attempts < 1 )) && max_attempts=1

  if $DRY_RUN; then
    sleep 2
    log "${host} is back (simulated)"
    return 0
  fi

  for (( i=1; i<=max_attempts; i++ )); do
    if ssh -o BatchMode=yes -o ConnectTimeout=5 "${SSH_USER}@${host}" 'true' 2>/dev/null; then
      log "${host} reachable via SSH"
      return 0
    fi
    log "Waiting for ${host} to become reachable... (${i}/${max_attempts})"
    sleep 10
  done
  log_warn "${host} did not become reachable within ${REBOOT_WAIT}s"
  return 1
}

# ---------- Wait for all OSDs up/in (JSON via python3) ----------
wait_for_osds() {
  if $DRY_RUN; then
    sleep 2
    log "OSDs up/in (simulated)"
    return 0
  fi

  while true; do
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

  while true; do
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

if $LLAMA; then
  draw_llama_banner
  echo
fi

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

# Start llama animation
if $LLAMA; then
  # Reserve the bottom 13 rows for the llama by setting a scroll region.
  # Main output scrolls only in the top portion; the llama area stays fixed.
  llama_term_height=$(tput lines 2>/dev/null || echo 24)
  llama_scroll_end=$((llama_term_height - 13))
  printf '\e[1;%dr' "$llama_scroll_end"
  tput cup "$((llama_scroll_end - 1))" 0 2>/dev/null || true

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

  # -- Update + reboot via SSH heredoc --
  log "[${current}/${total}] ${node}: running apt update + dist-upgrade"
  if $DRY_RUN; then
    log "Would SSH to ${SSH_USER}@${node} and run:"
    log "  apt-get update"
    log "  apt-get dist-upgrade (NEEDRESTART_MODE=l, --force-confdef/confold)"
    log "  reboot if /var/run/reboot-required exists"
  else
    ssh_rc=0
    ssh -o BatchMode=yes -o ConnectTimeout=10 "${SSH_USER}@${node}" bash -s <<'REMOTE' || ssh_rc=$?
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
    log "Update command sent to ${node} (ssh exit code: ${ssh_rc})"
  fi

  # -- Wait for node to return --
  log "[${current}/${total}] ${node}: waiting for host to return"
  if ! $DRY_RUN; then sleep 5; fi
  wait_for_node "$node" || { log_err "${node} did not return after update; aborting"; exit 1; }

  # -- Wait for OSDs up/in --
  log "[${current}/${total}] ${node}: waiting for all OSDs up/in"
  wait_for_osds

  # -- Stabilization pause + recheck --
  log "[${current}/${total}] ${node}: pausing for OSD state to stabilize"
  if $DRY_RUN; then sleep 2; else sleep 20; fi
  wait_for_osds

  # -- Second update pass (catches packages needing post-reboot install) --
  log "[${current}/${total}] ${node}: second update pass"
  if $DRY_RUN; then
    log "Would run second apt-get update + dist-upgrade on ${node}"
  else
    wait_for_node "$node" || { log_err "${node} not reachable for post-reboot check; aborting"; exit 1; }
    log "Checking for remaining updates on ${node}"
    ssh -o BatchMode=yes -o ConnectTimeout=10 "${SSH_USER}@${node}" bash -s <<'CHECK'
      set -e
      export DEBIAN_FRONTEND=noninteractive
      export NEEDRESTART_MODE=l
      apt-get update
      yes '' | apt-get -y -o Dpkg::Options::="--force-confdef" \
                       -o Dpkg::Options::="--force-confold" dist-upgrade
CHECK
  fi

  # -- Unset maintenance flags --
  log "[${current}/${total}] ${node}: unsetting Ceph maintenance flags"
  unset_ceph_flags

  # -- Wait for cluster health (3 consecutive OK) --
  log "[${current}/${total}] ${node}: waiting for cluster to become healthy"
  wait_for_health 3

  # -- Extra verification after pause --
  log "[${current}/${total}] ${node}: verifying health persists"
  if $DRY_RUN; then sleep 2; else sleep 20; fi
  wait_for_health 2

  log_ok "Completed update of ${node} (${current}/${total})"
done

# -- Stop animation and restore terminal --
if [[ -n "${ANIM_PID:-}" ]]; then
  kill "$ANIM_PID" 2>/dev/null || true
  wait "$ANIM_PID" 2>/dev/null || true
  ANIM_PID=""
  tput cnorm 2>/dev/null || true
  # Clear the llama area
  anim_bottom=$(tput lines 2>/dev/null || echo 24)
  for i in $(seq 1 12); do
    tput cup $((anim_bottom - i)) 0 2>/dev/null || true
    printf "\e[K"
  done
  # Restore full scroll region
  printf '\e[r' 2>/dev/null || true
  tput cup "$((anim_bottom - 13))" 0 2>/dev/null || true
fi

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

#!/bin/bash

# ====================================================
# Ceph Rolling Update – DRY RUN
# ====================================================

ANIMATION=false
[[ "$1" == "--animation" ]] && ANIMATION=true

# ---------- Foreground-only colors ----------
RESET="\e[0m"
CYAN="\e[96m"
MAGENTA="\e[95m"
YELLOW="\e[93m"
WHITE="\e[97m"

if [[ ! -t 1 ]]; then
  RESET=""; CYAN=""; MAGENTA=""; YELLOW=""; WHITE=""
fi

# ---------- Shared animation state ----------
FOOT_TOGGLE=0
CURRENT_MSG="Preparing dry run..."

# ---------- Static llama (EXACT original spacing) ----------
draw_llama_static() {
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

# ---------- Single-line leg + status animation ----------
animate_legs_and_status() {
  while true; do
    if (( FOOT_TOGGLE == 0 )); then
      feet="/  \\  /  \\"
    else
      feet="\\  /  \\  /"
    fi
    FOOT_TOGGLE=$((1 - FOOT_TOGGLE))

    printf "\r%s           %s   %s[DRY-RUN] %s%s   " \
      "$MAGENTA" "$feet" "$WHITE" "$CURRENT_MSG" "$RESET"
    sleep 0.8
  done
}

# ---------- Step helper ----------
step() {
  CURRENT_MSG="$1"
  if ! $ANIMATION; then
    printf "%b\n" "${WHITE}[DRY-RUN] $1${RESET}"
  fi
  sleep $((RANDOM % 4 + 2))
}

# ---------- Start output ----------
echo
printf "%b\n\n" "${YELLOW}=== Ceph Rolling Update – DRY RUN ===${RESET}"

draw_llama_static
echo

if $ANIMATION; then
  animate_legs_and_status &
  ANIM_PID=$!
  trap "kill $ANIM_PID 2>/dev/null; echo" EXIT
fi

# ---------- Script logic (dry run) ----------
NODES=("buclus1n01" "buclus1n02" "buclus1n03" "buclus1n04")
FLAGS=(noout norebalance norecover)

step "Starting dry run. No systems will be modified."

for node in "${NODES[@]}"; do
  step "Processing node: $node"

  for flag in "${FLAGS[@]}"; do
    step "Would set Ceph flag: $flag"
  done

  step "Would SSH into $node"
  step "Would run: apt-get update"
  step "Would upgrade packages"
  step "Would reboot $node"

  for flag in "${FLAGS[@]}"; do
    step "Would unset Ceph flag: $flag"
  done

  step "Cluster health is HEALTH_OK"
done

step "Dry run complete"
echo
#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="1.0.0"
SERVICE_NAME="${SERVICE_NAME:-svmstack-nginx}"
NGINX_BIN="${NGINX_BIN:-/usr/local/svmstack/nginx/bin/nginx}"
NGINX_CONF="${NGINX_CONF:-/usr/local/svmstack/nginx/conf/nginx.conf}"
PRELOAD_FILE="${PRELOAD_FILE:-/etc/ld.so.preload}"
UDEV_RULE_DIR="${UDEV_RULE_DIR:-/etc/udev/rules.d}"
VAR_ADM_DIR="${VAR_ADM_DIR:-/var/adm}"
PORT="${PORT:-6767}"
YES=0
DRY_RUN=0
MAKE_PRELOAD_IMMUTABLE=0

usage() {
  cat <<EOF
SolusVM svmstack-nginx rootkit recovery helper v${VERSION}

Usage:
  sudo bash scripts/solusvm_svmstack_nginx_recover.sh [options]

Options:
  -y, --yes               Run cleanup without interactive confirmation
      --dry-run           Diagnose only, do not modify files or restart services
      --immutable-preload Set chattr +i on /etc/ld.so.preload after cleanup
  -h, --help              Show this help

Environment overrides:
  SERVICE_NAME, NGINX_BIN, NGINX_CONF, PRELOAD_FILE, UDEV_RULE_DIR, VAR_ADM_DIR, PORT
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes) YES=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --immutable-preload) MAKE_PRELOAD_IMMUTABLE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
  esac
  shift
done

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "ERROR: run as root." >&2
  exit 1
fi

TS="$(date +%Y%m%d-%H%M%S)"
QUARANTINE_DIR="/root/solusvm-rootkit-quarantine-${TS}"
LOG_FILE="/root/solusvm-rootkit-recovery-${TS}.log"

exec > >(tee -a "$LOG_FILE") 2>&1

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
warn() { log "WARN: $*"; }
die() { log "ERROR: $*"; exit 1; }

run() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[dry-run] %q ' "$@"; printf '\n'
    return 0
  fi
  "$@"
}

ask_yes_no() {
  local prompt="$1"
  if [[ "$YES" -eq 1 ]]; then
    return 0
  fi
  read -r -p "${prompt} [y/N] " reply
  [[ "$reply" =~ ^[Yy]$|^[Yy][Ee][Ss]$ ]]
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

syscall_clear_preload() {
  log "Clearing ${PRELOAD_FILE} with direct syscalls"
  if ! have_cmd perl; then
    die "perl is required for syscall cleanup but was not found."
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[dry-run] would unlink and recreate ${PRELOAD_FILE} as an empty 0644 file"
    return 0
  fi
  PRELOAD_PATH="$PRELOAD_FILE" perl -e '
    use strict;
    use warnings;
    my $path = $ENV{"PRELOAD_PATH"} . "\0";
    my $unlink_ret = syscall(87, $path);
    print "unlink ret=$unlink_ret errno=$!\n";
    my $fd = syscall(2, $path, 0101|01000|01, 0644);
    print "open/create ret=$fd errno=$!\n";
    syscall(3, $fd) if $fd >= 0;
  '
  chmod 0644 "$PRELOAD_FILE" 2>/dev/null || true
  chown root:root "$PRELOAD_FILE" 2>/dev/null || true
}

nginx_test_output() {
  if [[ -x "$NGINX_BIN" ]]; then
    "$NGINX_BIN" -t -c "$NGINX_CONF" 2>&1 || true
  else
    echo "nginx binary not found or not executable: ${NGINX_BIN}"
  fi
}

collect_diagnosis() {
  log "Host: $(hostname 2>/dev/null || echo unknown)"
  log "Kernel: $(uname -r 2>/dev/null || echo unknown)"
  log "Service: ${SERVICE_NAME}"
  log "Nginx: ${NGINX_BIN}"
  log "Config: ${NGINX_CONF}"
  echo

  log "Service status"
  systemctl status "$SERVICE_NAME" --no-pager -l 2>&1 | sed -n '1,80p' || true
  echo

  log "Nginx config test"
  NGINX_TEST="$(nginx_test_output)"
  printf '%s\n' "$NGINX_TEST" | sed -n '1,120p'
  echo

  log "Port ${PORT} listeners"
  (ss -ltnp 2>/dev/null || netstat -ltnp 2>/dev/null || true) | grep ":${PORT}\b" || true
  echo

  log "Preload file"
  ls -l "$PRELOAD_FILE" 2>&1 || true
  stat "$PRELOAD_FILE" 2>&1 || true
  wc -c "$PRELOAD_FILE" 2>&1 || true
  echo

  log "Suspicious udev rules"
  if [[ -d "$UDEV_RULE_DIR" ]]; then
    find "$UDEV_RULE_DIR" -maxdepth 1 -type f -print \
      -exec grep -HnE '/var/adm|RING04H|libutilkeybd|module\.so' {} \; 2>/dev/null | sed -n '1,200p' || true
  fi
  echo

  log "Suspicious /var/adm content"
  find "$VAR_ADM_DIR" -maxdepth 4 -print 2>/dev/null | sed -n '1,240p' || true
  echo

  log "Processes with known injected library markers"
  find /proc -maxdepth 2 -name maps -readable \
    -exec sh -c 'grep -l "libutilkeybd.so\|/var/adm/.*/kernel" "$@" 2>/dev/null' sh {} + \
    2>/dev/null | sed -n '1,80p' || true
}

extract_uuids() {
  {
    printf '%s\n' "${NGINX_TEST:-}" | grep -oE '/var/adm/[0-9a-fA-F-]{36}/nginx/module\.so' | awk -F/ '{print $4}'
    if [[ -d "$UDEV_RULE_DIR" ]]; then
      grep -RhoE '/var/adm/[0-9a-fA-F-]{36}/udev/udev\.sh|RING04H\}="[0-9a-fA-F-]{36}"|RING04H="[0-9a-fA-F-]{36}"' "$UDEV_RULE_DIR" 2>/dev/null \
        | grep -oE '[0-9a-fA-F-]{36}' || true
    fi
    if [[ -d "$VAR_ADM_DIR" ]]; then
      find "$VAR_ADM_DIR" -maxdepth 1 -type d -regextype posix-extended \
        -regex '.*/[0-9a-fA-F-]{36}' -printf '%f\n' 2>/dev/null || true
    fi
  } | sort -u
}

has_rootkit_markers() {
  local found=1
  if [[ -n "${NGINX_TEST:-}" ]] && printf '%s\n' "$NGINX_TEST" | grep -qE '/var/adm/.*/nginx/module\.so|not binary compatible'; then
    found=0
  fi
  if [[ -e "$PRELOAD_FILE" ]]; then
    found=0
  fi
  if [[ -d "$UDEV_RULE_DIR" ]] && grep -R -qE '/var/adm/.*/udev/udev\.sh|RING04H|libutilkeybd' "$UDEV_RULE_DIR" 2>/dev/null; then
    found=0
  fi
  if [[ -d "$VAR_ADM_DIR" ]] && find "$VAR_ADM_DIR" -maxdepth 3 \( -name libutilkeybd.so -o -name module.so -o -name udev.sh -o -name ring04h_office_bin \) 2>/dev/null | grep -q .; then
    found=0
  fi
  return "$found"
}

backup_basics() {
  log "Creating quarantine/evidence directory: ${QUARANTINE_DIR}"
  run mkdir -p "$QUARANTINE_DIR/udev-rules" "$QUARANTINE_DIR/var-adm" "$QUARANTINE_DIR/evidence"
  for f in "$PRELOAD_FILE" "$NGINX_BIN" "$NGINX_CONF"; do
    [[ -e "$f" ]] || continue
    run cp -a "$f" "$QUARANTINE_DIR/evidence/$(printf '%s' "$f" | sed 's#/#_#g')" 2>/dev/null || true
  done
  systemctl cat "$SERVICE_NAME" --no-pager > "$QUARANTINE_DIR/evidence/systemd-${SERVICE_NAME}.txt" 2>/dev/null || true
}

quarantine_udev_rules() {
  [[ -d "$UDEV_RULE_DIR" ]] || return 0
  log "Quarantining malicious udev rules"
  while IFS= read -r rule; do
    [[ -f "$rule" ]] || continue
    log "Quarantine udev rule: ${rule}"
    run mv -f "$rule" "$QUARANTINE_DIR/udev-rules/$(basename "$rule")"
  done < <(grep -R -l -E '/var/adm/.*/udev/udev\.sh|RING04H|libutilkeybd' "$UDEV_RULE_DIR" 2>/dev/null || true)
}

quarantine_var_adm_dirs() {
  log "Quarantining malicious /var/adm batches"
  local uuid d base
  while IFS= read -r uuid; do
    [[ -n "$uuid" ]] || continue
    d="${VAR_ADM_DIR}/${uuid}"
    if [[ -d "$d" ]]; then
      log "Quarantine directory: ${d}"
      run mv -f "$d" "$QUARANTINE_DIR/var-adm/${uuid}"
    fi
  done < <(extract_uuids)

  if [[ -d "$VAR_ADM_DIR" ]]; then
    for d in "$VAR_ADM_DIR"/*; do
      [[ -d "$d" ]] || continue
      if find "$d" -maxdepth 3 \( -name libutilkeybd.so -o -name module.so -o -name udev.sh -o -name ring04h_office_bin \) 2>/dev/null | grep -q .; then
        base="$(basename "$d")"
        log "Quarantine marker-matching directory: ${d}"
        run mv -f "$d" "$QUARANTINE_DIR/var-adm/${base}"
      fi
    done
  fi

  run find "$QUARANTINE_DIR" -type f -exec chmod 000 {} \; 2>/dev/null || true
  run find "$QUARANTINE_DIR" -type d -exec chmod 700 {} \; 2>/dev/null || true
}

reload_and_restart() {
  log "Reloading udev/systemd"
  run udevadm control --reload-rules 2>/dev/null || true
  run systemctl daemon-reload 2>/dev/null || true

  log "Testing nginx config after cleanup"
  nginx_test_output | sed -n '1,120p'

  log "Restarting ${SERVICE_NAME}"
  run systemctl reset-failed "$SERVICE_NAME" 2>/dev/null || true
  run systemctl restart "$SERVICE_NAME"
  sleep 2
}

final_verify() {
  log "Final service status"
  systemctl is-active "$SERVICE_NAME" || true
  systemctl status "$SERVICE_NAME" --no-pager -l 2>&1 | sed -n '1,80p' || true
  echo

  log "Final port ${PORT} status"
  (ss -ltnp 2>/dev/null || netstat -ltnp 2>/dev/null || true) | grep ":${PORT}\b" || true
  echo

  log "Final preload status"
  ls -l "$PRELOAD_FILE" 2>&1 || true
  wc -c "$PRELOAD_FILE" 2>&1 || true
  echo

  log "Final udev marker check"
  if [[ -d "$UDEV_RULE_DIR" ]]; then
    grep -R -n -E '/var/adm/.*/udev/udev\.sh|RING04H|libutilkeybd' "$UDEV_RULE_DIR" 2>/dev/null || echo "No known malicious udev markers visible."
  fi
  echo

  log "Final nginx process map check"
  for pid in $(pgrep -x nginx 2>/dev/null || true); do
    echo "-- pid ${pid}"
    grep 'libutilkeybd\|/var/adm' "/proc/${pid}/maps" 2>/dev/null || echo "clean"
  done
  echo

  log "Log file: ${LOG_FILE}"
  log "Quarantine directory: ${QUARANTINE_DIR}"
}

main() {
  log "Starting SolusVM svmstack-nginx recovery helper v${VERSION}"
  collect_diagnosis

  if has_rootkit_markers; then
    warn "Known rootkit markers detected."
  else
    log "No known rootkit markers detected."
    if systemctl is-active --quiet "$SERVICE_NAME" && nginx_test_output | grep -q 'test is successful'; then
      log "${SERVICE_NAME} appears healthy. Nothing to repair."
      final_verify
      exit 0
    fi
    warn "Service is not fully healthy, but known markers were not detected."
  fi

  if ! ask_yes_no "Proceed with cleanup and restart ${SERVICE_NAME}?"; then
    log "Aborted by user."
    exit 0
  fi

  backup_basics
  syscall_clear_preload
  NGINX_TEST="$(nginx_test_output)"
  quarantine_udev_rules
  quarantine_var_adm_dirs

  if [[ "$MAKE_PRELOAD_IMMUTABLE" -eq 1 ]]; then
    log "Setting immutable bit on ${PRELOAD_FILE}"
    run chattr +i "$PRELOAD_FILE" 2>/dev/null || warn "chattr +i failed or is unsupported."
  fi

  reload_and_restart
  final_verify
}

main "$@"

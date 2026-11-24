#!/usr/bin/env bash
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP="$(mktemp -d)"
cleanup() { rm -rf -- "$TEST_TMP"; }
trap cleanup EXIT

export KOPIACTL_LIB_ONLY=true
export INSTALL_DIR="${TEST_TMP}/opt/kopiactl"
export BACKUP_DIR="${TEST_TMP}/var/backups/kopiactl"
export MANAGER_DIR="${TEST_TMP}/usr/local/lib/kopiactl"
export MANAGER_COMMAND="${TEST_TMP}/usr/local/bin/kopiactl"
export SYSTEMD_DIR="${TEST_TMP}/etc/systemd/system"

mkdir -p "$INSTALL_DIR" "$BACKUP_DIR" "$MANAGER_DIR" "$(dirname "$MANAGER_COMMAND")" "$SYSTEMD_DIR"

# shellcheck source=../kopiactl.sh
source "${REPO_ROOT}/kopiactl.sh"

TESTS_RUN=0
TESTS_FAILED=0

assert_eq() {
  local expected="$1" actual="$2" message="$3"
  ((TESTS_RUN++))
  if [[ "$expected" != "$actual" ]]; then
    printf 'FAIL: %s\n  expected: [%s]\n  actual:   [%s]\n' "$message" "$expected" "$actual" >&2
    ((TESTS_FAILED++))
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" message="$3"
  ((TESTS_RUN++))
  if [[ "$haystack" != *"$needle"* ]]; then
    printf 'FAIL: %s\n  missing: [%s]\n' "$message" "$needle" >&2
    ((TESTS_FAILED++))
  fi
}

assert_not_contains() {
  local haystack="$1" needle="$2" message="$3"
  ((TESTS_RUN++))
  if [[ "$haystack" == *"$needle"* ]]; then
    printf 'FAIL: %s\n  unexpected: [%s]\n' "$message" "$needle" >&2
    ((TESTS_FAILED++))
  fi
}

assert_ok() {
  local message="$1"
  shift
  ((TESTS_RUN++))
  if ! "$@"; then
    printf 'FAIL: %s (expected exit 0)\n' "$message" >&2
    ((TESTS_FAILED++))
  fi
}

assert_fail() {
  local message="$1"
  shift
  ((TESTS_RUN++))
  if "$@" >/dev/null 2>&1; then
    printf 'FAIL: %s (expected non-zero exit)\n' "$message" >&2
    ((TESTS_FAILED++))
  fi
}

# 1. Path & string helpers
assert_eq "abc" "$(trim_whitespace "  abc  ")" "trim_whitespace trims leading/trailing spaces"
assert_eq "/var/www" "$(normalize_absolute_path " /var/www/// ")" "normalize_absolute_path strips trailing slashes"
assert_eq "/" "$(normalize_absolute_path "/")" "normalize_absolute_path keeps root slash"
assert_fail "validate_docker_mount_path rejects root" validate_docker_mount_path "/"
assert_fail "validate_docker_mount_path rejects /app/config" validate_docker_mount_path "/app/config"
assert_fail "validate_docker_mount_path rejects colon" validate_docker_mount_path "/tmp/a:b"
assert_ok "validate_docker_mount_path allows normal dir" validate_docker_mount_path "/var/www"

# 2. IPv4 validation
assert_ok "is_valid_ipv4 accepts 127.0.0.1" is_valid_ipv4 "127.0.0.1"
assert_ok "is_valid_ipv4 accepts 192.168.1.255" is_valid_ipv4 "192.168.1.255"
assert_fail "is_valid_ipv4 rejects 256.0.0.1" is_valid_ipv4 "256.0.0.1"
assert_fail "is_valid_ipv4 rejects hostname" is_valid_ipv4 "example.com"

# 3. Compose env quoting
assert_eq "'plain\$pass\\1'" "$(compose_env_single_quote 'plain$pass\1')" "compose_env_single_quote preserves literal backslashes and dollars when no single quote"
assert_eq '"it'\''s\$a\\b\"`c"' "$(compose_env_single_quote "it's\$a\\b\"\`c")" "compose_env_single_quote double-quotes and escapes when single quote is present"
assert_fail "compose_env_single_quote rejects newline" compose_env_single_quote $'line1\nline2'

# 4. Config writing & reading
write_config native false pingzi 'secretPass123!' 51515 "'repo\$pw'" 127.0.0.1 cmVwbw==
assert_eq "native" "$(config_value INSTALL_MODE)" "config_value reads INSTALL_MODE"
assert_eq "secretPass123!" "$(config_value WEB_UI_PASSWORD)" "config_value reads WEB_UI_PASSWORD"
assert_eq "600" "$(stat -c '%a' "$CONFIG_FILE" 2>/dev/null || stat -f '%Lp' "$CONFIG_FILE")" "kopiactl.env permissions are 600"

# 5. Systemd timer generation (mock systemctl)
systemctl() { return 0; }
assert_ok "write_timer_schedule_units interval succeeds" write_timer_schedule_units "0123456789abcdef" interval "6h"
timer_content="$(cat "${SYSTEMD_DIR}/kopiactl-backup-0123456789abcdef.timer")"
service_content="$(cat "${SYSTEMD_DIR}/kopiactl-backup-0123456789abcdef.service")"
assert_contains "$timer_content" "OnActiveSec=6h" "interval timer includes OnActiveSec"
assert_contains "$timer_content" "OnUnitActiveSec=6h" "interval timer includes OnUnitActiveSec"
assert_contains "$service_content" "After=network-online.target docker.service" "timer service orders after docker.service"

assert_ok "write_timer_schedule_units daily succeeds" write_timer_schedule_units "fedcba9876543210" daily "02:30"
daily_timer_content="$(cat "${SYSTEMD_DIR}/kopiactl-backup-fedcba9876543210.timer")"
assert_contains "$daily_timer_content" "OnCalendar=*-*-* 02:30:00" "daily timer includes OnCalendar"
assert_contains "$daily_timer_content" "Persistent=true" "daily timer includes Persistent=true"

# 6. Native service does not expose password in ExecStart
mock_bin="${TEST_TMP}/bin"
mkdir -p "$mock_bin"
cat >"${mock_bin}/kopia" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "${mock_bin}/kopia"
PATH="${mock_bin}:${PATH}"
assert_ok "write_native_service succeeds" write_native_service
unit_content="$(cat "$SERVICE_FILE")"
assert_not_contains "$unit_content" "secretPass123!" "kopia-web-ui.service ExecStart does not expose WEB_UI_PASSWORD"
assert_contains "$unit_content" "ExecStart=${MANAGER_DIR}/kopia-web-ui-service.sh ${CONFIG_FILE} ${mock_bin}/kopia ${KOPIA_CONFIG_FILE}" "kopia-web-ui.service uses config-based ExecStart"

# 7. apply_backup_schedule clears opposing policy flags
KOPIA_LOG="${TEST_TMP}/kopia.log"
kopia() {
  printf '%s\n' "$*" >>"$KOPIA_LOG"
  return 0
}
backup_src="${TEST_TMP}/data"
mkdir -p "$backup_src"
touch "$KOPIA_CONFIG_FILE"
REPOSITORY_PASSWORD="repo-password"
: >"$KOPIA_LOG"
assert_ok "apply_backup_schedule policy interval" apply_backup_schedule "${backup_src}/" policy interval 30m
kopia_calls="$(cat "$KOPIA_LOG")"
assert_contains "$kopia_calls" "--no-manual --snapshot-interval=30m --snapshot-time=inherit --run-missed=true" "policy interval clears manual and snapshot-time"

: >"$KOPIA_LOG"
assert_ok "apply_backup_schedule policy daily" apply_backup_schedule "$backup_src" policy daily 03:15
kopia_calls="$(cat "$KOPIA_LOG")"
assert_contains "$kopia_calls" "--no-manual --snapshot-interval=inherit --snapshot-time=03:15 --run-missed=true" "policy daily clears manual and snapshot-interval"

# 8. configure_web_ui_publish_scope does not verify NPM when Web UI disabled
verify_called=false
select_npm_gateway_target() { NPM_GATEWAY_ADDRESS="127.0.0.1"; return 0; }
verify_npm_gateway_connection() { verify_called=true; return 0; }
write_config native false pingzi 'secretPass123!' 51515 '' 0.0.0.0 ''
configure_web_ui_publish_scope <<< $'2\n' >/dev/null
assert_eq "false" "$verify_called" "verify_npm_gateway_connection skipped when Web UI is disabled"

# 9. create_snapshot native failure returns 1 without prompting auto backup
kopia() { return 1; }
create_output="$(create_snapshot <<< "${backup_src}"$'\n' 2>&1)"
rc=$?
assert_eq "1" "$rc" "create_snapshot returns 1 when native kopia fails"
assert_not_contains "$create_output" "快照已创建" "create_snapshot does not print success message on failure"

# 10. restore_snapshot preserves existing directory permissions
restore_dir="${TEST_TMP}/restore_existing"
mkdir -p "$restore_dir"
chmod 0755 "$restore_dir"
kopia() { return 0; }
assert_ok "restore_snapshot succeeds on existing dir" restore_snapshot <<< $'snap123\n'"${restore_dir}"$'\ny\n' >/dev/null
assert_eq "755" "$(stat -c '%a' "$restore_dir" 2>/dev/null || stat -f '%Lp' "$restore_dir")" "restore_snapshot preserves existing directory permissions"

# 11. backup_local_config excludes cache
mkdir -p "${INSTALL_DIR}/cache" "${INSTALL_DIR}/config"
touch "${INSTALL_DIR}/cache/big-cache-blob" "${INSTALL_DIR}/config/repository.config"
assert_ok "backup_local_config succeeds" backup_local_config <<< $'y\n' >/dev/null
archive_path="$(find "$BACKUP_DIR" -name 'kopiactl-config.*.tar.gz' | head -n 1)"
archive_list="$(tar -tzf "$archive_path")"
assert_contains "$archive_list" "config/repository.config" "backup_local_config includes repository.config"
assert_not_contains "$archive_list" "cache/" "backup_local_config excludes cache directory"

# 12. classify_importable_policy (if jq is available)
if command -v jq >/dev/null 2>&1; then
  assert_ok "classify_importable_policy accepts interval" classify_importable_policy '{"scheduling":{"intervalSeconds":7200,"runMissed":true}}'
  assert_eq "interval" "$IMPORT_KIND" "classify_importable_policy interval kind"
  assert_eq "2h" "$IMPORT_VALUE" "classify_importable_policy interval value"
  assert_ok "classify_importable_policy accepts daily" classify_importable_policy '{"scheduling":{"timeOfDay":[{"hour":4,"min":5}],"runMissed":true}}'
  assert_eq "daily" "$IMPORT_KIND" "classify_importable_policy daily kind"
  assert_eq "04:05" "$IMPORT_VALUE" "classify_importable_policy daily value"
  assert_fail "classify_importable_policy rejects manual" classify_importable_policy '{"scheduling":{"manual":true}}'
  assert_fail "classify_importable_policy rejects mixed" classify_importable_policy '{"scheduling":{"intervalSeconds":3600,"timeOfDay":[{"hour":1,"min":0}]}}'
fi

printf '\nTests run: %d, Failed: %d\n' "$TESTS_RUN" "$TESTS_FAILED"
(( TESTS_FAILED == 0 ))

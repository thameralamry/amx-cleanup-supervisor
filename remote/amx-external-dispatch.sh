#!/usr/bin/env bash

# Bluehost-safe entry point for the AvailableMax cleanup supervisor.
# Each destructive cycle is split across two short SSH sessions: a one-property
# preview, followed by execution of that exact, revalidated plan.

set -u
set -o pipefail

export PATH="/usr/local/bin:/usr/bin:/bin"

readonly wp_root="/srv/htdocs"
readonly work_root="$wp_root/.amx-cleanup"
readonly batch_script="$work_root/amx-keep-one-batch.php"
readonly plan_file="$work_root/global-keep-one-next-batch.json"
readonly state_file="$work_root/amx-external-cleanup.state"
readonly complete_file="$work_root/amx-external-cleanup.complete"
readonly halted_file="$work_root/amx-external-cleanup.halted"
readonly test_command="amx-cleanup-test"
readonly legacy_tick_command="amx-cleanup-tick"
readonly preview_command="amx-cleanup-preview"
readonly execute_command="amx-cleanup-execute"

case "${SSH_ORIGINAL_COMMAND:-}" in
  "$test_command") mode="test" ;;
  "$legacy_tick_command") mode="preview" ;;
  "$preview_command") mode="preview" ;;
  "$execute_command") mode="execute" ;;
  *)
    echo "STOP: THIS DISPATCHER ONLY ACCEPTS $test_command, $preview_command, OR $execute_command" >&2
    exit 64
    ;;
esac

if [[ ! -r "$batch_script" ]]; then
  echo "STOP: BATCH SCRIPT IS NOT READABLE" >&2
  exit 66
fi

read_state() {
  local key="$1"
  [[ -f "$state_file" ]] || return 0
  sed -n "s/^${key}=//p" "$state_file" | tail -n 1
}

valid_nonnegative_integer() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

write_state() {
  local status="$1"
  local completed="$2"
  local last_message="$3"
  local plan_sha="${4:-}"
  local tmp
  tmp="$(mktemp "$work_root/amx-external-state.XXXXXX")" || return 1
  chmod 600 "$tmp" || return 1
  {
    printf 'version=2\n'
    printf 'status=%s\n' "$status"
    printf 'completed_properties=%s\n' "$completed"
    printf 'updated_at_utc=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'last_message=%s\n' "$last_message"
    printf 'plan_sha256=%s\n' "$plan_sha"
  } >"$tmp"
  mv "$tmp" "$state_file"
}

completed_properties="$(read_state completed_properties)"
valid_nonnegative_integer "$completed_properties" || completed_properties=0

echo "EXTERNAL SUPERVISOR: CONNECTED"
echo "UTC: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"

if [[ "$mode" == "test" ]]; then
  echo "MODE: TEST ONLY; PREVIEW AND EXECUTE NOT CALLED"
  if [[ -f "$state_file" ]]; then
    cat "$state_file"
  else
    echo "status=NOT_STARTED"
  fi
  echo "DISPATCHER_OK"
  exit 0
fi

if [[ -f "$complete_file" ]]; then
  cat "$state_file" 2>/dev/null || true
  echo "STATUS: ALREADY_COMPLETE"
  exit 0
fi
if [[ -f "$halted_file" ]]; then
  cat "$state_file" 2>/dev/null || true
  echo "STOP: CLEANUP IS HALTED FOR REVIEW" >&2
  exit 2
fi

run_out="$(mktemp "$work_root/amx-external-${mode}.XXXXXX.out")" || exit 70
cleanup() {
  rm -f "$run_out"
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

cd "$wp_root" || exit 70

if [[ "$mode" == "preview" ]]; then
  echo "MODE: PREVIEW ONE PROPERTY; NO DELETION"
  set +e
  AMX_MODE=preview AMX_LIMIT=1 wp eval-file "$batch_script" 2>&1 | tee "$run_out"
  preview_status=${PIPESTATUS[0]}
  set -e

  if (( preview_status == 0 )) \
    && grep -Fxq 'STATUS: PREVIEW_COMPLETE_NO_DELETION' "$run_out" \
    && grep -Fxq 'SELECTED PROPERTIES: 1' "$run_out"; then
    plan_sha="$(sed -n 's/^PLAN SHA256: \([0-9a-f][0-9a-f]*\)$/\1/p' "$run_out" | tail -n 1)"
    if [[ -z "$plan_sha" || ! -f "$plan_file" ]]; then
      write_state HALTED "$completed_properties" PREVIEW_PLAN_MISSING || true
      printf '%s\n' PREVIEW_PLAN_MISSING >"$halted_file"
      echo "STOP: PREVIEW PLAN WAS NOT SAVED" >&2
      exit 2
    fi
    write_state PREPARED "$completed_properties" ONE_PROPERTY_PLAN_READY "$plan_sha" || exit 70
    echo "DISPATCHER_PREVIEW_OK"
    exit 0
  fi

  if (( preview_status == 75 )) \
    && grep -Fxq 'STATUS: RETRY_AFTER_PROTECTED_UPDATE' "$run_out"; then
    write_state RETRYING "$completed_properties" PROTECTED_REGISTRY_UPDATED || exit 70
    echo "STATUS: RETRY_ON_NEXT_SCHEDULE"
    exit 0
  fi

  if grep -Eq '^STOP: ONLY 0 SAFE PROPERTIES FOUND$' "$run_out"; then
    write_state COMPLETE "$completed_properties" NO_MORE_SAFE_PROPERTIES || exit 70
    printf '%s\n' NO_MORE_SAFE_PROPERTIES >"$complete_file"
    chmod 600 "$complete_file"
    echo "STATUS: NO_MORE_SAFE_PROPERTIES"
    exit 0
  fi

  write_state HALTED "$completed_properties" "PREVIEW_FAILURE_${preview_status}" || true
  printf 'PREVIEW_FAILURE_%s\n' "$preview_status" >"$halted_file"
  chmod 600 "$halted_file"
  echo "STOP: UNEXPECTED PREVIEW FAILURE" >&2
  (( preview_status == 0 )) && exit 2
  exit "$preview_status"
fi

echo "MODE: EXECUTE EXACT PREVIEWED PLAN"
if [[ "$(read_state status)" != "PREPARED" ]]; then
  echo "STOP: NO PREPARED PLAN" >&2
  exit 2
fi
expected_sha="$(read_state plan_sha256)"
if [[ -z "$expected_sha" || ! -f "$plan_file" ]]; then
  echo "STOP: PREPARED PLAN FILE IS MISSING" >&2
  exit 2
fi
actual_sha="$(sha256sum "$plan_file" | awk '{print $1}')"
if [[ "$actual_sha" != "$expected_sha" ]]; then
  write_state HALTED "$completed_properties" PLAN_HASH_CHANGED || true
  printf '%s\n' PLAN_HASH_CHANGED >"$halted_file"
  chmod 600 "$halted_file"
  echo "STOP: PREPARED PLAN HASH CHANGED" >&2
  exit 2
fi

set +e
AMX_MODE=execute wp eval-file "$batch_script" 2>&1 | tee "$run_out"
execute_status=${PIPESTATUS[0]}
set -e

if (( execute_status == 0 )) \
  && grep -Fxq 'STATUS: COMPLETE' "$run_out" \
  && grep -Fxq 'PROPERTIES CLEANED: 1' "$run_out" \
  && grep -Fxq 'FAILED: 0' "$run_out"; then
  completed_properties=$((completed_properties + 1))
  batch_id="$(sed -n 's/^BATCH ID: //p' "$run_out" | tail -n 1)"
  write_state RUNNING "$completed_properties" "BATCH_COMPLETE_${batch_id}" || exit 70
  echo "DISPATCHER_EXECUTE_OK"
  exit 0
fi

write_state HALTED "$completed_properties" "EXECUTE_FAILURE_${execute_status}" || true
printf 'EXECUTE_FAILURE_%s\n' "$execute_status" >"$halted_file"
chmod 600 "$halted_file"
echo "STOP: EXECUTION FAILED; CLEANUP HALTED FOR REVIEW" >&2
(( execute_status == 0 )) && exit 2
exit "$execute_status"

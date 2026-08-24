#!/usr/bin/env bash

# Restricted entry point for the external AvailableMax cleanup supervisor.
# Bluehost does not reliably honor forced commands from authorized_keys, so
# GitHub Actions invokes this dispatcher explicitly and supplies one of the
# two exact commands below through SSH_ORIGINAL_COMMAND.

set -u
set -o pipefail

export PATH="/usr/local/bin:/usr/bin:/bin"

readonly work_root="/srv/htdocs/.amx-cleanup"
readonly queue_script="$work_root/amx-keep-one-queue.sh"
readonly tick_command="amx-cleanup-tick"
readonly test_command="amx-cleanup-test"

case "${SSH_ORIGINAL_COMMAND:-}" in
  "$tick_command")
    mode="tick"
    ;;
  "$test_command")
    mode="test"
    ;;
  *)
    echo "STOP: THIS DISPATCHER ONLY ACCEPTS $test_command OR $tick_command" >&2
    exit 64
    ;;
esac

if [[ ! -f "$queue_script" ]]; then
  echo "STOP: QUEUE SCRIPT NOT FOUND" >&2
  exit 66
fi

if [[ ! -r "$queue_script" ]]; then
  echo "STOP: QUEUE SCRIPT IS NOT READABLE" >&2
  exit 66
fi

echo "EXTERNAL SUPERVISOR: CONNECTED"
echo "UTC: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"

if [[ "$mode" == "test" ]]; then
  echo "MODE: TEST ONLY; TICK NOT CALLED"
  /bin/bash "$queue_script" status
  test_status=$?
  if (( test_status == 0 )); then
    echo "DISPATCHER_OK"
  fi
  exit "$test_status"
fi

echo "MODE: TICK"
echo "STATE BEFORE TICK:"
/bin/bash "$queue_script" status

# Do not wrap this call with nice or timeout. Bluehost blocks the underlying
# system calls and terminates the process with SIGSYS (Bad system call). The
# GitHub Actions job supplies the outer 14-minute connection limit, while the
# queue script still runs at most one bounded, resumable batch per invocation.
set +e
/bin/bash "$queue_script" tick
tick_status=$?
set -e

echo "STATE AFTER TICK:"
/bin/bash "$queue_script" status
echo "EXTERNAL SUPERVISOR: TICK EXIT $tick_status"
exit "$tick_status"

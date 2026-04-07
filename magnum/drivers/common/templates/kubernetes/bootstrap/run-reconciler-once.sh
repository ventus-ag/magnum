#!/bin/sh

set -u

ssh_cmd="ssh -F /srv/magnum/.ssh/config root@localhost"
result_file="/var/lib/magnum/reconciler-last-run.json"

json_escape() {
    printf '%s' "$1" | sed ':a;N;$!ba;s/\\/\\\\/g;s/"/\\"/g;s/\r/\\r/g;s/\t/\\t/g;s/\n/\\n/g'
}

emit_heat_outputs() {
    result_json="$1"

    printf '%s' "${result_json}" | HEAT_OUTPUTS_PATH="${heat_outputs_path:-}" python -c '
import json
import os
import sys

payload = json.load(sys.stdin)
base = os.environ.get("HEAT_OUTPUTS_PATH", "")

fields = {
    "reconcile_status": payload.get("status", ""),
    "reconcile_step": payload.get("step", ""),
    "reconcile_summary": payload.get("summary", ""),
    "reconcile_reason": payload.get("reason", ""),
    "reconcile_error_code": payload.get("errorCode", ""),
}

if payload.get("status") == "failed":
    fields["reconcile_failure"] = (
        payload.get("reason") or payload.get("summary") or "reconcile failed"
    )

if base:
    for name, value in fields.items():
        path = "%s.%s" % (base, name)
        if value:
            with open(path, "w") as fh:
                fh.write(str(value))

print(payload.get("status", ""))
'
}

# Enable the periodic timer without starting it yet.  Starting it here
# would reset OnBootSec causing an immediate timer-triggered run that
# races with the synchronous run below (double execution via flock
# serialisation).  The timer is started AFTER the synchronous run.
echo "Enabling reconciler timer (deferred start)" >&2
$ssh_cmd systemctl enable magnum-reconcile.timer 2>&1 || true

echo "Starting synchronous reconcile run" >&2

# Run the reconciler with one automatic retry.  During initial create or
# CA rotation the first attempt may fail due to transient issues (etcd
# quorum forming, API server stabilising).  A second attempt usually
# succeeds because the first run already applied most of the changes.
max_attempts=2
attempt=1
rc=1
while [ "${attempt}" -le "${max_attempts}" ]; do
    $ssh_cmd rm -f "${result_file}"
    $ssh_cmd systemctl reset-failed magnum-reconcile.service 2>/dev/null || true

    echo "Reconcile attempt ${attempt}/${max_attempts}" >&2
    $ssh_cmd systemctl start --wait magnum-reconcile.service
    rc=$?

    if [ "${rc}" -eq 0 ]; then
        break
    fi

    if [ "${attempt}" -lt "${max_attempts}" ]; then
        echo "Reconcile attempt ${attempt} failed (rc=${rc}), retrying in 15s" >&2
        sleep 15
    fi
    attempt=$((attempt + 1))
done

if $ssh_cmd test -s "${result_file}"; then
    result_json="$($ssh_cmd cat "${result_file}")"
else
    if [ "${rc}" -eq 0 ]; then
        rc=1
        summary="reconciler finished without writing result JSON"
    else
        summary="reconciler service failed before writing result JSON"
    fi

    service_log="$($ssh_cmd journalctl -u magnum-reconcile.service -n 50 --no-pager -o cat 2>/dev/null || true)"
    escaped_summary="$(json_escape "${summary}")"
    escaped_log="$(json_escape "${service_log}")"

    result_json=$(printf '{\n')
    result_json="${result_json}  \"status\": \"failed\",\n"
    result_json="${result_json}  \"step\": \"service\",\n"
    result_json="${result_json}  \"summary\": \"${escaped_summary}\",\n"
    result_json="${result_json}  \"reason\": \"${escaped_summary}\",\n"
    result_json="${result_json}  \"errorCode\": \"service_error\",\n"
    result_json="${result_json}  \"deploy_status_code\": ${rc},\n"
    result_json="${result_json}  \"deploy_stderr\": \"${escaped_log}\"\n"
    result_json="${result_json}}"
    printf '%b\n' "${result_json}" | $ssh_cmd "cat > '${result_file}.tmp' && mv '${result_file}.tmp' '${result_file}'"
fi

# Now that the synchronous run is complete, start the periodic timer.
# Use restart so a changed interval takes effect.  This is safe because
# the synchronous run already finished — no race with the timer's first tick.
echo "Starting reconciler timer" >&2
$ssh_cmd systemctl restart magnum-reconcile.timer 2>&1 || true

printf '%b\n' "${result_json}"
if result_status="$(emit_heat_outputs "${result_json}")"; then
    :
else
    result_status=""
fi

if [ "${result_status}" = "failed" ]; then
    # Let Heat fail via SoftwareConfig error outputs so the deployment
    # reason carries the reconciler summary instead of only exit code 1.
    exit 0
fi

exit "${rc}"

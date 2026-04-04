#!/bin/sh

set -eu

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

echo "Enabling reconciler timer" >&2
$ssh_cmd systemctl enable --now magnum-reconcile.timer

echo "Starting synchronous reconcile run" >&2
$ssh_cmd rm -f "${result_file}"

set +e
$ssh_cmd systemctl start --wait magnum-reconcile.service
rc=$?
set -e

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

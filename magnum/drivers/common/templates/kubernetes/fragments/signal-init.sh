#!/bin/sh
set -o pipefail
. /etc/sysconfig/heat-params

echo "notifying failed to heat"

if [ "$VERIFY_CA" == "True" ]; then
    VERIFY_CA=""
else
    VERIFY_CA="-k"
fi

function handle_error {
  local exit_code="$?"
  local line_number="$1"
  local error_message=$(echo "Exited with status $exit_code at line $line_number")

  escaped_error_message=\"${error_message//$'\n'/\\n}\"
  STATUS="FAILURE"
  UUID=`uuidgen`
  data=$(echo '{"status": "'${STATUS}'", "reason": "'$escaped_error_message'", "id": "'$UUID'"}')
  sh -c "${WAIT_CURL} ${VERIFY_CA} --data-binary '${data}'"
  exit $exit_code
}

trap 'handle_error $LINENO' ERR

#!/bin/sh
set -o pipefail
. /etc/sysconfig/heat-params

echo "heat signal init"

if [ "$VERIFY_CA" == "True" ]; then
    VERIFY_CA=""
else
    VERIFY_CA="-k"
fi

WAIT_CURL="$WAIT_CURL"

function handle_error {
  local exit_code="$?"
  local line_number="$1"
  local error_message=$(echo "Exited with status $exit_code at line $line_number")

  escaped_error_message=\"${error_message//$'\n'/\\n}\"
  STATUS="FAILURE"
  REASON="Setup failed"
  UUID=`uuidgen`
  echo ${escaped_error_message}
  
  data=$(echo '{"status": "'${STATUS}'", "reason": "'$REASON'",  "id": "'$UUID'"}')
  sh -c "${WAIT_CURL} ${VERIFY_CA} --data-binary '${data}'"
  exit $exit_code
}

trap 'handle_error $LINENO' ERR

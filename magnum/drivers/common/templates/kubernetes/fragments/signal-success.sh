#!/bin/sh

. /etc/sysconfig/heat-params

echo "notifying success to heat"

if [ "$VERIFY_CA" == "True" ]; then
    VERIFY_CA=""
else
    VERIFY_CA="-k"
fi

WAIT_CURL="$WAIT_CURL"

STATUS="SUCCESS"
REASON="Setup complete"
DATA="OK"
UUID=`uuidgen`

data=$(echo '{"status": "'${STATUS}'", "reason": "'$REASON'", "data": "'${DATA}'", "id": "'$UUID'"}')

${WAIT_CURL} ${VERIFY_CA} --data-binary '${data}'

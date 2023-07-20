#!/bin/sh

. /etc/sysconfig/heat-params

echo "notifying success to heat"

if [ "$VERIFY_CA" == "True" ]; then
    VERIFY_CA=""
else
    VERIFY_CA="-k"
fi

STATUS="SUCCESS"
REASON="Setup complete"
DATA="OK"
UUID=`uuidgen`

$WAIT_CURL ${VERIFY_CA} --data-binary '{"status": "'${STATUS}'", "reason": "'$REASON'", "data": "'${DATA}'", "id": "'$UUID'"}'

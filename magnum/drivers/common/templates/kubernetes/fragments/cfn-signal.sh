#!/bin/sh

. /etc/sysconfig/heat-params

echo "notifying heat"

if [ "$VERIFY_CA" == "True" ]; then
    VERIFY_CA=""
else
    VERIFY_CA="-k"
fi
if [ $? -eq 0 ]; then
    STATUS="SUCCESS"
    REASON="Setup complete"
else
    STATUS="FAILURE"
    REASON="Setup failed"

fi

DATA="OK"
UUID=`uuidgen`

# data=$(echo '{"status": "'${STATUS}'", "reason": "'$REASON'", "data": "'${DATA}'", "id": "'$UUID'"}')
data=$(echo '{"status": "'${STATUS}'", "reason": "'$REASON'", "id": "'$UUID'"}')

sh -c "${WAIT_CURL} ${VERIFY_CA} --data-binary '${data}'"

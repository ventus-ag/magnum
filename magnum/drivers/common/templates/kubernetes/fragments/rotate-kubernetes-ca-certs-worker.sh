echo "START: rotate CA certs on worker"

HEAT_PARAMS=/etc/sysconfig/heat-params

if [ ! -f "${HEAT_PARAMS}" ]; then
    echo "heat-params file is missing, skipping CA rotation"
    exit 0
fi

set +x
. "${HEAT_PARAMS}"
set -x

set -eu -o pipefail

ssh_cmd="ssh -F /srv/magnum/.ssh/config root@localhost"

service_account_key=$kube_service_account_key_input
service_account_private_key=$kube_service_account_private_key_input
current_service_account_key="${KUBE_SERVICE_ACCOUNT_KEY:-}"
current_service_account_private_key="${KUBE_SERVICE_ACCOUNT_PRIVATE_KEY:-}"
is_upgrade="${is_upgrade_input:-false}"

if [ ! -z "$service_account_key" ] && [ ! -z "$service_account_private_key" ] ; then
    if [ "$service_account_key" = "$current_service_account_key" ] && \
       [ "$service_account_private_key" = "$current_service_account_private_key" ]; then
        echo "Service account keys are unchanged, skipping CA rotation"
        exit 0
    fi

    if [ -z "$current_service_account_key" ] && [ -z "$current_service_account_private_key" ] && \
       { [ "$is_upgrade" = "True" ] || [ "$is_upgrade" = "true" ]; }; then
        echo "Initializing service account key state during upgrade"
        cat <<EOF >> "${HEAT_PARAMS}"
KUBE_SERVICE_ACCOUNT_KEY="$service_account_key"
KUBE_SERVICE_ACCOUNT_PRIVATE_KEY="$service_account_private_key"
EOF
        exit 0
    fi

    for service in kubelet kube-proxy; do
        echo "restart service $service"
        $ssh_cmd systemctl restart $service
    done

    cat <<EOF >> "${HEAT_PARAMS}"
KUBE_SERVICE_ACCOUNT_KEY="$service_account_key"
KUBE_SERVICE_ACCOUNT_PRIVATE_KEY="$service_account_private_key"
EOF
fi

echo "END: rotate CA certs on worker"

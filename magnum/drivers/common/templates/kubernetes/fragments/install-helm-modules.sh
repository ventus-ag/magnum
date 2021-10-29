#!/bin/bash

step="install-helm-modules"
echo "START: ${step}"

set +x
. /etc/sysconfig/heat-params

set -ex

if [ ! -z "$HTTP_PROXY" ]; then
    export HTTP_PROXY
fi

if [ ! -z "$HTTPS_PROXY" ]; then
    export HTTPS_PROXY
fi

if [ ! -z "$NO_PROXY" ]; then
    export NO_PROXY
fi

ssh_cmd="ssh -F /srv/magnum/.ssh/config root@localhost"

echo "Waiting for Kubernetes API..."
until  [ "ok" = "$(kubectl get --raw='/healthz' 2>nil)" ]; do
    sleep 5
done

if [[ "$(echo ${TILLER_ENABLED} | tr '[:upper:]' '[:lower:]')" != "true" && "${HELM_CLIENT_TAG}" == v2.* ]]; then
    echo "Use --labels tiller_enabled=True for helm_client_tag<v3.0.0 to allow for tiller dependent resources to be installed."
else
    helm_install_cmd="helm upgrade --install magnum . --namespace kube-system --values values.yaml --render-subchart-notes"
    helm_history_cmd="helm history magnum --namespace kube-system"
    if [[ "${HELM_CLIENT_TAG}" == v2.* ]]; then
        helm_install_cmd="helm upgrade --install --name magnum . --namespace kube-system --values values.yaml --render-subchart-notes"
        helm_history_cmd="helm history magnum"
    fi

    HELM_CHART_DIR="/srv/magnum/kubernetes/helm/magnum"
    if [[ -d "${HELM_CHART_DIR}" ]]; then
        pushd ${HELM_CHART_DIR}
        cat << EOF > Chart.yaml
apiVersion: v1
name: magnum
version: metachart
appVersion: metachart
description: Magnum Helm Charts
EOF
        sed -i '1i\dependencies:' requirements.yaml

        i=0
        until ($helm_history_cmd | grep magnum | grep deployed) || (helm dep update && $helm_install_cmd); do
            i=$((i + 1))
            [ $i -lt 60 ] || break;
            sleep 5
        done
        popd
    fi
fi

echo "END: ${step}"

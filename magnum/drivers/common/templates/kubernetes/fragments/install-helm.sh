#!/bin/bash

step="install-helm"
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

if [[ "$(echo ${TILLER_ENABLED} | tr '[:upper:]' '[:lower:]')" != "true" && "${HELM_CLIENT_TAG}" == v2.* ]]; then
    echo "Use --labels tiller_enabled=True for helm_client_tag<v3.0.0 to allow for tiller dependent resources to be installed."
else
    if [ -z "${HELM_CLIENT_URL}"  ] ; then
        HELM_CLIENT_URL="https://get.helm.sh/helm-$HELM_CLIENT_TAG-linux-amd64.tar.gz"
    fi
    i=0
    until curl -o /srv/magnum/helm-client.tar.gz "${HELM_CLIENT_URL}"; do
        i=$((i + 1))
        [ $i -lt 5 ] || break;
        sleep 5
    done

    if ! echo "${HELM_CLIENT_SHA256} /srv/magnum/helm-client.tar.gz" | sha256sum -c - ; then
        echo "ERROR helm-client.tar.gz computed checksum did NOT match, exiting."
        exit 1
    fi

    source /etc/bashrc
    $ssh_cmd tar xzvf /srv/magnum/helm-client.tar.gz linux-amd64/helm -O > /srv/magnum/bin/helm
    $ssh_cmd chmod +x /srv/magnum/bin/helm

    if [[ "${HELM_CLIENT_TAG}" == v2.* ]]; then
        CERTS_DIR="/etc/kubernetes/helm/certs"
        export HELM_HOME="/srv/magnum/kubernetes/helm/home"
        export HELM_TLS_ENABLE="true"
        export TILLER_NAMESPACE
        mkdir -p "${HELM_HOME}"
        ln -s ${CERTS_DIR}/helm.cert.pem ${HELM_HOME}/cert.pem
        ln -s ${CERTS_DIR}/helm.key.pem ${HELM_HOME}/key.pem
        ln -s ${CERTS_DIR}/ca.cert.pem ${HELM_HOME}/ca.pem

        # HACK - Force wait because of bug https://github.com/helm/helm/issues/5170
        until helm init --client-only --wait; do
            sleep 5s
        done
    fi
fi

echo "END: ${step}"

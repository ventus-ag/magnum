#!/bin/sh

step="enable-flannel-plugin"
printf "Starting to run ${step}\n"

. /etc/sysconfig/heat-params

ssh_cmd="ssh -F /srv/magnum/.ssh/config root@localhost"

if [ "$NETWORK_DRIVER" = "flannel" ]; then
    _prefix=${CONTAINER_INFRA_PREFIX:-quay.io/coreos/}
    FLANNEL_NS=/srv/magnum/kubernetes/manifests/flannel-namespace.yaml

    echo "Writing File: $FLANNEL_NS"
    mkdir -p "$(dirname ${FLANNEL_NS})"
    set +x
    cat << EOF > ${FLANNEL_NS}
---
kind: Namespace
apiVersion: v1
metadata:
  name: kube-flannel
  labels:
    pod-security.kubernetes.io/enforce: privileged
EOF

FLANNEL_VALUES_YAML=/srv/magnum/kubernetes/helm/flannel/values.yaml
    echo "Writing File: $FLANNEL_VALUES_YAML"
    mkdir -p $(dirname ${FLANNEL_VALUES_YAML})
    cat << EOF > ${FLANNEL_VALUES_YAML}
---
# The IPv4 cidr pool to create on startup if none exists. Pod IPs will be
# chosen from this range.
podCidr: "${FLANNEL_NETWORK_CIDR}"

flannel:
  backend: "${FLANNEL_BACKEND}"
EOF

    set -x

    if [ "$MASTER_INDEX" = "0" ]; then

        until  [ "ok" = "$(kubectl get --raw='/healthz' 2>nil)" ]
        do
            echo "Waiting for Kubernetes API..."
            sleep 5
        done
    fi

    $ssh_cmd kubectl apply -f "${FLANNEL_NS}"

    $ssh_cmd helm repo add flannel https://flannel-io.github.io/flannel/

    if $ssh_cmd helm plugin list | grep -q "mapkubeapis"; then
        echo "mapkubeapis is already installed."
    else
        echo "mapkubeapis is not installed. Installing now..."
        $ssh_cmd helm plugin install https://github.com/helm/helm-mapkubeapis
    fi
    if $ssh_cmd helm list --namespace kube-flannel| grep -q "flannel"; then
        $ssh_cmd helm mapkubeapis flannel --namespace kube-flannel
    fi


    $ssh_cmd rm -rf /opt/cni/bin/*
    $ssh_cmd mkdir -p /opt/cni/bin

    cni_plugin_path="/srv/magnum/kubernetes/cni"
    $ssh_cmd mkdir -p ${cni_plugin_path}
    $ssh_cmd curl --retry 5 --retry-delay 10 -L https://github.com/containernetworking/plugins/releases/download/${FLANNEL_CNI_TAG}/cni-plugins-linux-amd64-${FLANNEL_CNI_TAG}.tgz -o ${cni_plugin_path}/cni-plugins-linux-amd64-${FLANNEL_CNI_TAG}.tgz
    $ssh_cmd tar -C /opt/cni/bin -xzf ${cni_plugin_path}/cni-plugins-linux-amd64-${FLANNEL_CNI_TAG}.tgz
    $ssh_cmd chmod +x /opt/cni/bin/*

    $ssh_cmd helm upgrade -i flannel flannel/flannel --version ${FLANNEL_TAG} -n kube-flannel -f ${FLANNEL_VALUES_YAML}
    
    if $ssh_cmd helm list --namespace kube-flannel| grep -q "flannel"; then
        $ssh_cmd helm mapkubeapis flannel --namespace kube-flannel
    fi
fi


printf "Finished running ${step}\n"

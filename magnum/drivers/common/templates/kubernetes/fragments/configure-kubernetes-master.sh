#!/bin/bash

set +x
. /etc/sysconfig/heat-params
set -x
set -e

echo "configuring kubernetes (master)"

ssh_cmd="ssh -F /srv/magnum/.ssh/config root@localhost"

version_gt() { test "$(printf '%s\n' "$@" | sort -V | head -n 1)" != "$1"; }

if [ ! -z "$HTTP_PROXY" ]; then
    export HTTP_PROXY
fi

if [ ! -z "$HTTPS_PROXY" ]; then
    export HTTPS_PROXY
fi

if [ ! -z "$NO_PROXY" ]; then
    export NO_PROXY
fi

if [[ ! -f "/tmp/old_kube_tag" ]]; then
  $ssh_cmd rm -rf /etc/cni/net.d/*
fi

if [ "${CONTAINER_RUNTIME}" = "host-docker"  ] ; then
    $ssh_cmd rm -rf /var/lib/cni/*
    $ssh_cmd rm -rf /opt/cni/*
    $ssh_cmd mkdir -p /opt/cni/bin
    $ssh_cmd mkdir -p /etc/cni/net.d/

    cni_plugin_path="/srv/magnum/kubernetes/cni"
    cni_plugin_version="1.0.1"
    flannel_plugin_version="1.0"
    $ssh_cmd mkdir -p ${cni_plugin_path}
    # $ssh_cmd curl --retry 5 --retry-delay 10 -L https://github.com/containernetworking/plugins/releases/download/v${cni_plugin_version}/cni-plugins-linux-amd64-v${cni_plugin_version}.tgz -o ${cni_plugin_path}/cni-plugins-linux-amd64-v${cni_plugin_version}.tgz
    $ssh_cmd curl --retry 5 --retry-delay 10 -L https://magnum.ventuscloud.eu/public/cni-plugins-linux-amd64-v${cni_plugin_version}.tgz -o ${cni_plugin_path}/cni-plugins-linux-amd64-v${cni_plugin_version}.tgz
    $ssh_cmd mkdir -p /opt/cni/bin
    $ssh_cmd tar zxf ${cni_plugin_path}/cni-plugins-linux-amd64-v${cni_plugin_version}.tgz -C /opt/cni/bin
    # $ssh_cmd curl --retry 5 --retry-delay 10 -L https://github.com/flannel-io/cni-plugin/releases/download/v${flannel_plugin_version}/flannel-${ARCH} -o /opt/cni/bin/flannel
    $ssh_cmd curl --retry 5 --retry-delay 10 -L https://magnum.ventuscloud.eu/public/flannel-amd64 -o /opt/cni/bin/flannel
    $ssh_cmd chmod +x /opt/cni/bin/*
fi

if [ "$NETWORK_DRIVER" = "calico" ]; then
    echo "net.ipv4.conf.all.rp_filter = 1" >> /etc/sysctl.conf
    $ssh_cmd sysctl -p
    if [ "`systemctl status NetworkManager.service | grep -o "Active: active"`" = "Active: active" ]; then
        CALICO_NM=/etc/NetworkManager/conf.d/calico.conf
        [ -f ${CALICO_NM} ] || {
        echo "Writing File: $CALICO_NM"
        mkdir -p $(dirname ${CALICO_NM})
        cat << EOF > ${CALICO_NM}
[keyfile]
unmanaged-devices=interface-name:cali*;interface-name:tunl*
EOF
}
        systemctl restart NetworkManager
    fi
elif [ "$NETWORK_DRIVER" = "flannel" ]; then
    $ssh_cmd modprobe -a vxlan br_netfilter
    cat <<EOF > /etc/modules-load.d/flannel.conf
vxlan
br_netfilter
EOF
fi

cat <<EOF > /etc/sysctl.d/k8s_custom.conf
net.ipv4.conf.default.rp_filter=2
net.ipv4.conf.*.rp_filter=2
net.ipv4.conf.all.promote_secondaries = 1
net.ipv4.conf.*.accept_source_route = 1
net.ipv4.ip_unprivileged_port_start = 0
net.ipv4.ping_group_range = 0 2147483647
EOF

mkdir -p /srv/magnum/kubernetes/
cat > /etc/kubernetes/config <<EOF
KUBE_LOG_LEVEL="--v=2"
EOF

cat > /etc/kubernetes/apiserver <<EOF
KUBE_ETCD_SERVERS="--etcd-servers=http://127.0.0.1:2379,http://127.0.0.1:4001"
KUBE_SERVICE_ADDRESSES="--service-cluster-ip-range=10.254.0.0/16"
KUBE_API_ARGS=""
EOF

cat > /etc/kubernetes/controller-manager <<EOF
KUBE_CONTROLLER_MANAGER_ARGS="--authorization-always-allow-paths=/healthz,/readyz,/livez,/metrics"
EOF
cat > /etc/kubernetes/scheduler<<EOF
KUBE_SCHEDULER_ARGS="--authorization-always-allow-paths=/healthz,/readyz,/livez,/metrics"
EOF
cat > /etc/kubernetes/proxy <<EOF
KUBE_PROXY_ARGS=""
EOF


if [ "$(echo $USE_PODMAN | tr '[:upper:]' '[:lower:]')" == "true" ]; then
    cat > /etc/systemd/system/kube-apiserver.service <<EOF
[Unit]
Description=kube-apiserver
[Service]
EnvironmentFile=/etc/sysconfig/heat-params
EnvironmentFile=/etc/kubernetes/config
EnvironmentFile=/etc/kubernetes/apiserver
ExecStartPre=/bin/mkdir -p /etc/kubernetes/
ExecStartPre=-/usr/bin/podman rm kube-apiserver
ExecStart=/bin/bash -c '/usr/bin/podman run --name kube-apiserver \\
    --net host \\
    --volume /etc/kubernetes:/etc/kubernetes:ro,z \\
    --volume /usr/lib/os-release:/etc/os-release:ro \\
    --volume /etc/ssl/certs:/etc/ssl/certs:ro \\
    --volume /run:/run \\
    --volume /etc/pki/tls/certs:/usr/share/ca-certificates:ro \\
    \${CONTAINER_INFRA_PREFIX:-k8s.gcr.io/}kube-apiserver-\${ARCH}:\${KUBE_TAG} \\
    kube-apiserver \\
    \$KUBE_LOG_LEVEL \$KUBE_ETCD_SERVERS \$KUBE_API_ADDRESS \$KUBE_SERVICE_ADDRESSES \$KUBE_API_ARGS'
ExecStop=-/usr/bin/podman stop kube-apiserver
Delegate=yes
Restart=always
RestartSec=10
TimeoutStartSec=10min
[Install]
WantedBy=multi-user.target
EOF

    cat > /etc/systemd/system/kube-controller-manager.service <<EOF
[Unit]
Description=kube-controller-manager
[Service]
EnvironmentFile=/etc/sysconfig/heat-params
EnvironmentFile=/etc/kubernetes/config
EnvironmentFile=/etc/kubernetes/controller-manager
ExecStartPre=/bin/mkdir -p /etc/kubernetes/
ExecStartPre=-/usr/bin/podman rm kube-controller-manager
ExecStart=/bin/bash -c '/usr/bin/podman run --name kube-controller-manager \\
    --net host \\
    --volume /etc/kubernetes:/etc/kubernetes:ro,z \\
    --volume /usr/lib/os-release:/etc/os-release:ro \\
    --volume /etc/ssl/certs:/etc/ssl/certs:ro \\
    --volume /run:/run \\
    --volume /etc/pki/tls/certs:/usr/share/ca-certificates:ro \\
    \${CONTAINER_INFRA_PREFIX:-k8s.gcr.io/}kube-controller-manager-\${ARCH}:\${KUBE_TAG} \\
    kube-controller-manager \\
    --secure-port=0 \\
    \$KUBE_LOG_LEVEL \$KUBE_MASTER \$KUBE_CONTROLLER_MANAGER_ARGS'
ExecStop=-/usr/bin/podman stop kube-controller-manager
Delegate=yes
Restart=always
RestartSec=10
TimeoutStartSec=10min
[Install]
WantedBy=multi-user.target
EOF

    cat > /etc/systemd/system/kube-scheduler.service <<EOF
[Unit]
Description=kube-scheduler
[Service]
EnvironmentFile=/etc/sysconfig/heat-params
EnvironmentFile=/etc/kubernetes/config
EnvironmentFile=/etc/kubernetes/scheduler
ExecStartPre=/bin/mkdir -p /etc/kubernetes/
ExecStartPre=-/usr/bin/podman rm kube-scheduler
ExecStart=/bin/bash -c '/usr/bin/podman run --name kube-scheduler \\
    --net host \\
    --volume /etc/kubernetes:/etc/kubernetes:ro,z \\
    --volume /usr/lib/os-release:/etc/os-release:ro \\
    --volume /etc/ssl/certs:/etc/ssl/certs:ro \\
    --volume /run:/run \\
    --volume /etc/pki/tls/certs:/usr/share/ca-certificates:ro \\
    \${CONTAINER_INFRA_PREFIX:-k8s.gcr.io/}kube-scheduler-\${ARCH}:\${KUBE_TAG} \\
    kube-scheduler \\
    \$KUBE_LOG_LEVEL \$KUBE_MASTER \$KUBE_SCHEDULER_ARGS'
ExecStop=-/usr/bin/podman stop kube-scheduler
Delegate=yes
Restart=always
RestartSec=10
TimeoutStartSec=10min
[Install]
WantedBy=multi-user.target
EOF

    cat > /etc/systemd/system/kubelet.service <<EOF
[Unit]
Description=Kubelet
After=containerd.service
Wants=containerd.service

[Service]
EnvironmentFile=/etc/sysconfig/heat-params
EnvironmentFile=/etc/kubernetes/config
EnvironmentFile=-/etc/kubernetes/kubelet.env
ExecStartPre=/bin/mkdir -p /etc/kubernetes/cni/net.d
ExecStartPre=/bin/mkdir -p /etc/kubernetes/manifests
ExecStartPre=/bin/mkdir -p /var/lib/calico
ExecStartPre=/bin/mkdir -p /var/lib/containerd
ExecStartPre=/bin/mkdir -p /var/lib/docker
ExecStartPre=/bin/mkdir -p /var/lib/kubelet/volumeplugins
ExecStartPre=/bin/mkdir -p /opt/cni/bin
ExecStart=/usr/local/bin/kubelet \\
    \$KUBE_LOG_LEVEL \$KUBE_LOGTOSTDERR \$KUBELET_API_SERVER \$KUBELET_ADDRESS \$KUBELET_HOSTNAME \$KUBELET_ARGS
Delegate=yes
Restart=always
RestartSec=10
TimeoutStartSec=10min
[Install]
WantedBy=multi-user.target
EOF

    cat > /etc/systemd/system/kube-proxy.service <<EOF
[Unit]
Description=kube-proxy
[Service]
EnvironmentFile=/etc/sysconfig/heat-params
EnvironmentFile=/etc/kubernetes/config
EnvironmentFile=/etc/kubernetes/proxy
ExecStartPre=/bin/mkdir -p /etc/kubernetes/
ExecStartPre=-/usr/bin/podman rm kube-proxy
ExecStart=/bin/bash -c '/usr/bin/podman run --name kube-proxy \\
    --privileged \\
    --net host \\
    --volume /etc/kubernetes:/etc/kubernetes:ro,z \\
    --volume /usr/lib/os-release:/etc/os-release:ro \\
    --volume /etc/ssl/certs:/etc/ssl/certs:ro \\
    --volume /run:/run \\
    --volume /sys/fs/cgroup:/sys/fs/cgroup \\
    --volume /lib/modules:/lib/modules:ro \\
    --volume /etc/pki/tls/certs:/usr/share/ca-certificates:ro \\
    \${CONTAINER_INFRA_PREFIX:-k8s.gcr.io/}kube-proxy-\${ARCH}:\${KUBE_TAG} \\
    kube-proxy \\
    \$KUBE_LOG_LEVEL \$KUBE_MASTER \$KUBE_PROXY_ARGS'
ExecStop=-/usr/bin/podman stop kube-proxy
Delegate=yes
Restart=always
RestartSec=10
TimeoutStartSec=10min
[Install]
WantedBy=multi-user.target
EOF
else
    _prefix=${CONTAINER_INFRA_PREFIX:-docker.io/openstackmagnum/}
    _addtl_mounts=',{"type":"bind","source":"/opt/cni","destination":"/opt/cni","options":["bind","rw","slave","mode=777"]},{"type":"bind","source":"/var/lib/docker","destination":"/var/lib/docker","options":["bind","rw","slave","mode=755"]}'
    mkdir -p /srv/magnum/kubernetes/
    cat > /srv/magnum/kubernetes/install-kubernetes.sh <<EOF
#!/bin/bash -x
atomic install --storage ostree --system --set=ADDTL_MOUNTS='${_addtl_mounts}' --system-package=no --name=kubelet ${_prefix}kubernetes-kubelet:${KUBE_TAG}
atomic install --storage ostree --system --system-package=no --name=kube-apiserver ${_prefix}kubernetes-apiserver:${KUBE_TAG}
atomic install --storage ostree --system --system-package=no --name=kube-controller-manager ${_prefix}kubernetes-controller-manager:${KUBE_TAG}
atomic install --storage ostree --system --system-package=no --name=kube-scheduler ${_prefix}kubernetes-scheduler:${KUBE_TAG}
atomic install --storage ostree --system --system-package=no --name=kube-proxy ${_prefix}kubernetes-proxy:${KUBE_TAG}
EOF
    chmod +x /srv/magnum/kubernetes/install-kubernetes.sh
    $ssh_cmd "/srv/magnum/kubernetes/install-kubernetes.sh"
fi

CERT_DIR=/etc/kubernetes/certs

# kube-proxy config
PROXY_KUBECONFIG=/etc/kubernetes/proxy-kubeconfig.yaml
KUBE_PROXY_ARGS="--kubeconfig=${PROXY_KUBECONFIG} --cluster-cidr=${PODS_NETWORK_CIDR} --hostname-override=${INSTANCE_NAME}"
cat > /etc/kubernetes/proxy << EOF
KUBE_PROXY_ARGS="${KUBE_PROXY_ARGS} ${KUBEPROXY_OPTIONS}"
EOF

cat > ${PROXY_KUBECONFIG} << EOF
apiVersion: v1
clusters:
- cluster:
    certificate-authority: ${CERT_DIR}/ca.crt
    server: https://127.0.0.1:${KUBE_API_PORT}
  name: kubernetes
contexts:
- context:
    cluster: kubernetes
    user: kube-proxy
  name: default
current-context: default
kind: Config
preferences: {}
users:
- name: kube-proxy
  user:
    as-user-extra: {}
    client-certificate: ${CERT_DIR}/proxy.crt
    client-key: ${CERT_DIR}/proxy.key
EOF
chmod 0640 ${PROXY_KUBECONFIG}

sed -i '
    /^KUBE_ALLOW_PRIV=/ s/=.*/="--allow-privileged='"$KUBE_ALLOW_PRIV"'"/
' /etc/kubernetes/config

KUBE_API_ARGS="--runtime-config=api/all=true"
KUBE_API_ARGS="$KUBE_API_ARGS --allow-privileged=$KUBE_ALLOW_PRIV"
KUBE_API_ARGS="$KUBE_API_ARGS --kubelet-preferred-address-types=InternalIP,Hostname,ExternalIP"
KUBE_API_ARGS="$KUBE_API_ARGS $KUBEAPI_OPTIONS"
KUBE_API_ADDRESS="--bind-address=0.0.0.0 --secure-port=$KUBE_API_PORT"
KUBE_API_ARGS="$KUBE_API_ARGS --authorization-mode=Node,RBAC --tls-cert-file=$CERT_DIR/server.crt"
KUBE_API_ARGS="$KUBE_API_ARGS --service-account-signing-key-file=$CERT_DIR/service_account_private.key"
KUBE_API_ARGS="$KUBE_API_ARGS --service-account-issuer=https://kubernetes.default.svc.cluster.local"
KUBE_API_ARGS="$KUBE_API_ARGS --tls-private-key-file=$CERT_DIR/server.key"
KUBE_API_ARGS="$KUBE_API_ARGS --client-ca-file=$CERT_DIR/ca.crt"
KUBE_API_ARGS="$KUBE_API_ARGS --service-account-key-file=${CERT_DIR}/service_account.key"
KUBE_API_ARGS="$KUBE_API_ARGS --kubelet-certificate-authority=${CERT_DIR}/ca.crt --kubelet-client-certificate=${CERT_DIR}/server.crt --kubelet-client-key=${CERT_DIR}/server.key"
# Allow for metrics-server/aggregator communication
KUBE_API_ARGS="${KUBE_API_ARGS} \
    --proxy-client-cert-file=${CERT_DIR}/server.crt \
    --proxy-client-key-file=${CERT_DIR}/server.key \
    --requestheader-allowed-names=front-proxy-client,kube,kubernetes \
    --requestheader-client-ca-file=${CERT_DIR}/ca.crt \
    --requestheader-extra-headers-prefix=X-Remote-Extra- \
    --requestheader-group-headers=X-Remote-Group \
    --requestheader-username-headers=X-Remote-User"


# if [ "$(echo "${CLOUD_PROVIDER_ENABLED}" | tr '[:upper:]' '[:lower:]')" = "true" ]; then
#     KUBE_API_ARGS="$KUBE_API_ARGS --cloud-provider=external"
# fi

if [ "$KEYSTONE_AUTH_ENABLED" == "True" ]; then
    KEYSTONE_WEBHOOK_CONFIG=/etc/kubernetes/keystone_webhook_config.yaml

    [ -f ${KEYSTONE_WEBHOOK_CONFIG} ] || {
echo "Writing File: $KEYSTONE_WEBHOOK_CONFIG"
mkdir -p $(dirname ${KEYSTONE_WEBHOOK_CONFIG})
cat > ${KEYSTONE_WEBHOOK_CONFIG} << EOF
---
apiVersion: v1
clusters:
- cluster:
    certificate-authority: ${CERT_DIR}/ca.crt
    server: https://127.0.0.1:${KUBE_API_PORT}
  name: ${CLUSTER_UUID}
contexts:
- context:
    cluster: ${CLUSTER_UUID}
    user: admin
  name: default
current-context: default
kind: Config
preferences: {}
users:
- name: admin
  user:
    as-user-extra: {}
    client-certificate: ${CERT_DIR}/admin.crt
    client-key: ${CERT_DIR}/admin.key
EOF
}
    KUBE_API_ARGS="$KUBE_API_ARGS --authentication-token-webhook-config-file=/etc/kubernetes/keystone_webhook_config.yaml --authorization-webhook-config-file=/etc/kubernetes/keystone_webhook_config.yaml"
    webhook_auth="--authorization-mode=Node,Webhook,RBAC"
    KUBE_API_ARGS=${KUBE_API_ARGS/--authorization-mode=Node,RBAC/$webhook_auth}
fi

sed -i '
    /^KUBE_API_ADDRESS=/ s/=.*/="'"${KUBE_API_ADDRESS}"'"/
    /^KUBE_SERVICE_ADDRESSES=/ s|=.*|="--service-cluster-ip-range='"$PORTAL_NETWORK_CIDR"'"|
    /^KUBE_API_ARGS=/ s|=.*|="'"${KUBE_API_ARGS}"'"|
    /^KUBE_ETCD_SERVERS=/ s/=.*/="--etcd-servers=http:\/\/127.0.0.1:2379"/
' /etc/kubernetes/apiserver

# kube-config controller 
CONTROLLER_KUBECONFIG=/etc/kubernetes/controller-kubeconfig.yaml
cat > ${CONTROLLER_KUBECONFIG} << EOF
apiVersion: v1
clusters:
- cluster:
    certificate-authority: ${CERT_DIR}/ca.crt
    server: https://127.0.0.1:${KUBE_API_PORT}
  name: kubernetes
contexts:
- context:
    cluster: kubernetes
    user: controller
  name: default
current-context: default
kind: Config
preferences: {}
users:
- name: controller
  user:
    as-user-extra: {}
    client-certificate: ${CERT_DIR}/controller.crt
    client-key: ${CERT_DIR}/controller.key
EOF
chmod 0640 ${CONTROLLER_KUBECONFIG}

# Add controller manager args
KUBE_CONTROLLER_MANAGER_ARGS="--leader-elect=true"
KUBE_CONTROLLER_MANAGER_ARGS="$KUBE_CONTROLLER_MANAGER_ARGS --cluster-name=${CLUSTER_UUID}"
KUBE_CONTROLLER_MANAGER_ARGS="${KUBE_CONTROLLER_MANAGER_ARGS} --allocate-node-cidrs=true"
KUBE_CONTROLLER_MANAGER_ARGS="${KUBE_CONTROLLER_MANAGER_ARGS} --kubeconfig=${CONTROLLER_KUBECONFIG}"
KUBE_CONTROLLER_MANAGER_ARGS="${KUBE_CONTROLLER_MANAGER_ARGS} --cluster-cidr=${PODS_NETWORK_CIDR}"
KUBE_CONTROLLER_MANAGER_ARGS="$KUBE_CONTROLLER_MANAGER_ARGS $KUBECONTROLLER_OPTIONS"
if [ -n "${ADMISSION_CONTROL_LIST}" ] && [ "${TLS_DISABLED}" == "False" ]; then
    KUBE_CONTROLLER_MANAGER_ARGS="$KUBE_CONTROLLER_MANAGER_ARGS --service-account-private-key-file=$CERT_DIR/service_account_private.key --root-ca-file=$CERT_DIR/ca.crt"
fi

if [ "$(echo "${CLOUD_PROVIDER_ENABLED}" | tr '[:upper:]' '[:lower:]')" = "true" ]; then
    KUBE_CONTROLLER_MANAGER_ARGS="$KUBE_CONTROLLER_MANAGER_ARGS --cloud-provider=external"
    # if [ "$(echo "${VOLUME_DRIVER}" | tr '[:upper:]' '[:lower:]')" = "cinder" ] && [ "$(echo "${CINDER_CSI_ENABLED}" | tr '[:upper:]' '[:lower:]')" != "true" ]; then
    #     KUBE_CONTROLLER_MANAGER_ARGS="$KUBE_CONTROLLER_MANAGER_ARGS --external-cloud-volume-plugin=openstack --cloud-config=/etc/kubernetes/cloud-config"
    # fi
fi


if [ "$(echo $CERT_MANAGER_API | tr '[:upper:]' '[:lower:]')" = "true" ]; then
    KUBE_CONTROLLER_MANAGER_ARGS="$KUBE_CONTROLLER_MANAGER_ARGS --cluster-signing-cert-file=$CERT_DIR/ca.crt --cluster-signing-key-file=$CERT_DIR/ca.key"
fi
KUBE_CONTROLLER_MANAGER_ARGS="${KUBE_CONTROLLER_MANAGER_ARGS} --use-service-account-credentials=true"
sed -i '
    /^KUBELET_ADDRESSES=/ s/=.*/="--machines='""'"/
    /^KUBE_CONTROLLER_MANAGER_ARGS=/ s#\(KUBE_CONTROLLER_MANAGER_ARGS\).*#\1="'"${KUBE_CONTROLLER_MANAGER_ARGS}"'"#
' /etc/kubernetes/controller-manager

# kube-config scheduler 
SCHEDULER_KUBECONFIG=/etc/kubernetes/scheduler-kubeconfig.yaml
cat > ${SCHEDULER_KUBECONFIG} << EOF
apiVersion: v1
clusters:
- cluster:
    certificate-authority: ${CERT_DIR}/ca.crt
    server: https://127.0.0.1:${KUBE_API_PORT}
  name: kubernetes
contexts:
- context:
    cluster: kubernetes
    user: scheduler
  name: default
current-context: default
kind: Config
preferences: {}
users:
- name: scheduler
  user:
    as-user-extra: {}
    client-certificate: ${CERT_DIR}/scheduler.crt
    client-key: ${CERT_DIR}/scheduler.key
EOF
chmod 0640 ${SCHEDULER_KUBECONFIG}


# Add scheduler args
KUBE_SCHEDULER_ARGS="--leader-elect=true"
KUBE_SCHEDULER_ARGS="${KUBE_SCHEDULER_ARGS} --kubeconfig=${SCHEDULER_KUBECONFIG}"

sed -i '
    /^KUBE_SCHEDULER_ARGS=/ s#\(KUBE_SCHEDULER_ARGS\).*#\1="'"${KUBE_SCHEDULER_ARGS}"'"#
' /etc/kubernetes/scheduler


# Add kubelet args
$ssh_cmd mkdir -p /etc/kubernetes/manifests
# KUBELET_ARGS="--pod-manifest-path=/etc/kubernetes/manifests"
KUBELET_ARGS=""
# KUBELET_ARGS="${KUBELET_ARGS} --pod-infra-container-image=${CONTAINER_INFRA_PREFIX:-gcr.io/google_containers/}pause:3.1"
KUBELET_ARGS="${KUBELET_ARGS} ${KUBELET_OPTIONS}"

# if [ "$(echo "${CLOUD_PROVIDER_ENABLED}" | tr '[:upper:]' '[:lower:]')" = "true" ]; then
#     KUBELET_ARGS="${KUBELET_ARGS} --cloud-provider=external"
# fi

if [ -f /etc/sysconfig/docker ] ; then
    # For using default log-driver, other options should be ignored
    sed -i 's/\-\-log\-driver\=journald//g' /etc/sysconfig/docker
    # json-file is required for conformance.
    # https://docs.docker.com/config/containers/logging/json-file/
    sed -i -E 's/^OPTIONS=("|'"'"')/OPTIONS=\1--log-driver=json-file --log-opt max-size=10m --log-opt max-file=5 /' /etc/sysconfig/docker

    if [ -n "${INSECURE_REGISTRY_URL}" ]; then
        echo "INSECURE_REGISTRY='--insecure-registry ${INSECURE_REGISTRY_URL}'" >> /etc/sysconfig/docker
    fi
fi

#KUBELET_ARGS="${KUBELET_ARGS} --cni --cni-conf-dir=/etc/cni/net.d --cni-bin-dir=/opt/cni/bin"

KUBELET_ARGS="${KUBELET_ARGS} --node-labels=magnum.openstack.org/role=${NODEGROUP_ROLE}"
KUBELET_ARGS="${KUBELET_ARGS} --node-labels=magnum.openstack.org/nodegroup=${NODEGROUP_NAME}"

KUBELET_KUBECONFIG=/etc/kubernetes/kubelet.conf
cat > ${KUBELET_KUBECONFIG} << EOF
apiVersion: v1
clusters:
- cluster:
    certificate-authority: ${CERT_DIR}/ca.crt
    server: https://127.0.0.1:${KUBE_API_PORT}
  name: kubernetes
contexts:
- context:
    cluster: kubernetes
    user: system:node:${INSTANCE_NAME}
  name: default
current-context: default
kind: Config
preferences: {}
users:
- name: system:node:${INSTANCE_NAME}
  user:
    as-user-extra: {}
    client-certificate: ${CERT_DIR}/kubelet.crt
    client-key: ${CERT_DIR}/kubelet.key
EOF
chmod 0640 ${KUBELET_KUBECONFIG}

KUBELET_ARGS="${KUBELET_ARGS} --kubeconfig ${KUBELET_KUBECONFIG}"

cat > /etc/kubernetes/get_require_kubeconfig.sh << EOF
#!/bin/bash

KUBE_VERSION=\$(kubelet --version | awk '{print \$2}')
min_version=v1.8.0
if [[ "\${min_version}" != \$(echo -e "\${min_version}\n\${KUBE_VERSION}" | sort -s -t. -k 1,1 -k 2,2n -k 3,3n | head -n1) && "\${KUBE_VERSION}" != "devel" ]]; then
    echo "--require-kubeconfig"
fi
EOF
chmod +x /etc/kubernetes/get_require_kubeconfig.sh

# KUBELET_ARGS="${KUBELET_ARGS} --client-ca-file=${CERT_DIR}/ca.crt --tls-cert-file=${CERT_DIR}/kubelet.crt --tls-private-key-file=${CERT_DIR}/kubelet.key --kubeconfig ${KUBELET_KUBECONFIG}"

# specified cgroup driver
# KUBELET_ARGS="${KUBELET_ARGS} --cgroup-driver=${CGROUP_DRIVER}"
if [ ${CONTAINER_RUNTIME} = "containerd"  ] ; then
    KUBELET_ARGS="${KUBELET_ARGS} --runtime-cgroups=/system.slice/containerd.service"

  # if less than 1.27, use remote runtime flags
  if ! version_gt $(echo ${KUBE_TAG} | cut -c 2-) 1.27; then
      KUBELET_ARGS="${KUBELET_ARGS} --container-runtime=remote"
      KUBELET_ARGS="${KUBELET_ARGS} --container-runtime-endpoint=unix:///run/containerd/containerd.sock"
  fi

fi

if [ -z "${KUBE_NODE_IP}" ]; then
    KUBE_NODE_IP=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)
fi

#KUBELET_ARGS="${KUBELET_ARGS} --address=${KUBE_NODE_IP} --port=10250 --read-only-port=0 --anonymous-auth=false --authorization-mode=Webhook --authentication-token-webhook=true"

EXTRA_KUBELETCONFIG_PARAMETERS=""
if version_gt $(echo ${KUBE_TAG} | cut -c 2-) 1.21; then
  EXTRA_KUBELETCONFIG_PARAMETERS='containerRuntimeEndpoint: unix:///run/containerd/containerd.sock
shutdownGracePeriod: 60s
shutdownGracePeriodCriticalPods: 20s'
fi

KUBELET_CONFIG=/etc/kubernetes/kubelet-config.yaml
cat > ${KUBELET_CONFIG} << EOF
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
authentication:
  anonymous:
    enabled: false
  webhook:
    cacheTTL: 0s
    enabled: true
  x509:
    clientCAFile: "${CERT_DIR}/ca.crt"
authorization:
  mode: Webhook
  webhook:
    cacheAuthorizedTTL: 0s
    cacheUnauthorizedTTL: 0s
cgroupDriver: ${CGROUP_DRIVER}
clusterDNS:
- ${DNS_SERVICE_IP}
clusterDomain: ${DNS_CLUSTER_DOMAIN}
address: ${KUBE_NODE_IP}
failSwapOn: True
port: 10250
readOnlyPort: 0
containerLogMaxFiles: 5
containerLogMaxSize: 10Mi
registerWithTaints:
  - effect: "NoSchedule"
    key: "node-role.kubernetes.io/${LEAD_NODE_ROLE_NAME}"
maxPods: 110
podPidsLimit: -1
resolvConf: /run/systemd/resolve/resolv.conf
volumePluginDir: /var/lib/kubelet/volumeplugins
rotateCertificates: true
tlsCertFile: ${CERT_DIR}/kubelet.crt
tlsPrivateKeyFile: ${CERT_DIR}/kubelet.key
staticPodPath: /etc/kubernetes/manifests
runtimeRequestTimeout: 15m
eventRecordQPS: 5
${EXTRA_KUBELETCONFIG_PARAMETERS}
EOF
KUBELET_ARGS="${KUBELET_ARGS} --config=${KUBELET_CONFIG}"


cat > /etc/kubernetes/kubelet.env <<EOF
KUBELET_ADDRESS="--node-ip=${KUBE_NODE_IP}"
KUBELET_HOSTNAME="--hostname-override=${INSTANCE_NAME}"
KUBELET_ARGS="${KUBELET_ARGS}"
EOF

#!/bin/bash

set +x

echo "START: install cri"

. /etc/sysconfig/heat-params
set -x

ssh_cmd="ssh -F /srv/magnum/.ssh/config root@localhost"

if [ "${CONTAINER_RUNTIME}" = "containerd"  ] ; then
    $ssh_cmd systemctl stop docker 2>/dev/null
    $ssh_cmd systemctl disable docker 2>/dev/null

    # For containerd 2.0+, we need to install components separately
    # as the cri-containerd-cni bundle has been removed
    if [ -z "${CONTAINERD_TARBALL_URL}"  ] ; then
        CONTAINERD_TARBALL_URL="https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VERSION}/containerd-${CONTAINERD_VERSION}-linux-amd64.tar.gz"
    fi

    # Install containerd
    $ssh_cmd curl --retry 5 --retry-delay 10 -L ${CONTAINERD_TARBALL_URL} -o /srv/magnum/containerd.tar.gz
    $ssh_cmd mkdir -p /usr/local/bin
    $ssh_cmd tar xzvf /srv/magnum/containerd.tar.gz -C /usr/local --no-same-owner --touch --no-same-permissions

    # Install runc - required for containerd 2.0 as it's no longer bundled
    RUNC_VERSION="1.2.5"
    $ssh_cmd curl --retry 5 --retry-delay 10 -L https://github.com/opencontainers/runc/releases/download/v${RUNC_VERSION}/runc.amd64 -o /usr/local/bin/runc
    $ssh_cmd chmod +x /usr/local/bin/runc

    $ssh_cmd mkdir -p /etc/containerd
cat << EOF > /etc/containerd/config.toml
version = 3
root = "/var/lib/containerd"
state = "/run/containerd"
oom_score = 0

[grpc]
  address = "/run/containerd/containerd.sock"
  max_recv_message_size = 16777216
  max_send_message_size = 16777216

[debug]
  level = "info"

[metrics]
  address = ""
  grpc_histogram = false

[plugins]
  [plugins."io.containerd.grpc.v1.cri"]
    sandbox_image = "registry.k8s.io/pause:3.9"
    max_container_log_line_size = 16384
    enable_unprivileged_ports = true
    enable_unprivileged_icmp = true
    [plugins."io.containerd.grpc.v1.cri".cni]
      bin_dir = "/opt/cni/bin/"
      conf_dir = "/etc/cni/net.d"
    [plugins."io.containerd.grpc.v1.cri".containerd]
      default_runtime_name = "runc"
      snapshotter = "overlayfs"
      [plugins."io.containerd.grpc.v1.cri".containerd.runtimes]
        [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
          runtime_type = "io.containerd.runc.v2"
          [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
            BinaryName = "/usr/local/bin/runc"
    [plugins."io.containerd.grpc.v1.cri".registry]
      config_path = "/etc/containerd/certs.d"
      [plugins."io.containerd.grpc.v1.cri".registry.mirrors]
        [plugins."io.containerd.grpc.v1.cri".registry.mirrors."docker.io"]
          endpoint = ["https://registry-1.docker.io"]
  [plugins."io.containerd.internal.v1.opt"]
    path = "/var/lib/containerd/opt"
EOF

    # Create registry configuration directory
    $ssh_cmd mkdir -p /etc/containerd/certs.d

    $ssh_cmd systemctl daemon-reload
    $ssh_cmd systemctl enable containerd
    $ssh_cmd systemctl restart containerd
else
    # CONTAINER_RUNTIME=host-docker
    $ssh_cmd systemctl disable docker
    if $ssh_cmd cat /usr/lib/systemd/system/docker.service | grep 'native.cgroupdriver'; then
            $ssh_cmd cp /usr/lib/systemd/system/docker.service /etc/systemd/system/
            sed -i "s/\(native.cgroupdriver=\)\w\+/\1$CGROUP_DRIVER/" \
                    /etc/systemd/system/docker.service
    else
            cat > /etc/systemd/system/docker.service.d/cgroupdriver.conf << EOF
    ExecStart=---exec-opt native.cgroupdriver=$CGROUP_DRIVER
EOF
    fi

    $ssh_cmd systemctl daemon-reload
    $ssh_cmd systemctl enable docker
fi

echo "END: install cri"

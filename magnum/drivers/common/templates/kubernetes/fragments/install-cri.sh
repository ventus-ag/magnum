#!/bin/bash

set +x

echo "START: install cri"

. /etc/sysconfig/heat-params
set -x

ssh_cmd="ssh -F /srv/magnum/.ssh/config root@localhost"

if [ "${CONTAINER_RUNTIME}" = "containerd"  ] ; then
    $ssh_cmd systemctl disable docker
    if [ -z "${CONTAINERD_TARBALL_URL}"  ] ; then
        CONTAINERD_TARBALL_URL="https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VERSION}/cri-containerd-cni-${CONTAINERD_VERSION}-linux-amd64.tar.gz"
        #CONTAINERD_TARBALL_URL="https://magnum.ventuscloud.eu/public/cri-containerd-cni-${CONTAINERD_VERSION}-linux-amd64.tar.gz"
    fi

    $ssh_cmd curl --retry 5 --retry-delay 10 -L ${CONTAINERD_TARBALL_URL} -o /srv/magnum/cri-containerd-cni.tar.gz
    $ssh_cmd tar xzvf /srv/magnum/cri-containerd-cni.tar.gz -C / --no-same-owner --touch --no-same-permissions
    $ssh_cmd systemctl daemon-reload
    $ssh_cmd systemctl enable containerd
    $ssh_cmd systemctl start containerd
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

#!/bin/bash

. /etc/sysconfig/heat-params

set -x

ssh_cmd="ssh -F /srv/magnum/.ssh/config root@localhost"

export KUBECONFIG=/etc/kubernetes/admin.conf

if [ "$(echo $USE_PODMAN | tr '[:upper:]' '[:lower:]')" == "true" ]; then
    kubecontrol="/srv/magnum/bin/kubectl --kubeconfig $KUBECONFIG"
else
    kubecontrol="/var/lib/containers/atomic/heat-container-agent.0/rootfs/usr/bin/kubectl --kubeconfig $KUBECONFIG"
fi
new_kube_tag="$kube_tag_input"
new_kube_image_digest="$kube_image_digest"
new_ostree_remote="$ostree_remote_input"
new_ostree_commit="$ostree_commit_input"

function drain {
    # If there is only one master and this is the master node, skip the drain, just cordon it
    # If there is only one worker and this is the worker node, skip the drain, just cordon it
    all_masters=$(${ssh_cmd} ${kubecontrol} get nodes --selector=magnum.openstack.org/role=master -o name)
    all_workers=$(${ssh_cmd} ${kubecontrol} get nodes --selector=magnum.openstack.org/role!=master -o name)
    if [ "node/${INSTANCE_NAME}" != "${all_masters}" ] && [ "node/${INSTANCE_NAME}" != "${all_workers}" ]; then
        ${ssh_cmd} ${kubecontrol} drain ${INSTANCE_NAME} --ignore-daemonsets --delete-emptydir-data --force
    else
        ${ssh_cmd} ${kubecontrol} cordon ${INSTANCE_NAME}
    fi
}

if [ "${new_kube_tag}" != "${KUBE_TAG}" ]; then

    if [ "$(echo $USE_PODMAN | tr '[:upper:]' '[:lower:]')" == "true" ]; then
        SERVICE_LIST=$($ssh_cmd podman ps -f name=kube --format {{.Names}})
        echo "${SERVICE_LIST}" > /tmp/service_list

        echo "KUBE_TAG=$new_kube_tag" >> /etc/sysconfig/heat-params
        
        ${ssh_cmd} systemctl daemon-reload
        for service in ${SERVICE_LIST}; do
            ${ssh_cmd} systemctl start ${service}
        done
        ${ssh_cmd} systemctl start kubelet

        i=0
        until ${ssh_cmd} ${kubecontrol} uncordon ${INSTANCE_NAME}
        do
            i=$((i+1))
            [ $i -lt 30 ] || break;
            echo "Trying to uncordon node..."
            sleep 5s
        done
    fi
fi

function setup_uncordon {
    # Create a service to uncordon the node itself after reboot
    if [ ! -f /etc/systemd/system/uncordon.service ]; then
        $ssh_cmd cat > /etc/systemd/system/uncordon.service << EOF
[Unit]
Description=magnum-uncordon
After=network.target kubelet.service

[Service]
Restart=always
RemainAfterExit=yes
RestartSec=10
ExecStart=${kubecontrol} uncordon ${INSTANCE_NAME}

[Install]
WantedBy=multi-user.target
EOF
        ${ssh_cmd} systemctl enable uncordon.service
    fi
}

# NOTE(flwang): Record starts with "*" means the current one
current_ostree_commit=`${ssh_cmd} rpm-ostree status | grep -A 3 "* ostree://" | grep Commit | awk '{print $2}'`
current_ostree_remote=`${ssh_cmd} rpm-ostree status | awk '/* ostree/{print $0}' | awk '{match($0,"* ostree://([^ ]+)",a)}END{print a[1]}'`
remote_list=`${ssh_cmd} ostree remote list`

# NOTE(flwang): 1. Either deploy or rebase for only one upgrade
#               2. Using rpm-ostree command instead of atomic command to keep the possibility of supporting fedora coreos 30
if [ "$new_ostree_commit" != "" ] && [ "$current_ostree_commit" != "$new_ostree_commit" ]; then
    drain
    setup_uncordon
    ${ssh_cmd} rpm-ostree deploy $new_ostree_commit
    shutdown --reboot --no-wall -t 1
elif [ "$new_ostree_remote" != "" ] && [ "$current_ostree_remote" != "$new_ostree_remote" ]; then
    drain
    setup_uncordon
    ${ssh_cmd} rpm-ostree rebase $new_ostree_remote
    shutdown --reboot --no-wall -t 1
fi

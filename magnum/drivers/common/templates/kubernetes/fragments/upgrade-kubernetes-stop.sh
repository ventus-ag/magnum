#!/bin/bash

. /etc/sysconfig/heat-params

set -x

ssh_cmd="ssh -F /srv/magnum/.ssh/config root@localhost"

export KUBECONFIG=/etc/kubernetes/admin.conf

if [ "$(echo $USE_PODMAN | tr '[:upper:]' '[:lower:]')" == "true" ]; then
    kubecontrol="/srv/magnum/bin/kubectl --kubeconfig $KUBECONFIG"
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

    drain

    if [ "$(echo $USE_PODMAN | tr '[:upper:]' '[:lower:]')" == "true" ]; then
        SERVICE_LIST=$($ssh_cmd podman ps -f name=kube --format {{.Names}})
        echo "${SERVICE_LIST}" > /tmp/service_list

        for service in ${SERVICE_LIST}; do
            ${ssh_cmd} systemctl stop ${service}
            ${ssh_cmd} podman rm $(${ssh_cmd} podman ps --filter name=${service} -a -q)
            ${ssh_cmd} podman rmi $(${ssh_cmd} podman images --filter=reference=*${service}*:${KUBE_TAG} -a -q)
        done

        $ssh_cmd systemctl stop kubelet
        $ssh_cmd rm /usr/local/bin/kube*
        $ssh_cmd mkdir -p /srv/magnum/k8s/

        $ssh_cmd curl --retry 5 --retry-delay 10 -L -o /usr/local/bin/kubelet https://storage.googleapis.com/kubernetes-release/release/${new_kube_tag}/bin/linux/${ARCH}/kubelet
        $ssh_cmd curl --retry 5 --retry-delay 10 -L -o /usr/local/bin/kubectl https://storage.googleapis.com/kubernetes-release/release/${new_kube_tag}/bin/linux/${ARCH}/kubectl

        $ssh_cmd chmod +x /usr/local/bin/kube*

        if [[ "$SELINUX_MODE" == "enforcing" ]] ; then
            $ssh_cmd chcon system_u:object_r:bin_t:s0 /usr/local/bin/kube*
        fi

        $ssh_cmd cp /usr/local/bin/kubectl /srv/magnum/bin/
        $ssh_cmd chmod +x /srv/magnum/bin/kube*

        if [[ "$SELINUX_MODE" == "enforcing" ]] ; then
            $ssh_cmd chcon system_u:object_r:bin_t:s0 /srv/magnum/bin/kube*
        fi
    fi
fi
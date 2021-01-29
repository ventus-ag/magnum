#!/bin/bash
step="install-clients"
printf "Starting to run ${step}\n"

set -e
set +x
. /etc/sysconfig/heat-params
. /etc/bashrc
set -x

ssh_cmd="ssh -F /srv/magnum/.ssh/config root@localhost"
mkdir -p /srv/magnum/bin/

mkdir -p /srv/magnum/k8s/

echo "PATH=/srv/magnum/bin:\$PATH" >> /etc/bashrc

if [ -z "${KUBERNETES_TARBALL_URL}" ] ; then
    KUBERNETES_TARBALL_URL="https://dl.k8s.io/${KUBE_TAG}/kubernetes-server-linux-${ARCH}.tar.gz"
fi
#i=0
# until curl -L -o /srv/magnum/k8s.tar.gz ${KUBERNETES_TARBALL_URL} && echo "${KUBERNETES_TARBALL_SHA512} /srv/magnum/k8s.tar.gz" | sha512sum -c -
# do
#     i=$((i + 1))
#     if [ ${i} -gt 60 ] ; then
#         echo "ERROR Unable to download kubernetes-server-linux-${ARCH}.tar.gz. Abort."
#         exit 1
#     fi
#     echo "WARNING Attempt ${i}: Trying to download kubernetes-server-linux-${ARCH}.tar.gz. Sleeping 5s"
#     sleep 5s
# done

$ssh_cmd curl --retry 5 --retry-delay 10 -L -o /srv/magnum/k8s.tar.gz ${KUBERNETES_TARBALL_URL}

# Extrace binaries and images
$ssh_cmd tar xzvf /srv/magnum/k8s.tar.gz -C /srv/magnum/k8s/ kubernetes/server/bin

# Put node components in /usr/local/bin
$ssh_cmd mv /srv/magnum/k8s/kubernetes/server/bin/{kubelet,kubectl,kubeadm} /usr/local/bin/
$ssh_cmd chmod +x /usr/local/bin/kube*

if [[ "$SELINUX_MODE" == "enforcing" ]] ; then
    $ssh_cmd chcon system_u:object_r:bin_t:s0 /usr/local/bin/kube*
fi

$ssh_cmd cp /usr/local/bin/kubectl /srv/magnum/bin/
$ssh_cmd chmod +x /srv/magnum/bin/kube*

if [[ "$SELINUX_MODE" == "enforcing" ]] ; then
    $ssh_cmd chcon system_u:object_r:bin_t:s0 /srv/magnum/bin/kube*
fi

# Import images
if [ "$(echo $USE_PODMAN | tr '[:upper:]' '[:lower:]')" == "true" ] ; then
    for component in kube-apiserver kube-controller-manager kube-scheduler kube-proxy
    do
        $ssh_cmd podman load -i /srv/magnum/k8s/kubernetes/server/bin/${component}.tar "${CONTAINER_INFRA_PREFIX:-k8s.gcr.io}/${component}:$(cat /srv/magnum/k8s/kubernetes/server/bin/${component}.docker_tag)"
    done
fi

$ssh_cmd rm -f /srv/magnum/k8s.tar.gz
$ssh_cmd rm -rf /srv/magnum/k8s
echo "PATH=/srv/magnum/bin:\$PATH" >> /etc/bashrc

echo "INFO Installed kubernetes-server-linux."

printf "Finished running ${step}\n"

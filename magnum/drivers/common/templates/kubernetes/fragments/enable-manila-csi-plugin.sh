#!/bin/sh

step="enable-manila-csi-plugin"
printf "Starting to run ${step}\n"

. /etc/sysconfig/heat-params

manila_csi_plugin_enabled=$(echo $MANILA_CSI_PLUGIN_ENABLED | tr '[:upper:]' '[:lower:]')

if [ [ "${manila_csi_plugin_enabled}" = "true" ]; then
    helm repo add cpo https://kubernetes.github.io/cloud-provider-openstack
    helm repo update
    helm upgrade -i openstack-manila-csi cpo/openstack-manila-csi -n kube-system \
         --set fullnameOverride="" \
         --set shareProtocols[0].protocolSelector=CEPHFS \
         --set shareProtocols[0].fwdNodePluginEndpoint.dir=/var/lib/kubelet/plugins/cephfs.csi.ceph.com \
         --set shareProtocols[0].fwdNodePluginEndpoint.sockFile=csi.sock

fi
printf "Finished running ${step}\n"

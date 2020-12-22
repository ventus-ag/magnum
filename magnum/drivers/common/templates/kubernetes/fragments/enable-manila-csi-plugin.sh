#!/bin/sh

step="enable-manila-csi-plugin"
printf "Starting to run ${step}\n"

. /etc/sysconfig/heat-params

manila_csi_plugin_enabled=$(echo $MANILA_CSI_PLUGIN_ENABLED | tr '[:upper:]' '[:lower:]')

if [ "${manila_csi_plugin_enabled}" = "true" ]; then
    csi_plugin_path="/srv/magnum/kubernetes/manila-csi-plugin"
    rm -rf ${csi_plugin_path}
    mkdir -p ${csi_plugin_path}
    git clone --depth=1 -b release-1.19 https://github.com/kubernetes/cloud-provider-openstack.git ${csi_plugin_path}

    helm package ${csi_plugin_path}/charts/manila-csi-plugin -d ${csi_plugin_path}/package
    helm upgrade -i openstack-manila-csi $(ls -d ${csi_plugin_path}/package/*) -n kube-system \
         --set fullnameOverride="" \
         --set nodeplugin.registrar.image.tag=v1.2.0 \
         --set shareProtocols[0].protocolSelector=NFS \
         --set shareProtocols[0].fwdNodePluginEndpoint.dir=/var/lib/kubelet/plugins/csi-nfsplugin \
         --set shareProtocols[0].fwdNodePluginEndpoint.sockFile=csi.sock
fi
printf "Finished running ${step}\n"

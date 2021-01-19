#!/bin/sh

step="enable-cinder-csi-plugin"
printf "Starting to run ${step}\n"

. /etc/sysconfig/heat-params
. /etc/bashrc

volume_driver=$(echo "${VOLUME_DRIVER}" | tr '[:upper:]' '[:lower:]')
cinder_csi_plugin_enabled=$(echo $CINDER_CSI_PLUGIN_ENABLED | tr '[:upper:]' '[:lower:]')

if [ "${volume_driver}" = "cinder" ] && [ "${cinder_csi_plugin_enabled}" = "true" ]; then
    csi_plugin_path="/srv/magnum/kubernetes/cinder-csi-plugin"
    csi_plugin_branch="release-1.20"
    rm -rf ${csi_plugin_path}
    mkdir -p ${csi_plugin_path}
    curl -L https://github.com/kubernetes/cloud-provider-openstack/archive/${csi_plugin_branch}.tar.gz -o ${csi_plugin_path}/${csi_plugin_branch}.tar.gz
    tar -xzf ${csi_plugin_path}/${csi_plugin_branch}.tar.gz -C ${csi_plugin_path}
    helm package ${csi_plugin_path}/cloud-provider-openstack-${csi_plugin_branch}/charts/cinder-csi-plugin -d ${csi_plugin_path}/package
    helm upgrade -i cinder-csi $(ls -d ${csi_plugin_path}/package/*) -n kube-system \
         --set storageClass.delete.isDefault=true \
         --set csi.plugin.image.tag="${CINDER_CSI_PLUGIN_TAG}" \
         --set csi.attacher.image.tag="${CSI_ATTACHER_TAG}" \
         --set csi.provisioner.image.tag="${CSI_PROVISIONER_TAG}" \
         --set csi.snapshotter.image.tag="${CSI_SNAPSHOTTER_TAG}" \
         --set csi.resizer.image.tag="${CSI_RESIZER_TAG}" \
         --set csi.nodeDriverRegistrar.image.tag="${CSI_NODE_DRIVER_REGISTRAR_TAG}" \
         --set csi.plugin.volumes[0].name=cacert \
         --set csi.plugin.volumes[0].hostPath.path=/etc/kubernetes/ca-bundle.crt \
         --set csi.plugin.volumes[1].name=cloud-config \
         --set csi.plugin.volumes[1].hostPath.path=/etc/kubernetes/cloud-config \
         --set csi.plugin.volumeMounts[0].name=cacert \
         --set csi.plugin.volumeMounts[0].mountPath=/etc/kubernetes/ca-bundle.crt \
         --set csi.plugin.volumeMounts[0].readOnly=true \
         --set csi.plugin.volumeMounts[1].name=cloud-config \
         --set csi.plugin.volumeMounts[1].mountPath=/etc/kubernetes/cloud-config \
         --set csi.plugin.volumeMounts[1].readOnly=true

        # --version 1.2.2 \
fi
printf "Finished running ${step}\n"

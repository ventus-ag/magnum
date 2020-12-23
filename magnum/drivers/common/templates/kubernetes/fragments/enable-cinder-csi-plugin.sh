#!/bin/sh

step="enable-cinder-csi-plugin"
printf "Starting to run ${step}\n"

. /etc/sysconfig/heat-params

volume_driver=$(echo "${VOLUME_DRIVER}" | tr '[:upper:]' '[:lower:]')
cinder_csi_plugin_enabled=$(echo $CINDER_CSI_PLUGIN_ENABLED | tr '[:upper:]' '[:lower:]')

if [ "${volume_driver}" = "cinder" ] && [ "${cinder_csi_plugin_enabled}" = "true" ]; then
    csi_plugin_path="/srv/magnum/kubernetes/cinder-csi-plugin"
    rm -rf ${csi_plugin_path}
    mkdir -p ${csi_plugin_path}
    /bin/git clone --depth=1 -b release-1.19 https://github.com/kubernetes/cloud-provider-openstack.git ${csi_plugin_path}
    helm package ${csi_plugin_path}/charts/cinder-csi-plugin -d ${csi_plugin_path}/package
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

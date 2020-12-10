#!/bin/sh

step="enable-cinder-csi"
printf "Starting to run ${step}\n"

. /etc/sysconfig/heat-params

volume_driver=$(echo "${VOLUME_DRIVER}" | tr '[:upper:]' '[:lower:]')
cinder_csi_enabled=$(echo $CINDER_CSI_ENABLED | tr '[:upper:]' '[:lower:]')

if [ "${volume_driver}" = "cinder" ] && [ "${cinder_csi_enabled}" = "true" ]; then
    helm repo add cpo https://kubernetes.github.io/cloud-provider-openstack
    helm repo update
    helm upgrade -i cinder-csi cpo/openstack-cinder-csi -n kube-system \
         --set storageClass.delete.isDefault=true \
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
        #  --set csi.plugin.image.tag="${CINDER_CSI_PLUGIN_TAG}" \
        #  --set csi.attacher.image.tag="${CSI_ATTACHER_TAG}" \
        #  --set csi.provisioner.image.tag="${CSI_PROVISIONER_TAG}" \
        #  --set csi.snapshotter.image.tag="${CSI_SNAPSHOTTER_TAG}" \
        #  --set csi.resizer.image.tag="${CSI_RESIZER_TAG}" \
        #  --set csi.nodeDriverRegistrar.image.tag="${CSI_NODE_DRIVER_REGISTRAR_TAG}" \
fi
printf "Finished running ${step}\n"

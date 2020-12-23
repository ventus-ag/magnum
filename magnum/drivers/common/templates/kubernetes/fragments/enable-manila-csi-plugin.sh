#!/bin/sh

step="enable-manila-csi-plugin"
printf "Starting to run ${step}\n"

. /etc/sysconfig/heat-params

manila_csi_plugin_enabled=$(echo $MANILA_CSI_PLUGIN_ENABLED | tr '[:upper:]' '[:lower:]')

if [ "${manila_csi_plugin_enabled}" = "true" ]; then
    csi_driver_path="/srv/magnum/kubernetes/csi-driver-nfs"
    rm -rf ${csi_driver_path}
    mkdir -p ${csi_driver_path}
    /bin/git clone --depth=1 https://github.com/kubernetes-csi/csi-driver-nfs.git ${csi_driver_path}
    helm package ${csi_driver_path}/charts/v2.0.0/csi-driver-nfs -d ${csi_driver_path}/package
    helm upgrade -i nfs-driver $(ls -d ${csi_driver_path}/package/*) -n kube-system \
         --set controller.replicas=2


    csi_plugin_path="/srv/magnum/kubernetes/manila-csi-plugin"
    rm -rf ${csi_plugin_path}
    mkdir -p ${csi_plugin_path}
    /bin/git clone --depth=1 -b release-1.19 https://github.com/kubernetes/cloud-provider-openstack.git ${csi_plugin_path}
    helm package ${csi_plugin_path}/charts/manila-csi-plugin -d ${csi_plugin_path}/package
    helm upgrade -i openstack-manila-csi $(ls -d ${csi_plugin_path}/package/*) -n kube-system \
         --set fullnameOverride="" \
         --set shareProtocols[0].protocolSelector=NFS \
         --set shareProtocols[0].fwdNodePluginEndpoint.dir=/var/lib/kubelet/plugins/csi-nfsplugin \
         --set shareProtocols[0].fwdNodePluginEndpoint.sockFile=csi.sock


cat <<EOF | kubectl apply -f -
---
apiVersion: v1
kind: Secret
metadata:
  name: csi-manila-secrets
  namespace: kube-system
type: Opaque
stringData:
  os-authURL: "$AUTH_URL"
  os-region: "$REGION_NAME"
  os-trustID: "$TRUST_ID"
  os-trusteeID: "$TRUSTEE_USER_ID"
  os-trusteePassword: "$TRUSTEE_PASSWORD"
EOF


cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: csi-manila-nfs
provisioner: nfs.manila.csi.openstack.org
parameters:
  type: cephfsnfs1

  csi.storage.k8s.io/provisioner-secret-name: csi-manila-secrets
  csi.storage.k8s.io/provisioner-secret-namespace: kube-system
  csi.storage.k8s.io/node-stage-secret-name: csi-manila-secrets
  csi.storage.k8s.io/node-stage-secret-namespace: kube-system
  csi.storage.k8s.io/node-publish-secret-name: csi-manila-secrets
  csi.storage.k8s.io/node-publish-secret-namespace: kube-system
EOF

fi
printf "Finished running ${step}\n"

#!/bin/sh

step="enable-cinder-csi-plugin"
printf "Starting to run ${step}\n"

. /etc/sysconfig/heat-params

volume_driver=$(echo "${VOLUME_DRIVER}" | tr '[:upper:]' '[:lower:]')
cinder_csi_plugin_enabled=$(echo $CINDER_CSI_PLUGIN_ENABLED | tr '[:upper:]' '[:lower:]')

if [ "${volume_driver}" = "cinder" ] && [ "${cinder_csi_plugin_enabled}" = "true" ]; then
    _cindercsi_prefix=${CONTAINER_INFRA_PREFIX:-k8s.gcr.io/sig-storage/}
    _cinderplugin_prefix=${CONTAINER_INFRA_PREFIX:-docker.io/k8scloudprovider/}

CINDER_CSI_VALUES_YAML=/srv/magnum/kubernetes/helm/cinder-csi/values.yaml
[ -f ${CINDER_CSI_VALUES_YAML} ] || {
    echo "Writing File: $CINDER_CSI_VALUES_YAML"
    mkdir -p $(dirname ${CINDER_CSI_VALUES_YAML})
    cat << EOF > ${CINDER_CSI_VALUES_YAML}
csi:
  attacher:
    image:
      repository: ${_cindercsi_prefix}csi-attacher
  provisioner:
    topology: "true"
    image:
      repository: ${_cindercsi_prefix}csi-provisioner
  snapshotter:
    image:
      repository: ${_cindercsi_prefix}csi-snapshotter
  resizer:
    image:
      repository: ${_cindercsi_prefix}csi-resizer
  livenessprobe:
    image:
      repository: ${_cindercsi_prefix}livenessprobe
  nodeDriverRegistrar:
    image:
      repository: ${_cindercsi_prefix}csi-node-driver-registrar
  plugin:
    image:
      repository: ${_cinderplugin_prefix}cinder-csi-plugin
    volumes:
      - name: cacert
        hostPath:
          path: /etc/kubernetes/ca-bundle.crt
          type: File
    volumeMounts:
      - name: cacert
        mountPath: /etc/kubernetes/certs/ca-bundle.crt
        readOnly: true
      - name: cloud-config
        mountPath: /etc/kubernetes/config/
        readOnly: true
    nodePlugin:
      affinity: {}
      nodeSelector: {}
      tolerations:
        - operator: Exists
      kubeletDir: /var/lib/kubelet
  snapshotController:
    enabled: true
    image:
      repository: ${_cindercsi_prefix}snapshot-controller

secret:
  enabled: true
  create: true
  filename: config/cloud.conf
  name: cinder-csi-cloud-config
  data:
    cloud.conf: |-
      [Global]
      auth-url=${AUTH_URL}
      user-id=${TRUSTEE_USER_ID}
      password=${TRUSTEE_PASSWORD}
      trust-id=${TRUST_ID}
      region=${REGION_NAME}
      ca-file=/etc/kubernetes/certs/ca-bundle.crt

storageClass:
  enabled: true
  delete:
    isDefault: true
    allowVolumeExpansion: true
  retain:
    isDefault: false
    allowVolumeExpansion: true

# You may set ID of the cluster where openstack-cinder-csi is deployed. This value will be appended
# to volume metadata in newly provisioned volumes as cinder.csi.openstack.org/cluster=cluster ID.
clusterID: ${CLUSTER_UUID}

priorityClassName: ""
EOF
}

    echo "Waiting for Kubernetes API..."
    until  [ "ok" = "$(kubectl get --raw='/healthz' 2>nil)" ]
    do
        sleep 5
    done

    kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/release-6.2/client/config/crd/snapshot.storage.k8s.io_volumesnapshotclasses.yaml
    kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/release-6.2/client/config/crd/snapshot.storage.k8s.io_volumesnapshotcontents.yaml
    kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/release-6.2/client/config/crd/snapshot.storage.k8s.io_volumesnapshots.yaml

    helm repo add cpo https://kubernetes.github.io/cloud-provider-openstack
    helm upgrade -i cinder-csi cpo/openstack-cinder-csi --version 2.3.0 -n kube-system -f ${CINDER_CSI_VALUES_YAML}

fi
printf "Finished running ${step}\n"

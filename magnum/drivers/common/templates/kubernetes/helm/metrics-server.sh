#!/bin/bash

set +x
. /etc/sysconfig/heat-params
set -ex

CHART_NAME="metrics-server"

if [ "$(echo ${METRICS_SERVER_ENABLED} | tr '[:upper:]' '[:lower:]')" = "true" ]; then
    echo "Writing ${CHART_NAME} config"

    HELM_CHART_DIR="/srv/magnum/kubernetes/helm/magnum"
    mkdir -p ${HELM_CHART_DIR}

    cat << EOF >> ${HELM_CHART_DIR}/requirements.yaml
- name: ${CHART_NAME}
  version: ${METRICS_SERVER_CHART_TAG}
  repository: https://kubernetes-sigs.github.io/metrics-server/
EOF

    cat << EOF >> ${HELM_CHART_DIR}/values.yaml
metrics-server:
  image:
    repository: ${CONTAINER_INFRA_PREFIX:-registry.k8s.io/metrics-server/}metrics-server
  service:
    labels:
    kubernetes.io/cluster-service: "true"
    kubernetes.io/name: "Metrics-server"
  nodeSelector:
      node-role.kubernetes.io/master: ""
  tolerations:
      - effect: NoSchedule
        operator: Exists
      - key: CriticalAddonsOnly
        operator: Exists
      - effect: NoExecute
        operator: Exists
  apiService:
    caBundle: ""
    create: false
    insecureSkipTLSVerify: true
  args:
    - --cert-dir=/tmp
    - --kubelet-preferred-address-types=InternalIP,ExternalIP,Hostname
    - --kubelet-use-node-status-port
    - --metric-resolution=15s
    - --kubelet-insecure-tls=true
EOF
fi
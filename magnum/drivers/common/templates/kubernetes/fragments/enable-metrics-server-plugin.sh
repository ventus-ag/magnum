#!/bin/sh

step="enable-metrics-server-plugin"
printf "Starting to run ${step}\n"

. /etc/sysconfig/heat-params

ssh_cmd="ssh -F /srv/magnum/.ssh/config root@localhost"

if [ "$(echo ${METRICS_SERVER_ENABLED} | tr '[:upper:]' '[:lower:]')" = "true" ]; then

_metrics_prefix=${CONTAINER_INFRA_PREFIX:-registry.k8s.io/metrics-server/}

METRICS_SERVER_VALUES_YAML=/srv/magnum/kubernetes/helm/metrics-server/values.yaml
echo "Writing File: $METRICS_SERVER_VALUES_YAML"
mkdir -p $(dirname ${METRICS_SERVER_VALUES_YAML})
cat << EOF > ${METRICS_SERVER_VALUES_YAML}
metrics-server:
  image:
    repository: ${_metrics_prefix}metrics-server
  service:
    labels:
    kubernetes.io/cluster-service: "true"
    kubernetes.io/name: "Metrics-server"
  nodeSelector:
      node-role.kubernetes.io/${LEAD_NODE_ROLE_NAME}: ""
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


$ssh_cmd helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server

if $ssh_cmd helm plugin list | grep -q "mapkubeapis"; then
    echo "mapkubeapis is already installed."
else
    echo "mapkubeapis is not installed. Installing now..."
    $ssh_cmd helm plugin install https://github.com/helm/helm-mapkubeapis
fi

if $ssh_cmd helm list --namespace kube-system | grep -q "metrics-server"; then
    $ssh_cmd helm mapkubeapis metrics-server --namespace kube-system
fi

$ssh_cmd helm upgrade -i metrics-server metrics-server/metrics-server --version ${METRICS_SERVER_CHART_TAG} -n kube-system -f ${METRICS_SERVER_VALUES_YAML}

fi
printf "Finished running ${step}\n"

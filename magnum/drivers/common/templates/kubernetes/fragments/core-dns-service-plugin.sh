#!/bin/sh

step="core-dns-service-plugin"
printf "Starting to run ${step}\n"

. /etc/sysconfig/heat-params

_dns_prefix=${CONTAINER_INFRA_PREFIX:-docker.io/coredns/}
_autoscaler_prefix=${CONTAINER_INFRA_PREFIX:-gcr.io/google_containers/}

CORE_DNS_VALUES_YAML=/srv/magnum/kubernetes/helm/coredns/values.yaml
[ -f ${CORE_DNS_VALUES_YAML} ] || {
    echo "Writing File: $CORE_DNS_VALUES_YAML"
    mkdir -p $(dirname ${CORE_DNS_VALUES_YAML})
    cat << EOF > ${CORE_DNS_VALUES_YAML}
image:
  repository: ${_dns_prefix}coredns
  tag: "1.10.1"

replicaCount: 2

resources:
  limits:
    cpu: 100m
    memory: 128Mi
  requests:
    cpu: 100m
    memory: 128Mi

## Create HorizontalPodAutoscaler object.
autoscaling:
  minReplicas: 2
  maxReplicas: 10
  metrics:
  - type: Resource
    resource:
      name: cpu
      targetAverageUtilization: 60
  - type: Resource
    resource:
      name: memory
      targetAverageUtilization: 60

rollingUpdate:
  maxUnavailable: 1
  maxSurge: 25%

# Under heavy load it takes more that standard time to remove Pod endpoint from a cluster.
# This will delay termination of our pod by `preStopSleep`. To make sure kube-proxy has
# enough time to catch up.
# preStopSleep: 5
terminationGracePeriodSeconds: 30

prometheus:
  service:
    enabled: true
    annotations:
      prometheus.io/scrape: "true"
      prometheus.io/port: "9153"
  monitor:
    enabled: false
    additionalLabels: {}
    namespace: ""

serviceAccount:
  create: true
  # The name of the ServiceAccount to use
  # If not set and create is true, a name is generated using the fullname template
  name: "coredns"

service:
  clusterIP: "${DNS_SERVICE_IP}"
  name: "kube-dns"

nodeSelector:
  kubernetes.io/os: linux

# Optional priority class to be used for the coredns pods. Used for autoscaler if autoscaler.priorityClassName not set.
priorityClassName: "system-cluster-critical"

# expects input structure as per specification https://kubernetes.io/docs/reference/generated/kubernetes-api/v1.11/#toleration-v1-core
tolerations:
  # Make sure the pod can be scheduled on master kubelet.
  - effect: NoSchedule
    operator: Exists
  # Mark the pod as a critical add-on for rescheduling.
  - key: CriticalAddonsOnly
    operator: Exists
  - effect: NoExecute
    operator: Exists

# Default zone is what Kubernetes recommends:
# https://kubernetes.io/docs/tasks/administer-cluster/dns-custom-nameservers/#coredns-configmap-options
servers:
- zones:
  - zone: .
  port: 53
  plugins:
  - name: errors
  # Serves a /health endpoint on :8080, required for livenessProbe
  - name: health
    configBlock: |-
      lameduck 5s
  - name: log
    parameters: stdout
  # Serves a /ready endpoint on :8181, required for readinessProbe
  - name: ready
  # Required to query kubernetes API for data
  - name: kubernetes
    parameters: ${DNS_CLUSTER_DOMAIN} ${PORTAL_NETWORK_CIDR} ${PODS_NETWORK_CIDR}
    configBlock: |-
      pods verified
      fallthrough in-addr.arpa ip6.arpa
      ttl 30
  # Serves a /metrics endpoint on :9153, required for serviceMonitor
  - name: prometheus
    parameters: 0.0.0.0:9153
  - name: forward
    parameters: . 1.1.1.1 1.0.0.1
  - name: cache
    parameters: 30
  - name: loop
  - name: reload
  - name: loadbalance

## Alternative configuration for HPA deployment if wanted
#
hpa:
  enabled: false
  minReplicas: 1
  maxReplicas: 2
  metrics: {}

## Configue a cluster-proportional-autoscaler for coredns
# See https://github.com/kubernetes-incubator/cluster-proportional-autoscaler
autoscaler:
  # Enabled the cluster-proportional-autoscaler
  enabled: false

  # Number of cores in the cluster per coredns replica
  coresPerReplica: 256
  # Number of nodes in the cluster per coredns replica
  nodesPerReplica: 16
  # Min size of replicaCount
  min: 0
  # Max size of replicaCount (default of 0 is no max)
  max: 0
  # Whether to include unschedulable nodes in the nodes/cores calculations - this requires version 1.8.0+ of the autoscaler
  includeUnschedulableNodes: false
  # If true does not allow single points of failure to form
  preventSinglePointFailure: true

  image:
    repository: ${_autoscaler_prefix}cluster-proportional-autoscaler-${ARCH}
    tag: "1.10.1"

deployment:
  enabled: true
  name: "coredns"
EOF
}

echo "Waiting for Kubernetes API..."
until  [ "ok" = "$(kubectl get --raw='/healthz' 2>nil)" ]
do
    sleep 5
done

helm repo add coredns https://coredns.github.io/helm
helm upgrade -i coredns coredns/coredns --version 1.19.7 -n kube-system -f ${CORE_DNS_VALUES_YAML}

printf "Finished running ${step}\n"

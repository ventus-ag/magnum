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
  tag: "${coredns_tag}"

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

service:
  clusterIP: "${DNS_SERVICE_IP}"
  name: "kube-dns"

nodeSelector:
  kubernetes.io/os: linux

# Configure SecurityContext for Pod.
# Ensure that required linux capability to bind port number below 1024 is assigned (`CAP_NET_BIND_SERVICE`).
securityContext:
  capabilities:
    add:
      - NET_BIND_SERVICE

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
  # Serves a /ready endpoint on :8181, required for readinessProbe
  - name: ready
  # Required to query kubernetes API for data
  - name: kubernetes
    parameters: ${DNS_CLUSTER_DOMAIN} ${PORTAL_NETWORK_CIDR} ${PODS_NETWORK_CIDR}
    configBlock: |-
      pods insecure
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

  image:
    repository: ${_autoscaler_prefix}cluster-proportional-autoscaler-${ARCH}
    tag: "1.8.5"

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
helm upgrade -i coredns coredns/coredns --version 1.22.0 -n kube-system -f ${CORE_DNS_VALUES_YAML}

printf "Finished running ${step}\n"

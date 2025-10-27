#!/bin/sh

step="enable-auto-scaling-plugin"
printf "Starting to run ${step}\n"

. /etc/sysconfig/heat-params

auto_scaling_plugin_enabled=$(echo $AUTO_SCALING_ENABLED | tr '[:upper:]' '[:lower:]')

if [[ "${auto_scaling_plugin_enabled}" = "true" || ("${auto_healing_enabled}" = "true" && "${autohealing_controller}" = "draino") ]]; then

helm repo add autoscaler https://kubernetes.github.io/autoscaler
helm upgrade -i openstack-autoscaler autoscaler/cluster-autoscaler --version 9.1.0 -n kube-system \
  --set autoDiscovery.clusterName=${CLUSTER_UUID} \
  --set cloudProvider=magnum \
  --set nameOverride=manager \
  --set cloudConfigPath=/etc/kubernetes/cloud-config \
  --set autoscalingGroups[0].name=default-worker \
  --set autoscalingGroups[0].minSize=${MIN_NODE_COUNT} \
  --set autoscalingGroups[0].maxSize=${MAX_NODE_COUNT}

fi
printf "Finished running ${step}\n"

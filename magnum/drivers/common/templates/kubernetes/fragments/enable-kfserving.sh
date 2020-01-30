#!/bin/sh

step="enable-kfserving"
printf "Starting to run ${step}\n"

set +x
. /etc/sysconfig/heat-params
set -x
set -e

if [ "$(echo $KFSERVING_ENABLED | tr '[:upper:]' '[:lower:]')" == "true" ]; then

    echo "Waiting for Kubernetes API..."
    until  [ "ok" = "$(curl --silent http://127.0.0.1:8080/healthz)" ]
    do
        sleep 5
    done
	printf "Wait for cluster ready"
    while [[ $(kubectl get nodes -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}') != "True True"* ]]; do echo "waiting for nodes" && sleep 10; done
	
    printf "apply ${step}\n"

    kubectl apply -f https://raw.githubusercontent.com/kubeflow/kfserving/master/install/${KFSERVING_TAG}/kfserving.yaml
fi

printf "Finished running ${step}\n"
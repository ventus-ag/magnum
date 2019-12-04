#!/bin/sh

step="enable-tekton"
printf "Starting to run ${step}\n"

. /etc/sysconfig/heat-params

if [ "$(echo $TEKTON_ENABLED | tr '[:upper:]' '[:lower:]')" == "true" ]; then

    printf "apply ${step}\n"
    kubectl apply --filename https://storage.googleapis.com/tekton-releases/pipeline/previous/${TEKTON_TAG}/release.yaml

fi

printf "Finished running ${step}\n"
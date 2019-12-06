#!/bin/sh

step="cinder-storage-class"
printf "Starting to run ${step}\n"

. /etc/sysconfig/heat-params

if [ "$(echo $CINDER_ENABLED | tr '[:upper:]' '[:lower:]')" == "true" ]; then

    CINDER_DEPLOY=/srv/magnum/kubernetes/kubernetes-cinder.yaml

    [ -f ${CINDER_DEPLOY} ] || {
        echo "Writing File: $CINDER_DEPLOY"
        mkdir -p $(dirname ${CINDER_DEPLOY})
        cat << EOF > ${CINDER_DEPLOY}
---
kind: StorageClass
apiVersion: storage.k8s.io/v1
metadata:
  name: standard
  annotations: 
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: kubernetes.io/cinder
parameters:
  availability: nova
EOF
    }

    printf "apply ${step}\n"
    kubectl apply --validate=false -f $CINDER_DEPLOY
fi

printf "Finished running ${step}\n"
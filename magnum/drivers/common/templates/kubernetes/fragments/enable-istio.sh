#!/bin/sh

step="istio"
printf "Starting to run ${step}\n"

. /etc/sysconfig/heat-params

if [ "$(echo $ISTIO_ENABLED | tr '[:upper:]' '[:lower:]')" == "true" ]; then

  curl https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 | sed 's#/usr/local/bin#/srv/magnum#g' | bash
  ISTIO_DEPLOY=/srv/magnum/kubernetes/istio.yaml
  mkdir -p $(dirname ${ISTIO_DEPLOY})
  
  export ISTIO_VERSION=${ISTIO_TAG}
  (cd $(dirname ${ISTIO_DEPLOY}) && curl -L https://git.io/getLatestIstio | sh -)
  (cd $(dirname ${ISTIO_DEPLOY})/istio-${ISTIO_TAG} && /srv/magnum/helm template --namespace=istio-system \
    --set sidecarInjectorWebhook.enabled=true \
    --set sidecarInjectorWebhook.enableNamespacesByDefault=true \
    install/kubernetes/helm/istio \
    > $ISTIO_DEPLOY)

	printf "Wait for Openstack controller manager"
  while [[ $(kubectl get pods -l k8s-app=openstack-cloud-controller-manager -n kube-system -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}') != "True" ]]; do echo "waiting for pod" && sleep 10; done
	
    printf "apply ${step}\n"
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
 name: istio-system
 labels:
   istio-injection: disabled
EOF
    (cd $(dirname ${ISTIO_DEPLOY})/istio-${ISTIO_TAG} && for i in install/kubernetes/helm/istio-init/files/crd*yaml; do kubectl apply -f $i; done)
    kubectl apply --validate=false -f $ISTIO_DEPLOY
fi

printf "Finished running ${step}\n"
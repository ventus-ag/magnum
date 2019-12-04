#!/bin/sh

step="istio"
printf "Starting to run ${step}\n"

. /etc/sysconfig/heat-params

if [ "$(echo $ISTIO_ENABLED | tr '[:upper:]' '[:lower:]')" == "true" ]; then

  curl https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 | bash
  ISTIO_DEPLOY=/srv/magnum/kubernetes/istio.yaml
  ISTIO_TAG=1.4.0

  mkdir -p $(dirname ${ISTIO_DEPLOY})

  (cd $(dirname ${ISTIO_DEPLOY}) && curl -L https://git.io/getLatestIstio | sh -)
  (cd $(dirname ${ISTIO_DEPLOY})/istio-${ISTIO_TAG} && for i in install/kubernetes/helm/istio-init/files/crd*yaml; do kubectl apply -f $i; done)
  (cd $(dirname ${ISTIO_DEPLOY})/istio-${ISTIO_TAG} && helm template --namespace=istio-system \
    --set sidecarInjectorWebhook.enabled=true \
    --set sidecarInjectorWebhook.enableNamespacesByDefault=true \
    install/kubernetes/helm/istio \
    > $ISTIO_DEPLOY)

	printf "Wait for Openstack controller manager"
	until  [[ "$(kubectl get pod -n kube-system | grep openstack-cloud-controller-manager)" == *"openstack-cloud-controller-manager"* ]]
	do
		sleep 5
	done
	
    printf "apply ${step}\n"

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
name: istio-system
labels:
  istio-injection: disabled
EOF

    kubectl apply --validate=false -f $ISTIO_DEPLOY
fi

printf "Finished running ${step}\n"
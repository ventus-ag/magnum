#!/bin/sh

step="enable-knative"
printf "Starting to run ${step}\n"

set +x
. /etc/sysconfig/heat-params
set -x
set -e

if [ "$(echo $KNATIVE_ENABLED | tr '[:upper:]' '[:lower:]')" == "true" ]; then

    echo "Waiting for Kubernetes API..."
    until  [ "ok" = "$(curl --silent http://127.0.0.1:8080/healthz)" ]
    do
        sleep 5
    done
	
	printf "Wait for cluster ready"
    while [[ $(kubectl get nodes -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}') != "True True"* ]]; do echo "waiting for nodes" && sleep 10; done
	
	printf "apply ${step}\n"
    curl https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 | sed 's#/usr/local/bin#/srv/magnum#g' | bash
	ISTIO_DEPLOY=/srv/magnum/kubernetes/istio-knative.yaml

	mkdir -p $(dirname ${ISTIO_DEPLOY})

	export ISTIO_VERSION=${ISTIO_TAG}
	(cd $(dirname ${ISTIO_DEPLOY}) && curl -L https://git.io/getLatestIstio | sh -)
	(cd $(dirname ${ISTIO_DEPLOY})/istio-${ISTIO_TAG} && /srv/magnum/helm template --namespace=istio-system \
			--set sidecarInjectorWebhook.enabled=true \
			--set sidecarInjectorWebhook.enableNamespacesByDefault=true \
			--set global.proxy.autoInject=disabled \
			--set global.disablePolicyChecks=true \
			--set prometheus.enabled=false \
			`# Disable mixer prometheus adapter to remove istio default metrics.` \
			--set mixer.adapters.prometheus.enabled=false \
			`# Disable mixer policy check, since in our template we set no policy.` \
			--set global.disablePolicyChecks=true \
			`# Set gateway pods to 1 to sidestep eventual consistency / readiness problems.` \
			--set gateways.istio-ingressgateway.autoscaleMin=1 \
			--set gateways.istio-ingressgateway.autoscaleMax=1 \
			--set gateways.istio-ingressgateway.resources.requests.cpu=500m \
			--set gateways.istio-ingressgateway.resources.requests.memory=256Mi \
			`# Enable SDS in the gateway to allow dynamically configuring TLS of gateway.` \
			--set gateways.istio-ingressgateway.sds.enabled=true \
			`# More pilot replicas for better scale` \
			--set pilot.autoscaleMin=2 \
			`# Set pilot trace sampling to 100%` \
			--set pilot.traceSampling=100 \
			install/kubernetes/helm/istio \
			> $ISTIO_DEPLOY)

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


	printf "Wait for Istio Pilot"
	until  [[ "$(kubectl get pod -n istio-system -l app=pilot | grep pilot)" == *"Running"* ]]
	do
		sleep 5
	done
	
	printf "Wait for Istio Ingress Gateway"
	until  [[ "$(kubectl get pod -n istio-system -l app=istio-ingressgateway | grep ingressgateway)" == *"Running"* ]]
	do
		sleep 5
	done
	
   kubectl apply --selector knative.dev/crd-install=true \
   --filename https://github.com/knative/serving/releases/download/${KNATIVE_TAG}/serving.yaml \
   --filename https://github.com/knative/eventing/releases/download/${KNATIVE_TAG}/eventing.yaml
	   
   kubectl apply \
   --filename https://github.com/knative/serving/releases/download/${KNATIVE_TAG}/serving.yaml \
   --filename https://github.com/knative/eventing/releases/download/${KNATIVE_TAG}/eventing.yaml \
   --selector networking.knative.dev/certificate-provider!=cert-manager

fi

printf "Finished running ${step}\n"
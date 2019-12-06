#!/bin/sh

step="enable-knative"
printf "Starting to run ${step}\n"

. /etc/sysconfig/heat-params

if [ "$(echo $KNATIVE_ENABLED | tr '[:upper:]' '[:lower:]')" == "true" ]; then
	printf "apply ${step}\n"
    curl https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 | sed 's#/usr/local/bin#/srv/magnum#g' | bash
	ISTIO_DEPLOY=/srv/magnum/kubernetes/istio-knative.yaml

	mkdir -p $(dirname ${ISTIO_DEPLOY})
    ISTIO_VERSION=${ISTIO_TAG}
	(cd $(dirname ${ISTIO_DEPLOY}) && curl -L https://git.io/getLatestIstio | sh -)
	(cd $(dirname ${ISTIO_DEPLOY})/istio-${ISTIO_TAG} && /srv/magnum/helm template --namespace=istio-system \
			--set prometheus.enabled=false \
			--set mixer.enabled=false \
			--set mixer.policy.enabled=false \
			--set mixer.telemetry.enabled=false \
			`# Pilot doesn't need a sidecar.` \
			--set pilot.sidecar=false \
			--set pilot.resources.requests.memory=128Mi \
			`# Disable galley (and things requiring galley).` \
			--set galley.enabled=false \
			--set global.useMCP=false \
			`# Disable security / policy.` \
			--set security.enabled=false \
			--set global.disablePolicyChecks=true \
			`# Disable sidecar injection.` \
			--set sidecarInjectorWebhook.enabled=false \
			--set global.proxy.autoInject=disabled \
			--set global.omitSidecarInjectorConfigMap=true \
			--set gateways.istio-ingressgateway.autoscaleMin=1 \
			--set gateways.istio-ingressgateway.autoscaleMax=2 \
			`# Set pilot trace sampling to 100%` \
			--set pilot.traceSampling=100 \
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
   --filename https://github.com/knative/serving/releases/download/${KNATIVE_TAG}/serving.yaml
	   
   kubectl apply --filename https://github.com/knative/serving/releases/download/${KNATIVE_TAG}/serving.yaml --selector networking.knative.dev/certificate-provider!=cert-manager

fi

printf "Finished running ${step}\n"
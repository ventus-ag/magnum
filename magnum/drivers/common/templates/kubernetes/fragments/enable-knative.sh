#!/bin/sh

step="enable-knative"
printf "Starting to run ${step}\n"

. /etc/sysconfig/heat-params

if [ "$(echo $KNATIVE_ENABLED | tr '[:upper:]' '[:lower:]')" == "true" ]; then
	printf "apply ${step}\n"
	
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
   --filename https://github.com/knative/serving/releases/download/v0.7.1/serving.yaml
	   
   kubectl apply --filename https://github.com/knative/serving/releases/download/v0.7.1/serving.yaml --selector networking.knative.dev/certificate-provider!=cert-manager

fi

printf "Finished running ${step}\n"
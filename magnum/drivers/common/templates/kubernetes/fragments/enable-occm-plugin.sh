
step="enable-occm-plugin"
printf "Starting to run ${step}\n"

. /etc/sysconfig/heat-params

occm_enabled=$(echo $CLOUD_PROVIDER_ENABLED | tr '[:upper:]' '[:lower:]')
ssh_cmd="ssh -F /srv/magnum/.ssh/config root@localhost"

if [[ "${occm_enabled}" = "true" ]]; then

_k8s_prefix=${CONTAINER_INFRA_PREFIX:-registry.k8s.io/provider-os/openstack-cloud-controller-manager}

OCCM_VALUES_YAML=/srv/magnum/kubernetes/helm/openstack-cloud-controller-manager/values.yaml
echo "Writing File: $OCCM_VALUES_YAML"
mkdir -p $(dirname ${OCCM_VALUES_YAML})
cat << EOF > ${OCCM_VALUES_YAML}
# Image repository name and tag
image:
  repository: ${_k8s_prefix}
  tag: ""

# Create a secret resource cloud-config (or other name) to store credentials and settings from cloudConfig
# You can also provide your own secret (not created by the Helm chart), in this case set create to false
# and adjust the name of the secret as necessary
secret:
  create: true
  name: cloud-config-occm

# Specify settings with the same key as the CCM config: https://github.com/kubernetes/cloud-provider-openstack/blob/master/docs/openstack-cloud-controller-manager/using-openstack-cloud-controller-manager.md#config-openstack-cloud-controller-manager
cloudConfig:
  global:
    auth-url: ${AUTH_URL}
    user-id: ${TRUSTEE_USER_ID}
    password: ${TRUSTEE_PASSWORD}
    trust-id: ${TRUST_ID}
    region: ${REGION_NAME}
    ca-file: /etc/kubernetes/certs/ca-bundle.crt
EOF


$ssh_cmd helm repo add cpo https://kubernetes.github.io/cloud-provider-openstack
$ssh_cmd helm upgrade -i openstack-ccm cpo/openstack-cloud-controller-manager --version 2.27.1 -n kube-system -f ${OCCM_VALUES_YAML}

fi
printf "Finished running ${step}\n"
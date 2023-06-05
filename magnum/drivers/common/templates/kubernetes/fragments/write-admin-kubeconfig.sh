#!/bin/sh

set +x
. /etc/sysconfig/heat-params
set -x

# root kubeconfig
ADMIN_KUBECONFIG=/etc/kubernetes/admin.conf
cat > ${ADMIN_KUBECONFIG} << EOF
apiVersion: v1
clusters:
- cluster:
    certificate-authority-data: $(cat ${CERT_DIR}/ca.crt | base64 | tr -d '\n')
    server: https://127.0.0.1:${KUBE_API_PORT}
  name: ${CLUSTER_UUID}
contexts:
- context:
    cluster: ${CLUSTER_UUID}
    user: admin
  name: default
current-context: default
kind: Config
preferences: {}
users:
- name: admin
  user:
    as-user-extra: {}
    client-certificate-data: $(cat ${CERT_DIR}/admin.crt | base64 | tr -d '\n')
    client-key-data: $(cat ${CERT_DIR}/admin.key | base64 | tr -d '\n')
EOF
echo "export KUBECONFIG=${ADMIN_KUBECONFIG}" >> /etc/bashrc
chown root:root ${ADMIN_KUBECONFIG}
export KUBECONFIG=${ADMIN_KUBECONFIG}

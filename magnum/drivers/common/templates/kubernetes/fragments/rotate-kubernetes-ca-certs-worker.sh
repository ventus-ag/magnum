echo "START: rotate CA certs on worker"

HEAT_PARAMS=/etc/sysconfig/heat-params

if [ ! -f "${HEAT_PARAMS}" ]; then
    echo "heat-params file is missing, skipping CA rotation"
    exit 0
fi

set +x
. "${HEAT_PARAMS}"
set -x

set -eu -o pipefail

ssh_cmd="ssh -F /srv/magnum/.ssh/config root@localhost"

rotation_id="${ca_rotation_id_input:-}"
service_account_key="${kube_service_account_key_input:-}"
service_account_private_key="${kube_service_account_private_key_input:-}"
cert_dir=/etc/kubernetes/certs
ca_cert="${cert_dir}/ca.crt"
rotation_state_file=/var/lib/magnum/last_ca_rotation_id

current_rotation_id=""
if [ -f "${rotation_state_file}" ]; then
    current_rotation_id=$(cat "${rotation_state_file}")
fi

update_heat_param() {
    param_key="$1"
    param_value="$2"

    sed -i "/^${param_key}=/d" "${HEAT_PARAMS}"
    printf '%s="%s"\n' "${param_key}" "${param_value}" >> "${HEAT_PARAMS}"
}

generate_certificates() {
    cert_name="$1"
    cert_config="$2"
    cert_path="${cert_dir}/${cert_name}.crt"
    csr_path="${cert_dir}/${cert_name}.csr"
    key_path="${cert_dir}/${cert_name}.key"

    rm -f "${cert_path}" "${csr_path}" "${key_path}"

    $ssh_cmd openssl genrsa -out "${key_path}" 4096
    chmod 400 "${key_path}"
    $ssh_cmd openssl req -new -days 1000 \
        -key "${key_path}" \
        -out "${csr_path}" \
        -reqexts req_ext \
        -config "${cert_config}"

    csr_req=$(python -c "import json; fp = open('${csr_path}'); print(json.dumps({'cluster_uuid': '$CLUSTER_UUID', 'csr': fp.read()})); fp.close()")
    curl ${verify_ca_opt} -s -X POST \
        -H "X-Auth-Token: ${user_token}" \
        -H "OpenStack-API-Version: container-infra latest" \
        -H "Content-Type: application/json" \
        -d "${csr_req}" \
        "${MAGNUM_URL}/certificates" | python -c 'import sys, json; print(json.load(sys.stdin)["pem"])' > "${cert_path}"

    rm -f "${csr_path}"
}

if [ -z "${rotation_id}" ]; then
    echo "No CA rotation requested, skipping"
    exit 0
fi

if [ "${rotation_id}" = "${current_rotation_id}" ]; then
    echo "CA rotation ${rotation_id} already applied, skipping"
    exit 0
fi

if [ -z "${service_account_key}" ] || [ -z "${service_account_private_key}" ]; then
    echo "Missing service account key material for CA rotation"
    exit 1
fi

if [ "${TLS_DISABLED}" = "True" ]; then
    echo "TLS is disabled, skipping CA rotation"
    exit 0
fi

if [ "${VERIFY_CA}" = "True" ]; then
    verify_ca_opt=""
else
    verify_ca_opt="-k"
fi

if [ -z "${KUBE_NODE_IP:-}" ]; then
    KUBE_NODE_IP=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)
fi

HOSTNAME=$(cat /etc/hostname | head -1)
mkdir -p "${cert_dir}"
mkdir -p "$(dirname "${rotation_state_file}")"

auth_json=$(cat <<EOF
{
    "auth": {
        "identity": {
            "methods": [
                "password"
            ],
            "password": {
                "user": {
                    "id": "${TRUSTEE_USER_ID}",
                    "password": "${TRUSTEE_PASSWORD}"
                }
            }
        },
        "scope": {
            "OS-TRUST:trust": {
                "id": "${TRUST_ID}"
            }
        }
    }
}
EOF
)

user_token=$(curl ${verify_ca_opt} -s -i -X POST \
    -H "Content-Type: application/json" \
    -d "${auth_json}" \
    "${AUTH_URL}/auth/tokens" | grep -i X-Subject-Token | awk '{print $2}' | tr -d '[[:space:]]')

if [ -z "${user_token}" ]; then
    echo "Failed to obtain a Keystone token for CA rotation"
    exit 1
fi

curl ${verify_ca_opt} -s -X GET \
    -H "X-Auth-Token: ${user_token}" \
    -H "OpenStack-API-Version: container-infra latest" \
    "${MAGNUM_URL}/certificates/${CLUSTER_UUID}" | python -c 'import sys, json; print(json.load(sys.stdin)["pem"])' > "${ca_cert}"

cat > "${cert_dir}/kubelet.conf" <<EOF
[req]
distinguished_name = req_distinguished_name
req_extensions     = req_ext
prompt = no
[req_distinguished_name]
CN = system:node:${INSTANCE_NAME}
O=system:nodes
OU=OpenStack/Magnum
C=US
ST=TX
L=Austin
[req_ext]
subjectAltName = IP:${KUBE_NODE_IP},DNS:${INSTANCE_NAME},DNS:${HOSTNAME}
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=clientAuth,serverAuth
EOF

cat > "${cert_dir}/proxy.conf" <<EOF
[req]
distinguished_name = req_distinguished_name
req_extensions     = req_ext
prompt = no
[req_distinguished_name]
CN = system:kube-proxy
O=system:node-proxier
OU=OpenStack/Magnum
C=US
ST=TX
L=Austin
[req_ext]
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=clientAuth
EOF

generate_certificates kubelet "${cert_dir}/kubelet.conf"
generate_certificates proxy "${cert_dir}/proxy.conf"

chmod 550 "${cert_dir}"
chmod 440 "${cert_dir}/kubelet.key"
chmod 440 "${cert_dir}/proxy.key"

for service in kubelet kube-proxy; do
    echo "restart service ${service}"
    $ssh_cmd systemctl restart "${service}"
done

update_heat_param KUBE_SERVICE_ACCOUNT_KEY "${service_account_key}"
update_heat_param KUBE_SERVICE_ACCOUNT_PRIVATE_KEY "${service_account_private_key}"
update_heat_param CA_ROTATION_ID "${rotation_id}"
printf '%s' "${rotation_id}" > "${rotation_state_file}"
chmod 600 "${rotation_state_file}"

echo "END: rotate CA certs on worker"

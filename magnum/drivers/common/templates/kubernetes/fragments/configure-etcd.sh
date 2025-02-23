#!/bin/sh

. /etc/sysconfig/heat-params

set -x

ssh_cmd="ssh -F /srv/magnum/.ssh/config root@localhost"

if [ ! -z "$HTTP_PROXY" ]; then
    export HTTP_PROXY
fi

if [ ! -z "$HTTPS_PROXY" ]; then
    export HTTPS_PROXY
fi

if [ ! -z "$NO_PROXY" ]; then
    export NO_PROXY
fi

# Set protocol and cert directory
cert_dir="/etc/etcd/certs"
protocol="https"

if [ "$TLS_DISABLED" = "True" ]; then
    protocol="http"
fi

# Get local IP
if [ -z "$KUBE_NODE_IP" ]; then
    # FIXME(yuanying): Set KUBE_NODE_IP correctly
    KUBE_NODE_IP=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)
fi

myip="${KUBE_NODE_IP}"

# Add volume preparation section
if [ -n "$ETCD_VOLUME_SIZE" ] && [ "$ETCD_VOLUME_SIZE" -gt 0 ]; then
    # Skip if already mounted
    if ! $ssh_cmd mountpoint -q /var/lib/etcd; then
        attempts=60
        while [ ${attempts} -gt 0 ]; do
            device_name=$($ssh_cmd ls /dev/disk/by-id | grep ${ETCD_VOLUME:0:20}$)
            if [ -n "${device_name}" ]; then
                break
            fi
            echo "waiting for disk device"
            sleep 0.5
            $ssh_cmd udevadm trigger
            let attempts--
        done

        if [ -z "${device_name}" ]; then
            echo "ERROR: disk device does not exist" >&2
            exit 1
        fi

        device_path=/dev/disk/by-id/${device_name}
        fstype=$($ssh_cmd blkid -s TYPE -o value ${device_path} || echo "")
        if [ "${fstype}" != "xfs" ]; then
            $ssh_cmd mkfs.xfs -f ${device_path}
        fi
        $ssh_cmd mkdir -p /var/lib/etcd
        if ! grep -q "${device_path} /var/lib/etcd" /etc/fstab; then
            echo "${device_path} /var/lib/etcd xfs defaults 0 0" >> /etc/fstab
        fi
        $ssh_cmd mount -a
        $ssh_cmd chown -R etcd.etcd /var/lib/etcd
        $ssh_cmd chmod 755 /var/lib/etcd
    fi
fi

# Add service creation section
if [ "$(echo $USE_PODMAN | tr '[:upper:]' '[:lower:]')" == "true" ]; then
    # Only create service file if it doesn't exist or has changed
    service_file="/etc/systemd/system/etcd.service"
    
    # Ensure container image reference is properly formatted
    container_image="${CONTAINER_INFRA_PREFIX:-"quay.io/coreos/"}etcd"
    if [[ "$container_image" != *"/"* ]]; then
        container_image="docker.io/library/$container_image"
    fi
    
    service_content=$(cat << EOF
[Unit]
Description=Etcd server
After=network-online.target
Wants=network-online.target

[Service]
EnvironmentFile=/etc/sysconfig/heat-params
ExecStartPre=mkdir -p /var/lib/etcd
ExecStartPre=-/bin/podman rm etcd
ExecStart=/bin/podman run \
    --name etcd \
    --volume /etc/pki/ca-trust/extracted/pem:/etc/ssl/certs:ro,z \
    --volume /etc/etcd:/etc/etcd:ro,z \
    --volume /var/lib/etcd:/var/lib/etcd:rshared,z \
    --net=host \
    ${container_image}:${ETCD_TAG} \
    /usr/local/bin/etcd \
    --config-file /etc/etcd/etcd.conf.yaml
ExecStop=/bin/podman stop etcd
TimeoutStartSec=10min
IOSchedulingClass=best-effort
IOSchedulingPriority=0
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
)

    if [ ! -f "$service_file" ] || [ "$(cat $service_file)" != "$service_content" ]; then
        echo "$service_content" > "$service_file"
        $ssh_cmd systemctl daemon-reload
    fi
else
    _prefix=${CONTAINER_INFRA_PREFIX:-"docker.io/openstackmagnum/"}
    if ! $ssh_cmd atomic images list | grep -q "^${_prefix}etcd:${ETCD_TAG}"; then
        $ssh_cmd atomic install \
        --system-package no \
        --system \
        --storage ostree \
        --name=etcd ${_prefix}etcd:${ETCD_TAG}
    fi
fi

# Install etcdctl if not present or if version differs
etcdctl_dir="/usr/local/bin"
etcd_download_path="/srv/magnum/etcd"
$ssh_cmd mkdir -p ${etcd_download_path}

# Strip any 'v' prefix from ETCD_TAG if present
ETCD_VERSION=${ETCD_TAG#v}

# Download and install etcdctl if not present or if version differs
etcd_tgz="${etcd_download_path}/etcd-v${ETCD_VERSION}-linux-amd64.tar.gz"
if [ ! -f "${etcd_tgz}" ] || ! $ssh_cmd etcdctl version 2>/dev/null | grep -q "etcdctl version: ${ETCD_VERSION}"; then
    $ssh_cmd curl --retry 5 --retry-delay 10 -L \
        https://github.com/etcd-io/etcd/releases/download/v${ETCD_VERSION}/etcd-v${ETCD_VERSION}-linux-amd64.tar.gz \
        -o "${etcd_tgz}.tmp"
    $ssh_cmd mv "${etcd_tgz}.tmp" "${etcd_tgz}"
    
    # Extract only etcdctl
    $ssh_cmd mkdir -p ${etcd_download_path}/tmp
    $ssh_cmd tar -C ${etcd_download_path}/tmp -xzf ${etcd_tgz}
    $ssh_cmd cp ${etcd_download_path}/tmp/etcd-v${ETCD_VERSION}-linux-amd64/etcdctl ${etcdctl_dir}/
    $ssh_cmd chmod +x ${etcdctl_dir}/etcdctl
    $ssh_cmd rm -rf ${etcd_download_path}/tmp
fi

# Function to run etcdctl with retries
run_etcdctl() {
    local endpoints="$1"
    shift
    local max_attempts=3
    local attempt=1
    local delay=3
    local timeout=5

    # Base options for etcdctl
    local etcdctl_opts=(
        "--endpoints=$endpoints"
        "--command-timeout=${timeout}s"
    )

    # Add TLS options if TLS is enabled
    if [ "$TLS_DISABLED" != "True" ]; then
        etcdctl_opts+=(
            --cacert="$cert_dir/ca.crt"
            --cert="$cert_dir/server.crt"
            --key="$cert_dir/server.key"
        )
    fi

    while [ ${attempt} -le ${max_attempts} ]; do
        echo "Attempt $attempt/$max_attempts: etcdctl $*" >&2
        if output=$($ssh_cmd ETCDCTL_API=3 ${etcdctl_dir}/etcdctl "${etcdctl_opts[@]}" "$@" 2>&1); then
            echo "$output"
            return 0
        fi
        echo "$output" >&2
        sleep $delay
        let attempt++
    done
    return 1
}

# Function to check if a node is part of the cluster
is_member() {
    local endpoints="$1"
    local node_name="$2"
    local node_ip="$3"

    member_list=$(run_etcdctl "$endpoints" member list) || return 1
    echo "$member_list" | grep -q -E "$node_name|$node_ip" || return 1
    return 0
}

# Function to get endpoints from the load balancer VIP
get_known_endpoints() {
    local endpoints=()
    local lb_endpoint="$protocol://$ETCD_LB_VIP:2379"

    # Try to get member list from load balancer
    local member_list=$(run_etcdctl "$lb_endpoint" member list)

    # Extract endpoints from member list if not empty
    if [ -n "$member_list" ]; then
        while IFS=',' read -r id state name peerurl rest; do
            # Skip empty lines
            [ -z "$id" ] && continue

            # Convert peer URL to client URL (2380 to 2379)
            client_url=$(echo "$peerurl" | tr -d ' ' | cut -d'=' -f2 | sed 's/:2380/:2379/')
            if [ -n "$client_url" ]; then
                endpoints+=("$client_url")
            fi
        done <<< "$member_list"
    fi

    echo "${endpoints[@]}"
}

# Function to check if the cluster is alive by verifying load balancer endpoints.
# It uses the endpoints from get_known_endpoints (which are derived from ETCD_LB_VIP)
# and returns the first healthy endpoint.
check_cluster() {
    local known_endpoints=($(get_known_endpoints))
    echo "Found endpoints from load balancer: ${known_endpoints[@]}" >&2

    if [ ${#known_endpoints[@]} -eq 0 ]; then
         echo "No load balancer endpoints found; cluster is not alive" >&2
         echo ""
         return 0
    fi

    for endpoint in "${known_endpoints[@]}"; do
         # Skip our own endpoint
         if [ "$endpoint" != "$protocol://$myip:2379" ]; then
              echo "Checking health of $endpoint" >&2
              local health_check=$(run_etcdctl "$endpoint" endpoint health)
              if [ -n "$health_check" ]; then
                  echo "Endpoint $endpoint is healthy" >&2
                  echo "$endpoint"
                  return 0
              else
                  echo "Endpoint $endpoint is not healthy" >&2
              fi
         fi
    done

    echo "No live endpoints found via load balancer" >&2
    echo ""
    return 0
}

# Function to get properly formatted member list (unused in current flow)
get_member_list() {
    local endpoints="$1"
    local my_name="$2"
    local my_ip="$3"
    local member_list=$(run_etcdctl "$endpoints" member list)
    local formatted_list=""

    echo "Current member list:" >&2
    echo "$member_list" >&2

    while IFS=',' read -r id state name peerurl rest; do
        # Skip empty lines
        [ -z "$id" ] && continue

        # Clean up the values
        name=$(echo "$name" | tr -d ' ')
        peerurl=$(echo "$peerurl" | tr -d ' ' | cut -d'=' -f2)

        # Skip entries with empty names or URLs
        [ -z "$name" ] || [ -z "$peerurl" ] && continue

        # For our IP, use our name
        if echo "$peerurl" | grep -q "$my_ip"; then
            name="$my_name"
        fi

        if [ -z "$formatted_list" ]; then
            formatted_list="$name=$peerurl"
        else
            formatted_list="$formatted_list,$name=$peerurl"
        fi
    done <<< "$member_list"

    echo "Formatted member list: $formatted_list" >&2
    echo "$formatted_list"
}

# Function to get cluster members from discovery URL (unused in current flow)
get_discovery_members() {
    local discovery_response=$(curl -s "$ETCD_DISCOVERY_URL")
    echo "Discovery URL response: $discovery_response" >&2

    # Extract existing nodes from discovery
    local nodes=$(echo "$discovery_response" | grep -o '"nodes":\[[^]]*\]' | grep -o 'value":"[^"]*' | cut -d'"' -f3)
    echo "Extracted nodes: $nodes" >&2

    local formatted_list=""
    for node in $nodes; do
        local name=$(echo "$node" | cut -d'=' -f1)
        local url=$(echo "$node" | cut -d'=' -f2)
        if [ -n "$name" ] && [ -n "$url" ]; then
            if [ -z "$formatted_list" ]; then
                formatted_list="$name=$url"
            else
                formatted_list="$formatted_list,$name=$url"
            fi
        fi
    done
    echo "$formatted_list"
}

# Function to clean up etcd data and stop service
cleanup_etcd() {
    echo "Cleaning up etcd data..." >&2

    # Stop etcd service
    $ssh_cmd systemctl stop etcd

    # Remove existing container if any
    $ssh_cmd podman rm -f etcd || true

    # Wait for cleanup to complete
    sleep 5

    echo "Etcd cleanup completed" >&2
}

# Function to check if discovery URL is valid and has cluster data
check_discovery_url() {
    local url="$1"
    if [ -n "$url" ]; then
        local data=$(curl -sf "$url") || true
        if [ -n "$data" ] && ! echo "$data" | grep -q "unable to GET token"; then
            # Check if the response contains actual node data
            if echo "$data" | grep -q '"nodes":\['; then
                echo "Discovery URL contains existing cluster data" >&2
                return 0
            elif echo "$data" | jq -e '.node.nodes' >/dev/null 2>&1; then
                echo "Discovery URL contains existing cluster data" >&2
                return 0
            elif echo "$data" | grep -q '"dir":true'; then
                echo "Discovery URL is valid but empty, can be used for new cluster" >&2
                return 0
            fi
        fi
    fi
    echo "Discovery URL is not valid or contains no cluster data" >&2
    return 1
}

# Function to write etcd config and start service
write_and_start_etcd() {
    local config_content="$1"
    local write_success=0
    
    # Ensure config directory exists
    $ssh_cmd mkdir -p /etc/etcd
    
    # Write config
    echo "$config_content" > /etc/etcd/etcd.conf.yaml
    
    # Verify config was written
    if [ ! -f /etc/etcd/etcd.conf.yaml ]; then
        echo "Failed to write etcd config file" >&2
        write_success=1
    else
        echo "Starting etcd service..." >&2
        $ssh_cmd systemctl daemon-reload
        $ssh_cmd systemctl restart etcd
        write_success=0
    fi
    
    # Set global variable to indicate result
    ETCD_WRITE_RESULT=$write_success
}

# -----------------------------------------------------
# Revised Cluster Join/Creation Control Flow
# -----------------------------------------------------

# Define our key endpoints
local_endpoint="$protocol://$myip:2379"
lb_endpoint="$protocol://$ETCD_LB_VIP:2379"

# Initialize flags
discovery_ok=0
lb_ok=0
local_ok=0

# Check if discovery URL is valid
if check_discovery_url "$ETCD_DISCOVERY_URL"; then
    discovery_ok=1
fi

# Check LB VIP response
if run_etcdctl "$lb_endpoint" endpoint health >/dev/null 2>&1; then
    lb_ok=1
fi

# Check local endpoint health
if run_etcdctl "$local_endpoint" endpoint health >/dev/null 2>&1; then
    local_ok=1
fi

echo "Discovery OK: $discovery_ok, LB OK: $lb_ok, Local OK: $local_ok" >&2

# Cluster join/creation logic based on conditions

# Condition 1:
# If discovery URL is valid but LB is not responding, create a new cluster using discovery URL.
if [ $discovery_ok -eq 1 ] && [ $lb_ok -eq 0 ]; then
    echo "Discovery URL valid and LB not responding. Creating new cluster using discovery URL." >&2
    cleanup_etcd
    config="name: \"$INSTANCE_NAME\"
data-dir: \"/var/lib/etcd/default.etcd\"
listen-metrics-urls: \"http://$myip:2378\"
listen-client-urls: \"$protocol://$myip:2379,http://127.0.0.1:2379\"
listen-peer-urls: \"$protocol://$myip:2380\"
advertise-client-urls: \"$protocol://$myip:2379\"
initial-advertise-peer-urls: \"$protocol://$myip:2380\"
discovery: \"$ETCD_DISCOVERY_URL\"
heartbeat-interval: 1000
election-timeout: 15000
auto-compaction-mode: periodic
auto-compaction-retention: \"24h\""
    write_and_start_etcd "$config"
    etcd_configured=1

# Condition 2:
# Discovery is OK and LB responds. Then check the local endpoint.
elif [ $discovery_ok -eq 1 ] && [ $lb_ok -eq 1 ]; then
    if [ $local_ok -eq 0 ]; then
        echo "Discovery and LB OK but local endpoint unhealthy. Removing self and rejoining." >&2
        member_id=$(run_etcdctl "$lb_endpoint" member list | grep -E "$INSTANCE_NAME|$myip" | cut -d',' -f1)
        if [ -n "$member_id" ]; then
            run_etcdctl "$lb_endpoint" member remove "$member_id" || true
        fi
        if add_output=$(run_etcdctl "$lb_endpoint" member add "$INSTANCE_NAME" --peer-urls="$protocol://$myip:2380"); then
            initial_cluster=$(echo "$add_output" | grep '^ETCD_INITIAL_CLUSTER=' | cut -d'=' -f2- | tr -d '"')
            config="name: \"$INSTANCE_NAME\"
data-dir: \"/var/lib/etcd/default.etcd\"
listen-metrics-urls: \"http://$myip:2378\"
listen-client-urls: \"$protocol://$myip:2379,http://127.0.0.1:2379\"
listen-peer-urls: \"$protocol://$myip:2380\"
advertise-client-urls: \"$protocol://$myip:2379\"
initial-advertise-peer-urls: \"$protocol://$myip:2380\"
initial-cluster: \"$initial_cluster\"
initial-cluster-state: \"existing\"
heartbeat-interval: 1000
election-timeout: 15000
auto-compaction-mode: periodic
auto-compaction-retention: \"24h\""
            write_and_start_etcd "$config"
            etcd_configured=1
        else
            echo "Failed to rejoin via LB after removal" >&2
            exit 1
        fi
    else
        echo "Discovery, LB, and local endpoint are healthy. Skipping join/creation logic." >&2
        etcd_configured=1
    fi

# Condition 3:
# Discovery URL is invalid but LB responds.
elif [ $discovery_ok -eq 0 ] && [ $lb_ok -eq 1 ]; then
    if [ $local_ok -eq 1 ]; then
        echo "Discovery URL invalid but LB and local endpoint are healthy. Skipping join/creation." >&2
        etcd_configured=1
    else
        echo "Discovery URL invalid, LB OK but local endpoint unhealthy. Removing self and rejoining." >&2
        member_id=$(run_etcdctl "$lb_endpoint" member list | grep -E "$INSTANCE_NAME|$myip" | cut -d',' -f1)
        if [ -n "$member_id" ]; then
            run_etcdctl "$lb_endpoint" member remove "$member_id" || true
        fi
        if add_output=$(run_etcdctl "$lb_endpoint" member add "$INSTANCE_NAME" --peer-urls="$protocol://$myip:2380"); then
            initial_cluster=$(echo "$add_output" | grep '^ETCD_INITIAL_CLUSTER=' | cut -d'=' -f2- | tr -d '"')
            config="name: \"$INSTANCE_NAME\"
data-dir: \"/var/lib/etcd/default.etcd\"
listen-metrics-urls: \"http://$myip:2378\"
listen-client-urls: \"$protocol://$myip:2379,http://127.0.0.1:2379\"
listen-peer-urls: \"$protocol://$myip:2380\"
advertise-client-urls: \"$protocol://$myip:2379\"
initial-advertise-peer-urls: \"$protocol://$myip:2380\"
initial-cluster: \"$initial_cluster\"
initial-cluster-state: \"existing\"
heartbeat-interval: 1000
election-timeout: 15000
auto-compaction-mode: periodic
auto-compaction-retention: \"24h\""
            write_and_start_etcd "$config"
            etcd_configured=1
        else
            echo "Failed to rejoin via LB in condition 3" >&2
            exit 1
        fi
    fi

else
    echo "Error: Neither a valid discovery URL nor a healthy LB endpoint is available." >&2
    exit 1
fi

# Continue with rest of the script...
# Add TLS configuration to the YAML file if TLS is enabled
if [ "$TLS_DISABLED" = "False" ]; then
    cat >> /etc/etcd/etcd.conf.yaml <<EOF
client-transport-security:
  cert-file: "$cert_dir/server.crt"
  key-file: "$cert_dir/server.key"
  client-cert-auth: true
  trusted-ca-file: "$cert_dir/ca.crt"
peer-transport-security:
  cert-file: "$cert_dir/server.crt"
  key-file: "$cert_dir/server.key"
  client-cert-auth: true
  trusted-ca-file: "$cert_dir/ca.crt"
EOF
fi

# Append HTTP proxy configuration for discovery service if set
if [ -n "$HTTP_PROXY" ]; then
    cat >> /etc/etcd/etcd.conf.yaml <<EOF
# HTTP proxy to use for traffic to discovery service.
discovery-proxy: $HTTP_PROXY
EOF
fi

$ssh_cmd systemctl daemon-reload
$ssh_cmd systemctl restart etcd

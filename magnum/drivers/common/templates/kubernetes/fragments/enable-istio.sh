#!/bin/sh

step="istio"
printf "Starting to run ${step}\n"

. /etc/sysconfig/heat-params

if [ "$(echo $ISTIO_ENABLED | tr '[:upper:]' '[:lower:]')" == "true" ]; then

    ISTIO_DEPLOY=/srv/magnum/kubernetes/kubernetes-istio.yaml

    [ -f ${ISTIO_DEPLOY} ] || {
        echo "Writing File: $ISTIO_DEPLOY"
        mkdir -p $(dirname ${ISTIO_DEPLOY})
ISTIO_DEPLOY_YAML='---
apiVersion: v1
kind: Namespace
metadata:
  name: istio-system
---
# Source: istio/charts/galley/templates/poddisruptionbudget.yaml

apiVersion: policy/v1beta1
kind: PodDisruptionBudget
metadata:
  name: istio-galley
  namespace: istio-system
  labels:
    app: galley
    chart: galley
    heritage: Tiller
    release: release-name
    istio: galley
spec:

  minAvailable: 1
  selector:
    matchLabels:
      app: galley
      release: release-name
      istio: galley

---
# Source: istio/charts/gateways/templates/poddisruptionbudget.yaml

apiVersion: policy/v1beta1
kind: PodDisruptionBudget
metadata:
  name: istio-ingressgateway
  namespace: istio-system
  labels:
    chart: gateways
    heritage: Tiller
    release: release-name
    app: istio-ingressgateway
    istio: ingressgateway
spec:

  minAvailable: 1
  selector:
    matchLabels:
      release: release-name
      app: istio-ingressgateway
      istio: ingressgateway
---

---
# Source: istio/charts/mixer/templates/poddisruptionbudget.yaml

apiVersion: policy/v1beta1
kind: PodDisruptionBudget
metadata:
  name: istio-policy
  namespace: istio-system
  labels:
    app: policy
    chart: mixer
    heritage: Tiller
    release: release-name
    version: 1.1.0
    istio: mixer
    istio-mixer-type: policy
spec:

  minAvailable: 1
  selector:
    matchLabels:
      app: policy
      release: release-name
      istio: mixer
      istio-mixer-type: policy
---
apiVersion: policy/v1beta1
kind: PodDisruptionBudget
metadata:
  name: istio-telemetry
  namespace: istio-system
  labels:
    app: telemetry
    chart: mixer
    heritage: Tiller
    release: release-name
    version: 1.1.0
    istio: mixer
    istio-mixer-type: telemetry
spec:

  minAvailable: 1
  selector:
    matchLabels:
      app: telemetry
      release: release-name
      istio: mixer
      istio-mixer-type: telemetry
---

---
# Source: istio/charts/pilot/templates/poddisruptionbudget.yaml

apiVersion: policy/v1beta1
kind: PodDisruptionBudget
metadata:
  name: istio-pilot
  namespace: istio-system
  labels:
    app: pilot
    chart: pilot
    heritage: Tiller
    release: release-name
    istio: pilot
spec:

  minAvailable: 1
  selector:
    matchLabels:
      app: pilot
      release: release-name
      istio: pilot

---
# Source: istio/charts/galley/templates/configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: istio-galley-configuration
  namespace: istio-system
  labels:
    app: galley
    chart: galley
    heritage: Tiller
    release: release-name
    istio: galley
data:
  validatingwebhookconfiguration.yaml: |-
    apiVersion: admissionregistration.k8s.io/v1beta1
    kind: ValidatingWebhookConfiguration
    metadata:
      name: istio-galley
      namespace: istio-system
      labels:
        app: galley
        chart: galley
        heritage: Tiller
        release: release-name
        istio: galley
    webhooks:
      - name: pilot.validation.istio.io
        clientConfig:
          service:
            name: istio-galley
            namespace: istio-system
            path: "/admitpilot"
          caBundle: ""
        rules:
          - operations:
            - CREATE
            - UPDATE
            apiGroups:
            - config.istio.io
            apiVersions:
            - v1alpha2
            resources:
            - httpapispecs
            - httpapispecbindings
            - quotaspecs
            - quotaspecbindings
          - operations:
            - CREATE
            - UPDATE
            apiGroups:
            - rbac.istio.io
            apiVersions:
            - "*"
            resources:
            - "*"
          - operations:
            - CREATE
            - UPDATE
            apiGroups:
            - authentication.istio.io
            apiVersions:
            - "*"
            resources:
            - "*"
          - operations:
            - CREATE
            - UPDATE
            apiGroups:
            - networking.istio.io
            apiVersions:
            - "*"
            resources:
            - destinationrules
            - envoyfilters
            - gateways
            - serviceentries
            - sidecars
            - virtualservices
        failurePolicy: Fail
      - name: mixer.validation.istio.io
        clientConfig:
          service:
            name: istio-galley
            namespace: istio-system
            path: "/admitmixer"
          caBundle: ""
        rules:
          - operations:
            - CREATE
            - UPDATE
            apiGroups:
            - config.istio.io
            apiVersions:
            - v1alpha2
            resources:
            - rules
            - attributemanifests
            - circonuses
            - deniers
            - fluentds
            - kubernetesenvs
            - listcheckers
            - memquotas
            - noops
            - opas
            - prometheuses
            - rbacs
            - solarwindses
            - stackdrivers
            - cloudwatches
            - dogstatsds
            - statsds
            - stdios
            - apikeys
            - authorizations
            - checknothings
            # - kuberneteses
            - listentries
            - logentries
            - metrics
            - quotas
            - reportnothings
            - tracespans
        failurePolicy: Fail
---
# Source: istio/charts/security/templates/configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: istio-security-custom-resources
  namespace: istio-system
  labels:
    app: security
    chart: security
    heritage: Tiller
    release: release-name
    istio: citadel
data:
  custom-resources.yaml: |-
    # Authentication policy to enable permissive mode for all services (that have sidecar) in the mesh.
    apiVersion: "authentication.istio.io/v1alpha1"
    kind: "MeshPolicy"
    metadata:
      name: "default"
      labels:
        app: security
        chart: security
        heritage: Tiller
        release: release-name
    spec:
      peers:
      - mtls:
          mode: PERMISSIVE
  run.sh: |-
    #!/bin/sh
    set -x
    if [ "$#" -ne "1" ]; then
        echo "first argument should be path to custom resource yaml"
        exit 1
    fi
    pathToResourceYAML=${1}
    kubectl get validatingwebhookconfiguration istio-galley 2>/dev/null
    if [ "$?" -eq 0 ]; then
        echo "istio-galley validatingwebhookconfiguration found - waiting for istio-galley deployment to be ready"
        while true; do
            kubectl -n istio-system get deployment istio-galley 2>/dev/null
            if [ "$?" -eq 0 ]; then
                break
            fi
            sleep 1
        done
        kubectl -n istio-system rollout status deployment istio-galley
        if [ "$?" -ne 0 ]; then
            echo "istio-galley deployment rollout status check failed"
            exit 1
        fi
        echo "istio-galley deployment ready for configuration validation"
    fi
    sleep 5
    kubectl apply -f ${pathToResourceYAML}
---
# Source: istio/templates/configmap.yaml

apiVersion: v1
kind: ConfigMap
metadata:
  name: istio
  namespace: istio-system
  labels:
    app: istio
    chart: istio
    heritage: Tiller
    release: release-name
data:
  mesh: |-
    # Set the following variable to true to disable policy checks by the Mixer.
    # Note that metrics will still be reported to the Mixer.
    disablePolicyChecks: true
    # Set enableTracing to false to disable request tracing.
    enableTracing: true
    # Set accessLogFile to empty string to disable access log.
    accessLogFile: ""
    # If accessLogEncoding is TEXT, value will be used directly as the log format
    # example: "[%START_TIME%] %REQ(:METHOD)% %REQ(X-ENVOY-ORIGINAL-PATH?:PATH)% %PROTOCOL%\n"
    # If AccessLogEncoding is JSON, value will be parsed as map[string]string
    # example: '\''{"start_time": "%START_TIME%", "req_method": "%REQ(:METHOD)%"}'\''
    # Leave empty to use default log format
    accessLogFormat: ""
    # Set accessLogEncoding to JSON or TEXT to configure sidecar access log
    accessLogEncoding: '\''TEXT'\''
    mixerCheckServer: istio-policy.istio-system.svc.cluster.local:9091
    mixerReportServer: istio-telemetry.istio-system.svc.cluster.local:9091
    # policyCheckFailOpen allows traffic in cases when the mixer policy service cannot be reached.
    # Default is false which means the traffic is denied when the client is unable to connect to Mixer.
    policyCheckFailOpen: false
    # Let Pilot give ingresses the public IP of the Istio ingressgateway
    ingressService: istio-ingressgateway
    # Default connect timeout for dynamic clusters generated by Pilot and returned via XDS
    connectTimeout: 10s
    # DNS refresh rate for Envoy clusters of type STRICT_DNS
    dnsRefreshRate: 5s
    # Unix Domain Socket through which envoy communicates with NodeAgent SDS to get
    # key/cert for mTLS. Use secret-mount files instead of SDS if set to empty.
    sdsUdsPath:
    # This flag is used by secret discovery service(SDS).
    # If set to true(prerequisite: https://kubernetes.io/docs/concepts/storage/volumes/#projected), Istio will inject volumes mount
    # for k8s service account JWT, so that K8s API server mounts k8s service account JWT to envoy container, which
    # will be used to generate key/cert eventually. This isn'\''t supported for non-k8s case.
    enableSdsTokenMount: false
    # This flag is used by secret discovery service(SDS).
    # If set to true, envoy will fetch normal k8s service account JWT from '\''/var/run/secrets/kubernetes.io/serviceaccount/token'\''
    # (https://kubernetes.io/docs/tasks/access-application-cluster/access-cluster/#accessing-the-api-from-a-pod)
    # and pass to sds server, which will be used to request key/cert eventually.
    # this flag is ignored if enableSdsTokenMount is set.
    # This isn'\''t supported for non-k8s case.
    sdsUseK8sSaJwt: false
    # The trust domain corresponds to the trust root of a system.
    # Refer to https://github.com/spiffe/spiffe/blob/master/standards/SPIFFE-ID.md#21-trust-domain
    trustDomain:
    # Set the default behavior of the sidecar for handling outbound traffic from the application:
    # ALLOW_ANY - outbound traffic to unknown destinations will be allowed, in case there are no
    #   services or ServiceEntries for the destination port
    # REGISTRY_ONLY - restrict outbound traffic to services defined in the service registry as well
    #   as those defined through ServiceEntries
    outboundTrafficPolicy:
      mode: ALLOW_ANY
    localityLbSetting:
      {}
    # The namespace to treat as the administrative root namespace for istio
    # configuration.
    rootNamespace: istio-system
    configSources:
    - address: istio-galley.istio-system.svc:9901
    defaultConfig:
      #
      # TCP connection timeout between Envoy & the application, and between Envoys.  Used for static clusters
      # defined in Envoy'\''s configuration file
      connectTimeout: 10s
      #
      ### ADVANCED SETTINGS #############
      # Where should envoy'\''s configuration be stored in the istio-proxy container
      configPath: "/etc/istio/proxy"
      binaryPath: "/usr/local/bin/envoy"
      # The pseudo service name used for Envoy.
      serviceCluster: istio-proxy
      # These settings that determine how long an old Envoy
      # process should be kept alive after an occasional reload.
      drainDuration: 45s
      parentShutdownDuration: 1m0s
      #
      # The mode used to redirect inbound connections to Envoy. This setting
      # has no effect on outbound traffic: iptables REDIRECT is always used for
      # outbound connections.
      # If "REDIRECT", use iptables REDIRECT to NAT and redirect to Envoy.
      # The "REDIRECT" mode loses source addresses during redirection.
      # If "TPROXY", use iptables TPROXY to redirect to Envoy.
      # The "TPROXY" mode preserves both the source and destination IP
      # addresses and ports, so that they can be used for advanced filtering
      # and manipulation.
      # The "TPROXY" mode also configures the sidecar to run with the
      # CAP_NET_ADMIN capability, which is required to use TPROXY.
      #interceptionMode: REDIRECT
      #
      # Port where Envoy listens (on local host) for admin commands
      # You can exec into the istio-proxy container in a pod and
      # curl the admin port (curl http://localhost:15000/) to obtain
      # diagnostic information from Envoy. See
      # https://lyft.github.io/envoy/docs/operations/admin.html
      # for more details
      proxyAdminPort: 15000
      #
      # Set concurrency to a specific number to control the number of Proxy worker threads.
      # If set to 0 (default), then start worker thread for each CPU thread/core.
      concurrency: 2
      #
      tracing:
        zipkin:
          # Address of the Zipkin collector
          address: zipkin.istio-system:9411
      #
      # Mutual TLS authentication between sidecars and istio control plane.
      controlPlaneAuthPolicy: NONE
      #
      # Address where istio Pilot service is running
      discoveryAddress: istio-pilot.istio-system:15010
  # Configuration file for the mesh networks to be used by the Split Horizon EDS.
  meshNetworks: |-
    networks: {}
---
# Source: istio/templates/sidecar-injector-configmap.yaml

apiVersion: v1
kind: ConfigMap
metadata:
  name: istio-sidecar-injector
  namespace: istio-system
  labels:
    app: istio
    chart: istio
    heritage: Tiller
    release: release-name
    istio: sidecar-injector
data:
  config: |-
    policy: disabled
    template: |-
      rewriteAppHTTPProbe: false
      initContainers:
      [[ if ne (annotation .ObjectMeta `sidecar.istio.io/interceptionMode` .ProxyConfig.InterceptionMode) "NONE" ]]
      - name: istio-init
        image: "docker.io/istio/proxy_init:1.1.7"
        args:
        - "-p"
        - [[ .MeshConfig.ProxyListenPort ]]
        - "-u"
        - 1337
        - "-m"
        - [[ annotation .ObjectMeta `sidecar.istio.io/interceptionMode` .ProxyConfig.InterceptionMode ]]
        - "-i"
        - "[[ annotation .ObjectMeta `traffic.sidecar.istio.io/includeOutboundIPRanges`  "*"  ]]"
        - "-x"
        - "[[ annotation .ObjectMeta `traffic.sidecar.istio.io/excludeOutboundIPRanges`  ""  ]]"
        - "-b"
        - "[[ annotation .ObjectMeta `traffic.sidecar.istio.io/includeInboundPorts` (includeInboundPorts .Spec.Containers) ]]"
        - "-d"
        - "[[ excludeInboundPort (annotation .ObjectMeta `status.sidecar.istio.io/port`  15020 ) (annotation .ObjectMeta `traffic.sidecar.istio.io/excludeInboundPorts`  "" ) ]]"
        [[ if (isset .ObjectMeta.Annotations `traffic.sidecar.istio.io/kubevirtInterfaces`) -]]
        - "-k"
        - "[[ index .ObjectMeta.Annotations `traffic.sidecar.istio.io/kubevirtInterfaces` ]]"
        [[ end -]]
        imagePullPolicy: IfNotPresent
        resources:
          requests:
            cpu: 10m
            memory: 10Mi
          limits:
            cpu: 100m
            memory: 50Mi
        securityContext:
          runAsUser: 0
          runAsNonRoot: false
          capabilities:
            add:
            - NET_ADMIN
        restartPolicy: Always
      [[ end -]]
      containers:
      - name: istio-proxy
        image: [[ annotation .ObjectMeta `sidecar.istio.io/proxyImage`  "docker.io/istio/proxyv2:1.1.7"  ]]
        ports:
        - containerPort: 15090
          protocol: TCP
          name: http-envoy-prom
        args:
        - proxy
        - sidecar
        - --domain
        - $(POD_NAMESPACE).svc.cluster.local
        - --configPath
        - [[ .ProxyConfig.ConfigPath ]]
        - --binaryPath
        - [[ .ProxyConfig.BinaryPath ]]
        - --serviceCluster
        [[ if ne "" (index .ObjectMeta.Labels "app") -]]
        - [[ index .ObjectMeta.Labels "app" ]].$(POD_NAMESPACE)
        [[ else -]]
        - [[ valueOrDefault .DeploymentMeta.Name "istio-proxy" ]].[[ valueOrDefault .DeploymentMeta.Namespace "default" ]]
        [[ end -]]
        - --drainDuration
        - [[ formatDuration .ProxyConfig.DrainDuration ]]
        - --parentShutdownDuration
        - [[ formatDuration .ProxyConfig.ParentShutdownDuration ]]
        - --discoveryAddress
        - [[ annotation .ObjectMeta `sidecar.istio.io/discoveryAddress` .ProxyConfig.DiscoveryAddress ]]
        - --zipkinAddress
        - [[ .ProxyConfig.GetTracing.GetZipkin.GetAddress ]]
        - --connectTimeout
        - [[ formatDuration .ProxyConfig.ConnectTimeout ]]
        - --proxyAdminPort
        - [[ .ProxyConfig.ProxyAdminPort ]]
        [[ if gt .ProxyConfig.Concurrency 0 -]]
        - --concurrency
        - [[ .ProxyConfig.Concurrency ]]
        [[ end -]]
        - --controlPlaneAuthPolicy
        - [[ annotation .ObjectMeta `sidecar.istio.io/controlPlaneAuthPolicy` .ProxyConfig.ControlPlaneAuthPolicy ]]
      [[- if (ne (annotation .ObjectMeta `status.sidecar.istio.io/port`  15020 ) "0") ]]
        - --statusPort
        - [[ annotation .ObjectMeta `status.sidecar.istio.io/port`  15020  ]]
        - --applicationPorts
        - "[[ annotation .ObjectMeta `readiness.status.sidecar.istio.io/applicationPorts` (applicationPorts .Spec.Containers) ]]"
      [[- end ]]
        env:
        - name: POD_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        - name: POD_NAMESPACE
          valueFrom:
            fieldRef:
              fieldPath: metadata.namespace
        - name: INSTANCE_IP
          valueFrom:
            fieldRef:
              fieldPath: status.podIP
        - name: ISTIO_META_POD_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        - name: ISTIO_META_CONFIG_NAMESPACE
          valueFrom:
            fieldRef:
              fieldPath: metadata.namespace
        - name: ISTIO_META_INTERCEPTION_MODE
          value: [[ or (index .ObjectMeta.Annotations "sidecar.istio.io/interceptionMode") .ProxyConfig.InterceptionMode.String ]]
        [[ if .ObjectMeta.Annotations ]]
        - name: ISTIO_METAJSON_ANNOTATIONS
          value: |
                 [[ toJSON .ObjectMeta.Annotations ]]
        [[ end ]]
        [[ if .ObjectMeta.Labels ]]
        - name: ISTIO_METAJSON_LABELS
          value: |
                 [[ toJSON .ObjectMeta.Labels ]]
        [[ end ]]
        [[- if (isset .ObjectMeta.Annotations `sidecar.istio.io/bootstrapOverride`) ]]
        - name: ISTIO_BOOTSTRAP_OVERRIDE
          value: "/etc/istio/custom-bootstrap/custom_bootstrap.json"
        [[- end ]]
        imagePullPolicy: IfNotPresent
        [[ if (ne (annotation .ObjectMeta `status.sidecar.istio.io/port`  15020 ) "0") ]]
        readinessProbe:
          httpGet:
            path: /healthz/ready
            port: [[ annotation .ObjectMeta `status.sidecar.istio.io/port`  15020  ]]
          initialDelaySeconds: [[ annotation .ObjectMeta `readiness.status.sidecar.istio.io/initialDelaySeconds`  1  ]]
          periodSeconds: [[ annotation .ObjectMeta `readiness.status.sidecar.istio.io/periodSeconds`  2  ]]
          failureThreshold: [[ annotation .ObjectMeta `readiness.status.sidecar.istio.io/failureThreshold`  30  ]]
        [[ end -]]securityContext:
          readOnlyRootFilesystem: true
          [[ if eq (annotation .ObjectMeta `sidecar.istio.io/interceptionMode` .ProxyConfig.InterceptionMode) "TPROXY" -]]
          capabilities:
            add:
            - NET_ADMIN
          runAsGroup: 1337
          [[ else -]]
          runAsUser: 1337
          [[- end ]]
        resources:
          [[ if or (isset .ObjectMeta.Annotations `sidecar.istio.io/proxyCPU`) (isset .ObjectMeta.Annotations `sidecar.istio.io/proxyMemory`) -]]
          requests:
            [[ if (isset .ObjectMeta.Annotations `sidecar.istio.io/proxyCPU`) -]]
            cpu: "[[ index .ObjectMeta.Annotations `sidecar.istio.io/proxyCPU` ]]"
            [[ end ]]
            [[ if (isset .ObjectMeta.Annotations `sidecar.istio.io/proxyMemory`) -]]
            memory: "[[ index .ObjectMeta.Annotations `sidecar.istio.io/proxyMemory` ]]"
            [[ end ]]
        [[ else -]]
          limits:
            cpu: 2000m
            memory: 1024Mi
          requests:
            cpu: 100m
            memory: 128Mi
        [[ end -]]
        volumeMounts:
        [[- if (isset .ObjectMeta.Annotations `sidecar.istio.io/bootstrapOverride`) ]]
        - mountPath: /etc/istio/custom-bootstrap
          name: custom-bootstrap-volume
        [[- end ]]
        - mountPath: /etc/istio/proxy
          name: istio-envoy
        - mountPath: /etc/certs/
          name: istio-certs
          readOnly: true
          [[- if isset .ObjectMeta.Annotations `sidecar.istio.io/userVolumeMount` ]]
          [[ range $index, $value := fromJSON (index .ObjectMeta.Annotations `sidecar.istio.io/userVolumeMount`) ]]
        - name: "[[ $index ]]"
          [[ toYaml $value | indent 4 ]]
          [[ end ]]
          [[- end ]]
      volumes:
      [[- if (isset .ObjectMeta.Annotations `sidecar.istio.io/bootstrapOverride`) ]]
      - name: custom-bootstrap-volume
        configMap:
          name: [[ annotation .ObjectMeta `sidecar.istio.io/bootstrapOverride` `` ]]
      [[- end ]]
      - emptyDir:
          medium: Memory
        name: istio-envoy
      - name: istio-certs
        secret:
          optional: true
          [[ if eq .Spec.ServiceAccountName "" -]]
          secretName: istio.default
          [[ else -]]
          secretName: [[ printf "istio.%s" .Spec.ServiceAccountName ]]
          [[ end -]]
        [[- if isset .ObjectMeta.Annotations `sidecar.istio.io/userVolume` ]]
        [[ range $index, $value := fromJSON (index .ObjectMeta.Annotations `sidecar.istio.io/userVolume`) ]]
      - name: "[[ $index ]]"
        [[ toYaml $value | indent 2 ]]
        [[ end ]]
        [[ end ]]
---
# Source: istio/charts/galley/templates/serviceaccount.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: istio-galley-service-account
  namespace: istio-system
  labels:
    app: galley
    chart: galley
    heritage: Tiller
    release: release-name

---
# Source: istio/charts/gateways/templates/serviceaccount.yaml

apiVersion: v1
kind: ServiceAccount
metadata:
  name: istio-ingressgateway-service-account
  namespace: istio-system
  labels:
    app: istio-ingressgateway
    chart: gateways
    heritage: Tiller
    release: release-name
---


---
# Source: istio/charts/mixer/templates/serviceaccount.yaml

apiVersion: v1
kind: ServiceAccount
metadata:
  name: istio-mixer-service-account
  namespace: istio-system
  labels:
    app: mixer
    chart: mixer
    heritage: Tiller
    release: release-name

---
# Source: istio/charts/pilot/templates/serviceaccount.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: istio-pilot-service-account
  namespace: istio-system
  labels:
    app: pilot
    chart: pilot
    heritage: Tiller
    release: release-name

---
# Source: istio/charts/security/templates/cleanup-secrets.yaml
# The reason for creating a ServiceAccount and ClusterRole specifically for this
# post-delete hooked job is because the citadel ServiceAccount is being deleted
# before this hook is launched. On the other hand, running this hook before the
# deletion of the citadel (e.g. pre-delete) won'\''t delete the secrets because they
# will be re-created immediately by the to-be-deleted citadel.
#
# It'\''s also important that the ServiceAccount, ClusterRole and ClusterRoleBinding
# will be ready before running the hooked Job therefore the hook weights.

apiVersion: v1
kind: ServiceAccount
metadata:
  name: istio-cleanup-secrets-service-account
  namespace: istio-system
  annotations:
    "helm.sh/hook": post-delete
    "helm.sh/hook-delete-policy": hook-succeeded
    "helm.sh/hook-weight": "1"
  labels:
    app: security
    chart: security
    heritage: Tiller
    release: release-name
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: istio-cleanup-secrets-istio-system
  annotations:
    "helm.sh/hook": post-delete
    "helm.sh/hook-delete-policy": hook-succeeded
    "helm.sh/hook-weight": "1"
  labels:
    app: security
    chart: security
    heritage: Tiller
    release: release-name
rules:
- apiGroups: [""]
  resources: ["secrets"]
  verbs: ["list", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: istio-cleanup-secrets-istio-system
  annotations:
    "helm.sh/hook": post-delete
    "helm.sh/hook-delete-policy": hook-succeeded
    "helm.sh/hook-weight": "2"
  labels:
    app: security
    chart: security
    heritage: Tiller
    release: release-name
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: istio-cleanup-secrets-istio-system
subjects:
  - kind: ServiceAccount
    name: istio-cleanup-secrets-service-account
    namespace: istio-system
---
apiVersion: batch/v1
kind: Job
metadata:
  name: istio-cleanup-secrets-1.1.7
  namespace: istio-system
  annotations:
    "helm.sh/hook": post-delete
    "helm.sh/hook-delete-policy": hook-succeeded
    "helm.sh/hook-weight": "3"
  labels:
    app: security
    chart: security
    heritage: Tiller
    release: release-name
spec:
  template:
    metadata:
      name: istio-cleanup-secrets
      labels:
        app: security
        chart: security
        heritage: Tiller
        release: release-name
    spec:
      serviceAccountName: istio-cleanup-secrets-service-account
      containers:
        - name: kubectl
          image: "docker.io/istio/kubectl:1.1.7"
          imagePullPolicy: IfNotPresent
          command:
          - /bin/bash
          - -c
          - >
              kubectl get secret --all-namespaces | grep "istio.io/key-and-cert" |  while read -r entry; do
                ns=$(echo $entry | awk '\''{print $1}'\'');
                name=$(echo $entry | awk '\''{print $2}'\'');
                kubectl delete secret $name -n $ns;
              done
      restartPolicy: OnFailure
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: beta.kubernetes.io/arch
                operator: In
                values:
                - amd64
                - ppc64le
                - s390x
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 2
            preference:
              matchExpressions:
              - key: beta.kubernetes.io/arch
                operator: In
                values:
                - amd64
          - weight: 2
            preference:
              matchExpressions:
              - key: beta.kubernetes.io/arch
                operator: In
                values:
                - ppc64le
          - weight: 2
            preference:
              matchExpressions:
              - key: beta.kubernetes.io/arch
                operator: In
                values:
                - s390x

---
# Source: istio/charts/security/templates/create-custom-resources-job.yaml

apiVersion: v1
kind: ServiceAccount
metadata:
  name: istio-security-post-install-account
  namespace: istio-system
  labels:
    app: security
    chart: security
    heritage: Tiller
    release: release-name
---
apiVersion: rbac.authorization.k8s.io/v1beta1
kind: ClusterRole
metadata:
  name: istio-security-post-install-istio-system
  labels:
    app: security
    chart: security
    heritage: Tiller
    release: release-name
rules:
- apiGroups: ["authentication.istio.io"] # needed to create default authn policy
  resources: ["*"]
  verbs: ["*"]
- apiGroups: ["networking.istio.io"] # needed to create security destination rules
  resources: ["*"]
  verbs: ["*"]
- apiGroups: ["admissionregistration.k8s.io"]
  resources: ["validatingwebhookconfigurations"]
  verbs: ["get"]
- apiGroups: ["extensions", "apps"]
  resources: ["deployments", "replicasets"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1beta1
kind: ClusterRoleBinding
metadata:
  name: istio-security-post-install-role-binding-istio-system
  labels:
    app: security
    chart: security
    heritage: Tiller
    release: release-name
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: istio-security-post-install-istio-system
subjects:
  - kind: ServiceAccount
    name: istio-security-post-install-account
    namespace: istio-system
---
apiVersion: batch/v1
kind: Job
metadata:
  name: istio-security-post-install-1.1.7
  namespace: istio-system
  annotations:
    "helm.sh/hook": post-install
    "helm.sh/hook-delete-policy": hook-succeeded
  labels:
    app: security
    chart: security
    heritage: Tiller
    release: release-name
spec:
  template:
    metadata:
      name: istio-security-post-install
      labels:
        app: security
        chart: security
        heritage: Tiller
        release: release-name
    spec:
      serviceAccountName: istio-security-post-install-account
      containers:
        - name: kubectl
          image: "docker.io/istio/kubectl:1.1.7"
          imagePullPolicy: IfNotPresent
          command: [ "/bin/bash", "/tmp/security/run.sh", "/tmp/security/custom-resources.yaml" ]
          volumeMounts:
            - mountPath: "/tmp/security"
              name: tmp-configmap-security
      volumes:
        - name: tmp-configmap-security
          configMap:
            name: istio-security-custom-resources
      restartPolicy: OnFailure
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: beta.kubernetes.io/arch
                operator: In
                values:
                - amd64
                - ppc64le
                - s390x
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 2
            preference:
              matchExpressions:
              - key: beta.kubernetes.io/arch
                operator: In
                values:
                - amd64
          - weight: 2
            preference:
              matchExpressions:
              - key: beta.kubernetes.io/arch
                operator: In
                values:
                - ppc64le
          - weight: 2
            preference:
              matchExpressions:
              - key: beta.kubernetes.io/arch
                operator: In
                values:
                - s390x

---
# Source: istio/charts/security/templates/serviceaccount.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: istio-citadel-service-account
  namespace: istio-system
  labels:
    app: security
    chart: security
    heritage: Tiller
    release: release-name

---
# Source: istio/charts/sidecarInjectorWebhook/templates/serviceaccount.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: istio-sidecar-injector-service-account
  namespace: istio-system
  labels:
    app: sidecarInjectorWebhook
    chart: sidecarInjectorWebhook
    heritage: Tiller
    release: release-name
    istio: sidecar-injector

---
# Source: istio/templates/serviceaccount.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: istio-multi
  namespace: istio-system

---
# Source: istio/charts/galley/templates/clusterrole.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: istio-galley-istio-system
  labels:
    app: galley
    chart: galley
    heritage: Tiller
    release: release-name
rules:
- apiGroups: ["admissionregistration.k8s.io"]
  resources: ["validatingwebhookconfigurations"]
  verbs: ["*"]
- apiGroups: ["config.istio.io"] # istio mixer CRD watcher
  resources: ["*"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["networking.istio.io"]
  resources: ["*"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["authentication.istio.io"]
  resources: ["*"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["rbac.istio.io"]
  resources: ["*"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["extensions","apps"]
  resources: ["deployments"]
  resourceNames: ["istio-galley"]
  verbs: ["get"]
- apiGroups: [""]
  resources: ["pods", "nodes", "services", "endpoints"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["extensions"]
  resources: ["ingresses"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["extensions"]
  resources: ["deployments/finalizers"]
  resourceNames: ["istio-galley"]
  verbs: ["update"]

---
# Source: istio/charts/gateways/templates/clusterrole.yaml

apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: istio-ingressgateway-istio-system
  labels:
    app: ingressgateway
    chart: gateways
    heritage: Tiller
    release: release-name
rules:
- apiGroups: ["networking.istio.io"]
  resources: ["virtualservices", "destinationrules", "gateways"]
  verbs: ["get", "watch", "list", "update"]
---

---
# Source: istio/charts/mixer/templates/clusterrole.yaml

apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: istio-mixer-istio-system
  labels:
    app: mixer
    chart: mixer
    heritage: Tiller
    release: release-name
rules:
- apiGroups: ["config.istio.io"] # istio CRD watcher
  resources: ["*"]
  verbs: ["create", "get", "list", "watch", "patch"]
- apiGroups: ["apiextensions.k8s.io"]
  resources: ["customresourcedefinitions"]
  verbs: ["get", "list", "watch"]
- apiGroups: [""]
  resources: ["configmaps", "endpoints", "pods", "services", "namespaces", "secrets", "replicationcontrollers"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["extensions", "apps"]
  resources: ["replicasets"]
  verbs: ["get", "list", "watch"]

---
# Source: istio/charts/pilot/templates/clusterrole.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: istio-pilot-istio-system
  labels:
    app: pilot
    chart: pilot
    heritage: Tiller
    release: release-name
rules:
- apiGroups: ["config.istio.io"]
  resources: ["*"]
  verbs: ["*"]
- apiGroups: ["rbac.istio.io"]
  resources: ["*"]
  verbs: ["get", "watch", "list"]
- apiGroups: ["networking.istio.io"]
  resources: ["*"]
  verbs: ["*"]
- apiGroups: ["authentication.istio.io"]
  resources: ["*"]
  verbs: ["*"]
- apiGroups: ["apiextensions.k8s.io"]
  resources: ["customresourcedefinitions"]
  verbs: ["*"]
- apiGroups: ["extensions"]
  resources: ["ingresses", "ingresses/status"]
  verbs: ["*"]
- apiGroups: [""]
  resources: ["configmaps"]
  verbs: ["create", "get", "list", "watch", "update"]
- apiGroups: [""]
  resources: ["endpoints", "pods", "services", "namespaces", "nodes", "secrets"]
  verbs: ["get", "list", "watch"]

---
# Source: istio/charts/security/templates/clusterrole.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: istio-citadel-istio-system
  labels:
    app: security
    chart: security
    heritage: Tiller
    release: release-name
rules:
- apiGroups: [""]
  resources: ["configmaps"]
  verbs: ["create", "get", "update"]
- apiGroups: [""]
  resources: ["secrets"]
  verbs: ["create", "get", "watch", "list", "update", "delete"]
- apiGroups: [""]
  resources: ["serviceaccounts", "services"]
  verbs: ["get", "watch", "list"]
- apiGroups: ["authentication.k8s.io"]
  resources: ["tokenreviews"]
  verbs: ["create"]

---
# Source: istio/charts/sidecarInjectorWebhook/templates/clusterrole.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: istio-sidecar-injector-istio-system
  labels:
    app: sidecarInjectorWebhook
    chart: sidecarInjectorWebhook
    heritage: Tiller
    release: release-name
    istio: sidecar-injector
rules:
- apiGroups: [""]
  resources: ["configmaps"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["admissionregistration.k8s.io"]
  resources: ["mutatingwebhookconfigurations"]
  verbs: ["get", "list", "watch", "patch"]

---
# Source: istio/templates/clusterrole.yaml
kind: ClusterRole
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: istio-reader
rules:
  - apiGroups: ['\'''\'']
    resources: ['\''nodes'\'', '\''pods'\'', '\''services'\'', '\''endpoints'\'', "replicationcontrollers"]
    verbs: ['\''get'\'', '\''watch'\'', '\''list'\'']
  - apiGroups: ["extensions", "apps"]
    resources: ["replicasets"]
    verbs: ["get", "list", "watch"]

---
# Source: istio/charts/galley/templates/clusterrolebinding.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: istio-galley-admin-role-binding-istio-system
  labels:
    app: galley
    chart: galley
    heritage: Tiller
    release: release-name
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: istio-galley-istio-system
subjects:
  - kind: ServiceAccount
    name: istio-galley-service-account
    namespace: istio-system

---
# Source: istio/charts/gateways/templates/clusterrolebindings.yaml

apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: istio-ingressgateway-istio-system
  labels:
    app: ingressgateway
    chart: gateways
    heritage: Tiller
    release: release-name
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: istio-ingressgateway-istio-system
subjects:
- kind: ServiceAccount
  name: istio-ingressgateway-service-account
  namespace: istio-system
---

---
# Source: istio/charts/mixer/templates/clusterrolebinding.yaml

apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: istio-mixer-admin-role-binding-istio-system
  labels:
    app: mixer
    chart: mixer
    heritage: Tiller
    release: release-name
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: istio-mixer-istio-system
subjects:
  - kind: ServiceAccount
    name: istio-mixer-service-account
    namespace: istio-system

---
# Source: istio/charts/pilot/templates/clusterrolebinding.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: istio-pilot-istio-system
  labels:
    app: pilot
    chart: pilot
    heritage: Tiller
    release: release-name
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: istio-pilot-istio-system
subjects:
  - kind: ServiceAccount
    name: istio-pilot-service-account
    namespace: istio-system

---
# Source: istio/charts/security/templates/clusterrolebinding.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: istio-citadel-istio-system
  labels:
    app: security
    chart: security
    heritage: Tiller
    release: release-name
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: istio-citadel-istio-system
subjects:
  - kind: ServiceAccount
    name: istio-citadel-service-account
    namespace: istio-system

---
# Source: istio/charts/sidecarInjectorWebhook/templates/clusterrolebinding.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: istio-sidecar-injector-admin-role-binding-istio-system
  labels:
    app: sidecarInjectorWebhook
    chart: sidecarInjectorWebhook
    heritage: Tiller
    release: release-name
    istio: sidecar-injector
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: istio-sidecar-injector-istio-system
subjects:
  - kind: ServiceAccount
    name: istio-sidecar-injector-service-account
    namespace: istio-system

---
# Source: istio/templates/clusterrolebinding.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: istio-multi
  labels:
    chart: istio-1.1.0
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: istio-reader
subjects:
- kind: ServiceAccount
  name: istio-multi
  namespace: istio-system

---
# Source: istio/charts/gateways/templates/role.yaml

apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: istio-ingressgateway-sds
  namespace: istio-system
rules:
- apiGroups: [""]
  resources: ["secrets"]
  verbs: ["get", "watch", "list"]
---

---
# Source: istio/charts/gateways/templates/rolebindings.yaml

apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: istio-ingressgateway-sds
  namespace: istio-system
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: istio-ingressgateway-sds
subjects:
- kind: ServiceAccount
  name: istio-ingressgateway-service-account
---

---
# Source: istio/charts/galley/templates/service.yaml
apiVersion: v1
kind: Service
metadata:
  name: istio-galley
  namespace: istio-system
  labels:
    app: galley
    chart: galley
    heritage: Tiller
    release: release-name
    istio: galley
spec:
  ports:
  - port: 443
    name: https-validation
  - port: 15014
    name: http-monitoring
  - port: 9901
    name: grpc-mcp
  selector:
    istio: galley

---
# Source: istio/charts/gateways/templates/service.yaml

apiVersion: v1
kind: Service
metadata:
  name: istio-ingressgateway
  namespace: istio-system
  annotations:
  labels:
    chart: gateways
    heritage: Tiller
    release: release-name
    app: istio-ingressgateway
    istio: ingressgateway
spec:
  type: LoadBalancer
  selector:
    release: release-name
    app: istio-ingressgateway
    istio: ingressgateway
  ports:
    -
      name: status-port
      port: 15020
      targetPort: 15020
    -
      name: http2
      nodePort: 31380
      port: 80
      targetPort: 80
    -
      name: https
      nodePort: 31390
      port: 443
    -
      name: tcp
      nodePort: 31400
      port: 31400
    -
      name: https-kiali
      port: 15029
      targetPort: 15029
    -
      name: https-prometheus
      port: 15030
      targetPort: 15030
    -
      name: https-grafana
      port: 15031
      targetPort: 15031
    -
      name: https-tracing
      port: 15032
      targetPort: 15032
    -
      name: tls
      port: 15443
      targetPort: 15443
---

---
# Source: istio/charts/mixer/templates/service.yaml

apiVersion: v1
kind: Service
metadata:
  name: istio-policy
  namespace: istio-system
  annotations:
   networking.istio.io/exportTo: "*"
  labels:
    app: mixer
    chart: mixer
    heritage: Tiller
    release: release-name
    istio: mixer
spec:
  ports:
  - name: grpc-mixer
    port: 9091
  - name: grpc-mixer-mtls
    port: 15004
  - name: http-monitoring
    port: 15014
  selector:
    istio: mixer
    istio-mixer-type: policy
---
apiVersion: v1
kind: Service
metadata:
  name: istio-telemetry
  namespace: istio-system
  annotations:
   networking.istio.io/exportTo: "*"
  labels:
    app: mixer
    chart: mixer
    heritage: Tiller
    release: release-name
    istio: mixer
spec:
  ports:
  - name: grpc-mixer
    port: 9091
  - name: grpc-mixer-mtls
    port: 15004
  - name: http-monitoring
    port: 15014
  - name: prometheus
    port: 42422
  selector:
    istio: mixer
    istio-mixer-type: telemetry
---


---
# Source: istio/charts/pilot/templates/service.yaml
apiVersion: v1
kind: Service
metadata:
  name: istio-pilot
  namespace: istio-system
  labels:
    app: pilot
    chart: pilot
    heritage: Tiller
    release: release-name
    istio: pilot
spec:
  ports:
  - port: 15010
    name: grpc-xds # direct
  - port: 15011
    name: https-xds # mTLS
  - port: 8080
    name: http-legacy-discovery # direct
  - port: 15014
    name: http-monitoring
  selector:
    istio: pilot

---
# Source: istio/charts/security/templates/service.yaml
apiVersion: v1
kind: Service
metadata:
  # we use the normal name here (e.g. '\''prometheus'\'')
  # as grafana is configured to use this as a data source
  name: istio-citadel
  namespace: istio-system
  labels:
    app: security
    chart: security
    heritage: Tiller
    release: release-name
    istio: citadel
spec:
  ports:
    - name: grpc-citadel
      port: 8060
      targetPort: 8060
      protocol: TCP
    - name: http-monitoring
      port: 15014
  selector:
    istio: citadel

---
# Source: istio/charts/sidecarInjectorWebhook/templates/service.yaml
apiVersion: v1
kind: Service
metadata:
  name: istio-sidecar-injector
  namespace: istio-system
  labels:
    app: sidecarInjectorWebhook
    chart: sidecarInjectorWebhook
    heritage: Tiller
    release: release-name
    istio: sidecar-injector
spec:
  ports:
  - port: 443
  selector:
    istio: sidecar-injector

---
# Source: istio/charts/galley/templates/deployment.yaml
apiVersion: extensions/v1beta1
kind: Deployment
metadata:
  name: istio-galley
  namespace: istio-system
  labels:
    app: galley
    chart: galley
    heritage: Tiller
    release: release-name
    istio: galley
spec:
  replicas: 1
  strategy:
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  template:
    metadata:
      labels:
        app: galley
        chart: galley
        heritage: Tiller
        release: release-name
        istio: galley
      annotations:
        sidecar.istio.io/inject: "false"
    spec:
      serviceAccountName: istio-galley-service-account
      containers:
        - name: galley
          image: "docker.io/istio/galley:1.1.7"
          imagePullPolicy: IfNotPresent
          ports:
          - containerPort: 443
          - containerPort: 15014
          - containerPort: 9901
          command:
          - /usr/local/bin/galley
          - server
          - --meshConfigFile=/etc/mesh-config/mesh
          - --livenessProbeInterval=1s
          - --livenessProbePath=/healthliveness
          - --readinessProbePath=/healthready
          - --readinessProbeInterval=1s
          - --deployment-namespace=istio-system
          - --insecure=true
          - --validation-webhook-config-file
          - /etc/config/validatingwebhookconfiguration.yaml
          - --monitoringPort=15014
          - --log_output_level=default:info
          volumeMounts:
          - name: certs
            mountPath: /etc/certs
            readOnly: true
          - name: config
            mountPath: /etc/config
            readOnly: true
          - name: mesh-config
            mountPath: /etc/mesh-config
            readOnly: true
          livenessProbe:
            exec:
              command:
                - /usr/local/bin/galley
                - probe
                - --probe-path=/healthliveness
                - --interval=10s
            initialDelaySeconds: 5
            periodSeconds: 5
          readinessProbe:
            exec:
              command:
                - /usr/local/bin/galley
                - probe
                - --probe-path=/healthready
                - --interval=10s
            initialDelaySeconds: 5
            periodSeconds: 5
          resources:
            requests:
              cpu: 10m

      volumes:
      - name: certs
        secret:
          secretName: istio.istio-galley-service-account
      - name: config
        configMap:
          name: istio-galley-configuration
      - name: mesh-config
        configMap:
          name: istio
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: beta.kubernetes.io/arch
                operator: In
                values:
                - amd64
                - ppc64le
                - s390x
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 2
            preference:
              matchExpressions:
              - key: beta.kubernetes.io/arch
                operator: In
                values:
                - amd64
          - weight: 2
            preference:
              matchExpressions:
              - key: beta.kubernetes.io/arch
                operator: In
                values:
                - ppc64le
          - weight: 2
            preference:
              matchExpressions:
              - key: beta.kubernetes.io/arch
                operator: In
                values:
                - s390x

---
# Source: istio/charts/gateways/templates/deployment.yaml

apiVersion: extensions/v1beta1
kind: Deployment
metadata:
  name: istio-ingressgateway
  namespace: istio-system
  labels:
    chart: gateways
    heritage: Tiller
    release: release-name
    app: istio-ingressgateway
    istio: ingressgateway
spec:
  template:
    metadata:
      labels:
        chart: gateways
        heritage: Tiller
        release: release-name
        app: istio-ingressgateway
        istio: ingressgateway
      annotations:
        sidecar.istio.io/inject: "false"
    spec:
      serviceAccountName: istio-ingressgateway-service-account
      containers:
        - name: istio-proxy
          image: "docker.io/istio/proxyv2:1.1.7"
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 15020
            - containerPort: 80
            - containerPort: 443
            - containerPort: 31400
            - containerPort: 15029
            - containerPort: 15030
            - containerPort: 15031
            - containerPort: 15032
            - containerPort: 15443
            - containerPort: 15090
              protocol: TCP
              name: http-envoy-prom
          args:
          - proxy
          - router
          - --domain
          - $(POD_NAMESPACE).svc.cluster.local
          - --log_output_level=default:info
          - --drainDuration
          - '\''45s'\'' #drainDuration
          - --parentShutdownDuration
          - '\''1m0s'\'' #parentShutdownDuration
          - --connectTimeout
          - '\''10s'\'' #connectTimeout
          - --serviceCluster
          - istio-ingressgateway
          - --zipkinAddress
          - zipkin:9411
          - --proxyAdminPort
          - "15000"
          - --statusPort
          - "15020"
          - --controlPlaneAuthPolicy
          - NONE
          - --discoveryAddress
          - istio-pilot:15010
          readinessProbe:
            failureThreshold: 30
            httpGet:
              path: /healthz/ready
              port: 15020
              scheme: HTTP
            initialDelaySeconds: 1
            periodSeconds: 2
            successThreshold: 1
            timeoutSeconds: 1
          resources:
            limits:
              cpu: 2000m
              memory: 1024Mi
            requests:
              cpu: 500m
              memory: 256Mi

          env:
          - name: POD_NAME
            valueFrom:
              fieldRef:
                apiVersion: v1
                fieldPath: metadata.name
          - name: POD_NAMESPACE
            valueFrom:
              fieldRef:
                apiVersion: v1
                fieldPath: metadata.namespace
          - name: INSTANCE_IP
            valueFrom:
              fieldRef:
                apiVersion: v1
                fieldPath: status.podIP
          - name: HOST_IP
            valueFrom:
              fieldRef:
                apiVersion: v1
                fieldPath: status.hostIP
          - name: ISTIO_META_POD_NAME
            valueFrom:
              fieldRef:
                apiVersion: v1
                fieldPath: metadata.name
          - name: ISTIO_META_CONFIG_NAMESPACE
            valueFrom:
              fieldRef:
                fieldPath: metadata.namespace
          - name: ISTIO_META_ROUTER_MODE
            value: sni-dnat
          volumeMounts:
          - name: istio-certs
            mountPath: /etc/certs
            readOnly: true
          - name: ingressgateway-certs
            mountPath: "/etc/istio/ingressgateway-certs"
            readOnly: true
          - name: ingressgateway-ca-certs
            mountPath: "/etc/istio/ingressgateway-ca-certs"
            readOnly: true
      volumes:
      - name: istio-certs
        secret:
          secretName: istio.istio-ingressgateway-service-account
          optional: true
      - name: ingressgateway-certs
        secret:
          secretName: "istio-ingressgateway-certs"
          optional: true
      - name: ingressgateway-ca-certs
        secret:
          secretName: "istio-ingressgateway-ca-certs"
          optional: true
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: beta.kubernetes.io/arch
                operator: In
                values:
                - amd64
                - ppc64le
                - s390x
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 2
            preference:
              matchExpressions:
              - key: beta.kubernetes.io/arch
                operator: In
                values:
                - amd64
          - weight: 2
            preference:
              matchExpressions:
              - key: beta.kubernetes.io/arch
                operator: In
                values:
                - ppc64le
          - weight: 2
            preference:
              matchExpressions:
              - key: beta.kubernetes.io/arch
                operator: In
                values:
                - s390x
---

---
# Source: istio/charts/mixer/templates/deployment.yaml

apiVersion: extensions/v1beta1
kind: Deployment
metadata:
  name: istio-policy
  namespace: istio-system
  labels:
    app: istio-mixer
    chart: mixer
    heritage: Tiller
    release: release-name
    istio: mixer
spec:
  strategy:
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  selector:
    matchLabels:
      istio: mixer
      istio-mixer-type: policy
  template:
    metadata:
      labels:
        app: policy
        chart: mixer
        heritage: Tiller
        release: release-name
        istio: mixer
        istio-mixer-type: policy
      annotations:
        sidecar.istio.io/inject: "false"
    spec:
      serviceAccountName: istio-mixer-service-account
      volumes:
      - name: istio-certs
        secret:
          secretName: istio.istio-mixer-service-account
          optional: true
      - name: uds-socket
        emptyDir: {}
      - name: policy-adapter-secret
        secret:
          secretName: policy-adapter-secret
          optional: true
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: beta.kubernetes.io/arch
                operator: In
                values:
                - amd64
                - ppc64le
                - s390x
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 2
            preference:
              matchExpressions:
              - key: beta.kubernetes.io/arch
                operator: In
                values:
                - amd64
          - weight: 2
            preference:
              matchExpressions:
              - key: beta.kubernetes.io/arch
                operator: In
                values:
                - ppc64le
          - weight: 2
            preference:
              matchExpressions:
              - key: beta.kubernetes.io/arch
                operator: In
                values:
                - s390x
      containers:
      - name: mixer
        image: "docker.io/istio/mixer:1.1.7"
        imagePullPolicy: IfNotPresent
        ports:
        - containerPort: 15014
        - containerPort: 42422
        args:
          - --monitoringPort=15014
          - --address
          - unix:///sock/mixer.socket
          - --log_output_level=default:info
          - --configStoreURL=mcp://istio-galley.istio-system.svc:9901
          - --configDefaultNamespace=istio-system
          - --useAdapterCRDs=true
          - --trace_zipkin_url=http://zipkin:9411/api/v1/spans
        env:
        - name: GODEBUG
          value: "gctrace=1"
        - name: GOMAXPROCS
          value: "6"
        resources:
          requests:
            cpu: 10m

        volumeMounts:
        - name: istio-certs
          mountPath: /etc/certs
          readOnly: true
        - name: uds-socket
          mountPath: /sock
        livenessProbe:
          httpGet:
            path: /version
            port: 15014
          initialDelaySeconds: 5
          periodSeconds: 5
      - name: istio-proxy
        image: "docker.io/istio/proxyv2:1.1.7"
        imagePullPolicy: IfNotPresent
        ports:
        - containerPort: 9091
        - containerPort: 15004
        - containerPort: 15090
          protocol: TCP
          name: http-envoy-prom
        args:
        - proxy
        - --domain
        - $(POD_NAMESPACE).svc.cluster.local
        - --serviceCluster
        - istio-policy
        - --templateFile
        - /etc/istio/proxy/envoy_policy.yaml.tmpl
        - --controlPlaneAuthPolicy
        - NONE
        env:
        - name: POD_NAME
          valueFrom:
            fieldRef:
              apiVersion: v1
              fieldPath: metadata.name
        - name: POD_NAMESPACE
          valueFrom:
            fieldRef:
              apiVersion: v1
              fieldPath: metadata.namespace
        - name: INSTANCE_IP
          valueFrom:
            fieldRef:
              apiVersion: v1
              fieldPath: status.podIP
        resources:
          limits:
            cpu: 2000m
            memory: 1024Mi
          requests:
            cpu: 100m
            memory: 128Mi

        volumeMounts:
        - name: istio-certs
          mountPath: /etc/certs
          readOnly: true
        - name: uds-socket
          mountPath: /sock
        - name: policy-adapter-secret
          mountPath: /var/run/secrets/istio.io/policy/adapter
          readOnly: true

---
apiVersion: extensions/v1beta1
kind: Deployment
metadata:
  name: istio-telemetry
  namespace: istio-system
  labels:
    app: istio-mixer
    chart: mixer
    heritage: Tiller
    release: release-name
    istio: mixer
spec:
  strategy:
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  selector:
    matchLabels:
      istio: mixer
      istio-mixer-type: telemetry
  template:
    metadata:
      labels:
        app: telemetry
        chart: mixer
        heritage: Tiller
        release: release-name
        istio: mixer
        istio-mixer-type: telemetry
      annotations:
        sidecar.istio.io/inject: "false"
    spec:
      serviceAccountName: istio-mixer-service-account
      volumes:
      - name: istio-certs
        secret:
          secretName: istio.istio-mixer-service-account
          optional: true
      - name: uds-socket
        emptyDir: {}
      - name: telemetry-adapter-secret
        secret:
          secretName: telemetry-adapter-secret
          optional: true
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: beta.kubernetes.io/arch
                operator: In
                values:
                - amd64
                - ppc64le
                - s390x
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 2
            preference:
              matchExpressions:
              - key: beta.kubernetes.io/arch
                operator: In
                values:
                - amd64
          - weight: 2
            preference:
              matchExpressions:
              - key: beta.kubernetes.io/arch
                operator: In
                values:
                - ppc64le
          - weight: 2
            preference:
              matchExpressions:
              - key: beta.kubernetes.io/arch
                operator: In
                values:
                - s390x
      containers:
      - name: mixer
        image: "docker.io/istio/mixer:1.1.7"
        imagePullPolicy: IfNotPresent
        ports:
        - containerPort: 15014
        - containerPort: 42422
        args:
          - --monitoringPort=15014
          - --address
          - unix:///sock/mixer.socket
          - --log_output_level=default:info
          - --configStoreURL=mcp://istio-galley.istio-system.svc:9901
          - --configDefaultNamespace=istio-system
          - --useAdapterCRDs=true
          - --trace_zipkin_url=http://zipkin:9411/api/v1/spans
          - --averageLatencyThreshold
          - 100ms
          - --loadsheddingMode
          - enforce
        env:
        - name: GODEBUG
          value: "gctrace=1"
        - name: GOMAXPROCS
          value: "6"
        resources:
          limits:
            cpu: 4800m
            memory: 4G
          requests:
            cpu: 1000m
            memory: 1G

        volumeMounts:
        - name: istio-certs
          mountPath: /etc/certs
          readOnly: true
        - name: telemetry-adapter-secret
          mountPath: /var/run/secrets/istio.io/telemetry/adapter
          readOnly: true
        - name: uds-socket
          mountPath: /sock
        livenessProbe:
          httpGet:
            path: /version
            port: 15014
          initialDelaySeconds: 5
          periodSeconds: 5
      - name: istio-proxy
        image: "docker.io/istio/proxyv2:1.1.7"
        imagePullPolicy: IfNotPresent
        ports:
        - containerPort: 9091
        - containerPort: 15004
        - containerPort: 15090
          protocol: TCP
          name: http-envoy-prom
        args:
        - proxy
        - --domain
        - $(POD_NAMESPACE).svc.cluster.local
        - --serviceCluster
        - istio-telemetry
        - --templateFile
        - /etc/istio/proxy/envoy_telemetry.yaml.tmpl
        - --controlPlaneAuthPolicy
        - NONE
        env:
        - name: POD_NAME
          valueFrom:
            fieldRef:
              apiVersion: v1
              fieldPath: metadata.name
        - name: POD_NAMESPACE
          valueFrom:
            fieldRef:
              apiVersion: v1
              fieldPath: metadata.namespace
        - name: INSTANCE_IP
          valueFrom:
            fieldRef:
              apiVersion: v1
              fieldPath: status.podIP
        resources:
          limits:
            cpu: 2000m
            memory: 1024Mi
          requests:
            cpu: 100m
            memory: 128Mi

        volumeMounts:
        - name: istio-certs
          mountPath: /etc/certs
          readOnly: true
        - name: uds-socket
          mountPath: /sock

---

---
# Source: istio/charts/pilot/templates/deployment.yaml
apiVersion: extensions/v1beta1
kind: Deployment
metadata:
  name: istio-pilot
  namespace: istio-system
  # TODO: default template doesn'\''t have this, which one is right ?
  labels:
    app: pilot
    chart: pilot
    heritage: Tiller
    release: release-name
    istio: pilot
  annotations:
    checksum/config-volume: f8da08b6b8c170dde721efd680270b2901e750d4aa186ebb6c22bef5b78a43f9
spec:
  strategy:
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  selector:
    matchLabels:
      istio: pilot
  template:
    metadata:
      labels:
        app: pilot
        chart: pilot
        heritage: Tiller
        release: release-name
        istio: pilot
      annotations:
        sidecar.istio.io/inject: "false"
    spec:
      serviceAccountName: istio-pilot-service-account
      containers:
        - name: discovery
          image: "docker.io/istio/pilot:1.1.7"
          imagePullPolicy: IfNotPresent
          args:
          - "discovery"
          - --monitoringAddr=:15014
          - --log_output_level=default:info
          - --domain
          - cluster.local
          - --secureGrpcAddr
          - ""
          - --keepaliveMaxServerConnectionAge
          - "30m"
          ports:
          - containerPort: 8080
          - containerPort: 15010
          readinessProbe:
            httpGet:
              path: /ready
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 30
            timeoutSeconds: 5
          env:
          - name: POD_NAME
            valueFrom:
              fieldRef:
                apiVersion: v1
                fieldPath: metadata.name
          - name: POD_NAMESPACE
            valueFrom:
              fieldRef:
                apiVersion: v1
                fieldPath: metadata.namespace
          - name: GODEBUG
            value: "gctrace=1"
          - name: PILOT_PUSH_THROTTLE
            value: "100"
          - name: PILOT_TRACE_SAMPLING
            value: "100"
          - name: PILOT_DISABLE_XDS_MARSHALING_TO_ANY
            value: "1"
          resources:
            requests:
              cpu: 500m
              memory: 2048Mi

          volumeMounts:
          - name: config-volume
            mountPath: /etc/istio/config
          - name: istio-certs
            mountPath: /etc/certs
            readOnly: true
        - name: istio-proxy
          image: "docker.io/istio/proxyv2:1.1.7"
          imagePullPolicy: IfNotPresent
          ports:
          - containerPort: 15003
          - containerPort: 15005
          - containerPort: 15007
          - containerPort: 15011
          args:
          - proxy
          - --domain
          - $(POD_NAMESPACE).svc.cluster.local
          - --serviceCluster
          - istio-pilot
          - --templateFile
          - /etc/istio/proxy/envoy_pilot.yaml.tmpl
          - --controlPlaneAuthPolicy
          - NONE
          env:
          - name: POD_NAME
            valueFrom:
              fieldRef:
                apiVersion: v1
                fieldPath: metadata.name
          - name: POD_NAMESPACE
            valueFrom:
              fieldRef:
                apiVersion: v1
                fieldPath: metadata.namespace
          - name: INSTANCE_IP
            valueFrom:
              fieldRef:
                apiVersion: v1
                fieldPath: status.podIP
          resources:
            limits:
              cpu: 2000m
              memory: 1024Mi
            requests:
              cpu: 100m
              memory: 128Mi

          volumeMounts:
          - name: istio-certs
            mountPath: /etc/certs
            readOnly: true
      volumes:
      - name: config-volume
        configMap:
          name: istio
      - name: istio-certs
        secret:
          secretName: istio.istio-pilot-service-account
          optional: true
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: beta.kubernetes.io/arch
                operator: In
                values:
                - amd64
                - ppc64le
                - s390x
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 2
            preference:
              matchExpressions:
              - key: beta.kubernetes.io/arch
                operator: In
                values:
                - amd64
          - weight: 2
            preference:
              matchExpressions:
              - key: beta.kubernetes.io/arch
                operator: In
                values:
                - ppc64le
          - weight: 2
            preference:
              matchExpressions:
              - key: beta.kubernetes.io/arch
                operator: In
                values:
                - s390x

---
# Source: istio/charts/security/templates/deployment.yaml
# istio CA watching all namespaces
apiVersion: extensions/v1beta1
kind: Deployment
metadata:
  name: istio-citadel
  namespace: istio-system
  labels:
    app: security
    chart: security
    heritage: Tiller
    release: release-name
    istio: citadel
spec:
  replicas: 1
  strategy:
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  template:
    metadata:
      labels:
        app: security
        chart: security
        heritage: Tiller
        release: release-name
        istio: citadel
      annotations:
        sidecar.istio.io/inject: "false"
    spec:
      serviceAccountName: istio-citadel-service-account
      containers:
        - name: citadel
          image: "docker.io/istio/citadel:1.1.7"
          imagePullPolicy: IfNotPresent
          args:
            - --append-dns-names=true
            - --grpc-port=8060
            - --grpc-hostname=citadel
            - --citadel-storage-namespace=istio-system
            - --custom-dns-names=istio-pilot-service-account.istio-system:istio-pilot.istio-system
            - --monitoring-port=15014
            - --self-signed-ca=true
          livenessProbe:
            httpGet:
              path: /version
              port: 15014
            initialDelaySeconds: 5
            periodSeconds: 5
          resources:
            requests:
              cpu: 10m

      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: beta.kubernetes.io/arch
                operator: In
                values:
                - amd64
                - ppc64le
                - s390x
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 2
            preference:
              matchExpressions:
              - key: beta.kubernetes.io/arch
                operator: In
                values:
                - amd64
          - weight: 2
            preference:
              matchExpressions:
              - key: beta.kubernetes.io/arch
                operator: In
                values:
                - ppc64le
          - weight: 2
            preference:
              matchExpressions:
              - key: beta.kubernetes.io/arch
                operator: In
                values:
                - s390x

---
# Source: istio/charts/sidecarInjectorWebhook/templates/deployment.yaml
apiVersion: extensions/v1beta1
kind: Deployment
metadata:
  name: istio-sidecar-injector
  namespace: istio-system
  labels:
    app: sidecarInjectorWebhook
    chart: sidecarInjectorWebhook
    heritage: Tiller
    release: release-name
    istio: sidecar-injector
spec:
  replicas: 1
  strategy:
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  template:
    metadata:
      labels:
        app: sidecarInjectorWebhook
        chart: sidecarInjectorWebhook
        heritage: Tiller
        release: release-name
        istio: sidecar-injector
      annotations:
        sidecar.istio.io/inject: "false"
    spec:
      serviceAccountName: istio-sidecar-injector-service-account
      containers:
        - name: sidecar-injector-webhook
          image: "docker.io/istio/sidecar_injector:1.1.7"
          imagePullPolicy: IfNotPresent
          args:
            - --caCertFile=/etc/istio/certs/root-cert.pem
            - --tlsCertFile=/etc/istio/certs/cert-chain.pem
            - --tlsKeyFile=/etc/istio/certs/key.pem
            - --injectConfig=/etc/istio/inject/config
            - --meshConfig=/etc/istio/config/mesh
            - --healthCheckInterval=2s
            - --healthCheckFile=/health
          volumeMounts:
          - name: config-volume
            mountPath: /etc/istio/config
            readOnly: true
          - name: certs
            mountPath: /etc/istio/certs
            readOnly: true
          - name: inject-config
            mountPath: /etc/istio/inject
            readOnly: true
          livenessProbe:
            exec:
              command:
                - /usr/local/bin/sidecar-injector
                - probe
                - --probe-path=/health
                - --interval=4s
            initialDelaySeconds: 4
            periodSeconds: 4
          readinessProbe:
            exec:
              command:
                - /usr/local/bin/sidecar-injector
                - probe
                - --probe-path=/health
                - --interval=4s
            initialDelaySeconds: 4
            periodSeconds: 4
          resources:
            requests:
              cpu: 10m

      volumes:
      - name: config-volume
        configMap:
          name: istio
      - name: certs
        secret:
          secretName: istio.istio-sidecar-injector-service-account
      - name: inject-config
        configMap:
          name: istio-sidecar-injector
          items:
          - key: config
            path: config
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: beta.kubernetes.io/arch
                operator: In
                values:
                - amd64
                - ppc64le
                - s390x
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 2
            preference:
              matchExpressions:
              - key: beta.kubernetes.io/arch
                operator: In
                values:
                - amd64
          - weight: 2
            preference:
              matchExpressions:
              - key: beta.kubernetes.io/arch
                operator: In
                values:
                - ppc64le
          - weight: 2
            preference:
              matchExpressions:
              - key: beta.kubernetes.io/arch
                operator: In
                values:
                - s390x

---
# Source: istio/charts/gateways/templates/autoscale.yaml

apiVersion: autoscaling/v2beta1
kind: HorizontalPodAutoscaler
metadata:
  name: istio-ingressgateway
  namespace: istio-system
  labels:
    app: ingressgateway
    chart: gateways
    heritage: Tiller
    release: release-name
spec:
  maxReplicas: 1
  minReplicas: 1
  scaleTargetRef:
    apiVersion: apps/v1beta1
    kind: Deployment
    name: istio-ingressgateway
  metrics:
    - type: Resource
      resource:
        name: cpu
        targetAverageUtilization: 80
---

---
# Source: istio/charts/mixer/templates/autoscale.yaml

apiVersion: autoscaling/v2beta1
kind: HorizontalPodAutoscaler
metadata:
  name: istio-policy
  namespace: istio-system
  labels:
    app: mixer
    chart: mixer
    heritage: Tiller
    release: release-name
spec:
    maxReplicas: 5
    minReplicas: 1
    scaleTargetRef:
      apiVersion: apps/v1beta1
      kind: Deployment
      name: istio-policy
    metrics:
    - type: Resource
      resource:
        name: cpu
        targetAverageUtilization: 80
---
apiVersion: autoscaling/v2beta1
kind: HorizontalPodAutoscaler
metadata:
  name: istio-telemetry
  namespace: istio-system
  labels:
    app: mixer
    chart: mixer
    heritage: Tiller
    release: release-name
spec:
    maxReplicas: 5
    minReplicas: 1
    scaleTargetRef:
      apiVersion: apps/v1beta1
      kind: Deployment
      name: istio-telemetry
    metrics:
    - type: Resource
      resource:
        name: cpu
        targetAverageUtilization: 80
---

---
# Source: istio/charts/pilot/templates/autoscale.yaml

apiVersion: autoscaling/v2beta1
kind: HorizontalPodAutoscaler
metadata:
  name: istio-pilot
  namespace: istio-system
  labels:
    app: pilot
    chart: pilot
    heritage: Tiller
    release: release-name
spec:
  maxReplicas: 5
  minReplicas: 2
  scaleTargetRef:
    apiVersion: apps/v1beta1
    kind: Deployment
    name: istio-pilot
  metrics:
  - type: Resource
    resource:
      name: cpu
      targetAverageUtilization: 80
---

---
# Source: istio/charts/sidecarInjectorWebhook/templates/mutatingwebhook.yaml
apiVersion: admissionregistration.k8s.io/v1beta1
kind: MutatingWebhookConfiguration
metadata:
  name: istio-sidecar-injector
  namespace: istio-system
  labels:
    app: sidecarInjectorWebhook
    chart: sidecarInjectorWebhook
    heritage: Tiller
    release: release-name
webhooks:
  - name: sidecar-injector.istio.io
    clientConfig:
      service:
        name: istio-sidecar-injector
        namespace: istio-system
        path: "/inject"
      caBundle: ""
    rules:
      - operations: [ "CREATE" ]
        apiGroups: [""]
        apiVersions: ["v1"]
        resources: ["pods"]
    failurePolicy: Fail
    namespaceSelector:
      matchExpressions:
      - key: istio-injection
        operator: NotIn
        values:
        - disabled


---
# Source: istio/charts/galley/templates/validatingwebhookconfiguration.yaml.tpl


---
# Source: istio/charts/gateways/templates/preconfigured.yaml


---
# Source: istio/charts/pilot/templates/meshexpansion.yaml



---
# Source: istio/charts/security/templates/enable-mesh-mtls.yaml


---
# Source: istio/charts/security/templates/enable-mesh-permissive.yaml


---
# Source: istio/charts/security/templates/meshexpansion.yaml


---
# Source: istio/charts/security/templates/tests/test-citadel-connection.yaml


---
# Source: istio/templates/endpoints.yaml


---
# Source: istio/templates/install-custom-resources.sh.tpl


---
# Source: istio/templates/service.yaml


---
# Source: istio/charts/mixer/templates/config.yaml

apiVersion: "config.istio.io/v1alpha2"
kind: attributemanifest
metadata:
  name: istioproxy
  namespace: istio-system
  labels:
    app: mixer
    chart: mixer
    heritage: Tiller
    release: release-name
spec:
  attributes:
    origin.ip:
      valueType: IP_ADDRESS
    origin.uid:
      valueType: STRING
    origin.user:
      valueType: STRING
    request.headers:
      valueType: STRING_MAP
    request.id:
      valueType: STRING
    request.host:
      valueType: STRING
    request.method:
      valueType: STRING
    request.path:
      valueType: STRING
    request.url_path:
      valueType: STRING
    request.query_params:
      valueType: STRING_MAP
    request.reason:
      valueType: STRING
    request.referer:
      valueType: STRING
    request.scheme:
      valueType: STRING
    request.total_size:
      valueType: INT64
    request.size:
      valueType: INT64
    request.time:
      valueType: TIMESTAMP
    request.useragent:
      valueType: STRING
    response.code:
      valueType: INT64
    response.duration:
      valueType: DURATION
    response.headers:
      valueType: STRING_MAP
    response.total_size:
      valueType: INT64
    response.size:
      valueType: INT64
    response.time:
      valueType: TIMESTAMP
    response.grpc_status:
      valueType: STRING
    response.grpc_message:
      valueType: STRING
    source.uid:
      valueType: STRING
    source.user: # DEPRECATED
      valueType: STRING
    source.principal:
      valueType: STRING
    destination.uid:
      valueType: STRING
    destination.principal:
      valueType: STRING
    destination.port:
      valueType: INT64
    connection.event:
      valueType: STRING
    connection.id:
      valueType: STRING
    connection.received.bytes:
      valueType: INT64
    connection.received.bytes_total:
      valueType: INT64
    connection.sent.bytes:
      valueType: INT64
    connection.sent.bytes_total:
      valueType: INT64
    connection.duration:
      valueType: DURATION
    connection.mtls:
      valueType: BOOL
    connection.requested_server_name:
      valueType: STRING
    context.protocol:
      valueType: STRING
    context.proxy_error_code:
      valueType: STRING
    context.timestamp:
      valueType: TIMESTAMP
    context.time:
      valueType: TIMESTAMP
    # Deprecated, kept for compatibility
    context.reporter.local:
      valueType: BOOL
    context.reporter.kind:
      valueType: STRING
    context.reporter.uid:
      valueType: STRING
    api.service:
      valueType: STRING
    api.version:
      valueType: STRING
    api.operation:
      valueType: STRING
    api.protocol:
      valueType: STRING
    request.auth.principal:
      valueType: STRING
    request.auth.audiences:
      valueType: STRING
    request.auth.presenter:
      valueType: STRING
    request.auth.claims:
      valueType: STRING_MAP
    request.auth.raw_claims:
      valueType: STRING
    request.api_key:
      valueType: STRING
    rbac.permissive.response_code:
      valueType: STRING
    rbac.permissive.effective_policy_id:
      valueType: STRING
    check.error_code:
      valueType: INT64
    check.error_message:
      valueType: STRING
    check.cache_hit:
      valueType: BOOL
    quota.cache_hit:
      valueType: BOOL

---
apiVersion: "config.istio.io/v1alpha2"
kind: attributemanifest
metadata:
  name: kubernetes
  namespace: istio-system
  labels:
    app: mixer
    chart: mixer
    heritage: Tiller
    release: release-name
spec:
  attributes:
    source.ip:
      valueType: IP_ADDRESS
    source.labels:
      valueType: STRING_MAP
    source.metadata:
      valueType: STRING_MAP
    source.name:
      valueType: STRING
    source.namespace:
      valueType: STRING
    source.owner:
      valueType: STRING
    source.serviceAccount:
      valueType: STRING
    source.services:
      valueType: STRING
    source.workload.uid:
      valueType: STRING
    source.workload.name:
      valueType: STRING
    source.workload.namespace:
      valueType: STRING
    destination.ip:
      valueType: IP_ADDRESS
    destination.labels:
      valueType: STRING_MAP
    destination.metadata:
      valueType: STRING_MAP
    destination.owner:
      valueType: STRING
    destination.name:
      valueType: STRING
    destination.container.name:
      valueType: STRING
    destination.namespace:
      valueType: STRING
    destination.service.uid:
      valueType: STRING
    destination.service.name:
      valueType: STRING
    destination.service.namespace:
      valueType: STRING
    destination.service.host:
      valueType: STRING
    destination.serviceAccount:
      valueType: STRING
    destination.workload.uid:
      valueType: STRING
    destination.workload.name:
      valueType: STRING
    destination.workload.namespace:
      valueType: STRING
---
---
---
apiVersion: "config.istio.io/v1alpha2"
kind: handler
metadata:
  name: kubernetesenv
  namespace: istio-system
  labels:
    app: mixer
    chart: mixer
    heritage: Tiller
    release: release-name
spec:
  compiledAdapter: kubernetesenv
  params:
    # when running from mixer root, use the following config after adding a
    # symbolic link to a kubernetes config file via:
    #
    # $ ln -s ~/.kube/config mixer/adapter/kubernetes/kubeconfig
    #
    # kubeconfig_path: "mixer/adapter/kubernetes/kubeconfig"

---
apiVersion: "config.istio.io/v1alpha2"
kind: rule
metadata:
  name: kubeattrgenrulerule
  namespace: istio-system
  labels:
    app: mixer
    chart: mixer
    heritage: Tiller
    release: release-name
spec:
  actions:
  - handler: kubernetesenv
    instances:
    - attributes.kubernetes
---
apiVersion: "config.istio.io/v1alpha2"
kind: rule
metadata:
  name: tcpkubeattrgenrulerule
  namespace: istio-system
  labels:
    app: mixer
    chart: mixer
    heritage: Tiller
    release: release-name
spec:
  match: context.protocol == "tcp"
  actions:
  - handler: kubernetesenv
    instances:
    - attributes.kubernetes
---
apiVersion: "config.istio.io/v1alpha2"
kind: kubernetes
metadata:
  name: attributes
  namespace: istio-system
  labels:
    app: mixer
    chart: mixer
    heritage: Tiller
    release: release-name
spec:
  # Pass the required attribute data to the adapter
  source_uid: source.uid | ""
  source_ip: source.ip | ip("0.0.0.0") # default to unspecified ip addr
  destination_uid: destination.uid | ""
  destination_port: destination.port | 0
  attribute_bindings:
    # Fill the new attributes from the adapter produced output.
    # $out refers to an instance of OutputTemplate message
    source.ip: $out.source_pod_ip | ip("0.0.0.0")
    source.uid: $out.source_pod_uid | "unknown"
    source.labels: $out.source_labels | emptyStringMap()
    source.name: $out.source_pod_name | "unknown"
    source.namespace: $out.source_namespace | "default"
    source.owner: $out.source_owner | "unknown"
    source.serviceAccount: $out.source_service_account_name | "unknown"
    source.workload.uid: $out.source_workload_uid | "unknown"
    source.workload.name: $out.source_workload_name | "unknown"
    source.workload.namespace: $out.source_workload_namespace | "unknown"
    destination.ip: $out.destination_pod_ip | ip("0.0.0.0")
    destination.uid: $out.destination_pod_uid | "unknown"
    destination.labels: $out.destination_labels | emptyStringMap()
    destination.name: $out.destination_pod_name | "unknown"
    destination.container.name: $out.destination_container_name | "unknown"
    destination.namespace: $out.destination_namespace | "default"
    destination.owner: $out.destination_owner | "unknown"
    destination.serviceAccount: $out.destination_service_account_name | "unknown"
    destination.workload.uid: $out.destination_workload_uid | "unknown"
    destination.workload.name: $out.destination_workload_name | "unknown"
    destination.workload.namespace: $out.destination_workload_namespace | "unknown"
---
# Configuration needed by Mixer.
# Mixer cluster is delivered via CDS
# Specify mixer cluster settings
apiVersion: networking.istio.io/v1alpha3
kind: DestinationRule
metadata:
  name: istio-policy
  namespace: istio-system
  labels:
    app: mixer
    chart: mixer
    heritage: Tiller
    release: release-name
spec:
  host: istio-policy.istio-system.svc.cluster.local
  trafficPolicy:
    connectionPool:
      http:
        http2MaxRequests: 10000
        maxRequestsPerConnection: 10000
---
apiVersion: networking.istio.io/v1alpha3
kind: DestinationRule
metadata:
  name: istio-telemetry
  namespace: istio-system
  labels:
    app: mixer
    chart: mixer
    heritage: Tiller
    release: release-name
spec:
  host: istio-telemetry.istio-system.svc.cluster.local
  trafficPolicy:
    connectionPool:
      http:
        http2MaxRequests: 10000
        maxRequestsPerConnection: 10000
---'
echo "$ISTIO_DEPLOY_YAML" > $ISTIO_DEPLOY
    }


	printf "Wait for Openstack controller manager"
	until  [[ "$(kubectl get pod -n kube-system | grep openstack-cloud-controller-manager)" == *"openstack-cloud-controller-manager"* ]]
	do
		sleep 5
	done
	
    printf "apply ${step}\n"
    kubectl apply --validate=false -f $ISTIO_DEPLOY
fi

printf "Finished running ${step}\n"
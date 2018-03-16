#!/bin/bash
set -e

# List of etcd servers (http://ip:port), comma separated
export ETCD_ENDPOINTS=

# Interface to be mapped
export FLANNEL_IFACE=

# Specify the version (vX.Y.Z) of Kubernetes assets to deploy
# https://kubernetes.io/docs/reference/workloads-18-19/
export K8S_VER=v1.9.3_coreos.0

# Hyperkube image repository to use.
export HYPERKUBE_IMAGE_REPO=quay.io/coreos/hyperkube

# CNI plugin
# https://github.com/containernetworking/plugins/releases
export CNI_VER=0.7.0

# The CIDR network to use for pod IPs.
# Each pod launched in the cluster will be assigned an IP out of this range.
# Each node will be configured such that these IPs will be routable using the flannel overlay network.
export POD_NETWORK=10.2.0.0/16

# The CIDR network to use for service cluster IPs.
# Each service will be assigned a cluster IP out of this range.
# This must not overlap with any IP ranges assigned to the POD_NETWORK, or other existing network infrastructure.
# Routing to these IPs is handled by a proxy service local to each node, and are not required to be routable between nodes.
export SERVICE_IP_RANGE=10.3.0.0/24

# The IP address of the Kubernetes API Service
# If the SERVICE_IP_RANGE is changed above, this must be set to the first IP in that range.
export K8S_SERVICE_IP=10.3.0.1

# The IP address of the cluster DNS service.
# This IP must be in the range of the SERVICE_IP_RANGE and cannot be the first IP in the range.
# This same IP must be configured on all worker nodes to enable DNS service discovery.
export DNS_SERVICE_IP=10.3.0.10

# Whether to use Calico for Kubernetes network policy.
export USE_CALICO=false

# Determines the container runtime for kubernetes to use. Accepts 'docker' or 'rkt'.
export CONTAINER_RUNTIME=docker

# The above settings can optionally be overridden using an environment file:
ENV_FILE=/run/coreos-kubernetes/options.env

# To run a self hosted Calico install it needs to be able to write to the CNI dir
if [ "${USE_CALICO}" = "true" ]; then
    export CALICO_OPTS="--volume cni-bin,kind=host,source=/opt/cni/bin \
                        --mount volume=cni-bin,target=/opt/cni/bin"
else
    export CALICO_OPTS=""
fi

# -------------

function init_config {
    local REQUIRED=('ADVERTISE_IP' 'POD_NETWORK' 'ETCD_ENDPOINTS' 'SERVICE_IP_RANGE' 'K8S_SERVICE_IP' 'DNS_SERVICE_IP' 'K8S_VER' 'HYPERKUBE_IMAGE_REPO' 'USE_CALICO')

    if [ -f $ENV_FILE ]; then
        export $(cat $ENV_FILE | xargs)
    fi

    if [ -z $ADVERTISE_IP ]; then
        export ADVERTISE_IP=$(awk -F= '/COREOS_PUBLIC_IPV4/ {print $2}' /etc/environment)
    fi

    for REQ in "${REQUIRED[@]}"; do
        if [ -z "$(eval echo \$$REQ)" ]; then
            echo "Missing required config value: ${REQ}"
            exit 1
        fi
    done
}


# https://github.com/coreos/flannel/issues/535
function init_flannel {
    echo "Waiting for etcd..."
    while true
    do
        IFS=',' read -ra ES <<< "$ETCD_ENDPOINTS"
        for ETCD in "${ES[@]}"; do
            echo "Trying: $ETCD"
            if [ -n "$(curl --silent "$ETCD/v2/machines")" ]; then
                local ACTIVE_ETCD=$ETCD
                break
            fi
            sleep 1
        done
        if [ -n "$ACTIVE_ETCD" ]; then
            break
        fi
    done
    RES=$(curl --silent -X PUT -d "value={\"Network\":\"$POD_NETWORK\",\"Backend\":{\"Type\":\"vxlan\"}}" "$ACTIVE_ETCD/v2/keys/coreos.com/network/config?prevExist=false")
    if [ -z "$(echo $RES | grep '"action":"create"')" ] && [ -z "$(echo $RES | grep 'Key already exists')" ]; then
        echo "Unexpected error configuring flannel pod network: $RES"
    fi
    
    local TEMPLATE=/srv/kubernetes/manifests/flannel.yaml
    if [ ! -f $TEMPLATE ]; then
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
---
kind: ClusterRole
apiVersion: rbac.authorization.k8s.io/v1beta1
metadata:
  name: flannel
rules:
  - apiGroups:
      - ""
    resources:
      - pods
    verbs:
      - get
  - apiGroups:
      - ""
    resources:
      - nodes
    verbs:
      - list
      - watch
  - apiGroups:
      - ""
    resources:
      - nodes/status
    verbs:
      - patch
---
kind: ClusterRoleBinding
apiVersion: rbac.authorization.k8s.io/v1beta1
metadata:
  name: flannel
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: flannel
subjects:
- kind: ServiceAccount
  name: flannel
  namespace: kube-system
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: flannel
  namespace: kube-system
---
kind: ConfigMap
apiVersion: v1
metadata:
  name: kube-flannel-cfg
  namespace: kube-system
  labels:
    tier: node
    app: flannel
data:
  cni-conf.json: |
    {
      "name": "cbr0",
      "plugins": [
        {
          "type": "flannel",
          "delegate": {
            "hairpinMode": true,
            "isDefaultGateway": true
          }
        },
        {
          "type": "portmap",
          "capabilities": {
            "portMappings": true
          }
        }
      ]
    }
  net-conf.json: |
    {
      "Network": "${POD_NETWORK}",
      "Backend": {
        "Type": "vxlan"
      }
    }
---
apiVersion: extensions/v1beta1
kind: DaemonSet
metadata:
  name: kube-flannel-ds
  namespace: kube-system
  labels:
    tier: node
    app: flannel
spec:
  template:
    metadata:
      labels:
        tier: node
        app: flannel
    spec:
      hostNetwork: true
      nodeSelector:
        beta.kubernetes.io/arch: amd64
      tolerations:
      - key: node-role.kubernetes.io/master
        operator: Exists
        effect: NoSchedule
      serviceAccountName: flannel
      initContainers:
      - name: install-cni
        image: quay.io/coreos/flannel:v0.10.0-amd64
        command:
        - cp
        args:
        - -f
        - /etc/kube-flannel/cni-conf.json
        - /etc/cni/net.d/10-flannel.conflist
        volumeMounts:
        - name: cni
          mountPath: /etc/cni/net.d
        - name: flannel-cfg
          mountPath: /etc/kube-flannel/
      containers:
      - name: kube-flannel
        image: quay.io/coreos/flannel:v0.10.0-amd64
        command:
        - /opt/bin/flanneld
        args:
        - --ip-masq
        - --iface=${FLANNEL_IFACE}
        #- --kube-subnet-mgr
        #- -v 10
        resources:
          requests:
            cpu: "100m"
            memory: "50Mi"
          limits:
            cpu: "100m"
            memory: "50Mi"
        securityContext:
          privileged: true
        env:
        - name: POD_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        - name: POD_NAMESPACE
          valueFrom:
            fieldRef:
              fieldPath: metadata.namespace
        - name: FLANNELD_ETCD_ENDPOINTS
          value: ${ETCD_ENDPOINTS}
        - name: FLANNELD_ETCD_PREFIX
          value: /coreos.com/network
        volumeMounts:
        - name: run
          mountPath: /run
        - name: flannel-cfg
          mountPath: /etc/kube-flannel/
      volumes:
        - name: run
          hostPath:
            path: /run
        - name: cni
          hostPath:
            path: /etc/cni/net.d
        - name: flannel-cfg
          configMap:
            name: kube-flannel-cfg
EOF
    fi
}

function init_templates {
    local TEMPLATE=/etc/systemd/system/kubelet.service
    local uuid_file="/var/run/kubelet-pod.uuid"
    if [ ! -f $TEMPLATE ]; then
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
[Service]
Environment=PATH=/opt/bin/:/usr/bin/:/usr/sbin:${PATH}
Environment=KUBELET_IMAGE_TAG=${K8S_VER}
Environment=KUBELET_IMAGE_URL=${HYPERKUBE_IMAGE_REPO}
Environment="RKT_RUN_ARGS=--uuid-file-save=${uuid_file} \
  --volume dns,kind=host,source=/etc/resolv.conf \
  --mount volume=dns,target=/etc/resolv.conf \
  --volume rkt,kind=host,source=/opt/bin/host-rkt \
  --mount volume=rkt,target=/usr/bin/rkt \
  --volume var-lib-rkt,kind=host,source=/var/lib/rkt \
  --mount volume=var-lib-rkt,target=/var/lib/rkt \
  --volume stage,kind=host,source=/tmp \
  --mount volume=stage,target=/tmp \
  --volume var-log,kind=host,source=/var/log \
  --mount volume=var-log,target=/var/log \
  --volume modprobe,kind=host,source=/usr/sbin/modprobe \
  --mount volume=modprobe,target=/usr/sbin/modprobe \
  --volume lib-modules,kind=host,source=/lib/modules \
  --mount volume=lib-modules,target=/lib/modules \
  --volume etc-cni-netd,kind=host,source=/etc/cni/net.d \
  --mount volume=etc-cni-netd,target=/etc/cni/net.d \
  ${CALICO_OPTS}"
ExecStartPre=/usr/bin/mkdir -p /etc/kubernetes/manifests
ExecStartPre=/usr/bin/mkdir -p /opt/cni/bin
ExecStartPre=/usr/bin/mkdir -p /etc/cni/net.d
ExecStartPre=/usr/bin/mkdir -p /var/log/containers
ExecStartPre=-/usr/bin/rkt rm --uuid-file=${uuid_file}
ExecStart=/usr/lib/coreos/kubelet-wrapper \
  --kubeconfig=/etc/kubernetes/master-kubeconfig.yaml \
  --register-schedulable=false \
  --cni-conf-dir=/etc/cni/net.d \
  --cni-bin-dir=/opt/cni/bin \
  --network-plugin=cni \
  --container-runtime=${CONTAINER_RUNTIME} \
  --rkt-path=/usr/bin/rkt \
  --allow-privileged=true \
  --pod-manifest-path=/etc/kubernetes/manifests \
  --hostname-override=${ADVERTISE_IP} \
  --cluster_dns=${DNS_SERVICE_IP} \
  --cluster_domain=cluster.local \
  --volume-plugin-dir=/etc/kubernetes/volumeplugins
ExecStop=-/usr/bin/rkt stop --uuid-file=${uuid_file}
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
    fi

    local TEMPLATE=/etc/kubernetes/master-kubeconfig.yaml
    if [ ! -f $TEMPLATE ]; then
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
apiVersion: v1
kind: Config
clusters:
- name: local
  cluster:
    server: http://127.0.0.1:8080
users:
- name: kubelet
contexts:
- context:
    cluster: local
    user: kubelet
  name: kubelet-context
current-context: kubelet-context
EOF
    fi

    local TEMPLATE=/opt/bin/host-rkt
    if [ ! -f $TEMPLATE ]; then
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
#!/bin/sh
# This is bind mounted into the kubelet rootfs and all rkt shell-outs go
# through this rkt wrapper. It essentially enters the host mount namespace
# (which it is already in) only for the purpose of breaking out of the chroot
# before calling rkt. It makes things like rkt gc work and avoids bind mounting
# in certain rkt filesystem dependancies into the kubelet rootfs. This can
# eventually be obviated when the write-api stuff gets upstream and rkt gc is
# through the api-server. Related issue:
# https://github.com/coreos/rkt/issues/2878
exec nsenter -m -u -i -n -p -t 1 -- /usr/bin/rkt "\$@"
EOF
    fi


    local TEMPLATE=/etc/systemd/system/load-rkt-stage1.service
    if [ ${CONTAINER_RUNTIME} = "rkt" ] && [ ! -f $TEMPLATE ]; then
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
[Unit]
Description=Load rkt stage1 images
Documentation=http://github.com/coreos/rkt
Requires=network-online.target
After=network-online.target
Before=rkt-api.service

[Service]
RemainAfterExit=yes
Type=oneshot
ExecStart=/usr/bin/rkt fetch /usr/lib/rkt/stage1-images/stage1-coreos.aci /usr/lib/rkt/stage1-images/stage1-fly.aci  --insecure-options=image

[Install]
RequiredBy=rkt-api.service
EOF
    fi

    local TEMPLATE=/etc/systemd/system/rkt-api.service
    if [ ${CONTAINER_RUNTIME} = "rkt" ] && [ ! -f $TEMPLATE ]; then
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
[Unit]
Before=kubelet.service

[Service]
ExecStart=/usr/bin/rkt api-service
Restart=always
RestartSec=10

[Install]
RequiredBy=kubelet.service
EOF
    fi

    local TEMPLATE=/etc/kubernetes/manifests/kube-proxy.yaml
    if [ ! -f $TEMPLATE ]; then
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
apiVersion: v1
kind: Pod
metadata:
  name: kube-proxy
  namespace: kube-system
  annotations:
    rkt.alpha.kubernetes.io/stage1-name-override: coreos.com/rkt/stage1-fly
spec:
  hostNetwork: true
  containers:
  - name: kube-proxy
    image: ${HYPERKUBE_IMAGE_REPO}:$K8S_VER
    command:
    - /hyperkube
    - proxy
    - --master=http://127.0.0.1:8080
    - --cluster-cidr=${POD_NETWORK}
    - --masquerade-all
    - --v=2
    securityContext:
      privileged: true
    volumeMounts:
    - mountPath: /etc/ssl/certs
      name: ssl-certs-host
      readOnly: true
    - mountPath: /var/run/dbus
      name: dbus
      readOnly: false
  volumes:
  - hostPath:
      path: /usr/share/ca-certificates
    name: ssl-certs-host
  - hostPath:
      path: /var/run/dbus
    name: dbus
EOF
    fi

    local TEMPLATE=/etc/kubernetes/manifests/kube-apiserver.yaml
    if [ ! -f $TEMPLATE ]; then
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
apiVersion: v1
kind: Pod
metadata:
  name: kube-apiserver
  namespace: kube-system
spec:
  hostNetwork: true
  containers:
  - name: kube-apiserver
    image: ${HYPERKUBE_IMAGE_REPO}:$K8S_VER
    command:
    - /hyperkube
    - apiserver
    - --bind-address=0.0.0.0
    - --etcd-servers=${ETCD_ENDPOINTS}
    - --allow-privileged=true
    - --authorization-mode=RBAC
    - --service-cluster-ip-range=${SERVICE_IP_RANGE}
    - --secure-port=443
    - --advertise-address=${ADVERTISE_IP}
    - --admission-control=NamespaceLifecycle,LimitRanger,ServiceAccount,DefaultStorageClass,ResourceQuota
    - --tls-cert-file=/etc/kubernetes/ssl/apiserver.pem
    - --tls-private-key-file=/etc/kubernetes/ssl/apiserver-key.pem
    - --client-ca-file=/etc/kubernetes/ssl/ca.pem
    - --service-account-key-file=/etc/kubernetes/ssl/apiserver-key.pem
    - --runtime-config=extensions/v1beta1/networkpolicies=true
    - --anonymous-auth=false
    - --storage-backend=etcd3
    - --storage-media-type=application/json
    - --v=2
    livenessProbe:
      httpGet:
        host: 127.0.0.1
        port: 8080
        path: /healthz
      initialDelaySeconds: 15
      timeoutSeconds: 15
    ports:
    - containerPort: 443
      hostPort: 443
      name: https
    - containerPort: 7080
      hostPort: 7080
    - containerPort: 8080
      hostPort: 8080
      name: local
    volumeMounts:
    - mountPath: /etc/kubernetes/ssl
      name: ssl-certs-kubernetes
      readOnly: true
    - mountPath: /etc/ssl/certs
      name: ssl-certs-host
      readOnly: true
  volumes:
  - hostPath:
      path: /etc/kubernetes/ssl
    name: ssl-certs-kubernetes
  - hostPath:
      path: /usr/share/ca-certificates
    name: ssl-certs-host
EOF
    fi

    local TEMPLATE=/etc/kubernetes/manifests/kube-controller-manager.yaml
    if [ ! -f $TEMPLATE ]; then
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
apiVersion: v1
kind: Pod
metadata:
  name: kube-controller-manager
  namespace: kube-system
spec:
  containers:
  - name: kube-controller-manager
    image: ${HYPERKUBE_IMAGE_REPO}:$K8S_VER
    command:
    - /hyperkube
    - controller-manager
    - --master=http://127.0.0.1:8080
    - --leader-elect=true
    - --service-account-private-key-file=/etc/kubernetes/ssl/apiserver-key.pem
    - --root-ca-file=/etc/kubernetes/ssl/ca.pem
    - --flex-volume-plugin-dir=/etc/kubernetes/volumeplugins
    - --v=2
    resources:
      requests:
        cpu: 200m
    livenessProbe:
      httpGet:
        host: 127.0.0.1
        path: /healthz
        port: 10252
      initialDelaySeconds: 15
      timeoutSeconds: 15
    volumeMounts:
    - mountPath: /etc/kubernetes/ssl
      name: ssl-certs-kubernetes
      readOnly: true
    - mountPath: /etc/ssl/certs
      name: ssl-certs-host
      readOnly: true
    - mountPath: /etc/kubernetes/volumeplugins
      name: volumeplugins-host
      readonly: false
  hostNetwork: true
  volumes:
  - hostPath:
      path: /etc/kubernetes/ssl
    name: ssl-certs-kubernetes
  - hostPath:
      path: /usr/share/ca-certificates
    name: ssl-certs-host
  - hostPath:
      path: /etc/kubernetes/volumeplugins
    name: volumeplugins-host
EOF
    fi

    local TEMPLATE=/etc/kubernetes/manifests/kube-scheduler.yaml
    if [ ! -f $TEMPLATE ]; then
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
apiVersion: v1
kind: Pod
metadata:
  name: kube-scheduler
  namespace: kube-system
spec:
  hostNetwork: true
  containers:
  - name: kube-scheduler
    image: ${HYPERKUBE_IMAGE_REPO}:$K8S_VER
    command:
    - /hyperkube
    - scheduler
    - --master=http://127.0.0.1:8080
    - --leader-elect=true
    - --v=2
    resources:
      requests:
        cpu: 100m
    livenessProbe:
      httpGet:
        host: 127.0.0.1
        path: /healthz
        port: 10251
      initialDelaySeconds: 15
      timeoutSeconds: 15
EOF
    fi

    local TEMPLATE=/srv/kubernetes/manifests/add-on-cluster-admin-crb.yaml
    if [ ! -f $TEMPLATE ]; then
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: add-on-cluster-admin
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: default
  namespace: kube-system
EOF
    fi

    local TEMPLATE=/srv/kubernetes/manifests/kube-dns-de.yaml
    if [ ! -f $TEMPLATE ]; then
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
apiVersion: apps/v1beta1
kind: Deployment
metadata:
  name: kube-dns
  namespace: kube-system
  labels:
    k8s-app: kube-dns
    kubernetes.io/cluster-service: "true"
    addonmanager.kubernetes.io/mode: Reconcile
spec:
  # replicas: not specified here:
  # 1. In order to make Addon Manager do not reconcile this replicas parameter.
  # 2. Default is 1.
  # 3. Will be tuned in real time if DNS horizontal auto-scaling is turned on.
  strategy:
    rollingUpdate:
      maxSurge: 10%
      maxUnavailable: 0
  selector:
    matchLabels:
      k8s-app: kube-dns
  template:
    metadata:
      labels:
        k8s-app: kube-dns
      annotations:
        scheduler.alpha.kubernetes.io/critical-pod: ''
        scheduler.alpha.kubernetes.io/tolerations: '[{"key":"CriticalAddonsOnly", "operator":"Exists"}]'
    spec:
      priorityClassName: system-cluster-critical
      tolerations:
      - key: "CriticalAddonsOnly"
        operator: "Exists"
      volumes:
      - name: kube-dns-config
        configMap:
          name: kube-dns
          optional: true
      containers:
      - name: kubedns
        image: k8s.gcr.io/k8s-dns-kube-dns-amd64:1.14.8
        resources:
          # TODO: Set memory limits when we've profiled the container for large
          # clusters, then set request = limit to keep this container in
          # guaranteed class. Currently, this container falls into the
          # "burstable" category so the kubelet doesn't backoff from restarting it.
          limits:
            memory: 170Mi
          requests:
            cpu: 100m
            memory: 70Mi
        livenessProbe:
          httpGet:
            path: /healthcheck/kubedns
            port: 10054
            scheme: HTTP
          initialDelaySeconds: 60
          timeoutSeconds: 5
          successThreshold: 1
          failureThreshold: 5
        readinessProbe:
          httpGet:
            path: /readiness
            port: 8081
            scheme: HTTP
          # we poll on pod startup for the Kubernetes master service and
          # only setup the /readiness HTTP server once that's available.
          initialDelaySeconds: 3
          timeoutSeconds: 5
        args:
        - --domain=cluster.local.
        - --dns-port=10053
        - --config-dir=/kube-dns-config
        - --v=2
        env:
        - name: PROMETHEUS_PORT
          value: "10055"
        ports:
        - containerPort: 10053
          name: dns-local
          protocol: UDP
        - containerPort: 10053
          name: dns-tcp-local
          protocol: TCP
        - containerPort: 10055
          name: metrics
          protocol: TCP
        volumeMounts:
        - name: kube-dns-config
          mountPath: /kube-dns-config
      - name: dnsmasq
        image: k8s.gcr.io/k8s-dns-dnsmasq-nanny-amd64:1.14.8
        livenessProbe:
          httpGet:
            path: /healthcheck/dnsmasq
            port: 10054
            scheme: HTTP
          initialDelaySeconds: 60
          timeoutSeconds: 5
          successThreshold: 1
          failureThreshold: 5
        args:
        - -v=2
        - -logtostderr
        - -configDir=/etc/k8s/dns/dnsmasq-nanny
        - -restartDnsmasq=true
        - --
        - -k
        - --cache-size=1000
        - --no-negcache
        - --log-facility=-
        - --server=/cluster.local/127.0.0.1#10053
        - --server=/in-addr.arpa/127.0.0.1#10053
        - --server=/ip6.arpa/127.0.0.1#10053
        ports:
        - containerPort: 53
          name: dns
          protocol: UDP
        - containerPort: 53
          name: dns-tcp
          protocol: TCP
        # see: https://github.com/kubernetes/kubernetes/issues/29055 for details
        resources:
          requests:
            cpu: 150m
            memory: 20Mi
        volumeMounts:
        - name: kube-dns-config
          mountPath: /etc/k8s/dns/dnsmasq-nanny
      - name: sidecar
        image: k8s.gcr.io/k8s-dns-sidecar-amd64:1.14.8
        livenessProbe:
          httpGet:
            path: /metrics
            port: 10054
            scheme: HTTP
          initialDelaySeconds: 60
          timeoutSeconds: 5
          successThreshold: 1
          failureThreshold: 5
        args:
        - --v=2
        - --logtostderr
        - --probe=kubedns,127.0.0.1:10053,kubernetes.default.svc.cluster.local,5,SRV
        - --probe=dnsmasq,127.0.0.1:53,kubernetes.default.svc.cluster.local,5,SRV
        ports:
        - containerPort: 10054
          name: metrics
          protocol: TCP
        resources:
          requests:
            memory: 20Mi
            cpu: 10m
      dnsPolicy: Default  # Don't use cluster DNS.
      serviceAccountName: kube-dns
EOF
    fi

    local TEMPLATE=/srv/kubernetes/manifests/kube-dns-svc.yaml
    if [ ! -f $TEMPLATE ]; then
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
apiVersion: v1
kind: Service
metadata:
  name: kube-dns
  namespace: kube-system
  labels:
    k8s-app: kube-dns
    kubernetes.io/cluster-service: "true"
    addonmanager.kubernetes.io/mode: Reconcile
    kubernetes.io/name: "KubeDNS"
spec:
  selector:
    k8s-app: kube-dns
  clusterIP: ${DNS_SERVICE_IP}
  ports:
  - name: dns
    port: 53
    protocol: UDP
  - name: dns-tcp
    port: 53
    protocol: TCP
EOF
    fi

    local TEMPLATE=/srv/kubernetes/manifests/kube-dns-sa.yaml
    if [ ! -f $TEMPLATE ]; then
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
apiVersion: v1
kind: ServiceAccount
metadata:
  name: kube-dns
  namespace: kube-system
  labels:
    kubernetes.io/cluster-service: "true"
    addonmanager.kubernetes.io/mode: Reconcile
EOF
    fi

    local TEMPLATE=/srv/kubernetes/manifests/kube-dns-cm.yaml
    if [ ! -f $TEMPLATE ]; then
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
apiVersion: v1
kind: ConfigMap
metadata:
  name: kube-dns
  namespace: kube-system
  labels:
    addonmanager.kubernetes.io/mode: EnsureExists
EOF
    fi

    local TEMPLATE=/srv/kubernetes/manifests/kube-dns-autoscaler-de.yaml
    if [ ! -f $TEMPLATE ]; then
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
apiVersion: apps/v1beta2
kind: Deployment
metadata:
  name: kube-dns-autoscaler
  namespace: kube-system
  labels:
    k8s-app: kube-dns-autoscaler
    kubernetes.io/cluster-service: "true"
    addonmanager.kubernetes.io/mode: Reconcile
spec:
  selector:
    matchLabels:
      k8s-app: kube-dns-autoscaler
  template:
    metadata:
      labels:
        k8s-app: kube-dns-autoscaler
      annotations:
        scheduler.alpha.kubernetes.io/critical-pod: ''
        scheduler.alpha.kubernetes.io/tolerations: '[{"key":"CriticalAddonsOnly", "operator":"Exists"}]'
    spec:
      priorityClassName: system-cluster-critical
      containers:
      - name: autoscaler
        image: k8s.gcr.io/cluster-proportional-autoscaler-amd64:1.1.2-r2
        resources:
            requests:
                cpu: "20m"
                memory: "10Mi"
        command:
          - /cluster-proportional-autoscaler
          - --namespace=kube-system
          - --configmap=kube-dns-autoscaler
          # Should keep target in sync with cluster/addons/dns/kube-dns.yaml.base
          - --target=Deployment/kube-dns
          # When cluster is using large nodes(with more cores), "coresPerReplica" should dominate.
          # If using small nodes, "nodesPerReplica" should dominate.
          - --default-params={"linear":{"coresPerReplica":256,"nodesPerReplica":16,"preventSinglePointFailure":true}}
          - --logtostderr=true
          - --v=2
      tolerations:
      - key: "CriticalAddonsOnly"
        operator: "Exists"
      serviceAccountName: kube-dns-autoscaler
EOF
    fi

    local TEMPLATE=/srv/kubernetes/manifests/kube-dns-autoscaler-sa.yaml
    if [ ! -f $TEMPLATE ]; then
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
kind: ServiceAccount
apiVersion: v1
metadata:
  name: kube-dns-autoscaler
  namespace: kube-system
  labels:
    addonmanager.kubernetes.io/mode: Reconcile
EOF
    fi

    local TEMPLATE=/srv/kubernetes/manifests/kube-dns-autoscaler-rbac.yaml
    if [ ! -f $TEMPLATE ]; then
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
kind: ClusterRole
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: system:kube-dns-autoscaler
  labels:
    addonmanager.kubernetes.io/mode: Reconcile
rules:
  - apiGroups: [""]
    resources: ["nodes"]
    verbs: ["list"]
  - apiGroups: [""]
    resources: ["replicationcontrollers/scale"]
    verbs: ["get", "update"]
  - apiGroups: ["extensions"]
    resources: ["deployments/scale", "replicasets/scale"]
    verbs: ["get", "update"]
# Remove the configmaps rule once below issue is fixed:
# kubernetes-incubator/cluster-proportional-autoscaler#16
  - apiGroups: [""]
    resources: ["configmaps"]
    verbs: ["get", "create"]
---
kind: ClusterRoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: system:kube-dns-autoscaler
  labels:
    addonmanager.kubernetes.io/mode: Reconcile
subjects:
  - kind: ServiceAccount
    name: kube-dns-autoscaler
    namespace: kube-system
roleRef:
  kind: ClusterRole
  name: system:kube-dns-autoscaler
  apiGroup: rbac.authorization.k8s.io
EOF
    fi

    local TEMPLATE=/srv/kubernetes/manifests/heapster-de.yaml
    if [ ! -f $TEMPLATE ]; then
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
apiVersion: extensions/v1beta1
kind: Deployment
metadata:
  name: heapster-v1.5.1
  namespace: kube-system
  labels:
    k8s-app: heapster
    kubernetes.io/cluster-service: "true"
    addonmanager.kubernetes.io/mode: Reconcile
    version: v1.5.1
spec:
  replicas: 1
  selector:
    matchLabels:
      k8s-app: heapster
      version: v1.5.1
  template:
    metadata:
      labels:
        k8s-app: heapster
        version: v1.5.1
      annotations:
        scheduler.alpha.kubernetes.io/critical-pod: ''
    spec:
      priorityClassName: system-cluster-critical
      containers:
        - image: k8s.gcr.io/heapster-amd64:v1.5.1
          name: heapster
          livenessProbe:
            httpGet:
              path: /healthz
              port: 8082
              scheme: HTTP
            initialDelaySeconds: 180
            timeoutSeconds: 5
          command:
            - /heapster
            - --source=kubernetes.summary_api:''
        - image: k8s.gcr.io/addon-resizer:1.8.1
          name: heapster-nanny
          resources:
            limits:
              cpu: 50m
              memory: 90Mi
            requests:
              cpu: 50m
              memory: 90Mi
          env:
            - name: MY_POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: MY_POD_NAMESPACE
              valueFrom:
                fieldRef:
                  fieldPath: metadata.namespace
          volumeMounts:
          - name: heapster-config-volume
            mountPath: /etc/config
          command:
            - /pod_nanny
            - --config-dir=/etc/config
            - --cpu=80m
            - --extra-cpu=20m
            - --memory=200Mi
            - --extra-memory=4Mi
            - --threshold=5
            - --deployment=heapster-v1.5.1
            - --container=heapster
            - --poll-period=300000
            - --estimator=exponential
      volumes:
        - name: heapster-config-volume
          configMap:
            name: heapster-config
      serviceAccountName: heapster
      tolerations:
        - key: "CriticalAddonsOnly"
          operator: "Exists"
EOF
    fi

    local TEMPLATE=/srv/kubernetes/manifests/heapster-svc.yaml
    if [ ! -f $TEMPLATE ]; then
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
kind: Service
apiVersion: v1
metadata: 
  name: heapster
  namespace: kube-system
  labels: 
    kubernetes.io/cluster-service: "true"
    addonmanager.kubernetes.io/mode: Reconcile
    kubernetes.io/name: "Heapster"
spec: 
  ports: 
    - port: 80
      targetPort: 8082
  selector: 
    k8s-app: heapster
EOF
    fi

    local TEMPLATE=/srv/kubernetes/manifests/heapster-sa.yaml
    if [ ! -f $TEMPLATE ]; then
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
apiVersion: v1
kind: ServiceAccount
metadata:
  name: heapster
  namespace: kube-system
  labels:
    kubernetes.io/cluster-service: "true"
    addonmanager.kubernetes.io/mode: Reconcile
EOF
    fi

    local TEMPLATE=/srv/kubernetes/manifests/heapster-cm.yaml
    if [ ! -f $TEMPLATE ]; then
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
apiVersion: v1
kind: ConfigMap
metadata:
  name: heapster-config
  namespace: kube-system
  labels:
    kubernetes.io/cluster-service: "true"
    addonmanager.kubernetes.io/mode: EnsureExists
data:
  NannyConfiguration: |-
    apiVersion: nannyconfig/v1alpha1
    kind: NannyConfiguration
EOF
    fi

    local TEMPLATE=/srv/kubernetes/manifests/kube-dashboard-de.yaml
    if [ ! -f $TEMPLATE ]; then
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kubernetes-dashboard
  namespace: kube-system
  labels:
    k8s-app: kubernetes-dashboard
    kubernetes.io/cluster-service: "true"
    addonmanager.kubernetes.io/mode: Reconcile
spec:
  selector:
    matchLabels:
      k8s-app: kubernetes-dashboard
  template:
    metadata:
      labels:
        k8s-app: kubernetes-dashboard
      annotations:
        scheduler.alpha.kubernetes.io/critical-pod: ''
    spec:
      priorityClassName: system-cluster-critical
      containers:
      - name: kubernetes-dashboard
        image: k8s.gcr.io/kubernetes-dashboard-amd64:v1.8.3
        resources:
          limits:
            cpu: 100m
            memory: 300Mi
          requests:
            cpu: 50m
            memory: 100Mi
        ports:
        - containerPort: 8443
          protocol: TCP
        args:
          # PLATFORM-SPECIFIC ARGS HERE
          - --auto-generate-certificates
        volumeMounts:
        - name: kubernetes-dashboard-certs
          mountPath: /certs
        - name: tmp-volume
          mountPath: /tmp
        livenessProbe:
          httpGet:
            scheme: HTTPS
            path: /
            port: 8443
          initialDelaySeconds: 30
          timeoutSeconds: 30
      volumes:
      - name: kubernetes-dashboard-certs
        secret:
          secretName: kubernetes-dashboard-certs
      - name: tmp-volume
        emptyDir: {}
      serviceAccountName: kubernetes-dashboard
      tolerations:
      - key: "CriticalAddonsOnly"
        operator: "Exists"
EOF
    fi

    local TEMPLATE=/srv/kubernetes/manifests/kube-dashboard-svc.yaml
    if [ ! -f $TEMPLATE ]; then
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
apiVersion: v1
kind: Service
metadata:
  name: kubernetes-dashboard
  namespace: kube-system
  labels:
    k8s-app: kubernetes-dashboard
    kubernetes.io/cluster-service: "true"
    addonmanager.kubernetes.io/mode: Reconcile
spec:
  selector:
    k8s-app: kubernetes-dashboard
  ports:
  - port: 443
    targetPort: 8443
EOF
    fi

    local TEMPLATE=/srv/kubernetes/manifests/kube-dashboard-sec.yaml
    if [ ! -f $TEMPLATE ]; then
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
apiVersion: v1
kind: Secret
metadata:
  labels:
    k8s-app: kubernetes-dashboard
    # Allows editing resource and makes sure it is created first.
    addonmanager.kubernetes.io/mode: EnsureExists
  name: kubernetes-dashboard-certs
  namespace: kube-system
type: Opaque
---
apiVersion: v1
kind: Secret
metadata:
  labels:
    k8s-app: kubernetes-dashboard
    # Allows editing resource and makes sure it is created first.
    addonmanager.kubernetes.io/mode: EnsureExists
  name: kubernetes-dashboard-key-holder
  namespace: kube-system
type: Opaque
EOF
    fi

local TEMPLATE=/srv/kubernetes/manifests/kube-dashboard-sa.yaml
    if [ ! -f $TEMPLATE ]; then
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
apiVersion: v1
kind: ServiceAccount
metadata:
  labels:
    k8s-app: kubernetes-dashboard
    addonmanager.kubernetes.io/mode: Reconcile
  name: kubernetes-dashboard
  namespace: kube-system
EOF
    fi

local TEMPLATE=/srv/kubernetes/manifests/kube-dashboard-rbac.yaml
    if [ ! -f $TEMPLATE ]; then
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
kind: Role
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  labels:
    k8s-app: kubernetes-dashboard
    addonmanager.kubernetes.io/mode: Reconcile
  name: kubernetes-dashboard-minimal
  namespace: kube-system
rules:
  # Allow Dashboard to get, update and delete Dashboard exclusive secrets.
- apiGroups: [""]
  resources: ["secrets"]
  resourceNames: ["kubernetes-dashboard-key-holder", "kubernetes-dashboard-certs"]
  verbs: ["get", "update", "delete"]
  # Allow Dashboard to get and update 'kubernetes-dashboard-settings' config map.
- apiGroups: [""]
  resources: ["configmaps"]
  resourceNames: ["kubernetes-dashboard-settings"]
  verbs: ["get", "update"]
  # Allow Dashboard to get metrics from heapster.
- apiGroups: [""]
  resources: ["services"]
  resourceNames: ["heapster"]
  verbs: ["proxy"]
- apiGroups: [""]
  resources: ["services/proxy"]
  resourceNames: ["heapster", "http:heapster:", "https:heapster:"]
  verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: kubernetes-dashboard-minimal
  namespace: kube-system
  labels:
    k8s-app: kubernetes-dashboard
    addonmanager.kubernetes.io/mode: Reconcile
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: kubernetes-dashboard-minimal
subjects:
- kind: ServiceAccount
  name: kubernetes-dashboard
  namespace: kube-system
EOF
    fi

local TEMPLATE=/srv/kubernetes/manifests/kube-dashboard-cm.yaml
    if [ ! -f $TEMPLATE ]; then
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
apiVersion: v1
kind: ConfigMap
metadata:
  labels:
    k8s-app: kubernetes-dashboard
    # Allows editing resource and makes sure it is created first.
    addonmanager.kubernetes.io/mode: EnsureExists
  name: kubernetes-dashboard-settings
  namespace: kube-system
EOF
    fi

#     local TEMPLATE=/etc/flannel/options.env
#     if [ ! -f $TEMPLATE ]; then
#         echo "TEMPLATE: $TEMPLATE"
#         mkdir -p $(dirname $TEMPLATE)
#         cat << EOF > $TEMPLATE
# FLANNELD_IFACE=$ADVERTISE_IP
# FLANNELD_ETCD_ENDPOINTS=$ETCD_ENDPOINTS
# EOF
#     fi

#     local TEMPLATE=/etc/systemd/system/flanneld.service.d/40-ExecStartPre-symlink.conf.conf
#     if [ ! -f $TEMPLATE ]; then
#         echo "TEMPLATE: $TEMPLATE"
#         mkdir -p $(dirname $TEMPLATE)
#         cat << EOF > $TEMPLATE
# [Service]
# ExecStartPre=/usr/bin/ln -sf /etc/flannel/options.env /run/flannel/options.env
# EOF
#     fi

#     local TEMPLATE=/etc/systemd/system/docker.service.d/40-flannel.conf
#     if [ ! -f $TEMPLATE ]; then
#         echo "TEMPLATE: $TEMPLATE"
#         mkdir -p $(dirname $TEMPLATE)
#         cat << EOF > $TEMPLATE
# [Unit]
# Requires=flanneld.service
# After=flanneld.service
# [Service]
# EnvironmentFile=/etc/kubernetes/cni/docker_opts_cni.env
# EOF
#     fi

#     local TEMPLATE=/etc/kubernetes/cni/docker_opts_cni.env
#     if [ ! -f $TEMPLATE ]; then
#         echo "TEMPLATE: $TEMPLATE"
#         mkdir -p $(dirname $TEMPLATE)
#         cat << EOF > $TEMPLATE
# DOCKER_OPT_BIP=""
# DOCKER_OPT_IPMASQ=""
# EOF
#     fi

#     local TEMPLATE=/etc/kubernetes/cni/net.d/10-flannel.conf
#     if [ "${USE_CALICO}" = "false" ] && [ ! -f "${TEMPLATE}" ]; then
#         echo "TEMPLATE: $TEMPLATE"
#         mkdir -p $(dirname $TEMPLATE)
#         cat << EOF > $TEMPLATE
# {
#     "name": "podnet",
#     "type": "flannel",
#     "delegate": {
#         "isDefaultGateway": true
#     }
# }
# EOF
#     fi

    local TEMPLATE=/srv/kubernetes/manifests/calico.yaml
    if [ "${USE_CALICO}" = "true" ]; then
    echo "TEMPLATE: $TEMPLATE"
    mkdir -p $(dirname $TEMPLATE)
    cat << EOF > $TEMPLATE
# Calico Version v3.0.3
# https://docs.projectcalico.org/v3.0/releases#v3.0.3
# This manifest includes the following component versions:
#   calico/node:v3.0.3
#   calico/cni:v2.0.1
#   calico/kube-controllers:v2.0.1

# This ConfigMap is used to configure a self-hosted Calico installation.
kind: ConfigMap
apiVersion: v1
metadata:
  name: calico-config
  namespace: kube-system
data:
  # The location of your etcd cluster.  This uses the Service clusterIP
  # defined below.
  etcd_endpoints: "${ETCD_ENDPOINTS}"

  # Configure the Calico backend to use.
  calico_backend: "bird"

  # The CNI network configuration to install on each node.
  cni_network_config: |-
    {
      "name": "k8s-pod-network",
      "cniVersion": "0.3.0",
      "plugins": [
        {
          "type": "calico",
          "etcd_endpoints": "__ETCD_ENDPOINTS__",
          "log_level": "info",
          "mtu": 1500,
          "ipam": {
              "type": "calico-ipam"
          },
          "policy": {
              "type": "k8s",
               "k8s_api_root": "https://__KUBERNETES_SERVICE_HOST__:__KUBERNETES_SERVICE_PORT__",
               "k8s_auth_token": "__SERVICEACCOUNT_TOKEN__"
          },
          "kubernetes": {
              "kubeconfig": "/etc/cni/net.d/__KUBECONFIG_FILENAME__"
          }
        },
        {
          "type": "portmap",
          "snat": true,
          "capabilities": {"portMappings": true}
        }
      ]
    }


---

# This manifest installs the Calico etcd on the kubeadm master.  This uses a DaemonSet
# to force it to run on the master even when the master isn't schedulable, and uses
# nodeSelector to ensure it only runs on the master.
apiVersion: extensions/v1beta1
kind: DaemonSet
metadata:
  name: calico-etcd
  namespace: kube-system
  labels:
    k8s-app: calico-etcd
spec:
  template:
    metadata:
      labels:
        k8s-app: calico-etcd
      annotations:
        # Mark this pod as a critical add-on; when enabled, the critical add-on scheduler
        # reserves resources for critical add-on pods so that they can be rescheduled after
        # a failure.  This annotation works in tandem with the toleration below.
        scheduler.alpha.kubernetes.io/critical-pod: ''
    spec:
      # Only run this pod on the master.
      tolerations:
      # this taint is set by all kubelets running `--cloud-provider=external`
      # so we should tolerate it to schedule the calico pods
      - key: node.cloudprovider.kubernetes.io/uninitialized
        value: "true"
        effect: NoSchedule
      - key: node-role.kubernetes.io/master
        effect: NoSchedule
      # Allow this pod to be rescheduled while the node is in "critical add-ons only" mode.
      # This, along with the annotation above marks this pod as a critical add-on.
      - key: CriticalAddonsOnly
        operator: Exists
      nodeSelector:
        node-role.kubernetes.io/master: ""
      hostNetwork: true
      containers:
        - name: calico-etcd
          image: quay.io/coreos/etcd:v3.1.10
          env:
            - name: CALICO_ETCD_IP
              valueFrom:
                fieldRef:
                  fieldPath: status.podIP
          command:
          - /usr/local/bin/etcd
          args:
          - --name=calico
          - --data-dir=/var/etcd/calico-data
          - --advertise-client-urls=http://$CALICO_ETCD_IP:6666
          - --listen-client-urls=http://0.0.0.0:6666
          - --listen-peer-urls=http://0.0.0.0:6667
          - --auto-compaction-retention=1
          volumeMounts:
            - name: var-etcd
              mountPath: /var/etcd
      volumes:
        - name: var-etcd
          hostPath:
            path: /var/etcd

---

# This manifest installs the Service which gets traffic to the Calico
# etcd.
apiVersion: v1
kind: Service
metadata:
  labels:
    k8s-app: calico-etcd
  name: calico-etcd
  namespace: kube-system
spec:
  # Select the calico-etcd pod running on the master.
  selector:
    k8s-app: calico-etcd
  # This ClusterIP needs to be known in advance, since we cannot rely
  # on DNS to get access to etcd.
  clusterIP: ${CLUSTER_IP}
  ports:
    - port: 6666

---

# This manifest installs the calico/node container, as well
# as the Calico CNI plugins and network config on
# each master and worker node in a Kubernetes cluster.
kind: DaemonSet
apiVersion: extensions/v1beta1
metadata:
  name: calico-node
  namespace: kube-system
  labels:
    k8s-app: calico-node
spec:
  selector:
    matchLabels:
      k8s-app: calico-node
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1
  template:
    metadata:
      labels:
        k8s-app: calico-node
      annotations:
        # Mark this pod as a critical add-on; when enabled, the critical add-on scheduler
        # reserves resources for critical add-on pods so that they can be rescheduled after
        # a failure.  This annotation works in tandem with the toleration below.
        scheduler.alpha.kubernetes.io/critical-pod: ''
    spec:
      hostNetwork: true
      tolerations:
      # this taint is set by all kubelets running `--cloud-provider=external`
      # so we should tolerate it to schedule the calico pods
      - key: node.cloudprovider.kubernetes.io/uninitialized
        value: "true"
        effect: NoSchedule
      - key: node-role.kubernetes.io/master
        effect: NoSchedule
      # Allow this pod to be rescheduled while the node is in "critical add-ons only" mode.
      # This, along with the annotation above marks this pod as a critical add-on.
      - key: CriticalAddonsOnly
        operator: Exists
      serviceAccountName: calico-cni-plugin
      # Minimize downtime during a rolling upgrade or deletion; tell Kubernetes to do a "force
      # deletion": https://kubernetes.io/docs/concepts/workloads/pods/pod/#termination-of-pods.
      terminationGracePeriodSeconds: 0
      containers:
        # Runs calico/node container on each Kubernetes node.  This
        # container programs network policy and routes on each
        # host.
        - name: calico-node
          image: quay.io/calico/node:v3.0.3
          env:
            # The location of the Calico etcd cluster.
            - name: ETCD_ENDPOINTS
              valueFrom:
                configMapKeyRef:
                  name: calico-config
                  key: etcd_endpoints
            # Enable BGP.  Disable to enforce policy only.
            - name: CALICO_NETWORKING_BACKEND
              valueFrom:
                configMapKeyRef:
                  name: calico-config
                  key: calico_backend
            # Cluster type to identify the deployment type
            - name: CLUSTER_TYPE
              value: "kubeadm,bgp"
            # Disable file logging so `kubectl logs` works.
            - name: CALICO_DISABLE_FILE_LOGGING
              value: "true"
            # Set noderef for node controller.
            - name: CALICO_K8S_NODE_REF
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
            # Set Felix endpoint to host default action to ACCEPT.
            - name: FELIX_DEFAULTENDPOINTTOHOSTACTION
              value: "ACCEPT"
            # The default IPv4 pool to create on startup if none exists. Pod IPs will be
            # chosen from this range. Changing this value after installation will have
            # no effect. This should fall within `--cluster-cidr`.
            - name: CALICO_IPV4POOL_CIDR
              value: "192.168.0.0/16"
            - name: CALICO_IPV4POOL_IPIP
              value: "Always"
            # Disable IPv6 on Kubernetes.
            - name: FELIX_IPV6SUPPORT
              value: "false"
            # Set MTU for tunnel device used if ipip is enabled
            - name: FELIX_IPINIPMTU
              value: "1440"
            # Set Felix logging to "info"
            - name: FELIX_LOGSEVERITYSCREEN
              value: "info"
            # Auto-detect the BGP IP address.
            - name: IP
              value: "autodetect"
            - name: FELIX_HEALTHENABLED
              value: "true"
          securityContext:
            privileged: true
          resources:
            requests:
              cpu: 250m
          livenessProbe:
            httpGet:
              path: /liveness
              port: 9099
            periodSeconds: 10
            initialDelaySeconds: 10
            failureThreshold: 6
          readinessProbe:
            httpGet:
              path: /readiness
              port: 9099
            periodSeconds: 10
          volumeMounts:
            - mountPath: /lib/modules
              name: lib-modules
              readOnly: true
            - mountPath: /var/run/calico
              name: var-run-calico
              readOnly: false
        # This container installs the Calico CNI binaries
        # and CNI network config file on each node.
        - name: install-cni
          image: quay.io/calico/cni:v2.0.1
          command: ["/install-cni.sh"]
          env:
            # Name of the CNI config file to create.
            - name: CNI_CONF_NAME
              value: "10-calico.conflist"
            # The location of the Calico etcd cluster.
            - name: ETCD_ENDPOINTS
              valueFrom:
                configMapKeyRef:
                  name: calico-config
                  key: etcd_endpoints
            # The CNI network config to install on each node.
            - name: CNI_NETWORK_CONFIG
              valueFrom:
                configMapKeyRef:
                  name: calico-config
                  key: cni_network_config
          volumeMounts:
            - mountPath: /host/opt/cni/bin
              name: cni-bin-dir
            - mountPath: /host/etc/cni/net.d
              name: cni-net-dir
      volumes:
        # Used by calico/node.
        - name: lib-modules
          hostPath:
            path: /lib/modules
        - name: var-run-calico
          hostPath:
            path: /var/run/calico
        # Used to install CNI.
        - name: cni-bin-dir
          hostPath:
            path: /opt/cni/bin
        - name: cni-net-dir
          hostPath:
            path: /etc/cni/net.d

---

# This manifest deploys the Calico Kubernetes controllers.
# See https://github.com/projectcalico/kube-controllers
apiVersion: extensions/v1beta1
kind: Deployment
metadata:
  name: calico-kube-controllers
  namespace: kube-system
  labels:
    k8s-app: calico-kube-controllers
spec:
  # The controllers can only have a single active instance.
  replicas: 1
  strategy:
    type: Recreate
  template:
    metadata:
      name: calico-kube-controllers
      namespace: kube-system
      labels:
        k8s-app: calico-kube-controllers
      annotations:
        # Mark this pod as a critical add-on; when enabled, the critical add-on scheduler
        # reserves resources for critical add-on pods so that they can be rescheduled after
        # a failure.  This annotation works in tandem with the toleration below.
        scheduler.alpha.kubernetes.io/critical-pod: ''
    spec:
      # The controllers must run in the host network namespace so that
      # it isn't governed by policy that would prevent it from working.
      hostNetwork: true
      tolerations:
      # this taint is set by all kubelets running `--cloud-provider=external`
      # so we should tolerate it to schedule the calico pods
      - key: node.cloudprovider.kubernetes.io/uninitialized
        value: "true"
        effect: NoSchedule
      - key: node-role.kubernetes.io/master
        effect: NoSchedule
      # Allow this pod to be rescheduled while the node is in "critical add-ons only" mode.
      # This, along with the annotation above marks this pod as a critical add-on.
      - key: CriticalAddonsOnly
        operator: Exists
      serviceAccountName: calico-kube-controllers
      containers:
        - name: calico-kube-controllers
          image: quay.io/calico/kube-controllers:v2.0.1
          env:
            # The location of the Calico etcd cluster.
            - name: ETCD_ENDPOINTS
              valueFrom:
                configMapKeyRef:
                  name: calico-config
                  key: etcd_endpoints
            # Choose which controllers to run.
            - name: ENABLED_CONTROLLERS
              value: policy,profile,workloadendpoint,node

---

apiVersion: rbac.authorization.k8s.io/v1beta1
kind: ClusterRoleBinding
metadata:
  name: calico-cni-plugin
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: calico-cni-plugin
subjects:
- kind: ServiceAccount
  name: calico-cni-plugin
  namespace: kube-system

---

kind: ClusterRole
apiVersion: rbac.authorization.k8s.io/v1beta1
metadata:
  name: calico-cni-plugin
rules:
  - apiGroups: [""]
    resources:
      - pods
      - nodes
    verbs:
      - get

---

apiVersion: v1
kind: ServiceAccount
metadata:
  name: calico-cni-plugin
  namespace: kube-system

---

apiVersion: rbac.authorization.k8s.io/v1beta1
kind: ClusterRoleBinding
metadata:
  name: calico-kube-controllers
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: calico-kube-controllers
subjects:
- kind: ServiceAccount
  name: calico-kube-controllers
  namespace: kube-system

---

kind: ClusterRole
apiVersion: rbac.authorization.k8s.io/v1beta1
metadata:
  name: calico-kube-controllers
rules:
  - apiGroups:
    - ""
    - extensions
    resources:
      - pods
      - namespaces
      - networkpolicies
      - nodes
    verbs:
      - watch
      - list

---

apiVersion: v1
kind: ServiceAccount
metadata:
  name: calico-kube-controllers
  namespace: kube-system
EOF
    fi
}

function start_addons {
    echo "Waiting for Kubernetes API..."
    until curl --silent "http://127.0.0.1:8080/version"
    do
        sleep 5
    done

    echo
    echo "K8S: addon cluster admin"
    #curl --silent -H "Content-Type: application/yaml" -XPOST -d"$(cat /srv/kubernetes/manifests/add-on-cluster-admin-crb.yaml)" "http://127.0.0.1:8080/apis/rbac.authorization.k8s.io/v1/clusterrolebindings" > /dev/null
    docker run --rm --net=host -v /srv/kubernetes/manifests:/host/manifests $HYPERKUBE_IMAGE_REPO:$K8S_VER /hyperkube kubectl apply -f /host/manifests/add-on-cluster-admin-crb.yaml
    echo "K8S: DNS addon"
    # curl --silent -H "Content-Type: application/yaml" -XPOST -d"$(cat /srv/kubernetes/manifests/kube-dns-de.yaml)" "http://127.0.0.1:8080/apis/extensions/v1beta1/namespaces/kube-system/deployments" > /dev/null
    # curl --silent -H "Content-Type: application/yaml" -XPOST -d"$(cat /srv/kubernetes/manifests/kube-dns-svc.yaml)" "http://127.0.0.1:8080/api/v1/namespaces/kube-system/services" > /dev/null
    # curl --silent -H "Content-Type: application/yaml" -XPOST -d"$(cat /srv/kubernetes/manifests/kube-dns-sa.yaml)" "http://127.0.0.1:8080/api/v1/namespaces/kube-system/secrets" > /dev/null
    # curl --silent -H "Content-Type: application/yaml" -XPOST -d"$(cat /srv/kubernetes/manifests/kube-dns-cm.yaml)" "http://127.0.0.1:8080/api/v1/namespaces/kube-system/configMaps" > /dev/null
    # curl --silent -H "Content-Type: application/yaml" -XPOST -d"$(cat /srv/kubernetes/manifests/kube-dns-autoscaler-de.yaml)" "http://127.0.0.1:8080/apis/apps/v1/namespaces/kube-system/deployments" > /dev/null
    # curl --silent -H "Content-Type: application/yaml" -XPOST -d"$(cat /srv/kubernetes/manifests/kube-dns-autoscaler-sa.yaml)" "http://127.0.0.1:8080/api/v1/namespaces/kube-system/secrets" > /dev/null
    # curl --silent -H "Content-Type: application/yaml" -XPOST -d"$(cat /srv/kubernetes/manifests/kube-dns-autoscaler-rbac.yaml)" "http://127.0.0.1:8080/apis/rbac.authorization.k8s.io/v1/clusterrolebindings" > /dev/null
    docker run --rm --net=host -v /srv/kubernetes/manifests:/host/manifests $HYPERKUBE_IMAGE_REPO:$K8S_VER /hyperkube kubectl apply -f /host/manifests/kube-dns-svc.yaml
    docker run --rm --net=host -v /srv/kubernetes/manifests:/host/manifests $HYPERKUBE_IMAGE_REPO:$K8S_VER /hyperkube kubectl apply -f /host/manifests/kube-dns-sa.yaml
    docker run --rm --net=host -v /srv/kubernetes/manifests:/host/manifests $HYPERKUBE_IMAGE_REPO:$K8S_VER /hyperkube kubectl apply -f /host/manifests/kube-dns-cm.yaml
    docker run --rm --net=host -v /srv/kubernetes/manifests:/host/manifests $HYPERKUBE_IMAGE_REPO:$K8S_VER /hyperkube kubectl apply -f /host/manifests/kube-dns-de.yaml
    docker run --rm --net=host -v /srv/kubernetes/manifests:/host/manifests $HYPERKUBE_IMAGE_REPO:$K8S_VER /hyperkube kubectl apply -f /host/manifests/kube-dns-autoscaler-sa.yaml
    docker run --rm --net=host -v /srv/kubernetes/manifests:/host/manifests $HYPERKUBE_IMAGE_REPO:$K8S_VER /hyperkube kubectl apply -f /host/manifests/kube-dns-autoscaler-rbac.yaml
    docker run --rm --net=host -v /srv/kubernetes/manifests:/host/manifests $HYPERKUBE_IMAGE_REPO:$K8S_VER /hyperkube kubectl apply -f /host/manifests/kube-dns-autoscaler-de.yaml
    echo "K8S: Heapster addon"
    # curl --silent -H "Content-Type: application/yaml" -XPOST -d"$(cat /srv/kubernetes/manifests/heapster-de.yaml)" "http://127.0.0.1:8080/apis/extensions/v1beta1/namespaces/kube-system/deployments" > /dev/null
    # curl --silent -H "Content-Type: application/yaml" -XPOST -d"$(cat /srv/kubernetes/manifests/heapster-svc.yaml)" "http://127.0.0.1:8080/api/v1/namespaces/kube-system/services" > /dev/null
    # curl --silent -H "Content-Type: application/yaml" -XPOST -d"$(cat /srv/kubernetes/manifests/heapster-sa.yaml)" "http://127.0.0.1:8080/api/v1/namespaces/kube-system/secrets" > /dev/null
    # curl --silent -H "Content-Type: application/yaml" -XPOST -d"$(cat /srv/kubernetes/manifests/heapster-cm.yaml)" "http://127.0.0.1:8080/api/v1/namespaces/kube-system/configMaps" > /dev/null
    docker run --rm --net=host -v /srv/kubernetes/manifests:/host/manifests $HYPERKUBE_IMAGE_REPO:$K8S_VER /hyperkube kubectl apply -f /host/manifests/heapster-svc.yaml
    docker run --rm --net=host -v /srv/kubernetes/manifests:/host/manifests $HYPERKUBE_IMAGE_REPO:$K8S_VER /hyperkube kubectl apply -f /host/manifests/heapster-sa.yaml
    docker run --rm --net=host -v /srv/kubernetes/manifests:/host/manifests $HYPERKUBE_IMAGE_REPO:$K8S_VER /hyperkube kubectl apply -f /host/manifests/heapster-cm.yaml
    docker run --rm --net=host -v /srv/kubernetes/manifests:/host/manifests $HYPERKUBE_IMAGE_REPO:$K8S_VER /hyperkube kubectl apply -f /host/manifests/heapster-de.yaml
    echo "K8S: Dashboard addon"
    # curl --silent -H "Content-Type: application/yaml" -XPOST -d"$(cat /srv/kubernetes/manifests/kube-dashboard-de.yaml)" "http://127.0.0.1:8080/apis/apps/v1/namespaces/kube-system/deployments" > /dev/null
    # curl --silent -H "Content-Type: application/yaml" -XPOST -d"$(cat /srv/kubernetes/manifests/kube-dashboard-svc.yaml)" "http://127.0.0.1:8080/api/v1/namespaces/kube-system/services" > /dev/null
    # curl --silent -H "Content-Type: application/yaml" -XPOST -d"$(cat /srv/kubernetes/manifests/kube-dashboard-sec.yaml)" "http://127.0.0.1:8080/api/v1/namespaces/kube-system/secrets" > /dev/null
    # curl --silent -H "Content-Type: application/yaml" -XPOST -d"$(cat /srv/kubernetes/manifests/kube-dashboard-sa.yaml)" "http://127.0.0.1:8080/api/v1/namespaces/kube-system/secrets" > /dev/null
    # curl --silent -H "Content-Type: application/yaml" -XPOST -d"$(cat /srv/kubernetes/manifests/kube-dashboard-rbac.yaml)" "http://127.0.0.1:8080/apis/rbac.authorization.k8s.io/v1/clusterrolebindings" > /dev/null
    # curl --silent -H "Content-Type: application/yaml" -XPOST -d"$(cat /srv/kubernetes/manifests/kube-dashboard-cm.yaml)" "http://127.0.0.1:8080/api/v1/namespaces/kube-system/configMaps" > /dev/null
    docker run --rm --net=host -v /srv/kubernetes/manifests:/host/manifests $HYPERKUBE_IMAGE_REPO:$K8S_VER /hyperkube kubectl apply -f /host/manifests/kube-dashboard-sa.yaml
    docker run --rm --net=host -v /srv/kubernetes/manifests:/host/manifests $HYPERKUBE_IMAGE_REPO:$K8S_VER /hyperkube kubectl apply -f /host/manifests/kube-dashboard-rbac.yaml
    docker run --rm --net=host -v /srv/kubernetes/manifests:/host/manifests $HYPERKUBE_IMAGE_REPO:$K8S_VER /hyperkube kubectl apply -f /host/manifests/kube-dashboard-sec.yaml
    docker run --rm --net=host -v /srv/kubernetes/manifests:/host/manifests $HYPERKUBE_IMAGE_REPO:$K8S_VER /hyperkube kubectl apply -f /host/manifests/kube-dashboard-cm.yaml
    docker run --rm --net=host -v /srv/kubernetes/manifests:/host/manifests $HYPERKUBE_IMAGE_REPO:$K8S_VER /hyperkube kubectl apply -f /host/manifests/kube-dashboard-svc.yaml
    docker run --rm --net=host -v /srv/kubernetes/manifests:/host/manifests $HYPERKUBE_IMAGE_REPO:$K8S_VER /hyperkube kubectl apply -f /host/manifests/kube-dashboard-de.yaml
    
    
    
}

function start_calico {
    GREEN='\033[0;32m'
    RED='\033[0;31m'
    YELLOW='\033[0;33m'
    NC='\033[0m'

    printf "Waiting for Kubernetes API and extensions..."
    # wait for the API and extensions such as daemonset
    until curl --silent "http://127.0.0.1:8080/version/"
    do
        printf "${YELLOW}Kubernetes API and extensions not ready for Calico${NC}"
        sleep 5
    done
    printf "${GREEN}Kubernetes API and extensions ready for Calico${NC}"

    until curl --silent "http://127.0.0.1:8080/apis/extensions/v1beta1" | grep daemonset
    do
        printf "${YELLOW}Waitfing to deploy Calico${NC}"
        sleep 5
    done
    printf "${GREEN}Deploying Flannel${NC}"
    # Deploy Calico
    #TODO: change to rkt once this is resolved (https://github.com/coreos/rkt/issues/3181)
    docker run --rm --net=host -v /srv/kubernetes/manifests:/host/manifests $HYPERKUBE_IMAGE_REPO:$K8S_VER /hyperkube kubectl apply -f /host/manifests/calico.yaml
}

function start_flannel {
    GREEN='\033[0;32m'
    RED='\033[0;31m'
    YELLOW='\033[0;33m'
    NC='\033[0m'

    printf "Waiting for Kubernetes API and extensions..."
    # wait for the API and extensions such as daemonset
    until curl --silent "http://127.0.0.1:8080/version/"
    do
        printf "${YELLOW}Kubernetes API and extensions not ready for Flannel${NC}"
        sleep 5
    done
    printf "${GREEN}Kubernetes API and extensions ready for Flannel${NC}"

    until curl --silent "http://127.0.0.1:8080/apis/extensions/v1beta1" | grep daemonset
    do
        printf "${YELLOW}Waitfing to deploy Flannel${NC}"
        sleep 5
    done
    printf "${GREEN}Deploying Flannel${NC}"
    # Deploy flannel
    docker run --rm --net=host -v /srv/kubernetes/manifests:/host/manifests $HYPERKUBE_IMAGE_REPO:$K8S_VER /hyperkube kubectl apply -f /host/manifests/flannel.yaml
}

init_config
init_templates
init_flannel

chmod +x /opt/bin/host-rkt

systemctl stop update-engine; systemctl mask update-engine

systemctl daemon-reload

if [ $CONTAINER_RUNTIME = "rkt" ]; then
        systemctl enable load-rkt-stage1
        systemctl enable rkt-api
fi

#systemctl enable flanneld; systemctl start flanneld

systemctl enable kubelet; systemctl start kubelet

# start_flannel

if [ $USE_CALICO = "true" ]; then
        start_calico
else
        start_flannel
fi

start_addons

# ip route add ${POD_NETWORK} dev flannel.1 scope global

echo "DONE"

#!/usr/bin/env bash
set -e

# define location of openssl binary manually since running this
# script under Vagrant fails on some systems without it
if ! which cfssl cfssl-certinfo cfssljson > /dev/null ; then
    case $(uname -s) in
      "Linux")
        ;;
      "Darwin")
        ;;
      "MINGW*")
        curl -o /usr/bin/cfssl.exe https://pkg.cfssl.org/R1.2/cfssl_windows-amd64.exe && \
        curl -o /usr/bin/cfssl-certinfo.exe https://pkg.cfssl.org/R1.2/cfssl-certinfo_windows-amd64.exe && \
        curl -o /usr/bin/cfssljson.exe https://pkg.cfssl.org/R1.2/cfssljson_windows-amd64.exe
        ;;
    esac
fi

function usage {
    echo "USAGE: $0 <output-dir> <cert-base-name> <CN> [SAN,SAN,SAN]"
    echo "  example: $0 ./ssl/ worker kube-worker IP.1=127.0.0.1,IP.2=10.0.0.1"
}

# Check Mandatory 
if [ -z "$1" ] || [ -z "$2" ] || [ -z "$3" ]; then
    usage
    exit 1
fi

OUTDIR="$1"
CERTBASE="$2"
CN="$3"
SANS="$4"

if [ ! -d $OUTDIR ]; then
    echo "ERROR: output directory does not exist:  $OUTDIR"
    exit 1
fi

OUTFILE="$OUTDIR/$CN.tar"

if [ -f "$OUTFILE" ];then
    exit 0
fi

# Root CA certificate
# ---------------------------------------------
function write-ssl-ca {
local TEMPLATE=$OUTDIR/ca-config.json
    if [ ! -f $TEMPLATE ]; then
        echo "local TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
{
  "signing": {
    "default": {
      "expiry": "8760h"
    },
    "profiles": {
      "kubernetes": {
        "usages": [
            "signing",
            "key encipherment",
            "server auth",
            "client auth"
        ],
        "expiry": "8760h"
      }
    }
  }
}
EOF
    fi

local TEMPLATE=$OUTDIR/ca-csr.json
    if [ ! -f $TEMPLATE ]; then
        echo "local TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
{
  "CN": "kubernetes",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "O": "k8s",
      "OU": "CoreOS Kubernetes"
    }
  ]
}
EOF
    fi

local CERTIFICATE=$OUTDIR/${CERTBASE}.pem
    if [ ! -f $CERTIFICATE ]; then
        echo "local CERTIFICATE: $CERTIFICATE"
        mkdir -p $(dirname $CERTIFICATE)
        cfssl gencert -initca $OUTDIR/${CERTBASE}-csr.json | cfssljson -bare $OUTDIR/ca
    fi
}

# Etcd certificate
# ---------------------------------------------
function write-ssl-etcd {
ETCD_IP=$(for i in $(printf ${SANS} | tr ',' '\n'); do printf "\"$i\","; done)

local TEMPLATE=$OUTDIR/${CERTBASE}-csr.json
    if [ ! -f $TEMPLATE ]; then
        echo "local TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
{
  "CN": "${CN}",
  "hosts": [
    ${ETCD_IP}
    "127.0.0.1"
  ],
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "O": "k8s",
      "OU": "CoreOS Kubernetes"
    }
  ]
}
EOF
    fi

CERTIFICATE=$OUTDIR/${CERTBASE}.pem
    if [ ! -f $CERTIFICATE ]; then
        echo "local CERTIFICATE: $CERTIFICATE"
        mkdir -p $(dirname $CERTIFICATE)
        cfssl gencert -ca=$OUTDIR/ca.pem \
        -ca-key=$OUTDIR/ca-key.pem \
        -config=$OUTDIR/ca-config.json \
        -profile=kubernetes $OUTDIR/${CERTBASE}-csr.json | cfssljson -bare $OUTDIR/etcd
    fi
}

# Admin certificate
# ---------------------------------------------
function write-ssl-admin {
local TEMPLATE=$OUTDIR/${CERTBASE}-csr.json
    if [ ! -f $TEMPLATE ]; then
        echo "local TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
{
  "CN": "admin",
  "hosts": [],
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "O": "system:masters",
      "OU": "CoreOS Kubernetes"
    }
  ]
}
EOF
    fi

CERTIFICATE=$OUTDIR/${CERTBASE}.pem
    if [ ! -f $CERTIFICATE ]; then
        echo "local CERTIFICATE: $CERTIFICATE"
        mkdir -p $(dirname $CERTIFICATE)
        cfssl gencert -ca=$OUTDIR/ca.pem \
        -ca-key=$OUTDIR/ca-key.pem \
        -config=$OUTDIR/ca-config.json \
        -profile=kubernetes $OUTDIR/${CERTBASE}-csr.json | cfssljson -bare $OUTDIR/admin
    fi
}

# Master certificate
# ---------------------------------------------
function write-ssl-master {
MASTER_IP=$(for i in $(printf ${SANS} | tr ',' '\n'); do printf "\"$i\","; done)

local TEMPLATE=$OUTDIR/${CERTBASE}-csr.json
    if [ ! -f $TEMPLATE ]; then
        echo "local TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
{
  "CN": "kubernetes",
  "hosts": [
    "127.0.0.1",
    ${MASTER_IP}
    "localhost",
    "kubernetes",
    "kubernetes.default",
    "kubernetes.default.svc",
    "kubernetes.default.svc.cluster",
    "kubernetes.default.svc.cluster.local"
  ],
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "O": "system:masters",
      "OU": "CoreOS Kubernetes"
    }
  ]
}
EOF
    fi

CERTIFICATE=$OUTDIR/${CERTBASE}.pem
    if [ ! -f $CERTIFICATE ]; then
        echo "local CERTIFICATE: $CERTIFICATE"
        mkdir -p $(dirname $CERTIFICATE)
        cfssl gencert -ca=$OUTDIR/ca.pem \
        -ca-key=$OUTDIR/ca-key.pem \
        -config=$OUTDIR/ca-config.json \
        -profile=kubernetes $OUTDIR/${CERTBASE}-csr.json | cfssljson -bare $OUTDIR/${CERTBASE}
    fi
}

# Node certificate
# ---------------------------------------------
function write-ssl-node {
local TEMPLATE=$OUTDIR/${CERTBASE}-csr.json
    if [ ! -f $TEMPLATE ]; then
        echo "local TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
{
  "CN": "system:node:${CN}",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "O": "system:nodes",
      "OU": "CoreOS Kubernetes"
    }
  ]
}
EOF
    fi

CERTIFICATE=$OUTDIR/${CERTBASE}.pem
    if [ ! -f $CERTIFICATE ]; then
        echo "local CERTIFICATE: $CERTIFICATE"
        mkdir -p $(dirname $CERTIFICATE)
        cfssl gencert -ca=$OUTDIR/ca.pem \
        -ca-key=$OUTDIR/ca-key.pem \
        -config=$OUTDIR/ca-config.json \
        -hostname=${SANS} \
        -profile=kubernetes $OUTDIR/${CERTBASE}-csr.json | cfssljson -bare $OUTDIR/${CERTBASE}
    fi
}

# Kube-Proxy certificate
# ---------------------------------------------
function write-ssl-kube-proxy {
local TEMPLATE=$OUTDIR/${CERTBASE}-csr.json
    if [ ! -f $TEMPLATE ]; then
        echo "local TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
{
  "CN": "system:kube-proxy",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "O": "system:node-proxier",
      "OU": "CoreOS Kubernetes"
    }
  ]
}
EOF
    fi

CERTIFICATE=$OUTDIR/${CERTBASE}.pem
    if [ ! -f $CERTIFICATE ]; then
        echo "local CERTIFICATE: $CERTIFICATE"
        mkdir -p $(dirname $CERTIFICATE)
        cfssl gencert -ca=$OUTDIR/ca.pem \
        -ca-key=$OUTDIR/ca-key.pem \
        -config=$OUTDIR/ca-config.json \
        -profile=kubernetes $OUTDIR/${CERTBASE}-csr.json | cfssljson -bare $OUTDIR/${CERTBASE}
    fi
}

# Kube-Apiserver certificate
# ---------------------------------------------
function write-ssl-apiserver {
APISERVER_IP=$(for i in $(printf ${SANS} | tr ',' '\n'); do printf "\"$i\","; done)

local TEMPLATE=$OUTDIR/${CERTBASE}-csr.json
    if [ ! -f $TEMPLATE ]; then
        echo "local TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
{
  "CN": "{CN}",
  "hosts": [
    "127.0.0.1",
    ${APISERVER_IP}
    "localhost",
    "kubernetes",
    "kubernetes.default",
    "kubernetes.default.svc",
    "kubernetes.default.svc.cluster",
    "kubernetes.default.svc.cluster.local"
  ],
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "O": "k8s",
      "OU": "CoreOS Kubernetes"
    }
  ]
}
EOF
    fi

CERTIFICATE=$OUTDIR/${CERTBASE}.pem
    if [ ! -f $CERTIFICATE ]; then
        echo "local CERTIFICATE: $CERTIFICATE"
        mkdir -p $(dirname $CERTIFICATE)
        cfssl gencert -ca=$OUTDIR/ca.pem \
        -ca-key=$OUTDIR/ca-key.pem \
        -config=$OUTDIR/ca-config.json \
        -profile=kubernetes $OUTDIR/${CERTBASE}-csr.json | cfssljson -bare $OUTDIR/${CERTBASE}
    fi
}

# Dashboard certificate
# ---------------------------------------------
function write-ssl-dashboard {
local TEMPLATE=$OUTDIR/${CERTBASE}-csr.json
    if [ ! -f $TEMPLATE ]; then
        echo "local TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
{
  "CN": "dashboard",
  "hosts": [],
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "O": "k8s",
      "OU": "CoreOS Kubernetes"
    }
  ]
}
EOF
    fi

CERTIFICATE=$OUTDIR/${CERTBASE}.pem
    if [ ! -f $CERTIFICATE ]; then
        echo "local CERTIFICATE: $CERTIFICATE"
        mkdir -p $(dirname $CERTIFICATE)
        cfssl gencert -ca=$OUTDIR/ca.pem \
        -ca-key=$OUTDIR/ca-key.pem \
        -config=$OUTDIR/ca-config.json \
        -profile=kubernetes $OUTDIR/${CERTBASE}-csr.json | cfssljson -bare $OUTDIR/dashboard
    fi
}

# Flanneld certificate
# ---------------------------------------------
function write-ssl-flanneld {
local TEMPLATE=$OUTDIR/${CERTBASE}-csr.json
    if [ ! -f $TEMPLATE ]; then
        echo "local TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
{
  "CN": "flanneld",
  "hosts": [],
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "O": "k8s",
      "OU": "CoreOS Kubernetes"
    }
  ]
}
EOF
    fi

CERTIFICATE=$OUTDIR/${CERTBASE}.pem
    if [ ! -f $CERTIFICATE ]; then
        echo "local CERTIFICATE: $CERTIFICATE"
        mkdir -p $(dirname $CERTIFICATE)
        cfssl gencert -ca=$OUTDIR/ca.pem \
        -ca-key=$OUTDIR/ca-key.pem \
        -config=$OUTDIR/ca-config.json \
        -profile=kubernetes $OUTDIR/${CERTBASE}-csr.json | cfssljson -bare $OUTDIR/${CERTBASE}
    fi
}



case "$2" in
    "ca" )
      write-ssl-ca
      ;;
    "etcd" )
      write-ssl-etcd
      ;;
    "admin" )
      write-ssl-admin
      ;;
    "master" )
      write-ssl-master
      ;;
    "node" )
      write-ssl-node
      ;;
    "kube-proxy" )
      write-ssl-kube-proxy
      ;;
    "apiserver" )
      write-ssl-apiserver
      ;;
    "dashboard" )
      write-ssl-dashboard
      ;;
    "flanneld" )
      write-ssl-flanneld
      ;;
esac

CAFILE="$OUTDIR/ca.pem"
CAKEYFILE="$OUTDIR/ca-key.pem"
KEYFILE="$OUTDIR/$CERTBASE-key.pem"
CSRFILE="$OUTDIR/$CERTBASE.csr"
PEMFILE="$OUTDIR/$CERTBASE.pem"

CONTENTS="${CAFILE} ${KEYFILE} ${PEMFILE}"

tar -cf $OUTFILE -C $OUTDIR $(for  f in $CONTENTS;do printf "$(basename $f) ";done)

echo "Bundled SSL artifacts into $OUTFILE"
echo "$CONTENTS"
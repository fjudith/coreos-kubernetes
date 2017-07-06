# Introduction

Ceph is a free and open-source distributed object storage cluster platform that provides interfaces for object, block and file-level storage.
It can be leveraged in Kubernetes to store persistent data of stateful containers. 

# Scenario

Ceph-docker supports [various deployment scenarios](https://github.com/ceph/ceph-docker/tree/master/ceph-releases/kraken/ubuntu/16.04/daemon), `osd_directory` will be leveraged in this guide as allows deployers to implement additionnal disks later-on.

Deployment is performed by acheiving the following activites:

* Install Python jinja2
* Compile and install uuidgen (Windows only)
* Prepare storage worker node disks
* Deploy Ceph inside Kubernetes
* Create storage mounts units

## Install Python jinja2

Install python 2.7

```bash
cd ~/Downloads
curl -O https://bootstrap.pypa.io/get-pip.py
cd c:\python27\scripts
./pip install jinja2 pyaml

export PATH=$PATH:/c/Python27/Scripts
```

## Prepare storage worker node disks
Open an SSH session to the kubernetes node

```bash
Explain how to send a mount units
```

## Deploy Ceph inside Kubernetes

```bash
## Install daemon set
cd ~/git/ceph-docker/examples/kubernetes-coreos
pushd ~/git/coreos-kubernetes/multi-node/vsphere-powercli/ && . ./init-kubectl.sh && popd
kubectl create namespace ceph
kubectl create -f install-ds.yaml

## deploy ceph
cd ~/git/ceph-docker/examples/kubernetes
export osd_public_network=10.2.0.0/16 
export osd_cluster_network=10.2.0.0/16
export osd_pool_default_pg_num=32
export osd_pool_default_pgp_num=32

## Label nodes as storage

kubectl label node 192.168.251.201 node-type=storage
kubectl label node 192.168.251.202 node-type=storage
kubectl label node 192.168.251.203 node-type=storage

### Password
cd generator
# ./generate_secrets.sh all `./generate_secrets.sh fsid`
./generate_secrets.sh all `./generate_secrets.sh fsid` osd_public_network=10.2.0.0/16 osd_cluster_network=10.2.0.0/16 global_osd_pool_default_pg_num=32 global_osd_pool_default_pgp_num=32

kubectl create namespace ceph

kubectl create secret generic ceph-conf-combined --from-file=ceph.conf --from-file=ceph.client.admin.keyring --from-file=ceph.mon.keyring --namespace=ceph
kubectl create secret generic ceph-bootstrap-rgw-keyring --from-file=ceph.keyring=ceph.rgw.keyring --namespace=ceph
kubectl create secret generic ceph-bootstrap-mds-keyring --from-file=ceph.keyring=ceph.mds.keyring --namespace=ceph
kubectl create secret generic ceph-bootstrap-osd-keyring --from-file=ceph.keyring=ceph.osd.keyring --namespace=ceph
kubectl create secret generic ceph-client-key --from-file=ceph-client-key --namespace=ceph

cd ..


kubectl create -f https://github.com/ReSearchITEng/kubeadm-playbook/raw/master/allow-all-all-rbac.yml

# Ceph Monitor (MON)
kubectl create \
-f ceph-mds-v1-dp.yaml \
-f ceph-mon-v1-svc.yaml \
-f ceph-mon-v1-dp.yaml \
-f ceph-mon-check-v1-dp.yaml \
--namespace=ceph

sleep 300

# Ceph Object Store Deamon (OSD)
kubectl create \
-f ceph-osd-v1-ds.yaml \
--namespace=ceph

sleep 300

# Ceph Meta Data Server (MDS)
kubectl create \
-f ceph-mds-v1-dp.yaml  \
--namespace=ceph
```

### CephFS-test

```bash
kubectl create secret generic ceph-client-key --type="kubernetes.io/rbd" --from-file=./generator/ceph-client-key
kubectl create -f ceph-cephfs-test.yaml --namespace=ceph
```



# Reference
https://github.com/ceph/ceph-docker/tree/master/examples/kubernetes
http://docs.ceph.com/docs/master/rados/operations/monitoring/
export KUBECONFIG="$(pwd)/kubeconfig"
kubectl config use-context vagrant-multi

kubectl config set-cluster vagrant-multi-cluster \
--server=https://172.17.4.101:6443 \
--certificate-authority=${PWD}/ssl/ca.pem

kubectl config set-credentials admin \
--certificate-authority=${PWD}/ssl/ca.pem \
--client-key=${PWD}/ssl/admin-key.pem \
--client-certificate=${PWD}/ssl/admin.pem

kubectl config set-context vagrant-multi \
--cluster=vagrant-multi-cluster \
--user=admin

kubectl config use-context vagrant-multi

# Verification
kubectl get componentstatuses
kubectl get nodes
kubectl cluster-info
export KUBECONFIG="$(pwd)/kubeconfig"
kubectl config use-context vsphere-multi
kubectl config set-cluster vsphere-multi-cluster --server=https://192.168.251.101:443 --certificate-authority=${PWD}/ssl/ca.pem
kubectl config set-credentials vsphere-multi-admin --certificate-authority=${PWD}/ssl/ca.pem --client-key=${PWD}/ssl/admin-key.pem --client-certificate=${PWD}/ssl/admin.pem
kubectl config set-context vsphere-multi --cluster=vsphere-multi-cluster --user=vsphere-multi-admin
kubectl config use-context vsphere-multi
kubectl get nodes
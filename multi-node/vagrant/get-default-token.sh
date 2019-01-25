#! /bin/bash
kubectl describe secret -n kube-system $(kubectl get secrets -n kube-system | grep dashboard-token | awk '{printf $ 1}')
# Kube Services

A collection of helm templates for Kubernetes services like N8N, MetalLB, Minio and Rabbitmq. These are designed to be synced 
via ArgoCD to a Kubernetes cluster.

The base CRD's for these services are not installed by default on the cluster. If you need the metallb helm chart 
from this repo then MetalLB must be pre-installed on the cluster.

# Kube Services

A collection of helm templates for Kubernetes services like N8N, MetalLB, Minio and Rabbitmq. These are designed to be synced 
via ArgoCD to a Kubernetes cluster.

The base CRD's for these services are not installed by default on the cluster. If you need the metallb helm chart 
from this repo then MetalLB must be pre-installed on the cluster.

## ArgoCD

ArgoCD is a bit different it uses `kubectl apply` to directly apply the manifests. Updating it requires a step like:

```shell
# replace 3.3.9 with the version you want
kubectl apply -n argocd --server-side --force-conflicts -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.3.9/manifests/install.yaml
```

This won't remove any applications or configuration that's deployed. The `./manifests/argocd` directory just contains the configmap
that has some basic config changes for ArgoCD to work with the cluster and serve from the /argocd path instead of argocd.kraken-plugins.com.
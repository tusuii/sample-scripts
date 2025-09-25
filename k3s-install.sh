#!/bin/bash
set -e

# Update system
apt-get update
apt-get install -y curl wget

# Install K3s
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable=traefik" sh -

# Wait for K3s to be ready
sleep 30

# Set up kubectl for root
mkdir -p /root/.kube
cp /etc/rancher/k3s/k3s.yaml /root/.kube/config
chmod 600 /root/.kube/config

# Set up kubectl for ubuntu user
mkdir -p /home/ubuntu/.kube
cp /etc/rancher/k3s/k3s.yaml /home/ubuntu/.kube/config
chown ubuntu:ubuntu /home/ubuntu/.kube/config
chmod 600 /home/ubuntu/.kube/config

# Wait for node to be ready
/usr/local/bin/kubectl wait --for=condition=Ready node --all --timeout=300s

# Decode and apply ArgoCD manifest
echo "${argocd_manifest}" | base64 -d > /tmp/argocd-manifest.yaml
/usr/local/bin/kubectl apply -f /tmp/argocd-manifest.yaml

# Wait for ArgoCD to be ready
/usr/local/bin/kubectl wait --for=condition=available --timeout=600s deployment/argocd-server -n argocd

# Get ArgoCD admin password
sleep 60
ARGOCD_PASSWORD=$(/usr/local/bin/kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)

# Create info file
cat > /home/ubuntu/cluster-info.txt << EOF
K3s Cluster Information
======================
Cluster Status: Ready
ArgoCD URL: http://$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)
ArgoCD Username: admin
ArgoCD Password: $ARGOCD_PASSWORD

Commands:
- kubectl get nodes
- kubectl get pods -A
- kubectl port-forward svc/argocd-server -n argocd 8080:80
EOF

chown ubuntu:ubuntu /home/ubuntu/cluster-info.txt

# Enable and start K3s service
systemctl enable k3s
systemctl start k3s

echo "K3s with ArgoCD installation completed!"

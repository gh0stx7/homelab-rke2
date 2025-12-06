# --- PHASE 1: Install RKE2 & Tools ---
# 1. Install RKE2 (Single Node)
curl -sfL https://get.rke2.io | sh -
systemctl enable --now rke2-server.service

# 2. Setup Environment Variables (Wait for node to be ready)
echo "Waiting for RKE2 to start..."
sleep 30
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
export PATH=$PATH:/var/lib/rancher/rke2/bin

# 3. Install Helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# --- PHASE 2: Cert-Manager (With Split-DNS Fix) ---
# 4. Add Repos
helm repo add jetstack https://charts.jetstack.io
helm repo add rancher-latest https://releases.rancher.com/server-charts/latest
helm repo update

# 5. Install Cert-Manager with Recursive Nameservers (Fixes Local DNS issues)
helm install cert-manager jetstack/cert-manager \
--namespace cert-manager \
--create-namespace \
--set installCRDs=true \
--set "extraArgs={--dns01-recursive-nameservers=1.1.1.1:53\,8.8.8.8:53,--dns01-recursive-nameservers-only}"

# --- PHASE 3: Identity & Certificate ---
# 6. Create Cloudflare Secret (REPLACE THE TOKEN BELOW)
kubectl create secret generic cloudflare-api-token-secret \
--from-literal=api-token=<YOUR_API_TOKEN> \
-n cert-manager

# 7. Create ClusterIssuer (REPLACE EMAIL)
```angular2html
cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-local
  namespace: cert-manager
spec:
  acme:
    email: taylorcalderone@hotmail.com
    server: https://acme-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      name: le-local-account-key
    solvers:
      - dns01:
          cloudflare:
            apiTokenSecretRef:
              name: cloudflare-api-token
              key: api-token
EOF
```

# 8. Request Certificate for Rancher
kubectl create namespace cattle-system
cat <<EOF | kubectl apply -f -
```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: tls-rancher-ingress
  namespace: cattle-system
spec:
  secretName: tls-rancher-ingress
  issuerRef:
    name: letsencrypt-local
    kind: ClusterIssuer
  commonName: rancher.infra.ghostlabz.net
  dnsNames:
    - "rancher.infra.ghostlabz.net"
```
EOF

# --- PHASE 4: The Wait & Install ---
echo "Waiting for Certificate to be issued (this may take 2 mins)..."
kubectl wait --for=condition=Ready certificate/tls-rancher-ingress -n cattle-system --timeout=300s

# 9. Install Rancher (Single Node Optimized)
helm install rancher rancher-latest/rancher \
--namespace cattle-system \
--set hostname=rancher.lab.ghostlabz.net \
--set bootstrapPassword=admin \
--set ingress.tls.source=secret \
--set replicas=1
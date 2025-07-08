#!/bin/bash
set -e

echo "Starting Elastic Stack deployment..."

# Get AKS credentials
az aks get-credentials --resource-group $RESOURCE_GROUP --name $CLUSTER_NAME --overwrite-existing

# Install kubectl
az aks install-cli --only-show-errors

# Install Helm
curl https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 | bash

# Add Helm repositories
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo add jetstack https://charts.jetstack.io
helm repo add elastic https://helm.elastic.co
helm repo update

# Install NGINX Ingress Controller
echo "Installing NGINX Ingress Controller..."
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --set controller.resources.requests.cpu="250m" \
  --set controller.resources.requests.memory="256Mi" \
  --set controller.resources.limits.cpu="500m" \
  --set controller.resources.limits.memory="512Mi" \
  --set controller.admissionWebhooks.enabled=false \
  --set controller.service.type=LoadBalancer \
  --set controller.service.externalTrafficPolicy=Local \
  --set controller.service.annotations."service\.beta\.kubernetes\.io/azure-load-balancer-health-probe-request-path"=/healthz
  --wait --timeout 10m

# Wait for LoadBalancer IP
echo "Waiting for LoadBalancer IP..."
for i in {1..30}; do
  LB_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
  if [ -n "$LB_IP" ]; then
    echo "LoadBalancer IP: $LB_IP"
    break
  fi
  echo "Waiting for LoadBalancer IP... ($i/30)"
  sleep 10
done

# Install cert-manager
echo "Installing cert-manager..."
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --set installCRDs=true \
  --version v1.13.3 \
  --wait --timeout 10m

# Create ClusterIssuer for Let's Encrypt
echo "Creating Let's Encrypt ClusterIssuer..."
cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: $LETSENCRYPT_EMAIL
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
    - http01:
        ingress:
          class: nginx
EOF

# Install Elasticsearch
echo "Installing Elasticsearch..."
helm upgrade --install elasticsearch elastic/elasticsearch \
  --namespace elastic-system --create-namespace \
  --set replicas=1 \
  --version 8.5.1 \
  --set security.enabled=true \
  --set resources.requests.memory="1Gi" \
  --set resources.requests.cpu="250m" \
  --set persistence.size="10Gi" \
  --wait --timeout 15m

# Install Kibana
echo "Installing Kibana..."
helm upgrade --install kibana elastic/kibana \
  --namespace elastic-system \
  --version 8.5.1 \
  --set replicas=1 \
  --set service.type=ClusterIP \
  --set resources.requests.memory="512Mi" \
  --wait --timeout 10m

# Apply Kibana Ingress
echo "Configuring Kibana Ingress..."
KIBANA_DNS="kibana-${DNS_PREFIX}.${LOCATION}.cloudapp.azure.com"
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: kibana-ingress
  namespace: elastic-system
  annotations:
    nginx.ingress.kubernetes.io/backend-protocol: "HTTP"
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    cert-manager.io/cluster-issuer: "letsencrypt-prod"
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - $KIBANA_DNS
    secretName: kibana-tls
  rules:
  - host: $KIBANA_DNS
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: kibana-kibana
            port:
              number: 5601
EOF

# Apply Elasticsearch Ingress
echo "Configuring Elasticsearch Ingress..."
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: elasticsearch-ingress
  namespace: elastic-system
  annotations:
    nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    cert-manager.io/cluster-issuer: "letsencrypt-prod"
    nginx.ingress.kubernetes.io/proxy-body-size: "10m"
    nginx.ingress.kubernetes.io/rewrite-target: /\$1
    nginx.ingress.kubernetes.io/use-regex: "true"
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - $KIBANA_DNS
    secretName: kibana-tls
  rules:
  - host: $KIBANA_DNS
    http:
      paths:
      - path: /elasticsearch/(.*)
        pathType: ImplementationSpecific
        backend:
          service:
            name: elasticsearch-master
            port:
              number: 9200
EOF

#Apply elastic config.yaml
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: elasticsearch-config
  namespace: elastic-system
data:
  elasticsearch.yml: |
    xpack.security.enabled: true
    xpack.security.enrollment.enabled: true
    xpack.security.http.ssl.enabled: true
    xpack.security.transport.ssl.enabled: true
    # Allow API key authentication
    xpack.security.authc.api_key.enabled: true
    # Configure HTTP settings
    http.cors.enabled: true
    http.cors.allow-origin: "*"
    http.cors.allow-methods: POST
    http.cors.allow-headers: Authorization, X-Requested-With, Content-Type, Content-Length
EOF

# Wait for certificates to be ready
echo "Waiting for certificates..."
for i in {1..30}; do
  if kubectl get certificate -n elastic-system kibana-tls -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' | grep -q "True"; then
    echo "Certificate is ready!"
    break
  fi
  echo "Waiting for certificate... ($i/30)"
  sleep 10
done

# Get Elasticsearch password
echo "Getting Elasticsearch credentials..."
ES_PASSWORD=$(kubectl get secret -n elastic-system elasticsearch-master-credentials -o jsonpath='{.data.password}' | base64 -d)

# Create API key
echo "Creating API key..."
API_KEY_RESPONSE=$(kubectl exec -n elastic-system elasticsearch-master-0 -- curl -s -k -u elastic:$ES_PASSWORD \
  -X POST "https://localhost:9200/_security/api_key" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "marketplace-ingest-key",
    "role_descriptors": {
      "ingest_role": {
        "cluster": ["monitor", "manage_index_templates", "manage_ingest_pipelines"],
        "indices": [{
          "names": ["*"],
          "privileges": ["write", "create_index", "auto_configure", "create"]
        }]
      }
    }
  }')

API_KEY=$(echo $API_KEY_RESPONSE | jq -r .encoded)

# Prepare outputs
KIBANA_URL="https://$KIBANA_DNS"
ES_ENDPOINT="https://$KIBANA_DNS/elasticsearch"

# Output results
echo "Deployment completed successfully!"
echo "Kibana URL: $KIBANA_URL"
echo "Elasticsearch Endpoint: $ES_ENDPOINT"
echo "API Key: $API_KEY"

# Set outputs for ARM template
echo "{\"kibanaUrl\": \"$KIBANA_URL\", \"elasticsearchEndpoint\": \"$ES_ENDPOINT\", \"apiKey\": \"$API_KEY\"}" > $AZ_SCRIPTS_OUTPUT_PATH

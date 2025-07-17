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
  --set controller.service.annotations."service\.beta\.kubernetes\.io/azure-load-balancer-internal"="false" \
  --set controller.service.annotations."service\.beta\.kubernetes\.io/azure-load-balancer-health-probe-request-path"=/healthz \
  --wait --timeout 10m

# Wait for LoadBalancer IP
echo "Waiting for LoadBalancer IP..."
for i in {1..60}; do
  LB_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
  if [ -n "$LB_IP" ] && [ "$LB_IP" != "" ]; then
    echo "LoadBalancer IP: $LB_IP"
    # Check if it's an internal IP
    if [[ $LB_IP =~ ^(10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|192\.168\.) ]]; then
      echo "WARNING: Got internal IP $LB_IP, waiting for external IP..."
    else
      echo "Got external IP: $LB_IP"
      break
    fi
  fi
  echo "Waiting for LoadBalancer IP... ($i/60)"
  sleep 10
done

INGRESS_IP=$LB_IP



# Install cert-manager
echo "Installing cert-manager..."
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --set installCRDs=true \
  --version v1.13.3 \
  --wait --timeout 10m

# Wait for cert-manager to be ready
echo "Waiting for cert-manager to be ready..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/instance=cert-manager -n cert-manager --timeout=300s

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
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: kibana-ingress
  namespace: elastic-system
  annotations:
    nginx.ingress.kubernetes.io/backend-protocol: "HTTP"
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
spec:
  ingressClassName: nginx
  tls:
  - secretName: kibana-tls
  rules:
  - http:
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
    nginx.ingress.kubernetes.io/proxy-body-size: "10m"
    nginx.ingress.kubernetes.io/rewrite-target: /\$2
    nginx.ingress.kubernetes.io/use-regex: "true"
spec:
  ingressClassName: nginx
  tls:
  - secretName: elasticsearch-tls
  rules:
  - http:
      paths:
      - path: /elasticsearch(/|$)(.*)
        pathType: Prefix
        backend:
          service:
            name: elasticsearch-master
            port:
              number: 9200
EOF

# Get Elasticsearch password
echo "Getting Elasticsearch credentials..."
ES_PASSWORD=$(kubectl get secret -n elastic-system elasticsearch-master-credentials -o jsonpath='{.data.password}' | base64 -d)

# Create API key using port-forward
echo "Setting up port-forward to Elasticsearch..."
kubectl port-forward -n elastic-system svc/elasticsearch-master 9200:9200 &
PF_PID=$!
sleep 5

# Permission needs to restrict
echo "Creating API key..."
API_KEY_RESPONSE=$(curl -s -k -u elastic:$ES_PASSWORD \
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
        }],
        "applications": [
          {
            "application": "kibana-.kibana",
            "privileges": ["all"],
            "resources": ["*"]
          }
        ]
      }
    }
  }')

# Kill port-forward
kill $PF_PID 2>/dev/null || true

API_KEY=$(echo $API_KEY_RESPONSE | jq -r .encoded)
# Prepare outputs
KIBANA_URL="https://$INGRESS_IP"
ES_ENDPOINT="https://$INGRESS_IP/elasticsearch"

# Dashboard creation section
echo "Creating default dashboard for $CUSTOMER_NAME..."
curl -o /tmp/dashboard.ndjson https://raw.githubusercontent.com/h4l0gen/ARM---Infra-deployment/refs/heads/main/linked-templates/dashboard.ndjson

# Replace placeholders in the dashboard
sed -i "s/\"title\":\"Talsec\"/\"title\":\"$CUSTOMER_NAME Dashboard\"/g" /tmp/dashboard-template.ndjson
sed -i "s/\"title\":\"s\*\"/\"title\":\"$INDEX_PATTERN\"/g" /tmp/dashboard-template.ndjson
sed -i "s/\"description\":\"testing\"/\"description\":\"$CUSTOMER_NAME Security Dashboard\"/g" /tmp/dashboard-template.ndjson

echo "Waiting for Kibana to be ready..."
TIMEOUT=300  # 5 minutes
ELAPSED=0
until curl -s -k "$KIBANA_URL/api/status" | grep -q "\"state\":\"green\"" || [ $ELAPSED -ge $TIMEOUT ]; do
  sleep 5
  ELAPSED=$((ELAPSED + 5))
  echo "Waited ${ELAPSED}s for Kibana..."
done

if [ $ELAPSED -ge $TIMEOUT ]; then
  echo "Warning: Kibana health check timed out, proceeding anyway..."
fi

# Import dashboard using API key
DASHBOARD_RESPONSE=$(curl -s -k -X POST "$KIBANA_URL/api/saved_objects/_import?overwrite=true" \
  -H "kbn-xsrf: true" \
  -H "Authorization: ApiKey $API_KEY" \
  -F "file=@/tmp/dashboard.ndjson")

echo "Dashboard import response: $DASHBOARD_RESPONSE"

# Verify dashboard creation
if echo "$DASHBOARD_RESPONSE" | grep -q "\"success\":true"; then
  echo "Dashboard created successfully!"
else
  echo "Warning: Dashboard creation may have failed"
fi

#https://github.com/h4l0gen/ARM---Infra-deployment/tree/main/linked-templates
# Test the endpoints
echo "Testing Kibana endpoint..."
curl -I $KIBANA_URL || true

echo "Deployment completed successfully!"
echo "Kibana URL: $KIBANA_URL"
echo "Elasticsearch Endpoint: $ES_ENDPOINT"
echo "API Key: $API_KEY"
echo "Kibana password: $ES_PASSWORD"

# Validate API_KEY exists
if [ -z "$API_KEY" ]; then
    echo "Warning: API_KEY is empty, using placeholder"
    API_KEY="API_KEY_GENERATION_FAILED"
fi

# Create JSON output with proper escaping
cat > $AZ_SCRIPTS_OUTPUT_PATH <<EOF
{
  "kibanaUrl": "$KIBANA_URL",
  "elasticsearchEndpoint": "$ES_ENDPOINT",
  "apiKey": "$API_KEY",
  "elasticPassword": "$ES_PASSWORD"
}
EOF

echo "Output file created successfully"

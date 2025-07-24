#!/bin/bash
set -e

echo "Starting Talsec Elastic Cloud Setup..."
echo "Organization: $ORGANIZATION_NAME"
echo "Deployment: $DEPLOYMENT_NAME" 
echo "Performance Tier: $PERFORMANCE_TIER"
echo "Region: $ELASTIC_REGION"
echo "Elasticsearch Version: $ELASTIC_VERSION"
echo "Data Retention: $RETENTION_DAYS days"
echo "Index Pattern: $INDEX_PATTERN"

# REQUIRED: Set your Elastic Cloud API key
ELASTIC_CLOUD_API_KEY="essu_VDB0SWRVNDFaMEpqYkZWdllUUTBjMUJ2VDJNNlRGWmxkbUpmUjAxU2NYVkVRWG95Y0d0bk1XWTBkdz09AAAAABJ1RIE="


# Function to map performance tiers to Elastic Cloud specs
get_elastic_memory() {
    case $PERFORMANCE_TIER in
        "basic")
            echo "1024"  # 1GB
            ;;
        "standard") 
            echo "4096"  # 4GB
            ;;
        "premium")
            echo "8192"  # 8GB
            ;;
        *)
            echo "1024"  # Default
            ;;
    esac
}

# Function to map Azure regions to Elastic Cloud regions
# map_elastic_region() {
#     case $ELASTIC_REGION in
#         "eastus")
#             echo "aws-us-east-1"
#             ;;
#         "westus2")
#             echo "aws-us-west-2"
#             ;;
#         "centralus")
#             echo "aws-us-central-1"
#             ;;
#         "northeurope")
#             echo "aws-eu-north-1"
#             ;;
#         "westeurope")
#             echo "aws-eu-west-1"
#             ;;
#         *)
#             echo "aws-us-east-1"
#             ;;
#     esac
# }

ELASTIC_MEMORY=$(get_elastic_memory)
# ELASTIC_CLOUD_REGION=$(map_elastic_region)
ELASTIC_CLOUD_REGION="azure-eastus"

echo "Creating Elastic Cloud deployment..."
echo "  Memory: ${ELASTIC_MEMORY}MB"
echo "  Region: $ELASTIC_CLOUD_REGION"
echo "  Version: $ELASTIC_VERSION"

# Create Elastic Cloud deployment
DEPLOYMENT_RESPONSE=$(curl -s -X POST "https://api.elastic-cloud.com/api/v1/deployments" \
  -H "Authorization: ApiKey $ELASTIC_CLOUD_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "'$DEPLOYMENT_NAME'",
    "resources": {
      "elasticsearch": [{
        "ref_id": "main-elasticsearch",
        "region": "'$ELASTIC_CLOUD_REGION'",
        "plan": {
          "deployment_template": {
            "id": "azure-general-purpose"
          },
          "elasticsearch": {
            "version": "'$ELASTIC_VERSION'"
          },
          "cluster_topology": [{
            "id": "hot_content",
            "node_roles": [
              "master",
              "ingest",
              "transform",
              "data_hot",
              "remote_cluster_client",
              "data_content"
            ],
            "elasticsearch": {
              "node_attributes": {
                "data": "hot"
              }
            },
            "instance_configuration_id": "azure.es.datahot.ddv4",
            "size": {
              "resource": "memory",
              "value": '$ELASTIC_MEMORY'
            },
            "zone_count": 1,
            "topology_element_control": {
              "min": {
                "resource": "memory",
                "value": 1024
              }
            }
          }]
        }
      }],
      "kibana": [{
        "ref_id": "main-kibana",
        "elasticsearch_cluster_ref_id": "main-elasticsearch",
        "region": "'$ELASTIC_CLOUD_REGION'",
        "plan": {
          "kibana": {
            "version": "'$ELASTIC_VERSION'"
          },
          "cluster_topology": [{
            "instance_configuration_id": "azure.kibana.fsv2",
            "size": {
              "resource": "memory",
              "value": 1024
            },
            "zone_count": 1
          }]
        }
      }]
    }
  }')

# Check if deployment creation failed
if echo "$DEPLOYMENT_RESPONSE" | grep -q "errors"; then
    echo "ERROR: Failed to create deployment"
    echo "Response: $DEPLOYMENT_RESPONSE"
    exit 1
fi

# Extract deployment info
echo "$DEPLOYMENT_STATUS" | jq '.'


DEPLOYMENT_ID=$(echo $DEPLOYMENT_RESPONSE | jq -r '.id')
echo "Deployment created with ID: $DEPLOYMENT_ID"

# Wait for deployment to be ready
echo "Waiting for deployment to be ready..."
TIMEOUT=1800  # 30 minutes
ELAPSED=0

while [ $ELAPSED -lt $TIMEOUT ]; do
    DEPLOYMENT_STATUS=$(curl -s -X GET "https://api.elastic-cloud.com/api/v1/deployments/$DEPLOYMENT_ID" \
      -H "Authorization: ApiKey $ELASTIC_CLOUD_API_KEY")
    
    ES_STATUS=$(echo $DEPLOYMENT_STATUS | jq -r '.resources.elasticsearch[0].info.status')
    KB_STATUS=$(echo $DEPLOYMENT_STATUS | jq -r '.resources.kibana[0].info.status')
    
    if [ "$ES_STATUS" = "started" ] && [ "$KB_STATUS" = "started" ]; then
        echo "Deployment is ready!"
        break
    fi
    
    echo "Status: ES=$ES_STATUS, Kibana=$KB_STATUS (waited ${ELAPSED}s)"
    sleep 30
    ELAPSED=$((ELAPSED + 30))
done

if [ $ELAPSED -ge $TIMEOUT ]; then
    echo "ERROR: Deployment timed out"
    exit 1
fi

# # Get deployment credentials and endpoints
# ELASTICSEARCH_ENDPOINT=$(echo $DEPLOYMENT_STATUS | jq -r '.resources.elasticsearch[0].info.metadata.endpoint')
# KIBANA_ENDPOINT=$(echo $DEPLOYMENT_STATUS | jq -r '.resources.kibana[0].info.metadata.endpoint')
echo "Fetching deployment details..."
DEPLOYMENT_DETAILS=$(curl -s -X GET "https://api.elastic-cloud.com/api/v1/deployments/$DEPLOYMENT_ID" \
  -H "Authorization: ApiKey $ELASTIC_CLOUD_API_KEY")

# Debug: Check the structure
echo "DEBUG: Checking deployment details structure..."
echo "$DEPLOYMENT_DETAILS" | jq -r '.resources | keys'
# Print the whole resources object
echo "$DEPLOYMENT_DETAILS" | jq '.resources'

# Print elasticsearch
echo "$DEPLOYMENT_DETAILS" | jq '.resources.elasticsearch'

# Print first elasticsearch element
echo "$DEPLOYMENT_DETAILS" | jq '.resources.elasticsearch[0]'

# Try different paths for endpoints
ELASTICSEARCH_ENDPOINT=$(echo $DEPLOYMENT_DETAILS | jq -r '
  .resources.elasticsearch[0].info.metadata.services.elasticsearch.https_endpoint //
  .resources.elasticsearch[0].info.metadata.endpoint //
  .resources.elasticsearch[0].info.elasticsearch_cluster_https_endpoint //
  .elasticsearch.https_endpoint //
  empty
' 2>/dev/null)

KIBANA_ENDPOINT=$(echo $DEPLOYMENT_DETAILS | jq -r '
  .resources.kibana[0].info.metadata.services.kibana.https_endpoint //
  .resources.kibana[0].info.metadata.endpoint //
  .resources.kibana[0].info.kibana_cluster_https_endpoint //
  .kibana.https_endpoint //
  empty
' 2>/dev/null)

# If endpoints are still empty, try the credentials endpoint
if [ -z "$ELASTICSEARCH_ENDPOINT" ]; then
    CREDS_RESPONSE=$(curl -s -X GET "https://api.elastic-cloud.com/api/v1/deployments/$DEPLOYMENT_ID/credentials" \
      -H "Authorization: ApiKey $ELASTIC_CLOUD_API_KEY")
    
    ELASTICSEARCH_ENDPOINT=$(echo $CREDS_RESPONSE | jq -r '.elasticsearch.https_endpoint // empty')
    KIBANA_ENDPOINT=$(echo $CREDS_RESPONSE | jq -r '.kibana.https_endpoint // empty')
fi

echo "Elasticsearch endpoint: $ELASTICSEARCH_ENDPOINT"
echo "Kibana endpoint: $KIBANA_ENDPOINT"
echo "Elastic password retrieving"
# Get the elastic user password
ELASTIC_PASSWORD=$(echo $DEPLOYMENT_RESPONSE | jq -r '.resources.elasticsearch[0].credentials.password // empty')
echo "Elastic password got: $ELASTIC_PASSWORD"

if [ -z "$ELASTIC_PASSWORD" ]; then
    echo "Resetting elastic user password..."
    RESET_RESPONSE=$(curl -s -X POST "https://api.elastic-cloud.com/api/v1/deployments/$DEPLOYMENT_ID/elasticsearch/main-elasticsearch/_reset-password" \
      -H "Authorization: ApiKey $ELASTIC_CLOUD_API_KEY")
    ELASTIC_PASSWORD=$(echo $RESET_RESPONSE | jq -r '.password')
fi

ELASTIC_USERNAME="elastic"

echo "Deployment endpoints ready:"
echo "  Elasticsearch: $ELASTICSEARCH_ENDPOINT"
echo "  Kibana: $KIBANA_ENDPOINT"
echo "  Username: $ELASTIC_USERNAME"

# Wait for Elasticsearch to be accessible
echo "Waiting for Elasticsearch to be accessible..."
TIMEOUT=300
ELAPSED=0

until curl -s -k -u "$ELASTIC_USERNAME:$ELASTIC_PASSWORD" "$ELASTICSEARCH_ENDPOINT" | grep -q "cluster_name" || [ $ELAPSED -ge $TIMEOUT ]; do
    sleep 10
    ELAPSED=$((ELAPSED + 10))
    echo "Waited ${ELAPSED}s for Elasticsearch..."
done

if [ $ELAPSED -ge $TIMEOUT ]; then
    echo "WARNING: Elasticsearch accessibility check timed out, proceeding anyway..."
fi

# Create deployment info file
cat > /tmp/deployment-info.json << EOF
{
  "deploymentId": "$DEPLOYMENT_ID",
  "elasticsearchEndpoint": "$ELASTICSEARCH_ENDPOINT",
  "kibanaEndpoint": "$KIBANA_ENDPOINT",
  "username": "$ELASTIC_USERNAME",
  "password": "$ELASTIC_PASSWORD",
  "organizationName": "$ORGANIZATION_NAME",
  "indexPattern": "$INDEX_PATTERN",
  "performanceTier": "$PERFORMANCE_TIER",
  "region": "$ELASTIC_REGION",
  "version": "$ELASTIC_VERSION",
  "retentionDays": "$RETENTION_DAYS",
  "status": "ready",
  "createdAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

echo "Setup completed successfully!"

# Display summary
echo ""
echo "=== TALSEC ELASTIC CLOUD DEPLOYMENT SUMMARY ==="
echo "Organization: $ORGANIZATION_NAME"
echo "Deployment Name: $DEPLOYMENT_NAME"
echo "Deployment ID: $DEPLOYMENT_ID"
echo "Elasticsearch: $ELASTICSEARCH_ENDPOINT"
echo "Kibana: $KIBANA_ENDPOINT"
echo "Username: $ELASTIC_USERNAME"
echo "Password: $ELASTIC_PASSWORD"
echo "Performance Tier: $PERFORMANCE_TIER"
echo "Data Retention: $RETENTION_DAYS days"
echo "Status: Ready"
echo "==============================================="

echo ""
echo "=== NEXT STEPS ==="
echo "1. Access Kibana at: $KIBANA_ENDPOINT"
echo "2. Login with username: $ELASTIC_USERNAME"
echo "4. Send logs to: $ELASTICSEARCH_ENDPOINT"
echo "5. Use index pattern: $INDEX_PATTERN"
echo "=================="

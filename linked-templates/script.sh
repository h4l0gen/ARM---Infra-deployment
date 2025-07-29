#!/bin/bash

echo "Waiting for Elastic deployment to be ready..."
sleep 120

# Get Elastic monitor details
MONITOR_JSON=$(az resource show --resource-group $RESOURCE_GROUP --resource-type Microsoft.Elastic/monitors --name $MONITOR_NAME --api-version 2025-01-15-preview)

# Extract endpoints using Azure CLI's built-in JMESPath
KIBANA_URL=$(echo $MONITOR_JSON | az resource show --ids $(echo $MONITOR_JSON | jq -r '.id') --query 'properties.elasticCloudDeployment.kibanaEndPoint' -o tsv)
ELASTIC_URL=$(echo $MONITOR_JSON | az resource show --ids $(echo $MONITOR_JSON | jq -r '.id') --query 'properties.elasticCloudDeployment.elasticsearchEndPoint' -o tsv)

# Note: You need to retrieve password securely
PASSWORD="YourPassword"  # This should be retrieved securely
AUTH_HEADER="Authorization: Basic $(echo -n elastic:$PASSWORD | base64)"

echo "Cleaning Kibana saved objects..."

# Array of saved object types to clean
OBJECT_TYPES=("dashboard" "visualization" "search" "index-pattern" "lens" "map" "canvas-workpad" "canvas-element")

for TYPE in "${OBJECT_TYPES[@]}"; do
    echo "Processing $TYPE objects..."
    
    # Find all objects of this type
    RESPONSE=$(curl -s -X GET "$KIBANA_URL/api/saved_objects/_find?type=$TYPE&per_page=10000" \
        -H "$AUTH_HEADER" \
        -H "Content-Type: application/json" \
        -H "kbn-xsrf: true")
    
    # Extract object IDs using jq
    OBJECT_IDS=$(echo $RESPONSE | jq -r ".saved_objects[]?.id")
    
    if [ ! -z "$OBJECT_IDS" ]; then
        while IFS= read -r ID; do
            if [ ! -z "$ID" ]; then
                curl -X DELETE "$KIBANA_URL/api/saved_objects/$TYPE/$ID?force=true" \
                    -H "$AUTH_HEADER" \
                    -H "kbn-xsrf: true"
                echo "Deleted $TYPE: $ID"
            fi
        done <<< "$OBJECT_IDS"
    fi
done

# Clean sample data
SAMPLE_DATASETS=("flights" "logs" "ecommerce")
for DATASET in "${SAMPLE_DATASETS[@]}"; do
    curl -X DELETE "$KIBANA_URL/api/sample_data/$DATASET" \
        -H "$AUTH_HEADER" \
        -H "kbn-xsrf: true" || true
    echo "Attempted to remove sample data: $DATASET"
done

echo "Cleanup completed successfully!"

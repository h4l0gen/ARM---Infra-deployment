#!/bin/bash

set -e

echo "Starting Elasticsearch and Kibana setup script..."
echo "Waiting for services to be fully ready..."
sleep 180  # Wait 3 minutes for both services to start

curl -X POST "http://elasticsearch:9200/_security/user/kibana_system/_password" \
  -u elastic:$ELASTIC_PASSWORD \
  -H 'Content-Type: application/json' \
  -d '{"password":"'$KIBANA_SYSTEM_PASSWORD'"}'

# Get the Kibana URL from Container Apps
KIBANA_FQDN=$(az containerapp show \
  --name $KIBANA_NAME \
  --resource-group $RESOURCE_GROUP \
  --query "properties.configuration.ingress.fqdn" -o tsv)

ELASTICSEARCH_FQDN=$(az containerapp show \
  --name $ELASTICSEARCH_NAME \
  --resource-group $RESOURCE_GROUP \
  --query "properties.configuration.ingress.fqdn" -o tsv)

KIBANA_URL="https://$KIBANA_FQDN"
ELASTIC_URL="http://$ELASTICSEARCH_FQDN:9200"

echo "Kibana URL: $KIBANA_URL"
echo "Elasticsearch URL: $ELASTIC_URL"

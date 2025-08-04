#!/bin/bash

ELASTIC_URL="$ELASTICSEARCH_NAME"
KIBANA_URL="$KIBANA_NAME"
ELASTIC_USER="elastic"
ELASTIC_PASSWORD="$ELASTIC_PASSWORD"  # Pass this as secure parameter
KIBANA_SYSTEM_PASSWORD="$KIBANA_SYSTEM_PASSWORD"  # Pass this as secure parameter

echo "$ELASTIC_URL"
echo "$KIBANA_URL"
echo "KIBANA_SYSTEM_PASSWORD length: ${#KIBANA_SYSTEM_PASSWORD}"
echo "KIBANA_SYSTEM_PASSWORD exists: $([ -n "$KIBANA_SYSTEM_PASSWORD" ] && echo "YES" || echo "NO")"
echo "$KIBANA_SYSTEM_PASSWORD"

wait_for_elasticsearch() {
    echo "Waiting for Elasticsearch to be ready..."
    for i in {1..30}; do
        RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" -u "$ELASTIC_USER:$ELASTIC_PASSWORD" "$ELASTIC_URL")
        
        if [ "$RESPONSE" -eq "200" ]; then
            echo "Elasticsearch is ready and authenticated!"
            return 0
        elif [ "$RESPONSE" -eq "401" ]; then
            echo "Elasticsearch is ready but authentication failed - check credentials"
            exit 1
        else
            echo "Waiting for Elasticsearch... ($i/30) Response: $RESPONSE"
        fi
        
        sleep 10
    done
    echo "Elasticsearch failed to become ready after 5 minutes"
    exit 1
}

wait_for_kibana() {
    echo "Waiting for Kibana to be ready..."
    for i in {1..30}; do
        RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" -X GET "$KIBANA_URL/api/status" -H "kbn-xsrf: true" -u "$ELASTIC_USER:$ELASTIC_PASSWORD")
        
        if [ "$RESPONSE" -eq "200" ]; then
            echo "Kibana is ready!"
            return 0
        elif [ "$RESPONSE" -eq "503" ]; then
            echo "Kibana is starting... ($i/30)"
        elif [ "$RESPONSE" -eq "401" ]; then
            echo "Kibana authentication failed - check credentials"
            exit 1
        else
            echo "Unexpected response: $RESPONSE ($i/30)"
        fi
        
        if [ $i -eq 30 ]; then
            echo "Kibana failed to become ready after 5 minutes"
            exit 1
        fi
        
        sleep 10
    done
}

# Function to setup passwords if not already configured
setup_passwords() {
    echo "Checking if passwords need to be configured..."
    RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" -u "$ELASTIC_USER:$ELASTIC_PASSWORD" "$ELASTIC_URL/_security/_authenticate")
    
    if [ "$RESPONSE" -eq "200" ]; then
        echo "Passwords are already configured"
    else
        echo "Configuring built-in users passwords..."
        # This would only work if security is enabled but default passwords are still set
        curl -X POST -u "elastic:changeme" "$ELASTIC_URL/_security/user/elastic/_password" \
            -H "Content-Type: application/json" \
            -d "{\"password\":\"$ELASTIC_PASSWORD\"}" || echo "Password change may have failed"
        
        curl -X POST -u "elastic:$ELASTIC_PASSWORD" "$ELASTIC_URL/_security/user/kibana_system/_password" \
            -H "Content-Type: application/json" \
            -d "{\"password\":\"$KIBANA_SYSTEM_PASSWORD\"}" || echo "Kibana user password change may have failed"
    fi
}

# Main execution flow
wait_for_elasticsearch

echo "setting up password"
setup_passwords
echo "now waiting for kibana"
wait_for_kibana

echo "Connected successfully!"

# Configure ILM policy with authentication
curl -X PUT -u "$ELASTIC_USER:$ELASTIC_PASSWORD" "$ELASTIC_URL/_ilm/policy/talsec_prod_policy" \
  -H "Content-Type: application/json" \
  -d '{
    "policy": {
      "phases": {
        "hot": {
          "min_age": "0ms",
          "actions": {
            "rollover": {
              "max_size": "10gb",
              "max_age": "3h"
            },
            "set_priority": {
              "priority": 100
            }
          }
        }
      }
    }
  }'

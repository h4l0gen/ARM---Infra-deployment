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

setup_passwords() {
    echo "Setting up kibana_system password..."
    
    # Set the kibana_system password
    KIBANA_SET_RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
        -u "$ELASTIC_USER:$ELASTIC_PASSWORD" \
        "$ELASTIC_URL/_security/user/kibana_system/_password" \
        -H "Content-Type: application/json" \
        -d "{\"password\":\"$KIBANA_SYSTEM_PASSWORD\"}")
    
    if [ "$KIBANA_SET_RESPONSE" -eq "200" ]; then
        echo "Successfully set kibana_system password"
    else
        echo "Failed to set kibana_system password. Response: $KIBANA_SET_RESPONSE"
        exit 1
    fi
    
    # Verify kibana_system can authenticate
    VERIFY_RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" \
        -u "kibana_system:$KIBANA_SYSTEM_PASSWORD" \
        "$ELASTIC_URL/_security/_authenticate")
    
    if [ "$VERIFY_RESPONSE" -eq "200" ]; then
        echo "kibana_system user successfully authenticated"
    else
        echo "kibana_system authentication failed. Response: $VERIFY_RESPONSE"
        exit 1
    fi
}

wait_for_kibana() {
    echo "Waiting for Kibana to be ready..."
    for i in {1..18}; do
        RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" -X GET "$KIBANA_URL/api/status" -H "kbn-xsrf: true" -u "$ELASTIC_USER:$ELASTIC_PASSWORD")
        
        if [ "$RESPONSE" -eq "200" ]; then
            echo "Kibana is ready!"
            return 0
        elif [ "$RESPONSE" -eq "503" ]; then
            echo "Kibana is starting... ($i/18)"
        else
            echo "Unexpected response: $RESPONSE ($i/18)"
        fi
        
        sleep 10
    done
    echo "Kibana failed to become ready after 3 minutes"
    exit 1
}

setup_passwords
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

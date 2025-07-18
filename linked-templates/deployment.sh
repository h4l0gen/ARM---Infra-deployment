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
   "name": "marketplace-superuser-key",
   "role_descriptors": {
     "superuser_role": {
       "cluster": ["all"],
       "indices": [{
         "names": ["*"],
         "privileges": ["all"]
       }],
       "applications": [{
         "application": "*",
         "privileges": ["*"],
         "resources": ["*"]
       }]
     }
   }
 }')

# Kill port-forward
kill $PF_PID 2>/dev/null || true

API_KEY=$(echo $API_KEY_RESPONSE | jq -r .encoded)
# Prepare outputs
KIBANA_URL="https://$INGRESS_IP"
ES_ENDPOINT="https://$INGRESS_IP/elasticsearch"

# ILM policy creation
echo "Creating ILM policy for $CUSTOMER_NAME..."

curl -s --insecure -X PUT "$ES_ENDPOINT/_ilm/policy/talsec_prod_policy" \
  -H "Authorization: ApiKey $API_KEY" \
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

# Common template 1
curl -s --insecure -X PUT "$ES_ENDPOINT/_component_template/talsec_device_info" \
  -H "Authorization: ApiKey $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "template": {
      "mappings": {
        "properties": {
          "instanceId": {
            "type": "keyword"
          },
          "defaultDeviceId": {
            "eager_global_ordinals": true,
            "norms": false,
            "index": true,
            "store": false,
            "type": "keyword",
            "split_queries_on_whitespace": false,
            "index_options": "docs",
            "doc_values": true
          },
          "deviceState": {
            "type": "object",
            "properties": {
              "biometrics": {
                "type": "keyword"
              },
              "security": {
                "type": "keyword"
              },
              "hwBackedKeychain": {
                "type": "keyword"
              }
            }
          },
          "platform": {
            "type": "keyword"
          },
          "deviceInfo": {
            "type": "object",
            "properties": {
              "osVersion": {
                "type": "keyword"
              },
              "model": {
                "type": "keyword"
              },
              "manufacturer": {
                "type": "keyword"
              }
            }
          }
        }
      }
    }
  }'

# common template 2
curl -s --insecure -X PUT "$ES_ENDPOINT/_component_template/talsec_metadata" \
  -H "Authorization: ApiKey $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "template": {
      "mappings": {
        "properties": {
          "occurence": {
            "type": "date"
          },
          "@timestamp": {
            "type": "date"
          },
          "externalId": {
            "type": "keyword"
          },
          "sessionId": {
            "type": "keyword"
          }
        }
      }
    }
  }'

# common template 3
curl -s --insecure -X PUT "$ES_ENDPOINT/_component_template/talsec_app_info" \
  -H "Authorization: ApiKey $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "template":{
      "mappings":{
         "_routing":{
            "required":false
         },
         "numeric_detection":false,
         "dynamic_date_formats":[
            "strict_date_optional_time",
            "yyyy/MM/dd HH:mm:ss Z||yyyy/MM/dd Z"
         ],
         "dynamic":true,
         "_source":{
            "excludes":[

            ],
            "includes":[

            ],
            "enabled":true
         },
         "dynamic_templates":[

         ],
         "date_detection":true,
         "properties":{
            "appInfo":{
               "type":"object",
               "properties":{
                  "appVersion":{
                     "type":"keyword"
                  },
                  "appIdentifier":{
                     "type":"keyword"
                  },
                  "applicationIdentifier":{
                     "type":"keyword"
                  }
               }
            }
         }
      }
   }
}'

# common template 3
curl -s --insecure -X PUT "$ES_ENDPOINT/_component_template/talsec_sdk_info" \
  -H "Authorization: ApiKey $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "template":{
        "mappings":{
          "properties":{
              "sdkIdentifier":{
                "type":"keyword"
              },
              "sdkPlatform":{
                "type":"keyword"
              },
              "configVersion":{
                "type":"keyword"
              },
              "sdkVersion":{
                "type":"keyword"
              },
              "dynamicConfigVersion":{
                "type":"keyword"
              }
          }
        }
    }
}'

curl -s --insecure -X PUT "$ES_ENDPOINT/_component_template/talsec_fullrasp" \
  -H "Authorization: ApiKey $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "template":{
      "mappings":{
         "properties":{
            "identifiedWith":{
               "type":"keyword"
            },
            "securityWatcherMail":{
               "type":"keyword"
            },
            "securityReportMail":{
               "type":"keyword"
            }
         }
      }
   }
}'

curl -s --insecure -X PUT "$ES_ENDPOINT/_component_template/talsec_incident_info" \
  -H "Authorization: ApiKey $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "template":{
      "mappings":{
         "properties":{
            "checks":{
               "type":"object",
               "properties":{
                  "unofficialStore":{
                     "type":"object",
                     "properties":{
                        "status":{
                           "type":"keyword"
                        },
                        "timeMs":{
                           "type":"long"
                        }
                     }
                  },
                  "debug":{
                     "type":"object",
                     "properties":{
                        "status":{
                           "type":"keyword"
                        },
                        "timeMs":{
                           "type":"long"
                        }
                     }
                  },
                  "simulator":{
                     "type":"object",
                     "properties":{
                        "status":{
                           "type":"keyword"
                        },
                        "timeMs":{
                           "type":"long"
                        }
                     }
                  },
                  "privilegedAccess":{
                     "type":"object",
                     "properties":{
                        "status":{
                           "type":"keyword"
                        },
                        "timeMs":{
                           "type":"long"
                        }
                     }
                  },
                  "appIntegrity":{
                     "type":"object",
                     "properties":{
                        "status":{
                           "type":"keyword"
                        },
                        "timeMs":{
                           "type":"long"
                        }
                     }
                  },
                  "hooks":{
                     "type":"object",
                     "properties":{
                        "status":{
                           "type":"keyword"
                        },
                        "timeMs":{
                           "type":"long"
                        }
                     }
                  },
                  "deviceBinding":{
                     "type":"object",
                     "properties":{
                        "status":{
                           "type":"keyword"
                        },
                        "timeMs":{
                           "type":"long"
                        }
                     }
                  },
                  "obfuscationIssues":{
                     "type":"object",
                     "properties":{
                        "status":{
                           "type":"keyword"
                        },
                        "timeMs":{
                           "type":"long"
                        }
                     }
                  },
                  "systemVPN":{
                     "type":"object",
                     "properties":{
                        "status":{
                           "type":"keyword"
                        },
                        "timeMs":{
                           "type":"long"
                        }
                     }
                  },
                  "screenCapture":{
                     "type":"object",
                     "properties":{
                        "status":{
                           "type":"keyword"
                        },
                        "timeMs":{
                           "type":"long"
                        }
                     }
                  },
                  "screenshot":{
                     "type":"object",
                     "properties":{
                        "status":{
                           "type":"keyword"
                        },
                        "timeMs":{
                           "type":"long"
                        }
                     }
                  },
                  "screenRecording":{
                     "type":"object",
                     "properties":{
                        "status":{
                           "type":"keyword"
                        },
                        "timeMs":{
                           "type":"long"
                        }
                     }
                  }
               }
            },
            "incidentReport":{
               "type":"object",
               "properties":{
                  "type":{
                     "type":"keyword"
                  },
                  "featureTestingIgnored":{
                     "type":"object"
                  },
                  "info":{
                     "type":"object",
                     "properties":{
                        "sdkIntegrityCompromised":{
                           "type":"text"
                        },
                        "captureType":{
                           "type":"keyword"
                        }
                     }
                  }
               }
            },
            "type":{
               "type":"keyword"
            }
         }
      }
   }
}'

curl -s --insecure -X PUT "$ES_ENDPOINT/_component_template/talsec_incident_info_screenshot" \
  -H "Authorization: ApiKey $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "template":{
      "mappings":{
         "properties":{
            "incidentReport":{
               "type":"object",
               "properties":{
                  "info":{
                     "type":"object",
                     "properties":{
                        "detected":{
                           "type":"boolean"
                        }
                     }
                  }
               }
            }
         }
      }
   }
}'

curl -s --insecure -X PUT "$ES_ENDPOINT/_component_template/talsec_incident_info_screen_recording" \
  -H "Authorization: ApiKey $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "template": {
      "mappings": {
        "properties": {
          "occurence": {
            "type": "date"
          },
          "@timestamp": {
            "type": "date"
          },
          "externalId": {
            "type": "keyword"
          },
          "sessionId": {
            "type": "keyword"
          }
        }
      }
    }
  }'

# Android templates now

curl -s --insecure -X PUT "$ES_ENDPOINT/_component_template/talsec_device_info_android" \
  -H "Authorization: ApiKey $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "template":{
      "mappings":{
         "properties":{
            "deviceState":{
               "type":"object",
               "properties":{
                  "hasHuaweiMobileServices":{
                     "type":"boolean"
                  },
                  "securityPatch":{
                     "type":"date"
                  },
                  "isAdbEnabled":{
                     "type":"keyword"
                  },
                  "hasGoogleMobileServices":{
                     "type":"boolean"
                  },
                  "isVerifyAppsEnabled":{
                     "type":"boolean"
                  },
                  "selinuxProperties": {
                    "type": "object",
                    "properties": {
                      "buildSelinuxProperty": {
                        "type": "keyword"
                      },
                      "selinuxMode": {
                        "type": "keyword"
                      },
                      "bootSelinuxProperty": {
                        "type": "keyword"
                      },
                      "selinuxEnforcementFileContent": {
                        "type": "keyword"
                      },
                      "selinuxEnabledReflect": {
                        "type": "keyword"
                      },
                      "selinuxEnforcedReflect": {
                        "type": "keyword"
                      }
                    }
                  }
               }
            },
            "deviceId":{
               "type":"object",
               "properties":{
                  "mediaDrm":{
                     "type":"keyword"
                  },
                  "fingerprintV3":{
                     "type":"keyword"
                  },
                  "androidId":{
                     "type":"keyword"
                  }
               }
            }
         }
      }
   }
}'


curl -s --insecure -X PUT "$ES_ENDPOINT/_component_template/talsec_app_info_android" \
  -H "Authorization: ApiKey $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "template":{
      "mappings":{
         "properties":{
            "appInfo":{
               "type":"object",
               "properties":{
                  "alternativeCertHashes":{
                     "type":"keyword"
                  },
                  "certHash":{
                     "type":"keyword"
                  },
                  "installationSource":{
                     "type":"keyword"
                  },
                  "installedFromUnofficialStore":{
                     "type":"keyword"
                  }
               }
            },
            "accessibilityApps":{
               "type":"keyword"
            }
         }
      }
   }
}'

curl -s --insecure -X PUT "$ES_ENDPOINT/_component_template/talsec_sdk_state_android" \
  -H "Authorization: ApiKey $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "template":{
      "mappings":{
         "properties":{
            "sdkState":{
               "type":"object",
               "properties":{
                  "beatExecutionState":{
                     "type":"keyword"
                  },
                  "controlExecutionState":{
                     "type":"keyword"
                  }
               }
            }
         }
      }
   }
}'

curl -s --insecure -X PUT "$ES_ENDPOINT/_component_template/talsec_incident_info_android" \
  -H "Authorization: ApiKey $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "template":{
      "mappings":{
         "properties":{
            "checks":{
               "type":"object",
               "properties":{
                  "overlay":{
                     "type":"object",
                     "properties":{
                        "status":{
                           "type":"keyword"
                        }
                     }
                  },
                  "accessibility":{
                     "type":"object",
                     "properties":{
                        "status":{
                           "type":"keyword"
                        }
                     }
                  },
                  "devMode":{
                     "type":"object",
                     "properties":{
                        "status":{
                           "type":"keyword"
                        },
                        "timeMs":{
                           "type":"long"
                        }
                     }
                  },
                  "malware":{
                     "type":"object",
                     "properties":{
                        "status":{
                           "type":"keyword"
                        },
                        "timeMs":{
                           "type":"long"
                        }
                     }
                  },
                  "adbEnabled":{
                     "type":"object",
                     "properties":{
                        "status":{
                           "type":"keyword"
                        },
                        "timeMs":{
                           "type":"long"
                        }
                     }
                  }
               }
            }
         }
      }
   }
}'

curl -s --insecure -X PUT "$ES_ENDPOINT/_component_template/talsec_incident_info_privileged_access_android" \
  -H "Authorization: ApiKey $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "template":{
      "mappings":{
         "properties":{
            "incidentReport":{
               "type":"object",
               "properties":{
                  "featureTestingIgnored":{
                     "type": "object",
                     "properties":{
                         "isRunningSuProcessesPS":{
                            "type": "keyword"
                         },
                         "hasMagiskMountPaths":{
                            "type": "keyword"
                         },
                         "isRunningSuProcessesStatsManager":{
                            "type": "keyword"
                         },
                         "isSuOnPath":{
                            "type": "keyword"
                         },
                         "hasRootingPackagesInstalled":{
                            "type": "keyword"
                         },
                         "hasMagiskStub":{
                            "type": "keyword"
                         },
                         "isRunningSuProcessesActivityManager":{
                            "type": "keyword"
                         }
                     }
                  },
                  "info":{
                     "type":"object",
                     "properties":{
                        "hasMagiskStub":{
                            "type": "keyword"
                         },
                        "isSystemPropertyEqualTo":{
                           "type":"keyword"
                        },
                        "areFilesPresent":{
                           "type":"keyword"
                        },
                        "rootNative":{
                           "type":"keyword"
                        },
                        "isSuOnPath":{
                           "type":"keyword"
                        },
                        "isSElinuxInPermisiveMode":{
                           "type":"keyword"
                        },
                        "isRunningSuProcessesPS":{
                           "type":"keyword"
                        },
                        "areFoldersWritable":{
                           "type":"keyword"
                        },
                        "isRunningSuProcessesStatsManager":{
                           "type":"keyword"
                        },
                        "areTestKeysEnabled":{
                           "type":"keyword"
                        },
                        "areBinariesPresent":{
                           "type":"keyword"
                        },
                        "isOtaCertificateMissing":{
                           "type":"keyword"
                        },
                        "isSafetyNetBypassDetected":{
                           "type":"boolean"
                        },
                        "canExecuteCommandUsingWhich":{
                           "type":"keyword"
                        },
                        "checkPropertyDebuggable":{
                           "type":"keyword"
                        },
                        "canExecuteCommand":{
                           "type":"keyword"
                        },
                        "hasRootingPackagesInstalled":{
                           "type":"keyword"
                        },
                        "areApksAvailable":{
                           "type":"keyword"
                        },
                        "isRunningSuProcessesActivityManager":{
                           "type":"keyword"
                        },
                        "hasFeatureTestingData": {
                           "type":"boolean"
                        },
                        "shamikoHiderNative":{
                            "type": "boolean"
                         }
                     }
                  }
               }
            }
         }
      }
   }
}'

curl -s --insecure -X PUT "$ES_ENDPOINT/_component_template/talsec_incident_info_app_integrity_android" \
  -H "Authorization: ApiKey $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "template":{
      "mappings":{
         "properties":{
            "incidentReport":{
               "type":"object",
               "properties":{
                  "featureTestingIgnored": {
                    "type": "object",
                    "properties": {
                      "appIntegrityCheckError": {
                        "type": "keyword"
                      },
                      "invalidSignatureDigestList": {
                        "type": "keyword"
                      },
                      "invalidCertificateInfoList": {
                        "type": "object",
                        "properties": {
                          "serial": {
                            "type": "keyword"
                          },
                          "subject": {
                            "type": "keyword"
                          },
                          "subjectAlternativeNames": {
                            "type": "keyword"
                          },
                          "issuerAlternativeNames": {
                            "type": "keyword"
                          },
                          "issuer": {
                            "type": "keyword"
                          }
                        }
                      }
                    }
                  },
                  "info":{
                     "type":"object",
                     "properties":{
                        "appIntegrityCheckError": {
                          "type": "keyword"
                        },
                        "hasMultipleSignatures": {
                          "type": "keyword"
                        },
                        "hasInvalidSignatureDigest":{
                           "type":"keyword"
                        },
                        "certificateInfo":{
                           "type":"object",
                           "properties":{
                              "serial":{
                                 "type":"keyword"
                              },
                              "subject":{
                                 "type":"text"
                              },
                              "subjectAlternativeNames":{
                                 "type":"text"
                              },
                              "issuerAlternativeNames":{
                                 "type":"text"
                              },
                              "issuer":{
                                 "type":"text"
                              }
                           }
                        },
                        "incorrectPackageName":{
                           "type":"keyword"
                        },
                        "incorrectPackageNameNative":{
                           "type":"keyword"
                        },
                        "hasInvalidSignatureDigestNative":{
                           "type":"keyword"
                        }
                     }
                  }
               }
            }
         }
      }
   }
}'

curl -s --insecure -X PUT "$ES_ENDPOINT/_component_template/talsec_incident_info_missing_obfuscation_android" \
  -H "Authorization: ApiKey $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "template":{
      "mappings":{
         "properties":{
            "incidentReport":{
               "type":"object",
               "properties":{
                  "info":{
                     "type":"object",
                     "properties":{
                        "apiMethodNameNotObfuscated":{
                           "type":"keyword"
                        }
                     }
                  }
               }
            }
         }
      }
   }
}'

curl -s --insecure -X PUT "$ES_ENDPOINT/_component_template/talsec_incident_info_hooks_android" \
  -H "Authorization: ApiKey $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "template":{
      "mappings":{
         "properties":{
            "incidentReport":{
               "type":"object",
               "properties":{
                  "info":{
                     "type":"object",
                     "properties":{
                        "areFridaLibrariesDetected":{
                           "type":"keyword"
                        },
                        "isXposedVersionAvailable":{
                           "type":"keyword"
                        },
                        "checkStackTrace":{
                           "type":"keyword"
                        },
                        "checkNativeMethods":{
                           "type":"keyword"
                        },
                        "isFridaProcessInProc":{
                           "type":"keyword"
                        },
                        "isFridaServerListening":{
                           "type":"keyword"
                        },
                        "checkFrameworks":{
                           "type":"keyword"
                        },
                        "fridaNative":{
                           "type":"keyword"
                        },
                        "detectSharedObjsAndJarsLoadedInMemory":{
                           "type":"keyword"
                        }
                     }
                  }
               }
            }
         }
      }
   }
}'

curl -s --insecure -X PUT "$ES_ENDPOINT/_component_template/talsec_incident_info_debug_android" \
  -H "Authorization: ApiKey $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "template":{
      "mappings":{
         "properties":{
            "incidentReport":{
               "type":"object",
               "properties":{
                  "info":{
                     "type":"object",
                     "properties":{
                        "isDebuggerConnected":{
                           "type":"keyword"
                        },
                        "isBuildConfigDebug":{
                           "type":"keyword"
                        },
                        "isApplicationFlagEnabled":{
                           "type":"keyword"
                        },
                        "hasTracerPid":{
                           "type":"keyword"
                        }
                     }
                  }
               }
            }
         }
      }
   }
}'

curl -s --insecure -X PUT "$ES_ENDPOINT/_component_template/talsec_incident_info_simulator_android" \
  -H "Authorization: ApiKey $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "template":{
      "mappings":{
         "properties":{
            "incidentReport":{
               "type":"object",
               "properties":{
                  "info":{
                     "type":"object",
                     "properties":{
                        "checkEmulatorProduct":{
                           "type":"keyword"
                        },
                        "checkPropertyWhichIsOnlyOnEmulator":{
                           "type":"keyword"
                        },
                        "checkVoiceMailNumber":{
                           "type":"keyword"
                        },
                        "checkEmulatorDevice":{
                           "type":"keyword"
                        },
                        "checkEmulatorPropertyValues":{
                           "type":"keyword"
                        },
                        "checkSubsriberId":{
                           "type":"keyword"
                        },
                        "checkEmulatorManufacturer":{
                           "type":"keyword"
                        },
                        "checkEmulatorBrand":{
                           "type":"keyword"
                        },
                        "checkSimSerial":{
                           "type":"keyword"
                        },
                        "fakeDeviceProfile":{
                           "type":"object",
                           "properties":{
                              "cpuAbi":{
                                 "type":"keyword"
                              },
                              "product":{
                                 "type":"keyword"
                              },
                              "release":{
                                 "type":"keyword"
                              },
                              "cpuVendor":{
                                 "type":"keyword"
                              },
                              "model":{
                                 "type":"keyword"
                              },
                              "device":{
                                 "type":"keyword"
                              },
                              "board":{
                                 "type":"keyword"
                              },
                              "hardware":{
                                 "type":"keyword"
                              }
                           }
                        },
                        "checkEmulatorUser":{
                           "type":"keyword"
                        },
                        "checkEmulatorModel":{
                           "type":"keyword"
                        },
                        "checkLine1Number":{
                           "type":"keyword"
                        },
                        "checkEmulatorHardware":{
                           "type":"keyword"
                        },
                        "checkEmulatorFingerprint":{
                           "type":"keyword"
                        }
                     }
                  }
               }
            }
         }
      }
   }
}'

curl -s --insecure -X PUT "$ES_ENDPOINT/_component_template/talsec_incident_info_overlay_android" \
  -H "Authorization: ApiKey $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "template":{
      "mappings":{
         "properties":{
            "incidentReport":{
               "type":"object",
               "properties":{
                  "info":{
                     "type":"object",
                     "properties":{
                        "isObscuredMotionEvent":{
                           "type":"keyword"
                        },
                        "overlayInstalledApps":{
                           "type":"keyword"
                        }
                     }
                  }
               }
            }
         }
      }
   }
}'

curl -s --insecure -X PUT "$ES_ENDPOINT/_component_template/talsec_incident_info_accessibility_android" \
  -H "Authorization: ApiKey $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "template":{
      "mappings":{
         "properties":{
            "incidentReport":{
               "type":"object",
               "properties":{
                  "info":{
                     "type":"object",
                     "properties":{
                        "unknownServices":{
                           "type":"keyword"
                        }
                     }
                  }
               }
            },
            "accessibilityApps":{
               "type":"keyword"
            }
         }
      }
   }
}'

curl -s --insecure -X PUT "$ES_ENDPOINT/_component_template/talsec_incident_info_unofficial_store_android" \
  -H "Authorization: ApiKey $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "template":{
      "mappings":{
         "properties":{
            "incidentReport":{
               "type":"object",
               "properties":{
                  "info":{
                     "type":"object",
                     "properties":{
                        "unofficialInstallationSourceNative":{
                           "type":"keyword"
                        },
                        "unofficialInstallationSource":{
                           "type":"keyword"
                        }
                     }
                  }
               }
            }
         }
      }
   }
}'

curl -s --insecure -X PUT "$ES_ENDPOINT/_component_template/talsec_incident_info_device_binding_android" \
  -H "Authorization: ApiKey $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "template":{
      "mappings":{
         "properties":{
            "incidentReport":{
               "type":"object",
               "properties":{
                  "info":{
                     "type":"object",
                     "properties":{
                        "didKeyStoreChange":{
                           "type":"keyword"
                        },
                        "didAndroidIdChange":{
                           "type":"keyword"
                        }
                     }
                  }
               }
            }
         }
      }
   }
}'

curl -s --insecure -X PUT "$ES_ENDPOINT/_component_template/talsec_incident_info_devmode_android" \
  -H "Authorization: ApiKey $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "template":{
      "mappings":{
         "properties":{
            "incidentReport":{
               "type":"object",
               "properties":{
                  "info":{
                     "type":"object",
                     "properties":{
                        "isDeveloperModeEnabled":{
                           "type":"keyword"
                        }
                     }
                  }
               }
            }
         }
      }
   }
}'

curl -s --insecure -X PUT "$ES_ENDPOINT/_component_template/talsec_incident_info_systemvpn_android" \
  -H "Authorization: ApiKey $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "template":{
      "mappings":{
         "properties":{
            "incidentReport":{
               "type":"object",
               "properties":{
                  "info":{
                     "type":"object",
                     "properties":{
                        "isVpnRunning":{
                           "type":"keyword"
                        }
                     }
                  }
               }
            }
         }
      }
   }
}'

curl -s --insecure -X PUT "$ES_ENDPOINT/_component_template/talsec_incident_info_monitoring_android" \
  -H "Authorization: ApiKey $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "template":{
      "mappings":{
         "properties":{
            "incidentReport":{
               "type":"object",
               "properties":{
                  "info":{
                     "type":"object",
                     "properties":{
                        "componentHeartbeat":{
                           "type":"keyword"
                        },
                        "executionState":{
                           "type":"keyword"
                        }
                     }
                  }
               }
            }
         }
      }
   }
}'

curl -s --insecure -X PUT "$ES_ENDPOINT/_component_template/talsec_incident_info_malware_android" \
  -H "Authorization: ApiKey $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "template":{
      "mappings":{
         "properties":{
            "incidentReport":{
               "type":"object",
               "properties":{
                  "info":{
                     "type":"object",
                     "properties":{
                        "malwarePackages":{
                           "type":"object",
                           "properties": {
                              "malwareHashBlacklist": {
                                "type": "keyword"
                              },
                              "suspiciousInstallationSource": {
                                "type": "keyword"
                              },
                              "suspiciousPermissionGranted": {
                                "type": "keyword"
                              },
                              "malwarePackageNameBlacklist": {
                                "type": "keyword"
                              }
                           }
                        }
                     }
                  }
               }
            }
         }
      }
   }
}'

curl -s --insecure -X PUT "$ES_ENDPOINT/_component_template/talsec_incident_info_adb_enabled_android" \
  -H "Authorization: ApiKey $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "template":{
      "mappings":{
         "properties":{
            "incidentReport":{
               "type":"object",
               "properties":{
                  "info":{
                     "type":"object",
                     "properties":{
                        "isAdbEnabled":{
                           "type":"boolean"
                        }
                     }
                  }
               }
            }
         }
      }
   }
}'

curl -s --insecure -X PUT "$ES_ENDPOINT/_index_template/talsec_log_android_v2" \
  -H "Authorization: ApiKey $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "index_patterns":[
      "talsec_log_prod_android_v2_2*"
   ],
   "template":{
      "settings":{
         "index":{
            "lifecycle":{
               "name":"talsec_prod_policy",
               "rollover_alias":"talsec_log_prod_android_write"
            },
            "number_of_replicas":"1",
            "refresh_interval":"10s"
         }
      },
      "aliases":{
         "talsec_log_android":{

         },
         "talsec_log_prod":{

         }
      }
   },
   "composed_of":[
      "talsec_app_info_android",
      "talsec_device_info_android",
      "talsec_sdk_state_android",
      "talsec_incident_info_accessibility_android",
      "talsec_incident_info_android",
      "talsec_incident_info_app_integrity_android",
      "talsec_incident_info_debug_android",
      "talsec_incident_info_device_binding_android",
      "talsec_incident_info_hooks_android",
      "talsec_incident_info_overlay_android",
      "talsec_incident_info_privileged_access_android",
      "talsec_incident_info_simulator_android",
      "talsec_incident_info_unofficial_store_android",
      "talsec_incident_info_missing_obfuscation_android",
      "talsec_incident_info_devmode_android",
      "talsec_incident_info_systemvpn_android",
      "talsec_incident_info_monitoring_android",
      "talsec_incident_info_malware_android",
      "talsec_incident_info_adb_enabled_android",
      "talsec_incident_info_screenshot",
      "talsec_incident_info_screen_recording",
      "talsec_app_info",
      "talsec_device_info",
      "talsec_fullrasp",
      "talsec_incident_info",
      "talsec_metadata",
      "talsec_sdk_info"
   ]
}'

curl -s --insecure -X PUT "$ES_ENDPOINT/_index_template/talsec_log_dev_android_v2" \
  -H "Authorization: ApiKey $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "index_patterns":[
      "talsec_log_dev_android_v2_2*"
   ],
   "template":{
      "settings":{
         "index":{
            "lifecycle":{
               "name":"talsec_dev_policy",
               "rollover_alias":"talsec_log_dev_android_write"
            },
            "number_of_replicas":"1",
            "refresh_interval":"10s"
         }
      },
      "aliases":{
         "talsec_log_android":{

         },
         "talsec_log_dev":{

         }
      }
   },
   "composed_of":[
      "talsec_app_info_android",
      "talsec_device_info_android",
      "talsec_sdk_state_android",
      "talsec_incident_info_accessibility_android",
      "talsec_incident_info_android",
      "talsec_incident_info_app_integrity_android",
      "talsec_incident_info_debug_android",
      "talsec_incident_info_device_binding_android",
      "talsec_incident_info_hooks_android",
      "talsec_incident_info_overlay_android",
      "talsec_incident_info_privileged_access_android",
      "talsec_incident_info_simulator_android",
      "talsec_incident_info_unofficial_store_android",
      "talsec_incident_info_missing_obfuscation_android",
      "talsec_incident_info_devmode_android",
      "talsec_incident_info_systemvpn_android",
      "talsec_incident_info_monitoring_android",
      "talsec_incident_info_malware_android",
      "talsec_incident_info_adb_enabled_android",
      "talsec_incident_info_screenshot",
      "talsec_incident_info_screen_recording",
      "talsec_app_info",
      "talsec_device_info",
      "talsec_fullrasp",
      "talsec_incident_info",
      "talsec_metadata",
      "talsec_sdk_info"
   ]
}'

###### IOS starts from here
curl -s --insecure -X PUT "$ES_ENDPOINT/_component_template/talsec_device_info_ios" \
  -H "Authorization: ApiKey $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "template":{
      "mappings":{
         "properties":{
            "deviceId":{
               "type":"object",
               "properties":{
                  "currentVendorId":{
                     "type":"keyword"
                  },
                  "oldVendorId":{
                     "type":"keyword"
                  }
               }
            }
         }
      }
   }
}'

curl -s --insecure -X PUT "$ES_ENDPOINT/_component_template/talsec_incident_info_privileged_access_ios" \
  -H "Authorization: ApiKey $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "template":{
      "mappings":{
         "properties":{
            "incidentReport":{
               "type":"object",
               "properties":{
                  "info":{
                     "type":"object",
                     "properties":{
                        "appPaths":{
                           "type":"keyword"
                        },
                        "sysasm":{
                           "type":"keyword"
                        },
                        "dylibs":{
                           "type":"keyword"
                        },
                        "portOpen":{
                           "type":"keyword"
                        },
                        "sBifValue":{
                           "type":"keyword"
                        },
                        "sbiW":{
                           "type":"keyword"
                        },
                        "slPaths":{
                           "type":"keyword"
                        },
                        "ffl":{
                           "type":"keyword"
                        },
                        "sbiR":{
                           "type":"keyword"
                        },
                        "dylds":{
                           "type":"keyword"
                        }
                     }
                  }
               }
            }
         }
      }
   }
}'


curl -s --insecure -X PUT "$ES_ENDPOINT/_component_template/talsec_incident_info_app_integrity_ios" \
  -H "Authorization: ApiKey $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "template":{
      "mappings":{
         "properties":{
            "incidentReport":{
               "type":"object",
               "properties":{
                  "info":{
                     "type":"object",
                     "properties":{
                        "teamIdNative":{
                           "type":"keyword"
                        },
                        "teamId":{
                           "type":"keyword"
                        },
                        "appId":{
                           "type":"keyword"
                        },
                        "bundleId":{
                           "type":"keyword"
                        },
                        "certificateInfo":{
                           "type":"object",
                           "properties":{
                              "CreationDate":{
                                 "type":"long"
                              },
                              "TimeToLive":{
                                 "type":"long"
                              },
                              "Platform":{
                                 "type":"keyword"
                              },
                              "TeamIdentifier":{
                                 "type":"keyword"
                              },
                              "TeamName":{
                                 "type":"keyword"
                              },
                              "IsXcodeManaged":{
                                 "type":"boolean"
                              },
                              "Name":{
                                 "type":"keyword"
                              },
                              "ApplicationIdentifierPrefix":{
                                 "type":"keyword"
                              },
                              "ExpirationDate":{
                                 "type":"long"
                              },
                              "AppIDName":{
                                 "type":"keyword"
                              },
                              "Version":{
                                 "type":"long"
                              },
                              "Entitlements":{
                                 "type":"object",
                                 "properties":{
                                    "application-identifier":{
                                       "type":"keyword"
                                    },
                                    "get-task-allow":{
                                       "type":"boolean"
                                    },
                                    "keychain-access-groups":{
                                       "type":"keyword"
                                    },
                                    "aps-environment":{
                                       "type":"keyword"
                                    }
                                 }
                              },
                              "UUID":{
                                 "type":"keyword"
                              }
                           }
                        },
                        "bundleIdNative":{
                           "type":"keyword"
                        }
                     }
                  }
               }
            }
         }
      }
   }
}'

curl -s --insecure -X PUT "$ES_ENDPOINT/_component_template/talsec_incident_info_hooks_ios" \
  -H "Authorization: ApiKey $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "template":{
      "mappings":{
         "properties":{
            "incidentReport":{
               "type":"object",
               "properties":{
                  "info":{
                     "type":"object",
                     "properties":{
                        "dylibs":{
                           "type":"keyword"
                        }
                     }
                  }
               }
            }
         }
      }
   }
}'

curl -s --insecure -X PUT "$ES_ENDPOINT/_component_template/talsec_incident_info_systemvpn_ios" \
  -H "Authorization: ApiKey $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "template":{
      "mappings":{
         "properties":{
            "incidentReport":{
               "type":"object",
               "properties":{
                  "info":{
                     "type":"object",
                     "properties":{
                        "VPNInterfaces":{
                           "type":"keyword"
                        }
                     }
                  }
               }
            }
         }
      }
   }
}'


curl -s --insecure -X PUT "$ES_ENDPOINT/_component_template/talsec_incident_info_unofficial_store_ios" \
  -H "Authorization: ApiKey $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "template":{
      "mappings":{
         "properties":{
            "incidentReport":{
               "type":"object",
               "properties":{
                  "info":{
                     "type":"object",
                     "properties":{
                        "encryptedBinary":{
                           "type":"keyword"
                        },
                        "provisionIntegrity":{
                           "type":"keyword"
                        }
                     }
                  }
               }
            }
         }
      }
   }
}'


curl -s --insecure -X PUT "$ES_ENDPOINT/_index_template/talsec_log_ios_v2" \
  -H "Authorization: ApiKey $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "index_patterns":[
      "talsec_log_prod_ios_v2_2*"
   ],
   "template":{
      "settings":{
         "index":{
            "lifecycle":{
               "name":"talsec_prod_policy",
               "rollover_alias":"talsec_log_prod_ios_write"
            },
            "number_of_replicas":"1",
            "refresh_interval":"10s"
         }
      },
      "aliases":{
         "talsec_log_prod":{

         },
         "talsec_log_ios":{

         }
      }
   },
   "composed_of":[
      "talsec_app_info",
      "talsec_device_info",
      "talsec_device_info_ios",
      "talsec_fullrasp",
      "talsec_incident_info",
      "talsec_incident_info_app_integrity_ios",
      "talsec_incident_info_hooks_ios",
      "talsec_incident_info_privileged_access_ios",
      "talsec_incident_info_unofficial_store_ios",
      "talsec_incident_info_systemvpn_ios",
      "talsec_incident_info_screenshot",
      "talsec_incident_info_screen_recording",
      "talsec_sdk_info",
      "talsec_metadata"
   ]
}'


curl -s --insecure -X PUT "$ES_ENDPOINT/_index_template/talsec_log_dev_ios_v2" \
  -H "Authorization: ApiKey $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "index_patterns":[
      "talsec_log_dev_ios_v2_2*"
   ],
   "template":{
      "settings":{
         "index":{
            "lifecycle":{
               "name":"talsec_dev_policy",
               "rollover_alias":"talsec_log_dev_ios_write"
            },
            "number_of_replicas":"1",
            "refresh_interval":"10s"
         }
      },
      "aliases":{
         "talsec_log_ios":{

         },
         "talsec_log_dev":{

         }
      }
   },
   "composed_of":[
      "talsec_app_info",
      "talsec_device_info",
      "talsec_device_info_ios",
      "talsec_fullrasp",
      "talsec_incident_info",
      "talsec_incident_info_app_integrity_ios",
      "talsec_incident_info_hooks_ios",
      "talsec_incident_info_privileged_access_ios",
      "talsec_incident_info_unofficial_store_ios",
      "talsec_incident_info_systemvpn_ios",
      "talsec_incident_info_screenshot",
      "talsec_incident_info_screen_recording",
      "talsec_sdk_info",
      "talsec_metadata"
   ]
}'


curl -s --insecure -X PUT "$ES_ENDPOINT/_component_template/talsec_metadata" \
  -H "Authorization: ApiKey $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "template": {
      "mappings": {
        "properties": {
          "occurence": {
            "type": "date"
          },
          "@timestamp": {
            "type": "date"
          },
          "externalId": {
            "type": "keyword"
          },
          "sessionId": {
            "type": "keyword"
          }
        }
      }
    }
  }'


curl -s --insecure -X PUT "$ES_ENDPOINT/_component_template/talsec_metadata" \
  -H "Authorization: ApiKey $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "template": {
      "mappings": {
        "properties": {
          "occurence": {
            "type": "date"
          },
          "@timestamp": {
            "type": "date"
          },
          "externalId": {
            "type": "keyword"
          },
          "sessionId": {
            "type": "keyword"
          }
        }
      }
    }
  }'


curl -s --insecure -X PUT "$ES_ENDPOINT/_component_template/talsec_metadata" \
  -H "Authorization: ApiKey $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "template": {
      "mappings": {
        "properties": {
          "occurence": {
            "type": "date"
          },
          "@timestamp": {
            "type": "date"
          },
          "externalId": {
            "type": "keyword"
          },
          "sessionId": {
            "type": "keyword"
          }
        }
      }
    }
  }'

# #simplet index creation for testing
# curl -s --insecure -X PUT "$ES_ENDPOINT/test-index-simple" \
#   -H "Authorization: ApiKey $API_KEY" \
#   -H "Content-Type: application/json" \
#   -d '{}'


# ios Prod index
# curl -s --insecure -X POST "$ES_ENDPOINT/%3Ctalsec_log_prod_ios_v2_%7Bnow%2Fd%7D-000001%3E" \
#   -H "Authorization: ApiKey $API_KEY" \
#   -H "Content-Type: application/json" \
#   -d '{
#     "aliases": {
#       "talsec_log_prod_ios_write": {
#         "is_write_index": true
#       }
#     }
#   }'
TODAY=$(date +%Y.%m.%d)
curl -s --insecure -X PUT "$ES_ENDPOINT/talsec_log_prod_ios_v2_${TODAY}-000001" \
  -H "Authorization: ApiKey $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "aliases": {
      "talsec_log_prod_ios_write": {
        "is_write_index": true
      }
    }
  }'

# android prod index
curl -s --insecure -X PUT "$ES_ENDPOINT/talsec_log_prod_android_v2_${TODAY}-000001" \
  -H "Authorization: ApiKey $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "aliases": {
      "talsec_log_prod_android_write": {
        "is_write_index": true
      }
    }
  }'

# ios dev index
curl -s --insecure -X PUT "$ES_ENDPOINT/talsec_log_dev_ios_v2_${TODAY}-000001" \
  -H "Authorization: ApiKey $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "aliases": {
      "talsec_log_dev_ios_write": {
        "is_write_index": true
      }
    }
  }'
# android dev index
curl -s --insecure -X PUT "$ES_ENDPOINT/talsec_log_dev_android_v2_${TODAY}-000001" \
  -H "Authorization: ApiKey $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "aliases": {
      "talsec_log_dev_android_write": {
        "is_write_index": true
      }
    }
  }'

## API key is left here, cause its causing error in notebook itself


# Pipelines
curl -s --insecure -X PUT "$ES_ENDPOINT/_ingest/pipeline/talsec_log_set_session" \
  -H "Authorization: ApiKey $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "processors": [
      {
        "set": {
          "field": "@relation.name",
          "value": "message",
          "override": false
        }
      },
      {
        "set": {
          "field": "@relation.parent",
          "value": "apps_{{instanceId}}:{{sessionStart}}",
          "override": false
        }
      },
      {
        "set": {
          "field": "_routing",
          "value": "apps_{{instanceId}}:{{sessionStart}}",
          "override": false
        }
      }
    ]
  }'

curl -s --insecure -X PUT "$ES_ENDPOINT/_ingest/pipeline/set_timestamp" \
  -H "Authorization: ApiKey $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "processors": [
      {
        "set": {
          "field": "@timestamp",
          "value": "{{_ingest.timestamp}}",
          "override": false
        }
      }
    ]
  }'

curl -s --insecure -X PUT "$ES_ENDPOINT/_ingest/pipeline/talsec_log_set_type" \
  -H "Authorization: ApiKey $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "processors" : [
      {
        "set" : {
          "if" : "ctx.incidentReport == null",
          "field" : "type",
          "value" : "INFO"
        }
      },
      {
        "set" : {
          "if" : "ctx.incidentReport != null",
          "field" : "type",
          "value" : "ERROR"
        }
      }
    ]
  }'

curl -s --insecure -X PUT "$ES_ENDPOINT/_ingest/pipeline/talsec_log_deviceId" \
  -H "Authorization: ApiKey $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "processors": [
      {
        "set": {
          "field": "defaultDeviceId",
          "value": "{{{deviceId.androidId}}}",
          "if": "ctx.deviceId != null && ctx.deviceId.androidId != null"
        }
      },
      {
        "set": {
          "field": "defaultDeviceId",
          "value": "{{{deviceId.currentVendorId}}}",
          "if": "ctx.deviceId != null && ctx.deviceId.currentVendorId != null"
        }
      },
      {
        "set": {
          "field": "defaultDeviceId",
          "value": "{{{instanceId}}}",
          "if": "ctx.defaultDeviceId == null && ctx.instanceId != null"
        }
      },
      {
        "set": {
          "field": "defaultDeviceId",
          "value": "unknown",
          "if": "ctx.defaultDeviceId == null"
        }
      }
    ]
  }'

curl -s --insecure -X PUT "$ES_ENDPOINT/_ingest/pipeline/talsec_log_index" \
  -H "Authorization: ApiKey $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "processors": [
        {
          "pipeline": {
            "name": "set_timestamp"
          }
        },
        {
          "pipeline": {
            "name": "talsec_log_set_type"
          }
        },
        {
          "pipeline": {
            "name": "talsec_log_deviceId"
          }
        },
        {
          "pipeline": {
            "name": "talsec_log_set_session",
            "if": "ctx.sessionStart != null"
          }
        }
      ]
    }'

# Create API key for applications to send logs
echo "Creating log ingestion API key..."
LOG_API_KEY_RESPONSE=$(curl -s --insecure -X POST "$ES_ENDPOINT/_security/api_key" \
  -u "elastic:$ES_PASSWORD" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "talsec_create_doc",
    "role_descriptors": {
      "talsec_create_doc": {
        "cluster": [],
        "indices": [
          {
            "names": ["talsec_log_*"],
            "privileges": ["create_doc"]
          }
        ]
      }
    }
  }')

# Extract the encoded key (this is what customers will use)
LOG_API_KEY_ENCODED=$(echo $LOG_API_KEY_RESPONSE | jq -r .encoded)
echo "Log API Key Response: $LOG_API_KEY_RESPONSE"
echo "Encoded key for applications: $LOG_API_KEY_ENCODED"



# Dashboard creation section
echo "Creating default dashboard for $CUSTOMER_NAME..."
curl -o /tmp/dashboard.ndjson https://raw.githubusercontent.com/h4l0gen/ARM---Infra-deployment/refs/heads/main/linked-templates/dashboard.ndjson

# Replace placeholders in the dashboard
sed -i "s/\"title\":\"Talsec\"/\"title\":\"$CUSTOMER_NAME Dashboard\"/g" /tmp/dashboard.ndjson
sed -i "s/\"title\":\"s\*\"/\"title\":\"$INDEX_PATTERN\"/g" /tmp/dashboard.ndjson
sed -i "s/\"description\":\"testing\"/\"description\":\"$CUSTOMER_NAME Security Dashboard\"/g" /tmp/dashboard.ndjson

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
DASHBOARD_RESPONSE=$(curl -s -v --insecure -X POST "$KIBANA_URL/api/saved_objects/_import?overwrite=true" \
  -H "kbn-xsrf: true" \
  -H "Authorization: ApiKey $API_KEY" \
  -F "file=@/tmp/dashboard.ndjson")

echo "Dashboard import response: $DASHBOARD_RESPONSE"

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
  "elasticPassword": "$ES_PASSWORD",
  "logAPIKey": "$LOG_API_KEY_ENCODED"
}
EOF

echo "Output file created successfully"


# curl -s -k -u elastic:$ES_PASSWORD \
#  -X POST "https://localhost:9200/_security/api_key" \
#  -H "Content-Type: application/json" \
#  -d '{
#    "name": "marketplace-full-access-key",
#    "role_descriptors": {
#      "full_admin_role": {
#        "cluster": [
#          "monitor", 
#          "manage_index_templates", 
#          "manage_ingest_pipelines",
#          "manage_ilm",
#          "manage_enrich",
#          "manage_api_key",
#          "manage_security",
#          "all"
#        ],
#        "indices": [{
#          "names": ["*"],
#          "privileges": ["all"]
#        }],
#        "applications": [{
#          "application": "kibana-.kibana",
#          "privileges": ["all"],
#          "resources": ["*"]
#        }]
#      }
#    }
#  }'

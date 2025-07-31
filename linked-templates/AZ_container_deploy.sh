#!/bin/bash

KIBANA_URL="https://kapilpoc.kb.eastus.azure.elastic-cloud.com"
ELASTIC_URL="https://kapilpoc.es.eastus.azure.elastic-cloud.com"
EMAIL="kapil@talsecapp.onmicrosoft.com"

# need to get this password
PASSWORD="X71eskMvM69EkZN9gQaxvF4E"

# Create auth header
AUTH_HEADER="Authorization: Basic $(echo -n elastic:$PASSWORD | base64)"

echo "Testing connection to Kibana..."
# Test connection first
RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" -X GET "$KIBANA_URL/api/status" \
    -H "$AUTH_HEADER" \
    -H "kbn-xsrf: true")

if [ "$RESPONSE" -ne "200" ]; then
    echo "Failed to connect. HTTP Status: $RESPONSE"
    echo "Please check your password and try again"
    exit 1
fi

echo "Connected successfully!"

# List current saved objects
echo -e "\nChecking current Kibana objects..."
OBJECT_TYPES=("dashboard" "visualization" "search" "index-pattern")

for TYPE in "${OBJECT_TYPES[@]}"; do
    echo -e "\nChecking $TYPE objects:"
    curl -s -X GET "$KIBANA_URL/api/saved_objects/_find?type=$TYPE" \
        -H "$AUTH_HEADER" \
        -H "Content-Type: application/json" \
        -H "kbn-xsrf: true" | jq -r '.saved_objects[] | "\(.id) - \(.attributes.title)"'
done

# Ask before cleanup
echo -e "\nDo you want to proceed with cleanup? (y/n)"
read CONFIRM

if [ "$CONFIRM" = "y" ]; then
    # Cleanup script
    for TYPE in "${OBJECT_TYPES[@]}"; do
        echo -e "\nCleaning $TYPE objects..."
        
        RESPONSE=$(curl -s -X GET "$KIBANA_URL/api/saved_objects/_find?type=$TYPE&per_page=10000" \
            -H "$AUTH_HEADER" \
            -H "Content-Type: application/json" \
            -H "kbn-xsrf: true")
        
        echo $RESPONSE | jq -r ".saved_objects[]?.id" | while read ID; do
            if [ ! -z "$ID" ]; then
                curl -s -X DELETE "$KIBANA_URL/api/saved_objects/$TYPE/$ID?force=true" \
                    -H "$AUTH_HEADER" \
                    -H "kbn-xsrf: true"
                echo "Deleted $TYPE: $ID"
            fi
        done
    done
    
    echo -e "\nCleanup completed!"
fi

# In your deployment script
curl -X PUT "$ELASTIC_URL/_ilm/policy/talsec_prod_policy" \
  -H "Authorization: Basic $(echo -n elastic:$PASSWORD | base64)" \
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

echo "ILM policy is created"


# Common template 1
curl  -X PUT "$ELASTIC_URL/_component_template/talsec_device_info" \
  -H "Authorization: Basic $(echo -n elastic:$PASSWORD | base64)" \
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
curl  -X PUT "$ELASTIC_URL/_component_template/talsec_metadata" \
  -H "Authorization: Basic $(echo -n elastic:$PASSWORD | base64)" \
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
curl  -X PUT "$ELASTIC_URL/_component_template/talsec_app_info" \
  -H "Authorization: Basic $(echo -n elastic:$PASSWORD | base64)" \
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
curl  -X PUT "$ELASTIC_URL/_component_template/talsec_sdk_info" \
  -H "Authorization: Basic $(echo -n elastic:$PASSWORD | base64)" \
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

curl  -X PUT "$ELASTIC_URL/_component_template/talsec_fullrasp" \
  -H "Authorization: Basic $(echo -n elastic:$PASSWORD | base64)" \
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

curl  -X PUT "$ELASTIC_URL/_component_template/talsec_incident_info" \
  -H "Authorization: Basic $(echo -n elastic:$PASSWORD | base64)" \
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

curl  -X PUT "$ELASTIC_URL/_component_template/talsec_incident_info_screenshot" \
  -H "Authorization: Basic $(echo -n elastic:$PASSWORD | base64)" \
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

curl  -X PUT "$ELASTIC_URL/_component_template/talsec_incident_info_screen_recording" \
  -H "Authorization: Basic $(echo -n elastic:$PASSWORD | base64)" \
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

curl  -X PUT "$ELASTIC_URL/_component_template/talsec_device_info_android" \
  -H "Authorization: Basic $(echo -n elastic:$PASSWORD | base64)" \
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


curl  -X PUT "$ELASTIC_URL/_component_template/talsec_app_info_android" \
  -H "Authorization: Basic $(echo -n elastic:$PASSWORD | base64)" \
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

curl  -X PUT "$ELASTIC_URL/_component_template/talsec_sdk_state_android" \
  -H "Authorization: Basic $(echo -n elastic:$PASSWORD | base64)" \
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

curl  -X PUT "$ELASTIC_URL/_component_template/talsec_incident_info_android" \
  -H "Authorization: Basic $(echo -n elastic:$PASSWORD | base64)" \
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

curl  -X PUT "$ELASTIC_URL/_component_template/talsec_incident_info_privileged_access_android" \
  -H "Authorization: Basic $(echo -n elastic:$PASSWORD | base64)" \
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

curl  -X PUT "$ELASTIC_URL/_component_template/talsec_incident_info_app_integrity_android" \
  -H "Authorization: Basic $(echo -n elastic:$PASSWORD | base64)" \
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

curl  -X PUT "$ELASTIC_URL/_component_template/talsec_incident_info_missing_obfuscation_android" \
  -H "Authorization: Basic $(echo -n elastic:$PASSWORD | base64)" \
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

curl  -X PUT "$ELASTIC_URL/_component_template/talsec_incident_info_hooks_android" \
  -H "Authorization: Basic $(echo -n elastic:$PASSWORD | base64)" \
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

curl  -X PUT "$ELASTIC_URL/_component_template/talsec_incident_info_debug_android" \
  -H "Authorization: Basic $(echo -n elastic:$PASSWORD | base64)" \
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

curl  -X PUT "$ELASTIC_URL/_component_template/talsec_incident_info_simulator_android" \
  -H "Authorization: Basic $(echo -n elastic:$PASSWORD | base64)" \
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

curl  -X PUT "$ELASTIC_URL/_component_template/talsec_incident_info_overlay_android" \
  -H "Authorization: Basic $(echo -n elastic:$PASSWORD | base64)" \
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

curl  -X PUT "$ELASTIC_URL/_component_template/talsec_incident_info_accessibility_android" \
  -H "Authorization: Basic $(echo -n elastic:$PASSWORD | base64)" \
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

curl  -X PUT "$ELASTIC_URL/_component_template/talsec_incident_info_unofficial_store_android" \
  -H "Authorization: Basic $(echo -n elastic:$PASSWORD | base64)" \
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

curl  -X PUT "$ELASTIC_URL/_component_template/talsec_incident_info_device_binding_android" \
  -H "Authorization: Basic $(echo -n elastic:$PASSWORD | base64)" \
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

curl  -X PUT "$ELASTIC_URL/_component_template/talsec_incident_info_devmode_android" \
  -H "Authorization: Basic $(echo -n elastic:$PASSWORD | base64)" \
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

curl  -X PUT "$ELASTIC_URL/_component_template/talsec_incident_info_systemvpn_android" \
  -H "Authorization: Basic $(echo -n elastic:$PASSWORD | base64)" \
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

curl  -X PUT "$ELASTIC_URL/_component_template/talsec_incident_info_monitoring_android" \
  -H "Authorization: Basic $(echo -n elastic:$PASSWORD | base64)" \
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

curl  -X PUT "$ELASTIC_URL/_component_template/talsec_incident_info_malware_android" \
  -H "Authorization: Basic $(echo -n elastic:$PASSWORD | base64)" \
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

curl  -X PUT "$ELASTIC_URL/_component_template/talsec_incident_info_adb_enabled_android" \
  -H "Authorization: Basic $(echo -n elastic:$PASSWORD | base64)" \
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

curl  -X PUT "$ELASTIC_URL/_index_template/talsec_log_android_v2" \
  -H "Authorization: Basic $(echo -n elastic:$PASSWORD | base64)" \
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

curl  -X PUT "$ELASTIC_URL/_index_template/talsec_log_dev_android_v2" \
  -H "Authorization: Basic $(echo -n elastic:$PASSWORD | base64)" \
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
curl  -X PUT "$ELASTIC_URL/_component_template/talsec_device_info_ios" \
  -H "Authorization: Basic $(echo -n elastic:$PASSWORD | base64)" \
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

curl  -X PUT "$ELASTIC_URL/_component_template/talsec_incident_info_privileged_access_ios" \
  -H "Authorization: Basic $(echo -n elastic:$PASSWORD | base64)" \
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


curl  -X PUT "$ELASTIC_URL/_component_template/talsec_incident_info_app_integrity_ios" \
  -H "Authorization: Basic $(echo -n elastic:$PASSWORD | base64)" \
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

curl  -X PUT "$ELASTIC_URL/_component_template/talsec_incident_info_hooks_ios" \
  -H "Authorization: Basic $(echo -n elastic:$PASSWORD | base64)" \
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

curl  -X PUT "$ELASTIC_URL/_component_template/talsec_incident_info_systemvpn_ios" \
  -H "Authorization: Basic $(echo -n elastic:$PASSWORD | base64)" \
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


curl  -X PUT "$ELASTIC_URL/_component_template/talsec_incident_info_unofficial_store_ios" \
  -H "Authorization: Basic $(echo -n elastic:$PASSWORD | base64)" \
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


curl  -X PUT "$ELASTIC_URL/_index_template/talsec_log_ios_v2" \
  -H "Authorization: Basic $(echo -n elastic:$PASSWORD | base64)" \
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


curl  -X PUT "$ELASTIC_URL/_index_template/talsec_log_dev_ios_v2" \
  -H "Authorization: Basic $(echo -n elastic:$PASSWORD | base64)" \
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


curl  -X PUT "$ELASTIC_URL/_component_template/talsec_metadata" \
  -H "Authorization: Basic $(echo -n elastic:$PASSWORD | base64)" \
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


curl  -X PUT "$ELASTIC_URL/_component_template/talsec_metadata" \
  -H "Authorization: Basic $(echo -n elastic:$PASSWORD | base64)" \
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


curl  -X PUT "$ELASTIC_URL/_component_template/talsec_metadata" \
  -H "Authorization: Basic $(echo -n elastic:$PASSWORD | base64)" \
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

TODAY=$(date +%Y.%m.%d)
curl  -X PUT "$ELASTIC_URL/talsec_log_prod_ios_v2_${TODAY}-000001" \
  -H "Authorization: Basic $(echo -n elastic:$PASSWORD | base64)" \
  -H "Content-Type: application/json" \
  -d '{
    "aliases": {
      "talsec_log_prod_ios_write": {
        "is_write_index": true
      }
    }
  }'

# android prod index
curl  -X PUT "$ELASTIC_URL/talsec_log_prod_android_v2_${TODAY}-000001" \
  -H "Authorization: Basic $(echo -n elastic:$PASSWORD | base64)" \
  -H "Content-Type: application/json" \
  -d '{
    "aliases": {
      "talsec_log_prod_android_write": {
        "is_write_index": true
      }
    }
  }'

# ios dev index
curl  -X PUT "$ELASTIC_URL/talsec_log_dev_ios_v2_${TODAY}-000001" \
  -H "Authorization: Basic $(echo -n elastic:$PASSWORD | base64)" \
  -H "Content-Type: application/json" \
  -d '{
    "aliases": {
      "talsec_log_dev_ios_write": {
        "is_write_index": true
      }
    }
  }'
# android dev index
curl  -X PUT "$ELASTIC_URL/talsec_log_dev_android_v2_${TODAY}-000001" \
  -H "Authorization: Basic $(echo -n elastic:$PASSWORD | base64)" \
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
curl  -X PUT "$ELASTIC_URL/_ingest/pipeline/talsec_log_set_session" \
  -H "Authorization: Basic $(echo -n elastic:$PASSWORD | base64)" \
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

curl  -X PUT "$ELASTIC_URL/_ingest/pipeline/set_timestamp" \
  -H "Authorization: Basic $(echo -n elastic:$PASSWORD | base64)" \
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

curl  -X PUT "$ELASTIC_URL/_ingest/pipeline/talsec_log_set_type" \
  -H "Authorization: Basic $(echo -n elastic:$PASSWORD | base64)" \
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

curl  -X PUT "$ELASTIC_URL/_ingest/pipeline/talsec_log_deviceId" \
  -H "Authorization: Basic $(echo -n elastic:$PASSWORD | base64)" \
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

curl  -X PUT "$ELASTIC_URL/_ingest/pipeline/talsec_log_index" \
  -H "Authorization: Basic $(echo -n elastic:$PASSWORD | base64)" \
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

AUTH_HEADER="Authorization: Basic $(echo -n elastic:$PASSWORD | base64)"

LOG_API_KEY_RESPONSE=$(curl -s -X POST "$ELASTIC_URL/_security/api_key" \
  -H "$AUTH_HEADER" \
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

# Extract the encoded key
LOG_API_KEY_ENCODED=$(echo $LOG_API_KEY_RESPONSE | jq -r .encoded)
echo "Log ingestion API key created: $LOG_API_KEY_ENCODED"

# Dashboard creation section
echo "Creating default dashboard for $CUSTOMER_NAME..."
curl -o /tmp/dashboard.ndjson https://raw.githubusercontent.com/h4l0gen/ARM---Infra-deployment/refs/heads/main/linked-templates/dashboard.ndjson

# Replace placeholders in the dashboard
sed -i "s/\"title\":\"Talsec\"/\"title\":\"$CUSTOMER_NAME Dashboard\"/g" /tmp/dashboard.ndjson
sed -i "s/\"title\":\"s\*\"/\"title\":\"$INDEX_PATTERN\"/g" /tmp/dashboard.ndjson
sed -i "s/\"description\":\"testing\"/\"description\":\"$CUSTOMER_NAME Security Dashboard\"/g" /tmp/dashboard.ndjson

# Import dashboard using API key
DASHBOARD_RESPONSE=$(curl -X POST "$KIBANA_URL/api/saved_objects/_import?overwrite=true" \
  -H "kbn-xsrf: true" \
  -H "Authorization: Basic $(echo -n elastic:$PASSWORD | base64)" \
  -F "file=@/tmp/dashboard.ndjson")

echo "Dashboard import response: $DASHBOARD_RESPONSE"

# Check for success in response
if echo "$DASHBOARD_RESPONSE" | grep -q '"success":true'; then
  echo "Dashboard imported successfully"
  exit 0
else
  echo "Error importing dashboard:"
  echo "$DASHBOARD_RESPONSE"
  exit 1
fi

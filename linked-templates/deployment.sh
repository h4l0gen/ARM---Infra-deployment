{
  "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
  "contentVersion": "1.0.0.0",
  "parameters": {
    "location": {
      "type": "string",
      "defaultValue": "[resourceGroup().location]",
      "metadata": {
        "description": "Location for all resources"
      }
    },
    "letsEncryptEmail": {
      "type": "string",
      "metadata": {
        "description": "Email address for Let's Encrypt certificate notifications"
      }
    }
  },
  "variables": {
    "deploymentPrefix": "kapil7798",
    "kubernetesVersion": "1.31.9",
    "githubBaseUrl": "https://raw.githubusercontent.com/h4l0gen/ARM---Infra-deployment/refs/heads/main/linked-templates",
    "vnetTemplateUri": "[concat(variables('githubBaseUrl'), '/vnet.json')]",
    "aksTemplateUri": "[concat(variables('githubBaseUrl'), '/aks.json')]",
    "acrTemplateUri": "[concat(variables('githubBaseUrl'), '/acr.json')]",
    "keyVaultTemplateUri": "[concat(variables('githubBaseUrl'), '/keyvault.json')]",
    "deploymentScriptName": "[concat(variables('deploymentPrefix'), '-deployment-script')]",
    "userAssignedIdentityName": "[concat(variables('deploymentPrefix'), '-script-identity')]",
    "roleAssignmentName": "[guid(resourceGroup().id, variables('userAssignedIdentityName'))]",
    "contributorRoleDefinitionId": "[subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b24988ac-6180-42a0-ab88-20f7382dd24c')]",
    "mcResourceGroupName": "[concat('MC_', resourceGroup().name, '_', variables('deploymentPrefix'), '-aks_', parameters('location'))]"
  
  },
  "resources": [
    {
      "type": "Microsoft.ManagedIdentity/userAssignedIdentities",
      "apiVersion": "2018-11-30",
      "name": "[variables('userAssignedIdentityName')]",
      "location": "[parameters('location')]"
    },
    {
      "type": "Microsoft.Authorization/roleAssignments",
      "apiVersion": "2020-04-01-preview",
      "name": "[variables('roleAssignmentName')]",
      "dependsOn": [
        "[resourceId('Microsoft.ManagedIdentity/userAssignedIdentities', variables('userAssignedIdentityName'))]"
      ],
      "properties": {
        "roleDefinitionId": "[variables('contributorRoleDefinitionId')]",
        "principalId": "[reference(resourceId('Microsoft.ManagedIdentity/userAssignedIdentities', variables('userAssignedIdentityName'))).principalId]",
        "principalType": "ServicePrincipal",
        "scope": "[resourceGroup().id]"
      }
    },
    {
      "type": "Microsoft.Authorization/roleAssignments",
      "apiVersion": "2020-04-01-preview",
      "name": "[guid(concat(resourceGroup().id, variables('userAssignedIdentityName'), 'mc-contributor'))]",
      "dependsOn": [
        "[resourceId('Microsoft.ManagedIdentity/userAssignedIdentities', variables('userAssignedIdentityName'))]",
        "[resourceId('Microsoft.Resources/deployments', 'aks-deployment')]"
      ],
      "properties": {
        "roleDefinitionId": "[variables('contributorRoleDefinitionId')]",
        "principalId": "[reference(resourceId('Microsoft.ManagedIdentity/userAssignedIdentities', variables('userAssignedIdentityName'))).principalId]",
        "principalType": "ServicePrincipal",
        "scope": "[concat(subscription().id, '/resourceGroups/MC_', resourceGroup().name, '_', concat(variables('deploymentPrefix'), '-aks'), '_', parameters('location'))]"
      }
    },
    {
      "type": "Microsoft.Resources/deployments",
      "apiVersion": "2021-04-01",
      "name": "vnet-deployment",
      "properties": {
        "mode": "Incremental",
        "templateLink": {
          "uri": "[variables('vnetTemplateUri')]",
          "contentVersion": "1.0.0.0"
        },
        "parameters": {
          "vnetName": {
            "value": "[concat(variables('deploymentPrefix'), '-vnet')]"
          },
          "location": {
            "value": "[parameters('location')]"
          },
          "vnetAddressPrefix": {
            "value": "10.0.0.0/16"
          },
          "subnetName": {
            "value": "aks-subnet"
          },
          "subnetPrefix": {
            "value": "10.0.1.0/24"
          }
        }
      }
    },
    {
      "type": "Microsoft.Resources/deployments",
      "apiVersion": "2021-04-01",
      "name": "acr-deployment",
      "properties": {
        "mode": "Incremental",
        "templateLink": {
          "uri": "[variables('acrTemplateUri')]",
          "contentVersion": "1.0.0.0"
        },
        "parameters": {
          "acrName": {
            "value": "[concat(variables('deploymentPrefix'), 'acr')]"
          },
          "location": {
            "value": "[parameters('location')]"
          }
        }
      }
    },
    {
      "type": "Microsoft.Resources/deployments",
      "apiVersion": "2021-04-01",
      "name": "keyvault-deployment",
      "properties": {
        "mode": "Incremental",
        "templateLink": {
          "uri": "[variables('keyVaultTemplateUri')]",
          "contentVersion": "1.0.0.0"
        },
        "parameters": {
          "keyVaultName": {
            "value": "[concat(variables('deploymentPrefix'), '-kv')]"
          },
          "location": {
            "value": "[parameters('location')]"
          }
        }
      }
    },
    {
      "type": "Microsoft.Resources/deployments",
      "apiVersion": "2021-04-01",
      "name": "aks-deployment",
      "dependsOn": [
        "[resourceId('Microsoft.Resources/deployments', 'vnet-deployment')]",
        "[resourceId('Microsoft.Resources/deployments', 'acr-deployment')]"
      ],
      "properties": {
        "mode": "Incremental",
        "templateLink": {
          "uri": "[variables('aksTemplateUri')]",
          "contentVersion": "1.0.0.0"
        },
        "parameters": {
          "clusterName": {
            "value": "[concat(variables('deploymentPrefix'), '-aks')]"
          },
          "location": {
            "value": "[parameters('location')]"
          },
          "dnsPrefix": {
            "value": "[concat(variables('deploymentPrefix'), '-dns')]"
          },
          "kubernetesVersion": {
            "value": "[variables('kubernetesVersion')]"
          },
          "subnetId": {
            "value": "[reference('vnet-deployment').outputs.subnetId.value]"
          },
          "acrName": {
            "value": "[reference('acr-deployment').outputs.acrName.value]"
          }
        }
      }
    },
    {
      "type": "Microsoft.Resources/deploymentScripts",
      "apiVersion": "2020-10-01",
      "name": "[variables('deploymentScriptName')]",
      "location": "[parameters('location')]",
     "dependsOn": [
        "[resourceId('Microsoft.Resources/deployments', 'aks-deployment')]",
        "[resourceId('Microsoft.Authorization/roleAssignments', variables('roleAssignmentName'))]",
        "[resourceId('Microsoft.Authorization/roleAssignments', guid(concat(resourceGroup().id, variables('userAssignedIdentityName'), 'mc-contributor')))]"
      ],
      "kind": "AzureCLI",
      "identity": {
        "type": "UserAssigned",
        "userAssignedIdentities": {
          "[resourceId('Microsoft.ManagedIdentity/userAssignedIdentities', variables('userAssignedIdentityName'))]": {}
        
        }
      },
      "properties": {
        "azCliVersion": "2.47.0",
        "primaryScriptUri": "https://raw.githubusercontent.com/h4l0gen/ARM---Infra-deployment/refs/heads/main/linked-templates/deployment.sh",
        "timeout": "PT45M",
        "retentionInterval": "P1D",
        "environmentVariables": [
          {
            "name": "CLUSTER_NAME",
            "value": "[concat(variables('deploymentPrefix'), '-aks')]"
          },
          {
            "name": "RESOURCE_GROUP",
            "value": "[resourceGroup().name]"
          },
          {
            "name": "LOCATION",
            "value": "[parameters('location')]"
          },
          {
            "name": "LETSENCRYPT_EMAIL",
            "value": "[parameters('letsEncryptEmail')]"
          },
          {
            "name": "DNS_PREFIX",
            "value": "[variables('deploymentPrefix')]"
          }
        ]
      }
    }
  ],
  "outputs": {
    "kibanaUrl": {
      "type": "string",
      "value": "[reference(variables('deploymentScriptName')).outputs.kibanaUrl]"
    },
    "elasticsearchEndpoint": {
      "type": "string",
      "value": "[reference(variables('deploymentScriptName')).outputs.elasticsearchEndpoint]"
    },
    "apiKey": {
      "type": "string",
      "value": "[reference(variables('deploymentScriptName')).outputs.apiKey]"
    },
    "gettingStartedCommand": {
      "type": "string",
      "value": "[concat('curl -X POST ', reference(variables('deploymentScriptName')).outputs.elasticsearchEndpoint, '/your-index/_doc -H \"Authorization: ApiKey ', reference(variables('deploymentScriptName')).outputs.apiKey, '\" -H \"Content-Type: application/json\" -d \"{\\\"test\\\": \\\"data\\\"}\"')]"
    }
  }
}

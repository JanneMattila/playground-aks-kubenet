# Enable auto export
set -a

cd azure

# All the variables for the deployment
subscriptionName="AzureDev"
aadAdminGroupContains="janne''s"

aksName="myaksprivate"
workspaceName="myprivateworkspace"
vnetName="myaksprivate-vnet"
subnetAks="snet-aks"
subnetManagement="snet-management"
subnetBastion="AzureBastionSubnet"
subnetAksAPIServer="snet-aks-apiserver"
bastionPublicIP="pip-bastion"
bastionName="bas-management"
identityName="myaksprivate"
resourceGroupName="rg-myaksprivate"
location="westcentralus"

username="azureuser"
password=$(openssl rand -base64 32)

# Login and set correct context
az login -o table
az account set --subscription $subscriptionName -o table

# Prepare extensions and providers
az extension add --upgrade --yes --name aks-preview

# Enable feature
az feature register --namespace "Microsoft.ContainerService" --name "EnableAPIServerVnetIntegrationPreview"
az feature register --namespace "Microsoft.ContainerService" --name "PodSubnetPreview"
az feature list -o table --query "[?contains(name, 'Microsoft.ContainerService/EnableAPIServerVnetIntegrationPreview')].{Name:name,State:properties.state}"
az feature list -o table --query "[?contains(name, 'Microsoft.ContainerService/PodSubnetPreview')].{Name:name,State:properties.state}"
az provider register --namespace Microsoft.ContainerService

# Remove extension in case conflicting previews
# az extension remove --name aks-preview

#############################
#  ____  _             _
# / ___|| |_ __ _ _ __| |_
# \___ \| __/ _` | '__| __|
#  ___) | || (_| | |  | |_
# |____/ \__\__,_|_|   \__|
# deployment
#############################

az group create -l $location -n $resourceGroupName -o table

aadAdmingGroup=$(az ad group list --display-name $aadAdminGroupContains --query [].id -o tsv)
echo $aadAdmingGroup

workspaceid=$(az monitor log-analytics workspace create -g $resourceGroupName -n $workspaceName --query id -o tsv)
echo $workspaceid

vnetid=$(az network vnet create -g $resourceGroupName --name $vnetName \
  --address-prefix 10.0.0.0/8 \
  --query newVNet.id -o tsv)
echo $vnetid

subnetaksid=$(az network vnet subnet create -g $resourceGroupName --vnet-name $vnetName \
  --name $subnetAks --address-prefixes 10.2.0.0/24 \
  --query id -o tsv)
echo $subnetaksid

subnetmanagementid=$(az network vnet subnet create -g $resourceGroupName --vnet-name $vnetName \
  --name $subnetManagement --address-prefixes 10.3.0.0/24 \
  --query id -o tsv)
echo $subnetmanagementid

subnetbastionid=$(az network vnet subnet create -g $resourceGroupName --vnet-name $vnetName \
  --name $subnetBastion --address-prefixes 10.4.0.0/24 \
  --query id -o tsv)
echo $subnetbastionid

# Delegate a subnet to AKS API Server
# https://docs.microsoft.com/en-us/azure/aks/api-server-vnet-integration
subnetaksapiserverid=$(az network vnet subnet create -g $resourceGroupName --vnet-name $vnetName \
  --name $subnetAksAPIServer --address-prefixes 10.5.0.0/24 \
  --delegations "Microsoft.ContainerService/managedClusters" \
  --query id -o tsv)
echo $subnetaksapiserverid

# Create Bastion
az network public-ip create --resource-group $resourceGroupName --name $bastionPublicIP --sku Standard --location $location
bastionid=$(az network bastion create --name $bastionName --public-ip-address $bastionPublicIP --resource-group $resourceGroupName --vnet-name $vnetName --location $location --query id -o tsv)
az resource update --ids $bastionid --set properties.enableTunneling=true

# Create jumpbox VM
vmid=$(az vm create \
  --resource-group $resourceGroupName  \
  --name vm \
  --image UbuntuLTS \
  --size Standard_DS2_v2 \
  --subnet $subnetmanagementid \
  --admin-username $username \
  --admin-password $password \
  --query id -o tsv)

identityjson=$(az identity create --name $identityName --resource-group $resourceGroupName -o json)
identityid=$(echo $identityjson | jq -r .id)
identityobjectid=$(echo $identityjson | jq -r .principalId)
echo $identityid
echo $identityobjectid

# Assign Network Contributor to the API server subnet
az role assignment create --scope $subnetaksapiserverid \
  --role "Network Contributor" \
  --assignee $identityobjectid

# Assign Network Contributor to the cluster subnet
az role assignment create --scope $subnetaksid \
  --role "Network Contributor" \
  --assignee $identityobjectid

az aks get-versions -l $location -o table

#
# To use VNET Integration
# https://docs.microsoft.com/en-us/azure/aks/api-server-vnet-integration
# Add these:
# --enable-apiserver-vnet-integration \
# --apiserver-subnet-id $subnetaksapiserverid \
#

az aks create -g $resourceGroupName -n $aksName \
 --max-pods 50 --network-plugin azure \
 --node-count 1 --enable-cluster-autoscaler --min-count 1 --max-count 2 \
 --node-osdisk-type Ephemeral \
 --node-vm-size Standard_D8ds_v4 \
 --kubernetes-version 1.23.5 \
 --enable-addons monitoring,azure-policy,azure-keyvault-secrets-provider \
 --enable-aad \
 --enable-managed-identity \
 --disable-local-accounts \
 --aad-admin-group-object-ids $aadAdmingGroup \
 --workspace-resource-id $workspaceid \
 --load-balancer-sku standard \
 --vnet-subnet-id $subnetaksid \
 --assign-identity $identityid \
 --enable-private-cluster \
 --private-dns-zone System \
 -o table

###################
#          _ 
#  ___ ___| |__
# / __/ __| '_ \
# \__ \__ \ | | |
# |___/___/_| |_|
# to jumpbox 
###################
# Connect to a VM using Bastion and the native client on your Windows computer (Preview)
# https://docs.microsoft.com/en-us/azure/bastion/connect-native-client-windows

az extension add --upgrade --yes --name ssh
echo $password
az network bastion ssh --name $bastionName --resource-group $resourceGroupName --target-resource-id $vmid --auth-type "password" --username $username

aksName="myaksprivate"
resourceGroupName="rg-myaksprivate"
subscriptionName="AzureDev"

# Install Azure CLI
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
# Install kubectl
sudo az aks install-cli

# Login to Azure (inside jumpbox)
az login -o none
az account set --subscription $subscriptionName -o table
az aks get-credentials -n $aksName -g $resourceGroupName --overwrite-existing
kubelogin convert-kubeconfig -l azurecli

kubectl get nodes
kubectl get nodes -o wide

# Create namespace
kubectl apply -f https://raw.githubusercontent.com/JanneMattila/playground-private-aks/main/namespace.yaml
kubectl apply -f https://raw.githubusercontent.com/JanneMattila/playground-private-aks/main/deployment.yaml

kubectl get deployment -n demos
kubectl describe deployment -n demos

kubectl get pod -n demos

pod1=$(kubectl get pod -n demos -o name | head -n 1)
echo $pod1

pod1_ip=$(kubectl get pod -n demos -o jsonpath="{.items[0].status.podIP}")
echo $pod1_ip

# Test networking app
curl -X POST --data  "IPLOOKUP bing.com" -H "Content-Type: text/plain" "$pod1_ip/api/commands"

# Exit jumpbox
exit

# Wipe out the resources
az group delete --name $resourceGroupName -y

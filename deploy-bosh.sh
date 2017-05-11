#!/bin/bash
set -x
apt-get update
apt-get install -y git libssl-dev libffi-dev python-dev jq build-essential ruby

wget https://azurecliprod.blob.core.windows.net/install.py
yes "" | python install.py

PATH=$PATH:/root/bin
HOME=/home/pivotal

# clone bosh-deployment repo
git clone https://github.com/cloudfoundry/bosh-deployment /tmp/bosh-deployment

# get bosh cli
wget https://s3.amazonaws.com/bosh-cli-artifacts/bosh-cli-2.0.16-linux-amd64 -O /usr/bin/bosh
chmod +x /usr/bin/bosh

# set up azure stuff
tenantId=$1
appId=$2
pwd=$3
recipe=$4

# props to https://github.com/mszcool/azureSpBasedInstanceMetadata/
#
# Get the instance ID and crack it based on the guidance/doc due to big endian encoding
#
vmIdLine=$(sudo dmidecode | grep UUID)
vmId=${vmIdLine:6:37}

# For the first 3 sections of the GUID, the hex codes need to be reversed
vmIdCorrectParts=${vmId:20}
vmIdPart1=${vmId:0:9}
vmIdPart2=${vmId:10:4}
vmIdPart3=${vmId:15:4}
vmId=${vmIdPart1:7:2}${vmIdPart1:5:2}${vmIdPart1:3:2}${vmIdPart1:1:2}-${vmIdPart2:2:2}${vmIdPart2:0:2}-${vmIdPart3:2:2}${vmIdPart3:0:2}-$vmIdCorrectParts
vmId=${vmId,,}

az login --username "$appId" --service-principal --tenant "$tenantId" --password "$pwd"

vmJson=$(az vm list | jq --arg pVmId "$vmId" 'map(select(.vmId == $pVmId))')
vmResGroup=$(echo $vmJson | jq -r '.[0].resourceGroup')

storageAccount=$(az storage account list -g $vmResGroup | jq -r '.[0].name')

storageKey=$(az storage account keys list -n $storageAccount -g $vmResGroup | jq -r '.[0].value')

sub=$(az account list | jq -r '.[0].id')

# create containers
az storage container create --account-name $storageAccount --account-key $storageKey -n bosh --public-access off
az storage container create --account-name $storageAccount --account-key $storageKey -n stemcell --public-access blob

# create stemcell
az storage table create --account-name $storageAccount --account-key $storageKey -n stemcells

# deploy

su -l pivotal sh -c "
bosh --tty create-env /tmp/bosh-deployment/bosh.yml \
  -o /tmp/bosh-deployment/azure/cpi.yml \
  --state=/home/pivotal/azure-bosh-director.yml \
  --vars-store=/home/pivotal/azure-bosh-director-creds.yml  \
  -v director_name=azure-bosh \
  -v internal_cidr=10.2.0.0/24 \
  -v internal_gw=10.2.0.1 \
  -v internal_ip=10.2.0.10 \
  -v vnet_name=boshvnet \
  -v subnet_name=bosh \
  -v subscription_id=$sub \
  -v tenant_id=$tenantId \
  -v client_id=$appId \
  -v client_secret=$pwd \
  -v resource_group_name=$vmResGroup \
  -v storage_account_name=$storageAccount \
  -v default_security_group=nsg-bosh"

su -l pivotal sh -c "bosh --tty -e 10.2.0.10 --ca-cert <(bosh int azure-bosh-director-creds.yml --path /director_ssl/ca) alias-env bosh-azure"

adminPassword=$(ruby -ryaml -e "puts YAML::load(open(ARGV.first).read)['admin_password']" /home/pivotal/azure-bosh-director-creds.yml)
su -l pivotal sh -c "bosh --tty -e bosh-azure login --client=admin --client-secret=$adminPassword"

# Extract the recipe book
archive=$(ls *.tgz | head -n 1)
tar -xvzf $archive --exclude='deploy-bosh.sh' --strip 1

if [ -d "recipes/$recipe" ]; then
  stemcellCount=$(cat recipes/$recipe/index.json | jq -r ".stemcells | length")
  releaseCount=$(cat recipes/$recipe/index.json | jq -r ".releases | length")
  stemcellUbound=$(($stemcellCount-1))
  releaseUbound=$(($releaseCount-1))

  for i in {0..stemcellUbound}; do
    stemcell=$(cat recipes/$recipe/index.json | jq -r ".stemcells[$i]")
    su -l pivotal sh -c "bosh --tty -e bosh-azure upload-stemcell $stemcell"
  done

  for i in {0..releaseUbound}; do
    release=$(cat recipes/$recipe/index.json | jq -r ".releases[$i]")
    su -l pivotal sh -c "bosh --tty -e bosh-azure upload-release $release"
  done

 else
   echo "Recipe '$recipe' does not exist"
   exit 1
 fi

 cat stdout > /home/pivotal/install_log.txt

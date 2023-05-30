#!/bin/bash

# Define variables
RESOURCE_GROUP="t-yshady-test"
LOCATION="westus3"
VNET_NAME="YourVnetName"
SUBNET_NAME="YourSubnetName"
MYSQL_VM_NAME="mysql-vm"
MYSQL_VM_SIZE="Standard_D16ds_v5" 
SYSBENCH_VM_NAME="sysbench-vm"
SYSBENCH_VM_SIZE="Standard_D16s_v5" 
ADMIN_USER="usernametest"
ADMIN_PASSWORD="Password123!"
MYSQL_PORT=3306
SYSBENCH_PORT=3307
RETRY=5

# Function to install packages on VM
install_package() {
    package_name=$1
    if ! dpkg -s $package_name >/dev/null 2>&1; then
        sudo apt-get -y install $package_name
    fi
}

# Function to configure packages on VM
configure_packages() {
    install_package "mysql-server"
    install_package "sysbench"
}

# Function to troubleshoot MySQL connection issue
troubleshoot_mysql_connection() {
    echo "Performing troubleshooting steps..."

    # Step 1: Check for DNS resolution
    echo "Step 1: Checking DNS resolution..."
    if ! nslookup $MYSQL_VM_NAME &> /dev/null; then
        echo "DNS resolution for MySQL VM failed."
        echo "Checking hostname or DNS name configuration..."
        az vm show --resource-group $RESOURCE_GROUP --name $MYSQL_VM_NAME --query 'networkProfile.networkInterfaces[].ipConfigurations[].privateIpAddress' -o table
    fi

    # Step 2: Validate network connectivity
    echo "Step 2: Validating network connectivity..."
    if ! ping -c 1 $MYSQL_VM_NAME &> /dev/null; then
        echo "Network connectivity to MySQL VM failed."
        echo "Checking network configuration and connectivity..."
        az vm show --resource-group $RESOURCE_GROUP --name $MYSQL_VM_NAME --query 'networkProfile.networkInterfaces[].ipConfigurations[].privateIpAddress' -o table
    fi
}

# Function to check MySQL connection status
check_mysql_connection() {
    if mysql -h $MYSQL_VM_IP -u $MYSQL_USER -p$MYSQL_USER_PASSWORD -e "SELECT 1" &> /dev/null; then
        echo "MySQL connection from Sysbench VM to MySQL VM established successfully."
        return 0
    else
        echo "Failed to establish MySQL connection from Sysbench VM to MySQL VM."
        return 1
    fi
}

# Create resource group
az group create --name $RESOURCE_GROUP --location $LOCATION

# Create VNet and Subnet
az network vnet create --name $VNET_NAME --resource-group $RESOURCE_GROUP --location $LOCATION --address-prefix 10.0.0.0/16
az network vnet subnet create --name $SUBNET_NAME --resource-group $RESOURCE_GROUP --vnet-name $VNET_NAME --address-prefix 10.0.0.0/24

# Check if MySQL VM exists. If not, create it
#mysql_vm_exists=$(az vm show --resource-group $RESOURCE_GROUP --name $MYSQL_VM_NAME --query name -o tsv)
#if [ "$mysql_vm_exists" != "$MYSQL_VM_NAME" ]; then
#    az vm create --resource-group $RESOURCE_GROUP --name $MYSQL_VM_NAME --image UbuntuLTS --size $MYSQL_VM_SIZE --vnet-name $VNET_NAME --subnet $SUBNET_NAME --admin-username $MYSQL_USER --generate-ssh-keys
#fi

# Check if Sysbench VM exists. If not, create it
#sysbench_vm_exists=$(az vm show --resource-group $RESOURCE_GROUP --name $SYSBENCH_VM_NAME --query name -o tsv)
#if [ "$sysbench_vm_exists" != "$SYSBENCH_VM_NAME" ]; then
#    az vm create --resource-group $RESOURCE_GROUP --name $SYSBENCH_VM_NAME --image UbuntuLTS --size $SYSBENCH_VM_SIZE --vnet-name $VNET_NAME --subnet $SUBNET_NAME --admin-username $MYSQL_USER --generate-ssh-keys
#fi

# Create MySQL VM
az vm create \
    --resource-group $RESOURCE_GROUP \
    --name $MYSQL_VM_NAME \
    --image UbuntuLTS \
    --size $MYSQL_VM_SIZE \
    --admin-username $ADMIN_USER \
    --admin-password $ADMIN_PASSWORD \
    --vnet-name $VNET_NAME \
    --subnet $SUBNET_NAME \
    --public-ip-address "" \
    --generate-ssh-keys

# Create Sysbench VM
az vm create \
    --resource-group $RESOURCE_GROUP \
    --name $SYSBENCH_VM_NAME \
    --image UbuntuLTS \
    --size $SYSBENCH_VM_SIZE \
    --admin-username $ADMIN_USER \
    --admin-password $ADMIN_PASSWORD \
    --vnet-name $VNET_NAME \
    --subnet $SUBNET_NAME \
    --public-ip-address "" \
    --generate-ssh-keys

# Get the private IP addresses of the VMs
MYSQL_VM_IP=$(az vm show -d --resource-group $RESOURCE_GROUP --name $MYSQL_VM_NAME --query privateIps -o tsv)
SYSBENCH_VM_IP=$(az vm show -d --resource-group $RESOURCE_GROUP --name $SYSBENCH_VM_NAME --query privateIps -o tsv)

# Install MySQL server on MySQL VM and update mysql.cnf file to allow connections from the Sysbench VM
az vm run-command invoke --resource-group $RESOURCE_GROUP --name $MYSQL_VM_NAME --command-id RunShellScript --scripts "sudo apt-get update && sudo apt-get -y install mysql-server && sudo mysql_secure_installation -D << EOF
Y
$ADMIN_PASSWORD
$ADMIN_PASSWORD
Y
Y
Y
Y
EOF
sudo sed -i 's/127.0.0.1/0.0.0.0/g' /etc/mysql/mysql.conf.d/mysqld.cnf && sudo systemctl restart mysql.service"

# Install sysbench on Sysbench VM
az vm run-command invoke --resource-group $RESOURCE_GROUP --name $SYSBENCH_VM_NAME --command-id RunShellScript --scripts "sudo apt-get update && sudo apt-get -y install sysbench"

# Allow connections to MySQL VM on port 3306 from Sysbench VM
az vm open-port --resource-group $RESOURCE_GROUP --name $MYSQL_VM_NAME --port 3306 --priority 900

# Check the connectivity from Sysbench VM to MySQL VM on port 3306
az vm run-command invoke --resource-group $RESOURCE_GROUP --name $SYSBENCH_VM_NAME --command-id RunShellScript --scripts "nc -zv $MYSQL_VM_IP 3306"

# Allow inbound SSH connections on the VMs' NSGs
az vm open-port --resource-group $RESOURCE_GROUP --name $MYSQL_VM_NAME --port 22 --priority 1001
az vm open-port --resource-group $RESOURCE_GROUP --name $SYSBENCH_VM_NAME --port 22 --priority 1001

# Configure necessary packages on both VMs
az vm run-command invoke --resource-group $RESOURCE_GROUP --name $MYSQL_VM_NAME --command-id RunShellScript --scripts "sudo apt-get update; sudo apt-get -y install mysql-server"
az vm run-command invoke --resource-group $RESOURCE_GROUP --name $SYSBENCH_VM_NAME --command-id RunShellScript --scripts "sudo apt-get update; sudo apt-get -y install sysbench"
az vm run-command invoke --resource-group $RESOURCE_GROUP --name $MYSQL_VM_NAME --command-id RunShellScript --scripts "sudo ufw allow $MYSQL_PORT; sudo systemctl restart mysql;"

# Configure MySQL settings on MySQL VM
#az vm run-command invoke --resource-group $RESOURCE_GROUP --name $MYSQL_VM_NAME --command-id RunShellScript --scripts "sudo sed -i 's/bind-address.*/bind-address = 0.0.0.0/' /etc/mysql/mysql.conf.d/mysqld.cnf; sudo systemctl restart mysql"

# Configure inbound rules for MySQL VM NSG
troubleshoot_mysql_connection
check_mysql_connection

# Test MySQL connection and run sysbench
echo "TEST: Accesing MYSQL from SYSBENCH:"
az vm run-command invoke --resource-group $RESOURCE_GROUP --name $SYSBENCH_VM_NAME --command-id RunShellScript --scripts "nc -zv $MYSQL_VM_IP 3306"

MYSQL_VM_IP=$(az vm show -d --resource-group $RESOURCE_GROUP --name $MYSQL_VM_NAME --query publicIps --out tsv)
for i in $(seq 1 $RETRY); do
    echo "Trying to connect to MySQL at $MYSQL_VM_IP..."
    output=$(az vm run-command invoke --resource-group $RESOURCE_GROUP --name $SYSBENCH_VM_NAME --command-id RunShellScript --scripts "mysql -h $MYSQL_VM_IP -P $MYSQL_PORT -u $MYSQL_USER -p$MYSQL_USER_PASSWORD -e 'quit'")
    if [[ $output == *"ERROR"* ]]; then
        echo "Connecting to MySQL, trying in 10 seconds..."
        sleep 10
    else
        echo "Successfully connected to MySQL, running sysbench..."
        
        az vm run-command invoke --resource-group $RESOURCE_GROUP --name $SYSBENCH_VM_NAME --command-id RunShellScript --scripts "
        sudo apt-get update;
        sudo apt-get -y install mysql-client;
        mysql -h $MYSQL_VM_IP -P $MYSQL_PORT -u $MYSQL_USER -p$MYSQL_USER_PASSWORD -e \"CREATE DATABASE IF NOT EXISTS $SYSBENCH_TEST_DB;\"
        sudo apt-get install sysbench
        sysbench --test=cpu --cpu-max-prime=20000 run
        "

        #sysbench --test=oltp --oltp-table-size=1000000 --db-driver=mysql --mysql-db=$SYSBENCH_TEST_DB --mysql-user=$MYSQL_USER --mysql-password=$MYSQL_USER_PASSWORD

        echo "Setup completed successfully"
        break
    fi
done
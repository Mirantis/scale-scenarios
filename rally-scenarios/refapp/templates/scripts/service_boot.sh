#!/bin/bash
set -x
# allow access to the local variables from prepare-metadata.py
set -a

#
# Variables in this block are passed from heat template
#
NODE_NUMBER=$node_number
NODE_01_IP=$node_01_ip
NODE_02_IP=$node_02_ip
NODE_03_IP=$node_03_ip
DATABASE_NETWORK_CIDR=$database_network_cidr
DATABASE_ADMIN_PASSWORD=$database_admin_password
DATABASE_VIP=$database_vip
SERVICE_TYPE=$service_type
APP_DOCKER_IMAGE=$app_docker_image
APP_PORT=$app_port
#
# End of block
#
DATABASE_ADMIN_PASSWORD=${DATABASE_ADMIN_PASSWORD:-"r00tme"}
DATABASE_DISK=${DATABASE_DISK:-"/dev/vdc"}
APP_DATABASE_NAME=${APP_DATABASE_NAME:-"refapp"}
APP_DATABASE_USER=${APP_DATABASE_USER:-"refapp"}
APP_DATABASE_PASSWORD=${APP_DATABASE_PASSWORD:-"refapp"}

function retry {
    local retries=$1
    shift
    local msg="$1"
    shift

    local count=0
    until "$@"; do
        exit=$?
        wait=$((2 ** $count))
        count=$(($count + 1))
        if [ $count -lt $retries ]; then
            echo "Retry $count/$retries exited $exit, retrying in $wait seconds..."
            sleep $wait
        else
            echo "Retry $count/$retries exited $exit, no more retries left."
            echo "$msg"
            return $exit
        fi
    done
    return 0
}

function wait_condition_send {
    local status=${1:-SUCCESS}
    local reason=${2:-\"empty\"}
    local data=${3:-\"empty\"}
    local data_binary="{\"status\": \"$status\", \"reason\": \"$reason\", \"data\": $data}"
    echo "Trying to send signal to wait condition 50 times: $data_binary"
    WAIT_CONDITION_NOTIFY_EXIT_CODE=2
    i=0
    while (( ${WAIT_CONDITION_NOTIFY_EXIT_CODE} != 0 && ${i} < 50 )); do
        $wait_condition_notify -k --data-binary "$data_binary" && WAIT_CONDITION_NOTIFY_EXIT_CODE=0 || WAIT_CONDITION_NOTIFY_EXIT_CODE=2
        i=$((i + 1))
        sleep 5
    done
    if (( ${WAIT_CONDITION_NOTIFY_EXIT_CODE} !=0 && "${status}" == "SUCCESS" ))
    then
        status="FAILURE"
        reason="Can't reach metadata service to report about SUCCESS."
    fi
    if [ "$status" == "FAILURE" ]; then
        exit 1
    fi
}

function install_required_packages {
    function install_retry {
        apt update && \
        export DEBIAN_FRONTEND=noninteractive; apt install -y apt-transport-https ca-certificates curl software-properties-common jq unzip atop iptables-persistent
    }
    retry 10 "Failed to install required packages" install_retry
}


function install_mariadb {
    function install_retry {
        apt-key adv --recv-keys --keyserver hkp://keyserver.ubuntu.com:80 0xF1656F24C74CD1D8 && \
        add-apt-repository 'deb [arch=amd64] http://nyc2.mirrors.digitalocean.com/mariadb/repo/10.4/ubuntu bionic main' && \
        apt update && \
        apt install -y mariadb-server mariadb-client rsync
    }
    retry 10 "Failed to install docker" install_retry
    systemctl enable mariadb.service
    mysql_secure_installation <<EOF
y
${DATABASE_ADMIN_PASSWORD}
${DATABASE_ADMIN_PASSWORD}
y
y
y
y
EOF

}

function configure_mariadb {
    systemctl stop mariadb.service
    local node_ip_var="NODE_${NODE_NUMBER}_IP"
    cat <<EOF > /etc/mysql/conf.d/galera.cnf
[mysqld]
binlog_format=ROW
default-storage-engine=innodb
innodb_autoinc_lock_mode=2
bind-address=0.0.0.0

# Galera Provider Configuration
wsrep_on=ON
wsrep_provider=/usr/lib/galera/libgalera_smm.so

# Galera Cluster Configuration
wsrep_cluster_name="test_cluster"
wsrep_cluster_address="gcomm://${NODE_01_IP},${NODE_02_IP},${NODE_03_IP}"

# Galera Synchronization Configuration
wsrep_sst_method=rsync

# Galera Node Configuration
wsrep_node_address="${!node_ip_var}"
wsrep_node_name="$(hostname)"
EOF
}

function start_mariadb {
    if [[ "$NODE_NUMBER" -eq "01" ]]; then
        galera_new_cluster
    else
        systemctl start mariadb.service
    fi
}

function grant_remote_access {
    mysql -u root -p${DATABASE_ADMIN_PASSWORD} -e "GRANT ALL ON *.* to root@'%' IDENTIFIED BY \"${DATABASE_ADMIN_PASSWORD}\";"
}

function init_refapp_database {
    local db=$1
    local db_user=$2
    local db_password=$3

    mysql -u root -p${DATABASE_ADMIN_PASSWORD} -e "CREATE DATABASE $db CHARACTER SET utf8;"
    mysql -u root -p${DATABASE_ADMIN_PASSWORD} -e "CREATE USER IF NOT EXISTS '${db_user}'@'%' identified by '${db_password}';"
    mysql -u root -p${DATABASE_ADMIN_PASSWORD} -e "GRANT ALL PRIVILEGES ON ${db}.* TO '${db_user}'@'%';"
}

function mount_drives {
    if ! lsblk -f ${DATABASE_DISK} |grep -q ext4; then
        mkfs.ext4 ${DATABASE_DISK}
    fi
    if [ ! -d /var/lib/mysql ]; then
        mkdir /var/lib/mysql
    fi
    if ! grep -q "${DATABASE_DISK}" /etc/fstab; then
        mount /dev/vdc /var/lib/mysql
        echo "${DATABASE_DISK}    /var/lib/mysql   ext4    defaults    0 0" >> /etc/fstab
    fi
}

function install_database {
    install_required_packages
    install_mariadb
    configure_mariadb
    start_mariadb
    grant_remote_access
    init_refapp_database $APP_DATABASE_NAME $APP_DATABASE_USER $APP_DATABASE_PASSWORD
}

function install_docker {
    mkdir -p /etc/docker
    cat <<EOF > /etc/docker/daemon.json
{
  "default-address-pools": [
    { "base": "192.168.0.0/24", "size": 24 }
  ]
}
EOF
    apt update
    apt install -y docker.io
}

function install_app {
    install_docker
    docker run --restart=always -dit -p ${APP_PORT}:8000 --hostname $(hostname) -e OS_REFAPP_DB_URL="mysql+pymysql://${APP_DATABASE_USER}:${APP_DATABASE_PASSWORD}@${DATABASE_VIP}:3306/refapp" $APP_DOCKER_IMAGE
}

case "$SERVICE_TYPE" in
    database)
        mount_drives
        install_database
        ;;
    app)
        install_app
        ;;
    *)
        echo "Unknown service type: $SERVICE_TYPE. Supported types are database or app"
        exist 1
esac

wait_condition_send "SUCCESS" "Instance successfuly started."

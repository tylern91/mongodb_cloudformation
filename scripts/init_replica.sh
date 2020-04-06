#!/bin/bash

#################################################################
# Update the OS, install packages, initialize environment vars,
# and get the instance tags
#################################################################
yum -y update
yum install -y jq
yum install -y xfsprogs

source ./orchestrator.sh -i
source ./config.sh

tags=`aws ec2 describe-tags --filters "Name=resource-id,Values=${AWS_INSTANCEID}"`

#################################################################
#  gatValue() - Read a value from the instance tags
#################################################################
getValue() {
    index=`echo $tags | jq '.[]' | jq '.[] | .Key == "'$1'"' | grep -n true | sed 's/:.*//g' | tr -d '\n'`
    (( index-- ))
    filter=".[$index]"
    result=`echo $tags | jq '.[]' | jq $filter.Value | sed s/\"//g | sed 's/.*[Pp]rimary.*/Primary/g' | tr -d '\n'`

    echo $result
}

# MongoDBVersion set inside config.sh
version=${MongoDBVersion}

if [ -z "$version" ] ; then
  version="3.6"
fi

echo "[mongodb-org-${version}]
name=MongoDB Repository
baseurl=http://repo.mongodb.org/yum/amazon/2013.03/mongodb-org/${version}/x86_64/
gpgcheck=0
enabled=1" > /etc/yum.repos.d/mongodb-org-${version}.repo

# To be safe, wait a bit for flush
sleep 5

yum --enablerepo=epel install node npm -y

yum install -y mongodb-org
yum install -y libcgroup
yum -y install mongo-10gen-server mongodb-org-shell
yum -y install sysstat

#################################################################
#  Figure out what kind of node we are and set some values
#################################################################
NODE_TYPE=`getValue Name`
IP=$(curl http://169.254.169.254/latest/meta-data/local-ipv4)
NODES=`getValue ClusterReplicaSetCount`

#################################################################
#  Wait for all the nodes to synchronize so we have all IP addrs
#################################################################
if [ "${NODE_TYPE}" == "Primary" ]; then
    ./orchestrator.sh -c -n "${TABLE_NAMETAG}"
    ./orchestrator.sh -s "WORKING" -n "${TABLE_NAMETAG}"
    ./orchestrator.sh -w "WORKING=${NODES}" -n "${TABLE_NAMETAG}"
    IPADDRS=$(./orchestrator.sh -g -n "${TABLE_NAMETAG}")
    read -a IPADDRS <<< $IPADDRS
else
    ./orchestrator.sh -b -n "${TABLE_NAMETAG}"
    ./orchestrator.sh -w "WORKING=1" -n "${TABLE_NAMETAG}"
    ./orchestrator.sh -s "WORKING" -n "${TABLE_NAMETAG}"
    NODE_TYPE="Secondary"
    ./orchestrator.sh -w "WORKING=${NODES}" -n "${TABLE_NAMETAG}"
fi


#################################################################
# Make filesystems, set ulimits and block read ahead on ALL nodes
#################################################################
mkfs.xfs -f /dev/xvdf
echo "/dev/xvdf /var/lib/mongodb-data xfs defaults,auto,noatime,noexec 0 0" | tee -a /etc/fstab
mkdir -p /var/lib/mongodb-data
mount /var/lib/mongodb-data
chown -R mongod:mongod /var/lib/mongodb-data
blockdev --setra 32 /dev/xvdf
rm -rf /etc/udev/rules.d/85-ebs.rules
touch /etc/udev/rules.d/85-ebs.rules
echo 'ACTION=="add", KERNEL=="'$1'", ATTR{bdi/read_ahead_kb}="16"' | tee -a /etc/udev/rules.d/85-ebs.rules
echo "* soft nofile 64000
* hard nofile 64000
* soft nproc 64000
* hard nproc 64000" > /etc/limits.conf

#################################################################
# Setup MongoDB servers and config nodes
#################################################################
mkdir /var/run/mongod
chown mongod:mongod /var/run/mongod

echo "net:" > mongod.conf
echo "  port:" >> mongod.conf
if [ "$version" == "3.6" ] || [ "$version" == "4.0" ]; then
    echo "  bindIpAll: true" >> mongod.conf
fi
echo "" >> mongod.conf
echo "systemLog:" >> mongod.conf
echo "  destination: file" >> mongod.conf
echo "  logAppend: true" >> mongod.conf
echo "  logRotate: reopen" >> mongod.conf
echo "  path: /var/log/mongodb/mongod.log" >> mongod.conf
echo "" >> mongod.conf
echo "operationProfiling:" >> mongod.conf
echo "  slowOpThresholdMs: 50" >> mongod.conf
echo "  mode: slowOp" >> mongod.conf
echo "" >> mongod.conf
echo "storage:" >> mongod.conf
echo "  dbPath: /var/lib/mongodb-data" >> mongod.conf
echo "  engine: wiredTiger"  >> mongod.conf
echo "" >> mongod.conf
echo "processManagement:" >> mongod.conf
echo "  fork: true" >> mongod.conf
echo "  pidFilePath: /var/run/mongod/mongod.pid" >> mongod.conf
echo "" >> mongod.conf

#################################################################
#  Figure out how much RAM we have and how to slice it up
#################################################################
memory=$(vmstat -s | grep "total memory" | sed -e 's/K total.*//g' | sed -e 's/[ ]//g' | tr -d '\n')
memory=$(printf %.0f $(echo "${memory} / 1024 / 1 * .9 / 1024" | bc))

if [ ${memory} -lt 1 ]; then
    memory=1
fi

#################################################################
# Clone the mongod config file and create cgroups for mongod
#################################################################
c=0
port=27017

cp mongod.conf /etc/mongod.conf
sed -i "s/.*port:.*/  port: ${port}/g" /etc/mongod.conf
echo "replication:" >> /etc/mongod.conf
echo "  replSetName: ${TABLE_NAMETAG}" >> /etc/mongod.conf
echo "  oplogSizeMB: 5120" >> /etc/mongod.conf

echo CGROUP_DAEMON="memory:mongod" > /etc/sysconfig/mongod

#################################################################
# Listen to all interfaces, not just local
#################################################################

enable_all_listen() {
  for f in /etc/mongo*.conf
  do
    sed -e '/bindIp/s/^/#/g' -i ${f}
    sed -e '/bind_ip/s/^/#/g' -i ${f}
    echo " Set listen to all interfaces : ${f}"
  done
}

check_primary() {
    expected_state=$1
    master_substr=\"ismaster\"\ :\ ${expected_state}

mongo --port ${port} << EOF
rs.initiate()
EOF

    while true; do
      check_master=$( mongo --eval "printjson(db.isMaster())" )
      log "${check_master}..."
      if [[ $check_master == *"$master_substr"* ]]; then
        log "Node is in desired state, proceed with security setup"
        break
      else
        log "Wait for node to become primary"
        sleep 10
      fi
    done
}

setup_security_common() {
    DDB_TABLE=$1
    auth_key=$(./orchestrator.sh -f -n $DDB_TABLE)
    echo $auth_key > /mongo_auth/mongodb.key
    chmod 400 /mongo_auth/mongodb.key
    chown -R mongod:mongod /mongo_auth
    sed $'s/processManagement:/security: \\\n  authorization: enabled \\\n  keyFile: \/mongo_auth\/mongodb.key \\\n\\\n&/g' /etc/mongod.conf >> /tmp/mongod_sec.txt
    mv /tmp/mongod_sec.txt /etc/mongod.conf
}

setup_security_primary() {
    DDB_TABLE=$1
    port=27017
    MONGO_PASSWORD=$( cat /tmp/mongo_pass.txt )

mongo --port ${port} << EOF
use admin;
db.createUser(
  {
    user: "${MONGODB_ADMIN_USER}",
    pwd: "${MONGO_PASSWORD}",
    roles: [ { role: "root", db: "admin" } ]
  }
);
EOF

    service mongod stop
    ./orchestrator.sh -k -n "${TABLE_NAMETAG}"
    sleep 5
    setup_security_common "${TABLE_NAMETAG}"
    sleep 5
    service mongod start
    sleep 10
}

#################################################################
#  Start all mongod processes
#################################################################
chkconfig mongod on
if [ "$version" != "3.6" ] && [ "$version" != "4.0" ];  then
    enable_all_listen
fi
service mongod start

#################################################################
#  Primaries initiate replica sets
#################################################################
if [[ "$NODE_TYPE" == "Primary" ]]; then

    #################################################################
    # Wait unitil all the hosts for the replica set are responding
    #################################################################
    for addr in "${IPADDRS[@]}"
    do
        addr="${addr%\"}"
        addr="${addr#\"}"

        echo ${addr}:${port}
        while [ true ]; do

            echo "mongo --host ${addr} --port ${port}"

mongo --host ${addr} --port ${port} << EOF
use admin
EOF

            if [ $? -eq 0 ]; then
                break
            fi
            sleep 5
        done
    done

    #################################################################
    # Configure the replica sets, set this host as Primary with
    # highest priority
    #################################################################
    if [ "${NODES}" -gt "3" ]; then
        port=27017
        conf="{\"_id\" : \"${TABLE_NAMETAG}\", \"version\" : 1, \"members\" : ["
        node=1
        for addr in "${IPADDRS[@]}"
        do
            addr="${addr%\"}"
            addr="${addr#\"}"

            priority=0
            votes=0
            conf="${conf}{\"_id\" : ${node}, \"host\" :\"${addr}:${port}\", \"priority\": ${priority}, \"votes\": ${votes}}"

            if [ $node -lt ${NODES} ]; then
                conf=${conf}","
            fi

            (( node++ ))
        done

        conf=${conf}"]}"
        echo ${conf}

mongo --port ${port} << EOF
rs.initiate(${conf})
EOF

        if [ $? -ne 0 ]; then
            # Houston, we've had a problem here...
            ./signalFinalStatus.sh 1
        fi
    else
        port=27017

        priority=0
        votes=0
        conf="{\"_id\" : \"${TABLE_NAMETAG}\", \"version\" : 1, \"members\" : ["
        conf="${conf}{\"_id\" : 1, \"host\" :\"${IP}:${port}\", \"priority\":${priority}, \"votes\": ${votes}}"
        conf=${conf}"]}"

mongo --port ${port} << EOF
rs.initiate(${conf})
EOF

    fi

    #################################################################
    #  Update status to FINISHED, if this is s0 then wait on the rest
    #  of the nodes to finish and remove orchestration tables
    #################################################################
    ./orchestrator.sh -s "FINISHED" -n "${TABLE_NAMETAG}"
    ./orchestrator.sh -w "FINISHED=${NODES}" -n "${TABLE_NAMETAG}"

    echo "Setting up security, bootstrap table: " "${TABLE_NAMETAG}"
    # wait for mongo to become primary
    sleep 10
    check_primary true

    setup_security_primary "${TABLE_NAMETAG}"

    for addr in "${IPADDRS[@]}"
    do
        addr="${addr%\"}"
        addr="${addr#\"}"

        port=27017
        node=1
        priority=0
        votes=0
        if [ "${addr}" != "${IP}" ] || [ $node -lt ${NODES} ]; then
            repl="{\"host\" :\"${addr}:${port}\", \"priority\": ${priority}, \"votes\": ${votes}}"

mongo --port ${port} -u ${MONGODB_ADMIN_USER} -p ${MONGO_PASSWORD} << EOF
rs.add(${repl})
EOF

        fi
        (( node++ ))
    done

    ./orchestrator.sh -s "SECURED" -n "${TABLE_NAMETAG}"
    ./orchestrator.sh -w "SECURED=${NODES}" -n "${TABLE_NAMETAG}"
    #./orchestrator.sh -d -n "${TABLE_NAMETAG}"
    rm /tmp/mongo_pass.txt
else
    #################################################################
    #  Update status of Secondary to FINISHED
    #################################################################
    ./orchestrator.sh -s "FINISHED" -n "${TABLE_NAMETAG}"
    ./orchestrator.sh -w "FINISHED=${NODES}" -n "${TABLE_NAMETAG}"

    ./orchestrator.sh -w "SECURED=1" -n "${TABLE_NAMETAG}"
    service mongod stop
    setup_security_common "${TABLE_NAMETAG}"
    service mongod start
    ./orchestrator.sh -s "SECURED" -n "${TABLE_NAMETAG}"
    rm /tmp/mongo_pass.txt

fi

# exit with 0 for SUCCESS
exit 0

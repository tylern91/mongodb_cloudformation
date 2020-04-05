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
    result=`echo $tags | jq '.[]' | jq $filter.Value | sed s/\"//g | sed 's/Primary.*/Primary/g' | tr -d '\n'`
    echo $result
}

##version=`getValue MongoDBVersion`

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
yum install -y munin-node
yum install -y libcgroup
yum -y install mongo-10gen-server mongodb-org-shell
yum -y install sysstat

#################################################################
#  Figure out what kind of node we are and set some values
#################################################################
NODE_TYPE="Arbiter"
IP=$(curl http://169.254.169.254/latest/meta-data/local-ipv4)
NODES=`getValue ClusterReplicaSetCount`

#  Do NOT use timestamps here!!
# This has to be unique across multiple runs!
#UNIQUE_NAME=MONGODB_${TABLE_NAMETAG}

#################################################################
#  Wait for all the nodes to synchronize so we have all IP addrs
#################################################################
    IPADDRS=$(./orchestrator.sh -g -n "${TABLE_NAMETAG}")
    ./orchestrator.sh -w "WORKING=${NODES}" -n "${TABLE_NAMETAG}"

#################################################################
# Make filesystems, set ulimits and block read ahead on ALL nodes
#################################################################
mkdir -p /var/lib/mongodb-data
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
# End All Nodes
#################################################################

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
#  Enable munin plugins for iostat and iostat_ios
#################################################################
#ln -s /usr/share/munin/plugins/iostat /etc/munin/plugins/iostat
#ln -s /usr/share/munin/plugins/iostat_ios /etc/munin/plugins/iostat_ios
#touch /var/lib/munin/plugin-state/iostat-ios.state
#chown munin:munin /var/lib/munin/plugin-state/iostat-ios.state

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
echo "  oplogSizeMB: 1024" >> /etc/mongod.conf

echo CGROUP_DAEMON="memory:mongod" > /etc/sysconfig/mongod

echo "mount {
    cpuset  = /cgroup/cpuset;
    cpu     = /cgroup/cpu;
    cpuacct = /cgroup/cpuacct;
    memory  = /cgroup/memory;
    devices = /cgroup/devices;
  }

  group mongod {
    perm {
      admin {
        uid = mongod;
        gid = mongod;
      }
      task {
        uid = mongod;
        gid = mongod;
      }
    }
    memory {
      memory.limit_in_bytes = ${memory}G;
      }
  }" > /etc/cgconfig.conf


#################################################################
#  Start cgconfig, munin-node, and all mongod processes
#################################################################
chkconfig cgconfig on
service cgconfig start

chkconfig munin-node on
service munin-node start

chkconfig mongod on
if [ "$version" != "3.6" ] && [ "$version" != "4.0" ];  then
    enable_all_listen
fi
service mongod start

# exit with 0 for SUCCESS
exit 0

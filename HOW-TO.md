# How to deploy the stack by using CloudFormation

## Create the `my-release` stack with only 1 MongoDB instance

Update the `ClusterReplicaSetCount` parameter key's value in [parameters/mongob-master.json](https://github.com/tylern91/mongodb_cloudformation/blob/master/parameters/mongodb-master.json) to `1` to deploy the MongoDB replica set with only 1 instance. Default value is `3`

Then run the AWS CLI command to deploy the stack. You may need to setup AWS profile in local to run this command.

```bash
$ aws cloudformation create-stack --stack-name my-release --template-body file://templates/mongodb-master.template --parameters file://parameters/mongodb-master.json --capabilities CAPABILITY_IAM
```

## Create the `my-release` replica set with 1 master and 2 secondaries instances

Just run the AWS CLI command to deploy the stack. You may need to setup AWS profile in local to run this command.

```bash
$ aws cloudformation create-stack --stack-name my-release --template-body file://templates/mongodb-master.template --parameters file://parameters/mongodb-master.json --capabilities CAPABILITY_IAM
```

## Create the secondary node to join the current replica set

This is used when you have the current replica set with 1 primary and would like to add the secondary node. You need to update all values of the parameter keys in [parameters/mongob-node.json](https://github.com/tylern91/mongodb_cloudformation/blob/master/parameters/mongodb-node.json) first to match with your current AWS environment.

Then run the AWS CLI command to deploy the stack.

```bash
$ aws cloudformation create-stack --stack-name my-release --template-body file://templates/mongodb-node.template --parameters file://parameters/mongodb-node.json --capabilities CAPABILITY_IAM
```

## Create the another arbiter node to join the current replicaset

Same as adding replica node, we also need to update all the values of the parameter keys defined in [parameters/mongob-arbiter.json](https://github.com/tylern91/mongodb_cloudformation/blob/master/parameters/mongodb-arbiter.json) first to match with your current AWS environment.

Then run the AWS CLI command to deploy the stack.

```bash
$ aws cloudformation create-stack --stack-name my-release --template-body file://templates/arbiter.template --parameters file://parameters/arbiter.json --capabilities CAPABILITY_IAM
```

## How to change instance type of the MongoDB instance

To changing the instance type, we are able to either use the AWS CLI or via AWS Console. The instance type process should basically is `stop instance` -> `update instance type` -> `start instance`.

For updating the instance type via AWS CLI, we need to get the `instance-id` value of the instance.

Here below is an example with AWS CLI:

```bash
# Stop the instance need to be updated
aws ec2 stop-instances --instance-ids i-1234567890abcdef0

# Update the instance type
aws ec2 modify-instance-attribute --instance-id i-1234567890abcdef0 --instance-type "{\"Value\": \"t3.medium\"}"

# Start the instance back, we need to wait few minutes for replica set sync
aws ec2 start-instances --instance-ids i-1234567890abcdef0
```

## How to change the volume size of the EC2 instance

For this operation, we don't need to stop the instance as the MongoDB stack is running with EBS-backed instance type. This allows us to expand the instance volume with no-downtime approach. To change the volume size, we will follow the list command as below. Replace the `<placeholders>` with your values:

```bash
# Expand the volume size
aws ec2 modify-volume --region <regionName> --volume-id <volumeId> --size <newSize> --volume-type <newType> --iops <newIops>

# View the progress of your task
aws ec2 describe-volumes-modifications --volume <volumeId> --region <region>
```
*   Note: if the volume type is `gp2` we don't need to set the `--iops <newIops>` argument

SSH login to the instance and run the below commands to extend the file system:

```bash
# Use the df -h command to verify the size of the file system for each volume
$ df -h

# Install the XFS tools as follows, if they are not already installed.
$ sudo yum install xfsprogs

# Use the xfs_growfs command to extend the file system on each volume. In this example, /var/lib/mongodb-data is the volume mount point of MongoDB data
$ sudo xfs_growfs -d /var/lib/mongodb-data

# You can verify that each file system reflects the increased volume size by using the df -h command again.
$ df -h
```

## Create the MongoDB backup

Simply create the backup location in S3 bucket and update the location path to the `mongodb_s3_backup.sh` script then run inside the MongoDB instance and provide the `username` and `password` of MongoDB replica set.

```bash
$ sh ./mongodb_s3_backup.sh
Your MongoDB administrator username:
Your MongoDB administrator password:
```

Reference [scripts/mongo_s3_backup.sh](https://github.com/tylern91/mongodb_cloudformation/blob/master/scripts/mongo_s3_backup.sh) for the details

## Deleting the stack

Delete the stack deployment as normal

```bash
$ aws cloudformation delete-stack --stack-name my-release
```

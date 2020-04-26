# MongoDB Setup by AWS CloudFormation

This sets up a flexible, scalable AWS environment for MongoDB, and launches MongoDB into a configuration of your choice based on the [aws-quickstart/quickstart-mongodb](https://github.com/aws-quickstart/quickstart-mongodb) with the bug fixes and improvements.

The module offers the deployment option for deploying MongoDB into an existing VPC on AWS with the AWS CloudFormation templates as a starting point for your own implementation.

![Architecture for MongoDB on AWS](https://d0.awsstatic.com/partner-network/QuickStart/datasheets/mongodb-architecture-on-aws.png)

For architectural details, best practices, step-by-step instructions, and customization options, see the
[deployment guide](https://fwd.aws/3d33d).

## Prerequisites Details

*   Your verified AWS account.
*   An IAM account with the needed permissions to create the stack using CloudFormation.
*   Create the manifest S3 bucket and upload all the templates in `templates` folder and the scripts in `scripts` folder to there. CloudFormation needs those files referenced while creating the stack. The name and region of this bucket need to be defined as described variables as below section.

## Module Details

This module will do the following:
*   Create the EC2-based MondoDB instance running in replica set or standalone.
*   Include the MondoDB Arbiter node in replica set for participating in elections for primary node.
*   Create the associate IAM role for EC2 instances for handling the operations (e.g initiate, backup, fetch templates from S3, etc.).
*   Configurations for the MongoDB storage engine (currently support only wiredTiger) and auto-discovery.
*   Using the separated EBS volume with io1 volume type support for handling the MongoDB's data.
*   See the list of instance types support for replica and arbiter nodes:
    *   [Replica node](https://github.com/tylern91/mongodb_cloudformation/blob/5db6189466a2c7ada9f16ca67d52bda2699f5904/templates/mongodb-node.template#L61-L81)
    *   [Arbiter node](https://github.com/tylern91/mongodb_cloudformation/blob/5db6189466a2c7ada9f16ca67d52bda2699f5904/templates/mongodb-arbiter.template#L57-L68)

## Configuration

The following table lists the configurable parameters of the MongoDB replica set and their default values.

|               Parameter               |                            Description                           |  Default  |
| ------------------------------------- | ---------------------------------------------------------------- | ----------|
| `BastionSecurityGroupID`              | ID of the Bastion Security Group                                 | `nil`     |
| `ClusterReplicaSetCount`              | Number of Replica Set Members (choose 1 or 3)                    | `3`       |
| `ReplicaInstanceType`                 | Amazon EC2 instance type for the MongoDB replica members         | `t2.micro` |
| `ArbiterInstanceType`                 | Amazon EC2 instance type for the MongoDB arbiter members         | `t2.micro` |
| `ImageId`                             | AMI ID for MongoDB instance                                      | `nil`     |
| `Iops`                                | Iops of EBS volume when io1 type is chosen<br>Otherwise ignored  | `100`     |
| `KeyPairName`                         | Name of an existing EC2 KeyPair for launching MongoDB EC2 instances | `home` |
| `MongoDBAdminUsername`                | MongoDB database administrator username                          | `admin`   |
| `MongoDBAdminPassword`                | MongoDB Database administrator password                          | `nil`     |
| `MongoDBInterServersSecurityGroupID`  | ID of the MongoDB Inter-Server Communication Security Group      | `nil`     |
| `MongoDBNodeIAMProfileID`             | ID of the MongoDB IAM instance profile (Role)                    | `nil`     |
| `MongoDBServerSecurityGroupID`        | ID of the MongoDB Server Access Security Group                   | `nil`     |
| `MongoDBVersion`                      | MongoDB version                                                  | `4.0`     |
| `NodeNameTag`                         | Instance Name                                                    | `nil`     |
| `PrimaryNodeSubnet`                   | Subnet ID in VPC for Primary node deployment.                    | `nil`     |
| `Secondary0NodeSubnet`                | Subnet ID in VPC for the #1 Secondary node deployment            | `nil`     |
| `Secondary1NodeSubnet`                | Subnet ID in VPC for the #2 Secondary node deployment            | `nil`     |
| `Arbiter0NodeSubnet`                  | Subnet ID in VPC for the #1 Arbiter node deployment              | `nil`     |
| `ReplicaSetName`                      | Name for the MongoDB Replica Set                                 | `nil`     |
| `S3BucketName`                        | S3 bucket name for the manifests                                 | `cloudformation-manifests` |
| `S3BucketRegion`                      | The AWS Region where the S3 bucket (`S3BucketName`) is hosted    | `us-east-1` |
| `S3KeyPrefix`                         | S3 key prefix for the assets                                     | `mongodb/` |
| `VolumeSize`                          | EBS Volume size (MongoDB Data) to be attached to node in GBs     | `400`     |
| `VolumeType`                          | EBS Volume Type (MongoDB Data) to be attached to node in GBs     | `gp2`     |
| `VPC`                                 |  VPC for the MongoDB replica set deployment                      | `nil`     |

Specify each parameter by modifying the JSON parameter files in `parameters` folder.

## Guidelines

Please follow this tutorial for accessing the MongoDB replica set from AWS Lambda: [Best Practices Connecting from AWS Lambda](https://docs.atlas.mongodb.com/best-practices-connecting-to-aws-lambda/)

Preference the [How-to](https://github.com/tylern91/mongodb_cloudformation/blob/master/HOW-TO.md) page for the guidelines

## Backup MongoDB to S3

For the backup strategy, we would go with [mongodump](https://docs.mongodb.com/v4.0/reference/program/mongodump/) since it is part of the MongoDB tools package. Based on that, I prepare the tiny script which can help you to backup your MongdoDB database and even can run it as schedule in arbiter node (or somewhere else in the same VPC). The `mongo_s3_backup.sh` shell script can be found in `scripts` folder.

To post feedback, submit feature ideas, or report bugs, use the **Issues** section of this GitHub repo.

#!/bin/sh

# Make sure to:
# 1) Name this file `mongo_s3_backup.sh` and place it in /home/ec2-user
# 2) Run sudo yum install awscli to install the AWSCLI
# 3) No need to have aws configured (it's assumed by the attached role)
# 4) Fill in DB host + name
# 5) Create S3 bucket for the backups and fill it in below (set a lifecycle rule to expire files older than X days in the bucket)
# 6) Run chmod +x mongo_s3_backup.sh
# 7) Test it out via ./mongo_s3_backup.sh
# 8) Set up a daily backup at midnight via `crontab -e`:
#    0 0 * * * /home/ubuntu/mongo_s3_backup.sh > /home/ubuntu/backup.log

backup_name=~/db_backups-`date +%Y-%m-%d-%H%M`
mongodump --out $backup_name
tar czf $backup_name.tar.gz $backup_name
aws s3 cp $backup_name.tar.gz s3://my_bucket/db_backups/
rm -rf $backup_name
rm $backup_name.tar.gz

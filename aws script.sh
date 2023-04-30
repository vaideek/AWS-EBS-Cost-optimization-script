
#!/bin/bash

# Usage: ./ebs-optimizer-v2.sh ${REGION} ${BACKUP} ${ENVIRONMENT}
# Example: ./ebs-optimizer-v2.sh us-east-1 nobackup production
# ${REGION} - AWS region where this script will be launched
# ${BACKUP} - backup option:
#	1) backup - create EBS snapshot before volume type modification
#	2) nobackup - do not ceate ENS snapshot before volume type modification
# ${ENVIRONMENT} - environment
# 	For production environment gp2 to gp3 volume modification for attached (in-use) volumes will be skipped

# This script review all EBS volumes and checks their size and type. If they are unattached and larger than 125 GiB they will be converted to sc1 type.
# If they are unattached gp2 and smaller than 125 GiB they will modified to gp3 type.
# If they are attached gp2 (any size) they will be modified to gp3 type.
# Snapshots before modification are optional and can be set by backup/nobackup parameter for script execution. 

# Check if region and backup/nobackup parameters have been defined 
if [[ $# -eq 0 ]] ; then
	echo "Missed input parameters. Set AWS region, backup/nobackup and environment first."
	exit 1
fi

# Set REGION variable
REGION=$1

# Set BACKUP variable
BACKUP=$2

# Set ENVIRONMENT variable
ENVIRONMENT=$3

# Get service quotas for storage for gp2 volumes
GP2_QUOTAS=$(aws service-quotas get-service-quota --service-code ebs --quota-code L-D18FCD1D --region $REGION --output=text | awk '{print $NF}')

# Get service quotas for storage for gp3 volumes
GP3_QUOTAS=$(aws service-quotas get-service-quota --service-code ebs --quota-code L-7A658B76 --region $REGION --output=text | awk '{print $NF}')

# Compare service quotas for further storage modification
if [[ ${GP2_QUOTAS} > ${GP3_QUOTAS} ]]; then
	echo "Please increase service quotas for storage for gp3 volumes first. Modification can be failed because of existing limits."
	exit 1
fi

# EBS snapshot function
ebs_snapshot () {
	echo "Preparing volume ${VOLUME_ID} snapshot for restore cases."
	echo "Creating restore and automation tags for ${VOLUME_ID} volume snapshot."
	TAGS=$(aws ec2 describe-tags --region $REGION --filters Name=resource-id,Values=${VOLUME_ID} --output=text | awk '{print "{Key="$2",Value="$5"},"}' | tr -d "\n")
	TAGS+="{Key=volume-id,Value=${VOLUME_ID}},{Key=automation-control,Value=ebs-cost-governance}"
	echo "Creating ${VOLUME_ID} volume snapshot."
	SNAPSHOT_ID=$(aws ec2 create-snapshot --region $REGION --volume-id ${VOLUME_ID} --description "Created by EBS Cost Optimization script on ${DATE}" \
		--tag-specifications "ResourceType=snapshot,Tags=[${TAGS}]" --query 'SnapshotId' --output text)
	while [ "${exit_status}" != "0" ]; do
		SNAPSHOT_STATE=$(aws ec2 describe-snapshots --region $REGION --filters Name=snapshot-id,Values=${SNAPSHOT_ID} --query 'Snapshots[0].State')
		SNAPSHOT_PROGRESS=$(aws ec2 describe-snapshots --region $REGION --filters Name=snapshot-id,Values=${SNAPSHOT_ID} --query 'Snapshots[0].Progress')
		echo "Snapshot ${SNAPSHOT_ID} creation state is ${SNAPSHOT_STATE}, ${SNAPSHOT_PROGRESS} done."
		aws ec2 wait snapshot-completed --snapshot-ids ${SNAPSHOT_ID} --region $REGION
		exit_status="$?"
	done
	exit_status="-1"
		}

# Get today's date and week ago gate to permanently delete outdated and unused snapshots created a week ago by EBS Cost Optimization script 
DATE=$(date +"%Y-%m-%d")
OLD_DATE=$(date +'%Y-%m-%d' -d '7 days ago')

# Delete outdated and unused snapshots created a week ago by EBS Cost Optimization script 
SNAPSHOTS_TO_DELETE=$(aws ec2 describe-snapshots --region $REGION --query "Snapshots[?StartTime<='${OLD_DATE}'].SnapshotId" --filters Name=tag:automation-control,Values=ebs-cost-governance --output text)
# Deletion process
if [ -z "${SNAPSHOTS_TO_DELETE}" ]
then
	echo "Nothing to delete. No outdated snapshots."
else
	echo "List of snapshots to delete: ${SNAPSHOTS_TO_DELETE}"
	for SNAPSHOT in ${SNAPSHOTS_TO_DELETE}; do
		aws ec2 delete-snapshot --snapshot-id ${SNAPSHOT} --region $REGION
	done
fi

# Uncomment next line if you want to print EBS unattached request details
#aws ec2 describe-volumes --region ${REGION} --filters Name=status,Values=available --query 'Volumes[*].[VolumeType, VolumeId, Size, State]' --output=table

# Detect unattached EBS with gp2 volume type and size less than 125 GiB, and convert them to gp3 volume type
VOLUMES_TO_MODIFY=$(aws ec2 describe-volumes --region $REGION --filters Name=status,Values=available --query 'Volumes[?(Size < `125` && VolumeType == `gp2`)].[VolumeId]' --output=text)
if [ -z "${VOLUMES_TO_MODIFY}" ]
then
	echo "No volumes to modify."
else
	echo "List of volumes to modify: ${VOLUMES_TO_MODIFY}"
	for VOLUME_ID in ${VOLUMES_TO_MODIFY}; do
		if [[ ${BACKUP} != "nobackup" ]]; then
			ebs_snapshot
		fi
		echo "Modyfyifying ${VOLUME_ID} volume from gp2 to gp3 volume type to save costs."
		aws ec2 modify-volume --volume-type gp3 --volume-id ${VOLUME_ID} --region $REGION
		aws ec2 wait volume-available --volume-ids ${VOLUME_ID} --region $REGION
		echo "${VOLUME_ID} volume has been successfully modified to gp3 volume type. Backup snapshot ${SNAPSHOT_ID} can be permanently deleted in 7 days."
	done
fi

# Unset VOLUMES_TO_MODIFY variable
unset VOLUMES_TO_MODIFY

# Detect unattached EBS with gp2|gp3|io1|io2|st1|standard volume type and size equal or greater than 125 GiB (can be converted to sc1 volume type) and convert them to sc1 volume type
VOLUMES_TO_MODIFY=$(aws ec2 describe-volumes --region $REGION --filters Name=status,Values=available --query 'Volumes[?(Size >= `125` && VolumeType != `sc1`)].[VolumeId]' --output=text)
if [ -z "${VOLUMES_TO_MODIFY}" ]
then
	echo "No volumes to modify."
else
	echo "List of volumes to modify: ${VOLUMES_TO_MODIFY}"
	for VOLUME_ID in ${VOLUMES_TO_MODIFY}; do
		if [[ ${BACKUP} != "nobackup" ]]; then
			ebs_snapshot
		fi
		echo "Modyfyifying ${VOLUME_ID} volume to sc1 volume type to save costs."
		aws ec2 modify-volume --volume-type sc1 --volume-id ${VOLUME_ID} --region $REGION
		aws ec2 wait volume-available --volume-ids ${VOLUME_ID} --region $REGION
		echo "${VOLUME_ID} volume has been successfully modified to sc1 volume type. Backup snapshot ${SNAPSHOT_ID} can be permanently deleted in 7 days."
	done
fi

# Unset VOLUMES_TO_MODIFY variable
unset VOLUMES_TO_MODIFY

# Detect attached (in-use) EBS with gp2 volume type and convert them to gp3 volume type
if [[ ${ENVIRONMENT} == "production" ]]; then
	echo "Skipping gp2 to gp3 volume modification for attached (in-use) gp2 EBS volumes on production environment."
	exit 0
else
	VOLUMES_TO_MODIFY=$(aws ec2 describe-volumes --region $REGION --filters Name=status,Values=in-use --query 'Volumes[?VolumeType == `gp2`].[VolumeId]' --output=text)
	if [ -z "${VOLUMES_TO_MODIFY}" ]
	then
		echo "No volumes to modify."
	else
		echo "List of volumes to modify: ${VOLUMES_TO_MODIFY}"
		for VOLUME_ID in ${VOLUMES_TO_MODIFY}; do
			if [[ ${BACKUP} != "nobackup" ]]; then
				ebs_snapshot
			fi
			echo "Modyfyifying ${VOLUME_ID} volume from gp2 to gp3 volume type to save costs."
			aws ec2 modify-volume --volume-type gp3 --volume-id ${VOLUME_ID} --region $REGION
			echo "${VOLUME_ID} volume has been successfully modified to gp3 volume type. Backup snapshot ${SNAPSHOT_ID} can be permanently deleted in 7 days."
		done
	fi
fi




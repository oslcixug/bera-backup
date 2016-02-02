#!/bin/bash
# @date 06/25/2015
#
# @description Backup and migrate a Linux server in less than 10 minutes. Backup all important information:
#	- Services configuration
#	- Any group of folders
#	- Websites
# Yet more important, backup can be easily restored in any server. So it can be also used
# to migrate a server. See "bera-restore.sh" for further information.
#
# Features:
# · Migrate a complex Linux server in less than 10 minutes
# · High speed for incremental backups
# · 3 kinds of backups: 
#	files: Backup any file or folder you want (services config, important information...)
#	config: Backup system information (users, crontabs, iptables...)
#	domains: Backup any websites
#
# Development background:
# · Developed by our in-house tech staff 
# · Tested several times in live with our own servers and websites
# 
# @usage
# ./bera-backup.sh CONFIG_FILE
#
###
#
# DO NOT TOUCH ANYTHING BELOW THIS LINE
#
########################################
### CONFIG
########################################
servicesFile="enabledServices"
installedPackagesFile="installedPackages"
dirScript="$(dirname $(readlink -f $0))/";
IFS='
'
########################################
### CHECKS
########################################
# Config checks
if [ -z $1 ]; then
	echo "[ERROR] A config file is required as parameter"
	echo "	ls -l $1"
	exit
fi
if [ ! -f $1 ]; then
	echo "[ERROR] Config file doesn't exist"
	echo "	ls -l $1"
	exit
fi
source $dirScript$1
if [ -z "$backupDir" ]; then
	echo "[ERROR] Var 'backupDir' is missing in config file"
	exit
fi
# backupDir must exist
if [ ! -d "$backupDir" ]; then
	echo "[ERROR] Backup directory doesn't exist '$backupDir'"
	exit
fi
# Root should do it
if [ "$(id -u)" != "0" ]; then
	echo "[WARN] Please, consider to backup data as root to avoid permission issues"
fi

# Setting texts used several times
txtCreatingBackup="- Creating backup for"
txtChecking="- Checking"

# Different types of backups for different type of information. Different actions can be performed on each one.
# For example, we could encrypt files.
backupDirDomains=${backupDir}domains/
backupDirFiles=${backupDir}files/
backupDirConfig=${backupDir}config/

# Set files and folders to exclude from all backups
fileExcludedTemp="/tmp/_BERA_backup_excluded"
echo -n "" > $fileExcludedTemp
for concreteExcludedFile in "${BackupListExcluded[@]}"
do
	echo "${concreteExcludedFile}" >> $fileExcludedTemp
done
# The backup dir itself is excluded 
echo "${backupDir}" >> $fileExcludedTemp

########################################
### FUNCTIONS
########################################
# Configured to stop on Control + C
int_handler()
{
    echo "Interrupted."
    # Kill the parent process of the script.
    kill $PPID
    exit 1
}

# 
# @param userName		Name of the user to add
# @param userBackupFile		Path to backup file
#
# @usage			addUserToUserList USERNAME PATH_TO_USERLIST_FILE
addUserToUserList()
{
	# params
	userName=$1
	userBackupFile=$2

	# Check if user exists in the user list
	if ! grep "^$userName:" $userBackupFile > /dev/null
	then
		# As help to create the user within the new system, his home folder is also saved
		entry=`cat /etc/passwd | grep -i "^$userName:"`
		# And also his groups 
		groupsList=`groups $userName`
		echo "$userName:$entry:$groupsList" >> $userBackupFile
	fi	
}
trap 'int_handler' INT

########################################
### FILES/FOLDERS BACKUP
########################################
echo ""
echo "----------------------------------"
echo "-- SERVER FILES BACKUP "
echo "----------------------------------"

# Create folder where config is stored
mkdir ${backupDirFiles}		2>/dev/null

# Files and folders to backup
for resourceToBackup in ${backupList[*]}; do
	# Check resource exists
	echo "$txtCreatingBackup '$resourceToBackup'..."
	if [ ! -d "$resourceToBackup" -a ! -f "$resourceToBackup" ]; then
		echo "	[ERROR] Resource '$resourceToBackup' doesn't exist"
		continue
	fi

	# Syncronization
	# --relative		To preserve absolute path
	# GZIP the backup is possible but can dramatically affect performance for heavy websites. Synchronizing file by file, incremental backups are really fast.
	rsync -v -azvH --delete --relative  --exclude-from "$fileExcludedTemp" $resourceToBackup ${backupDirFiles} >/dev/null
done

########################################
### BACKUP SERVER CONFIG
########################################
echo ""
echo "----------------------------------"
echo "-- SERVER CONFIG BACKUPS "
echo "----------------------------------"
# Create folder where config is stored
mkdir ${backupDirConfig}		2>/dev/null

# Dump database
# echo "$txtCreatingBackup databases..."
# mysqldump --defaults-file=/home/osl/.my.cnf -h $DBHOST --max_allowed_packet=1024M -u $DBUSER $DBNAME > ${backupDirConfig}$DBNAME.sql

# Save user names which should exist in new server
echo "$txtCreatingBackup users..."
userBackupFile=${backupDirConfig}/users
if [ "$checkUsers" = "1" ]; then
	echo -n '' > $userBackupFile
	while read line; do 
		userName=`echo "$line" | awk -F: '{print $1}'`
		addUserToUserList $userName $userBackupFile
	done < /etc/passwd
else
	echo "   [SKIP] Requested by user"
fi

# Iptables
if [ "$backupIptables" = "1" ]; then
	echo "$txtCreatingBackup iptables..."
	rm -f ${backupDirConfig}/iptables
	/sbin/iptables-save > ${backupDirConfig}/iptables
fi

# Crontabs of all users
if [ "$backupCrontabs" = "1" ]; then
	echo "$txtCreatingBackup crontabs..."
	backupDirCrontabs=${backupDirConfig}/crontabs/
	mkdir -p ${backupDirCrontabs}
	rm -fR ${backupDirCrontabs}/*
	cp -f /var/spool/cron/* ${backupDirCrontabs}
fi

# PEAR modules
if type "pear" > /dev/null; then
	echo "$txtCreatingBackup PEAR modules list..."
	pear list |  tail -n +4 | awk '{print $1}' > ${backupDirConfig}/pearModules
fi

# List of services enabled on startup
if [ "$checkEnabledServices" = "1" ]; then
	echo "$txtChecking enabled services..."
	chkconfig --list | grep -i "2:activ" | awk '{print $1}' | sort > ${backupDirConfig}/$servicesFile
fi

# List of installed packages
if [ "$checkInstalledPackages" = "1" ]; then
	# Sometimes RPM is not the package manager
	if [ $PackagesSystem == "RPM" ]; then
		echo "$txtChecking installed RPM packages..."
		rpm -qa --qf "%{NAME}\n" | sort > /tmp/$installedPackagesFile.tmp

		# Now adding more information for each package
		echo -n "" > ${backupDirConfig}/$installedPackagesFile
		while read concretePackage; do 
			# Add provider (only 1)
			provider=`rpm -q --whatprovides "$concretePackage" --qf "%{NAME}\n" | head -n 1`
			echo "$concretePackage	$provider" >> ${backupDirConfig}/$installedPackagesFile
		done < /tmp/$installedPackagesFile.tmp
		rm -f /tmp/$installedPackagesFile.tmp
	elif [ $PackagesSystem == "DEB" ]; then
		echo "$txtChecking installed APT packages..."
		dpkg-query -l > ${backupDirConfig}/$installedPackagesFile.tab
		dpkg-query -f '${binary:Package}\n' -W > ${backupDirConfig}/$installedPackagesFile.lst
	fi
fi

# Permissions of all folders are changed in order to non-root users can access the full backup
# (as many files belongs to multiple users and otherwise they can find permissions errors to download the backup
echo "----------------------------------"
echo "- Changing some permissions to allow external users to access the backups"
if [ "$maintainFilePermissions" = "0" ]; then
	find ${backupDir} -type d -exec chmod o+xr {} \;
	find ${backupDir} -type f -exec chmod o+r {} \;
else
	echo "   [SKIP] Requested by user"
fi

########################################
### HELP
########################################
echo -e "\n----------------------------------"
echo "- Backup ended ;) Check it out:"
echo "	$backupDir"
exit


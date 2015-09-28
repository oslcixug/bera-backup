#!/bin/bash
# @date 06/25/2015
#
# @description Restores a Linux server from a previous backup done with Bera backup tool (bera-backup.sh script).
# This scripts downloads the backup from the backup server and restores the server.
#
# You should execute "bera-backup.sh" at the original server. And then "bera-restore.sh" at the new server.
# More information at "bera-backup.sh"
#
# @usage
# ./bera-restore.sh CONFIG_FILE
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
# Generic text
DONE="	[OK] Done"
ONLYROOT="	[SKIP] Only root can do it"

# Only root can do some tasks
userIsRoot=0
if [ "$(id -u)" == "0" ]; then
	userIsRoot=1
fi

########################################
### CHECK
########################################
# Config file is required
if [ "$#" != 1 ]; then
	echo "[ERROR] Path of config file is required. Ie:"
	echo "	$0 _restore-server-s1"
	exit
fi
if [ ! -f $1 ]; then
	echo "[ERROR] Config file doesn't exist"
	echo "	ls -l $1"
	exit
fi
pathConfig=$1

source $pathConfig

# Some vars  need to be defined in config file
if [ "$backupOrigin" = "ssh" ]; then
	if [ -z $backupRemoteUser ]; then
		echo "[ERROR] Config file needs var 'backupRemoteUser'"
		exit
	fi
	if [ -z $backupRemoteServer ]; then
		echo "[ERROR] Config file needs var 'backupRemoteServer'"
		exit
	fi
	if [ -z $backupRemoteDir ]; then
		echo "[ERROR] Config file needs var 'backupRemoteDir'"
		exit
	fi
fi

# Origin must be valid
if [ "$backupOrigin" != "local" -a "$backupOrigin" != "ssh" ]; then
	echo "[ERROR] 'backupOrigin' must be 'local' or 'ssh'"
	exit
fi

# backupDir must exist
if [ ! -d "$backupLocalDir" ]; then
	echo "[ERROR] Backup directory doesn't exist '$backupLocalDir'"
	exit
fi

# Don't restore some domains
fileExcludedTemp="/tmp/_BERA_restore_excluded"
echo -n "" > $fileExcludedTemp
for concreteExcluded in "${domainsExcluded[@]}"
do
	echo "${concreteExcluded}" >> $fileExcludedTemp
done
# Set files and folders to exclude from all backups
for concreteExcluded in "${filesExcluded[@]}"
do
	echo "${concreteExcluded}" >> $fileExcludedTemp
done

# Configured to stop on Control + C
int_handler()
{
    echo "Interrupted."
    # Kill the parent process of the script.
    kill $PPID
    exit 1
}
trap 'int_handler' INT

########################################
### DOWNLOAD BACKUP TO THIS SERVER
########################################
echo "----------------------------------"
echo "-- BACKUPS DOWNLOAD "
echo "----------------------------------"
cd ${backupLocalDir}
echo "- Backup stored locally at '${backupLocalDir}'"

# Backups download
if [ "$backupOrigin" = "ssh" ]; then
	echo "- Downloading backups..."
	if [ -d "${backupLocalDir}backups/" -a  "$backupRemoteForceDownload" = "0" ]; then
		echo "	[SKIP] Using existing backup at '${backupLocalDir}'"
	else
		echo "	[INFO] Downloading from '$backupRemoteServer' as user '${backupRemoteUser}'..."
		rsync -a -v -e "ssh -p${backupRemotePort}" --exclude-from "${fileExcludedTemp}" ${backupRemoteUser}@$backupRemoteServer:${backupRemoteDir}* ${backupLocalDir} > /dev/null
		# Check if it worked
		if [ "$?" != "0" ]; then
			echo "	[ERROR] Rsync no pudo restaurar los archivos desde '$backupRemoteServer'"
			exit
		fi
		echo $DONE
	fi
fi

# Set folder for different types of backups
backupLocalDirConfig=${backupLocalDir}config/
backupLocalDirFiles=${backupLocalDir}files/

########################################
### RESTORING SERVICES
########################################
echo ""
echo "----------------------------------"
echo "-- RESTORING SERVER CONFIGURATIONS "
echo "----------------------------------"
if [ "$userIsRoot" = "0" ]; then
	echo $ONLYROOT
elif [ ! -d ${backupLocalDirConfig} ]; then
	echo "[WARN] Backup for server configurations was not found, skipping..."
	echo "	ls -l ${backupLocalDirConfig}"
else
	# Everything is OK, lets go...
	cd ${backupLocalDirConfig}

	# Required users should exist in the new system
	echo "- Checking users..."
	someUserDoesntExist=0
	if [ "$checkUsers" = "1" ]; then
		while read userInfo; do 
			# Extract user data
			userName=`echo "$userInfo" | awk -F: '{print $1}'`
			extraInfo=`echo "$userInfo" | awk -F: '{print $2}'`
			userHome=`echo "$userInfo" | awk -F: '{print $7}'`
			groups=`echo "$userInfo" | awk -F: '{print $9}' | xargs`

			# User in new system should be exactly the same
			if ! grep "^$userName:" /etc/passwd > /dev/null
			then
				echo "	[WARN] User '$userName' doesn't exist If needed:"
				echo "		useradd $userName"
				echo "		usermod -d $userHome $userName"
				echo "		passwd $userName"
				echo "		passwd -u $userName"
				someUserDoesntExist=1
			# Check if home is also the same
			elif ! grep "^$userName:.*:$userHome" /etc/passwd > /dev/null
			then
				# Get current home for this user
				currentHome=`cat /etc/passwd | grep -i "^$userName:" | awk -F: '{print $6}'`

				echo "	[WARN] Path for user '$userName' doesn't match:"
				echo "		Current folder: $currentHome"
				echo "		Folder from backup: $userHome"
				echo "		Recommended command:"
				echo "			usermod -d $userHome $userName"
				someUserDoesntExist=1
			else
				# If user exist, try to add him to all groups
				groupsList=( ${groups} )
				for concreteGroup in ${groupsList[*]}; do
					# Group by group to be sure they exist before adding the user
					if grep $concreteGroup /etc/group > /dev/null
					then
						# Group exists, add the user
						if ! usermod -G $concreteGroup $userName > /dev/null
						then
							echo "	[ERROR] Adding user '$userName' to group '$concreteGroup'"
							someUserDoesntExist=1
						fi
					else
						# Group doesn't exist
						echo "	[WARN] Group '$concreteGroup' doesn't exist. Needed for user '$userName'"
						someUserDoesntExist=1
					fi
				done		
			fi
		done < ./users
	else
		echo "   [SKIP] Requested by user"
	fi

	# Users of crontabs should also exist
	if [ -d "crontabs/" ]; then
		crontabUsers=(`ls -l crontabs/ | awk '{print $9}'`)
		for concreteUser in ${crontabUsers[*]}; do
			# We check if user exists within current system
			userExists=`cut -f1 -d: /etc/passwd | grep -i "^${concreteUser}$" | wc -l`
			if [ $userExists != "1" ]; then
				echo "	[ERROR] User '${concreteUser}' is needed in this server to restore as we have a crontab record for him."
				someUserDoesntExist=1
			fi
		done
	fi

	# If errors, exit
	if [ "$someUserDoesntExist" = "1" ] 
	then
		echo "	[INFO] Users/groups are not created automatically for security reasons. Please, check report above and add them if necessary."
		#exit
	else
		echo $DONE
	fi

	# Restore iptables
	if [ -d "iptables/" ]; then
		echo ""
		echo "- Restoring iptables..."
		echo "	[INFO] Iptables is not automatically restored as it could hurt the system. Change it carefully. We recommend:"
		echo "	1. Create a copy of iptables"
		echo "		iptables-save > ${backupLocalDirConfig}iptables.backup"
		echo "	2. Check iptables from backup"
		echo "		cat ${backupLocalDirConfig}iptables"
		echo "	3. Restore iptables if it is correct"
		echo "		iptables-restore < ${backupLocalDirConfig}iptables"
		echo "	3. Restart iptables"
		echo "		systemctl restart iptables"
	fi

	# Restore crontabs
	if [ -d "crontabs/" ]; then
		usersWithCrontab=(`ls -l crontabs/ | awk '{print $9}'`)
		crontabsDir="/var/spool/cron/"
		echo ""
		echo "- Restoring crontab for $(( ${#usersWithCrontab[@]} )) users:"
		for usuarioConcreto in ${usersWithCrontab[*]}; do
			# If crontab exists, back it up
			if [ -f $crontabsDir${usuarioConcreto} ]; then
				# Create current crontabs backup directory
				crontabsBackupDir="${backupLocalDirConfig}crontabs/backups/"
				newCrontabFile="$crontabsBackupDir${usuarioConcreto}.bck"
				if [ ! -d "$crontabsBackupDir" ]; then
				    mkdir -p "$crontabsBackupDir"
				fi
				cp -f $crontabsDir${usuarioConcreto} $newCrontabFile
				echo "	[INFO] User '{$usuarioConcreto}' had a previous crontab. Moved to:"
				echo "		$newCrontabFile "
			fi

			# Restore crontab
			crontab -u ${usuarioConcreto} "crontabs/${usuarioConcreto}"
			#echo "	[INFO] Crontab added for '${usuarioConcreto}'"				
		done
		echo $DONE
	fi

	# Checking PEAR
	pearModulesFile=pearModules
	if [ -f "$pearModulesFile" ]; then
		echo -e "\n- Checking PEAR modules..."
		if type "pear" > /dev/null; then
			# PEAR installed
			while read concretePearService; do 
				# get information about modules
				isInstalled=`pear list |  tail -n +4 | awk '{print $1}' | grep -i  ${concretePearService}`

				# Print info
				if [ "$isInstalled" = "" ] 
				then
					echo "	[WARN] PEAR module '$concretePearService' is not installed"
				fi

			done < $pearModulesFile
		else
			# not installed
			echo "[WARN] PEAR is not installed. To install:"
			echo "		yum install php-pear"
		fi
	fi

	# Check info about installed packages
	echo -e "\n- Checking info about installed packages..."
	if [ -f "$installedPackagesFile" ]; then
		if [ "$checkInstalledPackages" = "1" ]; then
			# Check if RPM package manager is installed
			if type "rpm" > /dev/null; then
				installCommands=""
				while read line; do 
					# get fields
					concretePackage=`echo "$line" | awk '{print $1}'`
					yumPackageName=`echo "$line" | awk '{print $2}'`

					# Check if package exists
					if ! rpm -q --quiet $concretePackage; then 
						echo "	[WARN] Package '$concretePackage' missing"
						# One command each line so user can choose what to install
						installCommands="${installCommands}		yum -y install $yumPackageName\n"
					fi
				done < $installedPackagesFile

				# If missing packages
				if [ "$installCommands" != "" ] 
				then
					echo "	----------------------------------"
					echo "	[WARN] Some packages are missing. To install, check them carefully and try:"
					echo -e "$installCommands"
				fi
			else
				echo "	[WARN] Can't check packages as RPM is not the package manager. Check the list of packages at the server which was backed up:"
				echo "		less $servicesFile"
			fi
		else
			echo "	 [SKIP] Requested by user"
		fi
	else
		echo "	 [SKIP] Not present in this backup"
	fi

	# Check info about enabled services
	echo -e "\n- Checking info about services..."
	if [ -f "$servicesFile" ]; then
		if [ "$checkInstalledPackages" = "1" ]; then
			if type "systemctl" > /dev/null; then
				commandsList=""
				while read concreteService; do 
					# Check if service exists
					if [ "`systemctl is-active $concreteService 2>&1`" = "unknown" ] 
					then
						echo "	[WARN] Service '$concreteService' is not installed"

					# Check if service is active
					elif [ "`systemctl is-active $concreteService 2>&1`" != "active" ] 
					then
						echo "	[WARN] Service '$concreteService' is not actived"
						commandsList="${commandsList}		systemctl start $concreteService\n"

					# Check if service is enabled
					elif [ "`systemctl is-enabled $concreteService 2>&1`" != "enabled" ] 
					then
						echo "	[WARN] Service '$concreteService' is not enabled"
						commandsList="${commandsList}		systemctl enable $concreteService\n"
					fi
				done < $servicesFile

				# If errors, exit
				if [ "$commandsList" != "0" ] 
				then
					echo "	----------------------------------"
					echo "	[INFO] Some services were enabled at backed up server:"
					echo -e "$commandsList"
				fi
			fi
		else
			echo "	 [SKIPPING] User request"
		fi
	else
		echo "	 [SKIPPING] Not present in this backup"
	fi
fi

########################################
### RESTORING FILES
########################################
echo ""
echo "----------------------------------"
echo "-- RESTORING FILES "
echo "----------------------------------"
echo "- Restoring files ($backupLocalDirFiles) from backup..."
opt_dirtimes=""
opt_group=""
if [ "$userIsRoot" = "0" ]; then
	echo "	[WARN] As user is not root, 'group' check and 'dir modification time' are not done"
	opt_group="--no-group"
	opt_dirtimes="--omit-dir-times"
fi
echo "	- Executing RSYNC...."
rsync -azvH $opt_group $opt_dirtimes --exclude-from "${fileExcludedTemp}" $backupLocalDirFiles / >/dev/null
# Check if it worked
if [ "$?" != "0" ]; then
	echo "	[ERROR] Rsync could not restore all files from '$backupLocalDirFiles'"
	exit
fi

########################################
### HELP
########################################
echo ""
echo "----------------------------------"
echo "- Backup successfully restored ;) It is stored for any need:"
echo "	$backupLocalDir"
exit



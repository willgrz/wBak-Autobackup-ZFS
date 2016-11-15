#!/bin/bash
#configuration directory
confdir="/mnt/backup/config"
source ${confdir}/autobackup.conf
cgpg=$(which gpg)
action=$1


function log {
  sexit=$1
  slog=$2
  if [ "$sexit" == "0" ]; then
	base=$(date "+%b %d %R:%S $(hostname -s) autobackup: INFO")
	if [ "$eonly" != "1" ]; then
		  echo "${slog}"
        fi
  elif [ "$sexit" == "1" ]; then
	base=$(date "+%b %d %R:%S $(hostname -s) autobackup: ERROR")
	echo "${slog}"
  else
	base=$(date "+%b %d %R:%S $(hostname -s) autobackup: UNKNOWN")
	echo "${slog}"
  fi
  echo "${base}" "${slog}" >>${ablog}
}

if [ ! -d "${lockdir}" ]; then
        log 1 "Lockdir not existing - creating: ${lockdir}"
        mkdir -p ${lockdir}
fi

if [ "${action}" == '--full-backup' ]; then
#|| [ "${action}" == '--fullbackup' ] || [ "${action}" == 'fullbackup' ]; then
        log 0 "Admin - Running full backup and external sync on next run (few minutes at most) - watch control window"
        for file in $(ls -1 ${lockdir}/*:*); do
                touch -a -m -t 201601010000.01 ${file}
        done
	for file in $(ls -1 ${lockdir}/ext-backup-*); do
                touch -a -m -t 201601010000.01 ${file}
        done
	exit 0
fi


function sync_external {
	ymdstr=$(date +'%Y-%m-%d-%H%M')
	ssname=$1
	syncsnap=$2
	ssnap=$(echo $syncsnap |sed -e "s+${zpool}/++" -e "s+${ssname}@++")
	if [ "$eonly" != "1" ]; then
		log 0 "External sync of $syncsnap of server $ssname started"
        fi
	RANDRR=$RANDOM
	#override, run once uncommented to enable sync on that run
	touch -a -m -t 201601010000.01 ${lockdir}/ext-backup-${ssname}
	#/override
	if [ "$(find ${lockdir}/ext-backup-${ssname} -mmin +${esyncf} | wc -l)" != "1" ]; then
		log 0 "${ssname} - Not ${esyncf} minutes since last external sync of this server, exiting"
		break
	else
		touch ${lockdir}/ext-backup-${ssname}
	fi
	if [ ! -d "${etmp}/${ssname}-${RANDRR}" ]; then
		mkdir -p ${etmp}/${ssname}
	fi
	if [ "$eonly" != "1" ]; then
		log 0 "${ssname} - Starting targz + GPG"
	fi
	tar --exclude="/.zfs/" --numeric-owner -cz ${backupdir}/${ssname}/.zfs/snapshot/${ssnap}/ | $cgpg --trust-model always --encrypt --recipient $gkey -o "${etmp}/${ssname}/${ssname}-${RANDRR}-${ymdstr}.tar.gz.enc"
	sleep 3
	for exserv in $(echo $exsync); do
		if [ "$eonly" != "1" ]; then
			log 0 "${ssname} - Starting upload of ${etmp}/${ssname}/${ssname}-${RANDRR}-${ymdstr}.tar.gz.enc to ${exserv}/${ssname}/"
			rsync --progress ${etmp}/${ssname}/${ssname}-${RANDRR}-${ymdstr}.tar.gz.enc ${exserv}/${ssname}/
		else
			rsync ${etmp}/${ssname}/${ssname}-${RANDRR}-${ymdstr}.tar.gz.enc ${exserv}/${ssname}/
		fi
	done
	#remove GPG file from local
	if [ "$gpgremove" == "1" ]; then
		if [ "$eonly" != "1" ]; then
			log 0 "Removing local GPG encrypted file: ${etmp}/${ssname}/${ssname}-${RANDRR}-${ymdstr}.tar.gz.enc"
		fi
		rm "${etmp}/${ssname}/${ssname}-${RANDRR}-${ymdstr}.tar.gz.enc"
	fi
}

function backupbox {
		ymdstr=$(date +'%Y-%m-%d-%H%M')
		sname=$1
		sipp=$2
		bsexcludes=$3
		RANDRRR=$RANDOM
		if [ "x$sfrequency" != "x" ] && [ "$sfrequency" != "-" ]; then
			bfreq="$sfrequency"
		else
			bfreq="$bfre"
		fi
		if [ "x$bsexcludes" != "x" ] && [ "$bsexcludes" != "-" ]; then
			#eg /abc/|.zfs*|
			echo $bsexcludes | sed -e 's+|+\n+g' >>/tmp/rsync.$RANDRRR
			rsyncadd1="--exclude-from=/tmp/rsync.$RANDRRR"
		fi
		if [ -f "${lockdir}/bk-${sname}" ]; then
			log 1 "${sname} - Lock file found, former backup not finished? ${lockdir}/bk-${sname}"
			echo ""
			break
		else
			touch ${lockdir}/bk-${sname}
		fi
		if [ "$(find ${lockdir}/${sname}-${sipp} -mmin +${bfreq} | wc -l)" != "1" ] && [ -d "${backupdir}/${sname}" ]; then
			#not one hour since last run, exit
			log 0 "${sname} - Not ${bfreq} minutes since last run, exiting (override manual with --full-backup for all servers)"
			rm "${lockdir}/bk-$sname"
			break
		else
			touch ${lockdir}/${sname}-${sipp}
		fi
		#convert IP:Port to IP and Port
                eip=$(echo $sipp | sed -e 's/:/ /g' | awk '{print $1}')
                eport=$(echo $sipp | sed -e 's/:/ /g' | awk '{print $2}')
		oldpwd=$PWD
		cd $backupdir
		if [ ! -d "${backupdir}/${sname}" ]; then
			if [ "$eonly" != "1" ]; then
				log 0 "${sname} - ZFS volume not existing, creating - ${zpool}/${sname}"
			fi
			zfs create "${zpool}/${sname}"
		fi
		if [ -f "${backupdir}/${sname}/.lock" ]; then
			log 1 "${sname} - Server disabled by lock file: ${backupdir}/${sname}/.lock"
			break
		fi
		if [ -f "${rexc}" ]; then
			rsyncadd2="--exclude-from=${rexc}"
		fi
		if [ "$eonly" != "1" ]; then
			log 0 "${sname} - Starting rsync..."
		fi
		rsync --stats -a -D --port=${eport} --delete-after --noatime --numeric-ids --compress --compress-level=3 ${rsyncadd1} ${rsyncadd2} ${rsyncadd3} root@${eip}:/ ${backupdir}/${sname}/ && ok=1
		if [ "$ok" != "1" ]; then
			ok=0
			log 1 "${sname} - First rsync failed - starting second one in 60s"
			sleep 60
			rsync --stats -a -D --port=${eport} --delete-after --noatime --numeric-ids --compress --compress-level=3 ${rsyncadd1} ${rsyncadd2} ${rsyncadd3} root@${eip}:/ ${backupdir}/${sname}/ && ok=1
		fi
		if [ "$ok" != "1" ]; then
			log 1 "${sname} - Second rsync failed - snapshotting but making extra note in log"
			ok=0
		fi
		sleep 1
		if [ "$eonly" != "1" ]; then
			log 0 "${sname} - Creating snapshot ${zpool}/${sname}@autobak-${ymdstr}"
		fi
		zfs snap "${zpool}/${sname}@autobak-${ymdstr}"
		log 0 "${sname} - Snapshot completed - ${zpool}/${sname}@autobak-${ymdstr}"
		if [ "x${addzpools}" != "x" ]; then
			for addzpool in $(echo ${addzpools}); do
				if [ "$eonly" != "1" ]; then
					log 0 "${sname} - Syncing to zpool $addzpool"
				fi
#echo				zfs create "${addzpool}/${sname}"
#echo 				zfs send "${zpool}/${sname}@autobak-${ymdstr}" zfs recv "${addzpool}/${sname}@autobak-${ymdstr}"
			done
		fi
		if [ "$extsync" == "1" ]; then
	                if [ "$eonly" != "1" ]; then
				log 0 "${sname} - Syncing volume to external servers"
                        fi
			sync_external "${sname}" "${zpool}/${sname}@autobak-${ymdstr}"
		else
			if [ "$eonly" != "1" ]; then
				log 0 "${sname} - External sync disabled"
			fi
		fi
		if [ -f "${lockdir}/bk-$sname" ]; then
			rm "${lockdir}/bk-$sname"
		else
			log 1 "${sname} - Lockfile not found? wtf? - ${lockdir}/bk-$sname - exiting entirely"
			exit 1
		fi
		if [ -f "/tmp/rsync.$RANDRR" ]; then
			rm /tmp/rsync.$RANDRR
		fi
		cd "$oldpwd"
		echo ""
}


for server in $(cat ${bconf} | awk '{print $1}' | fgrep -v '#'); do
	backupserver="${server}"
        exthostp=$(cat ${bconf} | grep ${server} | awk '{print $2}')
        sexcludes=$(cat ${bconf} | grep ${server} | awk '{print $3}')
	sfrequency=$(cat ${bconf} | grep ${server} | awk '{print $4}')
	echo ""
        if [ "$eonly" != "1" ]; then
		log 0 "Backing up: $backupserver - $exthostp"
        fi
	if [ "$bgbkup" == "1" ]; then
		backupbox "${backupserver}" "${exthostp}" "${sexcludes}" "${sfrequency}" &
	else
		backupbox "${backupserver}" "${exthostp}" "${sexcludes}" "${sfrequency}"
	fi
done

if [ "$action" != "--or" ]; then
	if [ "x${sltime}" != "x" ] && [[ ${sltime} =~ ^[0-9]+$ ]]; then
	        if [ "$eonly" != "1" ]; then
	                log 0 "Run finished - Sleeping ${sltime} seconds (--or to override)"
	        fi
		sleep ${sltime}
	else
		if [ "$eonly" != "1" ]; then
	        	log 0 "Run finished - Sleeping 60 seconds (--or to override)"
	        fi
		sleep 60
	fi
else
	        if [ "$eonly" != "1" ]; then
                        log 0 "Run finished - not sleeping due to --or switch"
                fi
fi

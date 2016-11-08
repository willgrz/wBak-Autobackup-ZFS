#!/bin/bash
#configuration directory
confdir="/mnt/backup/config"
source ${confdir}/autobackup.conf
cgpg=$(which gpg)
action=$1


function log {
  slog=$1
  base=$(date "+%b %d %R:%S $(hostname -s) autobackup: INFO")
  echo "${base}" "${slog}" >> $ablog
  echo "${slog}"
}

if [ ! -d "${lockdir}" ]; then
        log "Lockdir not existing - creating: ${lockdir}"
        mkdir -p ${lockdir}
fi

if [ "${action}" == "--full-backup" ]; then
        log "Admin - Running full backup and external sync on next run (few minutes at most) - watch loop window"
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
	log "External sync of $syncsnap of server $ssname started"
	RANDRR=$RANDOM
	#override, run once uncommented to enable sync on that run
	touch -a -m -t 201601010000.01 ${lockdir}/ext-backup-${ssname}
	#/override
	if [ "$(find ${lockdir}/ext-backup-${ssname} -mmin +${esyncf} | wc -l)" != "1" ]; then
		log "${ssname} - Not ${esyncf} minutes ($(($esyncf/60)) hours) since last external sync of this server, exiting"
	else
		touch ${lockdir}/ext-backup-${ssname}
	fi
	if [ ! -d "${etmp}/${ssname}-${RANDRR}" ]; then
		mkdir -p ${etmp}/${ssname}
	fi
	log "${ssname} - Starting targz + GPG"
	tar --exclude="/.zfs/" --numeric-owner -cz ${backupdir}/${ssname}/.zfs/snapshot/${ssnap}/ | $cgpg --trust-model always --encrypt --recipient $gkey -o "${etmp}/${ssname}/${ssname}-${RANDRR}-${ymdstr}.tar.gz.enc"
	sleep 3
	for exserv in $(echo $exsync); do
		log "${ssname} - Starting upload of ${etmp}/${ssname}/${ssname}-${RANDRR}-${ymdstr}.tar.gz.enc to ${exserv}/${ssname}/"
		rsync -q ${etmp}/${ssname}/${ssname}-${RANDRR}-${ymdstr}.tar.gz.enc ${exserv}/${ssname}/
	done
	#remove GPG file from local
	if [ "$gpgremove" == "1" ]; then
		log "Removing local GPG encrypted file: ${etmp}/${ssname}/${ssname}-${RANDRR}-${ymdstr}.tar.gz.enc"
		rm "${etmp}/${ssname}/${ssname}-${RANDRR}-${ymdstr}.tar.gz.enc"
	fi
}

function backupbox {
		#call backupbox servername ip:port user holdb
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
		#nvm the -z idiocy, <3 @Fusl :3
		if [ "x$bsexcludes" != "x" ] && [ "$bsexcludes" != "-" ]; then
			#eg /abc/|.zfs*|
			echo $bsexcludes | sed -e 's+|+\n+g' >>/tmp/rsync.$RANDRRR
			rsyncadd1="--exclude-from=/tmp/rsync.$RANDRRR"
		fi
		if [ -f "${lockdir}/bk-${sname}" ]; then
			log "${sname} - Lock file found, former backup not finished? ${lockdir}/bk-${sname}"
			echo ""
			break
		else
			touch ${lockdir}/bk-${sname}
		fi
		if [ "$(find ${lockdir}/${sname}-${sipp} -mmin +${bfreq} | wc -l)" != "1" ] && [ -d "${backupdir}/${sname}" ]; then
			#not one hour since last run, exit
			log "${sname} - Not ${bfreq} minutes since last run, exiting (override manual with --full-backup for all servers)"
			rm "${lockdir}/bk-$sname"
			echo ""
			break
		else
			touch ${lockdir}/${sname}-${sipp}
		fi
		#convert IP:Port to IP and Port
                eip=$(echo $sipp | sed -e 's/:/ /g' | awk '{print $1}')
                eport=$(echo $sipp | sed -e 's/:/ /g' | awk '{print $2}')
		oldpwd=$PWD
		cd $backupdir
		#mkdir backupserver dir if not already available
		if [ -f "${backupdir}/${sname}/.lock" ]; then
			log "${sname} - Server disabled by lock file: ${backupdir}/${sname}/.lock"
			rm "${lockdir}/bk-$sname"
			break
		fi
		if [ ! -d "${backupdir}/${sname}" ]; then
			log "${sname} - ZFS volume not existing, creating - ${zpool}/${sname}"
			zfs create "${zpool}/${sname}"
		fi
		if [ -f "${rexc}" ]; then
			rsyncadd2="--exclude-from=${rexc}"
		fi
		rsync -q --stats -a -D -4 --port=${eport} --delete-after --noatime --numeric-ids --compress --compress-level=3 ${rsyncadd1} ${rsyncadd2} ${rsyncadd3} root@${eip}:/ ${backupdir}/${sname}/ && ok=1
		if [ "$ok" != "1" ]; then
			ok=0
			log "${sname} - First rsync failed - starting second one in 60s"
			sleep 60
			rsync -q --stats -a -D -4 --port=${eport} --delete-after --noatime --numeric-ids --compress --compress-level=3 ${rsyncadd1} ${rsyncadd2} ${rsyncadd3} root@${eip}:/ ${backupdir}/${sname}/ && ok=1
		fi
		if [ "$ok" != "1" ]; then
			log "${sname} - Second rsync failed - snapshotting but making extra note in log"
			ok=0
		fi
		sleep 1
		log "${sname} - Creating snapshot ${zpool}/${sname}@autobak-${ymdstr}"
		zfs snap "${zpool}/${sname}@autobak-${ymdstr}"
		log "${sname} - Syncing volume to external servers"
		if [ "$extsync" == "1" ]; then
			sync_external "${sname}" "${zpool}/${sname}@autobak-${ymdstr}"
		fi
		rm "${lockdir}/bk-$sname"
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
	log "Backing up: $backupserver - $exthostp"
	backupbox "${backupserver}" "${exthostp}" "${sexcludes}" "${sfrequency}" &
done

#sleep 120

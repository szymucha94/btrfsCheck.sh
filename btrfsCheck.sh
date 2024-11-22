#!/bin/bash

hostname=$(hostname)

#settings
btrfs="/bin/btrfs"
defaultDestinationMountPoint="/storage"

export sendMailServer="192.168.1.194"
sendMailPort="25"
sendMailSender="notifier@${hostname}"
sendMailRecipient="user@domain"
sendMailNotification="yes"
sendMailNoOfRetries="3"

haNotificationEnabled="true"
haAddressAndPort="192.168.57.2:8123"
readonly haAuthToken=$(/usr/sbin/get_ha_token.sh)
if [ -z $haAuthToken ]; then
  echo "HA token unavailable. Disabling HA integrations."
  HA_TOKEN_AVAILABLE="false"
else
  HA_TOKEN_AVAILABLE="true"
fi
haSystemAlertIndicationSensor="sensor.${hostname}BtrfsSystemAlert"
HARestApiUrl="http://$haAddressAndPort/api/states/$haSystemAlertIndicationSensor"

scrubAllowedRuntimeInSeconds=21600
scrubLoopTimeInSeconds=600
scrubOutputFile="/dev/shm/.btrfsScrubOutput.tmp"
lockFile="/dev/shm/.btrfsCheck_lock"
messageFile="$scrubOutputFile"

haTargetSensor="input_text.${hostname}_btrfs_scrub_last_target"
HaTargetUrl="http://$haAddressAndPort/api/services/input_text/set_value"
haStatusSensor="input_text.${hostname}_btrfs_scrub_status"
HaStatusUrl="http://$haAddressAndPort/api/services/input_text/set_value"

reportTargetToHa() {
  if [[ $HA_TOKEN_AVAILABLE == "false" ]]; then
    return 1
  else
    curl -s -o /dev/null -X POST -H "Authorization: Bearer $haAuthToken" -H "Content-Type: application/json" -d '{"entity_id": "'"$haTargetSensor"'", "value": "'"$1"'"}' $HaStatusUrl
  fi
}

reportStatusToHa() {
  if [[ $HA_TOKEN_AVAILABLE == "false" ]]; then
    return 1
  else
    curl -s -o /dev/null -X POST -H "Authorization: Bearer $haAuthToken" -H "Content-Type: application/json" -d '{"entity_id": "'"$haStatusSensor"'", "value": "'"$1"'"}' $HaStatusUrl
  fi
}

pidCheck() {
  if ps -p $1 >/dev/null 2>&1; then
    echo "[RUNNING]"
  else
    echo "[NOT RUNNING]"
  fi
}

throwError() {
  echo "[ERROR] $*"
}

throwWarning() {
  echo "[WARNING] $*"
}

throwOk() {
  echo "[OK] $*"
}

initialChecks() {
  if [[ $(whoami) != "root" ]]; then
    throwError "Insufficient permissions to start. Root permissions required."
    reportStatusToHa ERR_PERMISSIONS
    exit
  fi

  if [[ ! -f "/bin/btrfs" ]]; then
    throwError "Btrfs is not installed."
    reportStatusToHa ERR_BTRFS
    exit
  fi

  if [ -f $lockFile ]; then
    lockPid="$(cat $lockFile)"
    messageFile="/dev/shm/.lockErrorMessage"
    throwError "Script is locked by PID: $lockPid $(pidCheck $lockPid), exiting..." | tee $messageFile
    subject="btrfsCheck script startup failure at $(hostname)"
    sendHAWarningNotification
    sendMailNotification
    reportStatusToHa ERR_LOCK
    rm $messageFile
    exit
  fi

  touch $lockFile
  if [ $? -ne 0 ]; then
    throwError "Failed to create lock file. $lockFile not writable?"
    exit
  fi
  echo $$ > $lockFile

  #check in case of PID change (script is executed twice in very short period of time)
  sleep 0.1
  if [[ $$ -ne $(cat $lockFile) ]]; then
    throwError "Suspected simultaneous execution of the script: lockPid changed. Refusing to continue"
    reportStatusToHa ERR_MULTI
    exit
  fi
}

printHelp() {
cat <<EOF
btrfs statistics, scrub monitoring and reporting utility
Default destination mount point is defined in settings section of this script.

Usage: $0 <option>
Options:
  start                  Takes mount point as argument. Checks device stats and scrubs entire medium
  errors-only            Takes mount point as argument. Only checks device stats
  help                   Prints this help
EOF
}

checkIfDefaultMountPoint() {
  if [[ ! -z "$1" ]]; then
    dest="$1"
    destHa=$(echo $1 | tr -dc '[:alnum:]\n\r')
  else
    dest=$defaultDestinationMountPoint
  fi
}

checkIfMountedAsBtrfs() {
  if [[ ! $(findmnt -n -o FSTYPE -T $dest) == "btrfs" ]]; then
    throwError "$dest is not a btrfs filesystem. Refusing to start..." | tee $scrubOutputFile
    subject="btrfs filesystem type check failed for $dest at $(hostname)"
    sendMailNotification
    sendHAWarningNotification
    reportStatusToHa FAILED
    cleanup
    unlock
    exit
  fi
}

checkBtrfsScrubStatus() {
  if [[ $($btrfs scrub status $dest | grep -v "not running" | grep -i "running") ]]; then
    throwError "btrfs scrub for $dest already running. Refusing to start..." | tee $scrubOutputFile
    subject="btrfs scrub failed to start for $dest at $(hostname)"
    sendMailNotification
    sendHAWarningNotification
    reportStatusToHa FAILED
    cleanup
    unlock
    exit
  fi
  echo "btrfs statistics for $dest before scrub:" > $scrubOutputFile
  $btrfs device stats $dest >> $scrubOutputFile
}

startBtrfsScrub() {
  reportStatusToHa SCRUB_STARTED
  reportTargetToHa ${destHa}_scrub
  $btrfs scrub start $dest
}

monitorBtrfsScrubStatus() {
  timeElapsed=0
  while [[ $timeElapsed -le $scrubAllowedRuntimeInSeconds ]]
  do
    if [[ $timeElapsed -gt $((scrubAllowedRuntimeInSeconds - scrubLoopTimeInSeconds)) ]]; then
      scrubLoopTimeInSeconds=$((scrubAllowedRuntimeInSeconds - timeElapsed))
    fi
    if [[ $($btrfs scrub status $dest | grep -i "finished") ]]; then
      throwOk "btrfs scrub finished"
      result="PASSED"
      reportStatusToHa SCRUB_PASSED
      break
    else
      if [[ $($btrfs scrub status $dest | grep -i 'failed\|aborted\|cancelled' ) ]]; then
        throwError "btrfs scrub failed. Manual intervention is required" | tee -a $scrubOutputFile
        echo " " >> $scrubOutputFile
        result="FAILED"
        reportStatusToHa SCRUB_FAILED
        break
      fi
      if [[ $timeElapsed -ge $scrubAllowedRuntimeInSeconds ]]; then
        throwWarning "btrfs scrub check timeout. Manual intervention is required" | tee -a $scrubOutputFile
        echo " " >> $scrubOutputFile
        result="TIMEOUT"
        reportStatusToHa SCRUB_TIMEOUT
        break
      fi
      timeElapsed=$((timeElapsed + scrubLoopTimeInSeconds))
      sleep $scrubLoopTimeInSeconds
    fi
  done
  if [[ ! $($btrfs device stats $dest | grep -v " 0$") ]]; then
    echo " " >> $scrubOutputFile
    throwOk "Data integrity check passed. No errors reported" | tee -a $scrubOutputFile
    echo " " >> $scrubOutputFile
    echo "btrfs scrub status for $dest:" >> $scrubOutputFile
    $btrfs scrub status -d $dest >> $scrubOutputFile
    echo " " >> $scrubOutputFile
    echo "btrfs statistics for $dest after scrub attempt:" >> $scrubOutputFile
    $btrfs device stats -z $dest >> $scrubOutputFile
  else
    echo " " >> $scrubOutputFile
    throwError "Data integrity check failed. Errors reported" | tee -a $scrubOutputFile
    echo " " >> $scrubOutputFile
    echo "btrfs scrub status for $dest:" >> $scrubOutputFile
    $btrfs scrub status -d $dest >> $scrubOutputFile
    echo " " >> $scrubOutputFile
    echo "btrfs statistics for $dest after scrub attempt:" >> $scrubOutputFile
    $btrfs device stats -z $dest >> $scrubOutputFile
    result="FAILED"
    sendHAWarningNotification
  fi
  subject="btrfs scrub status for $dest at $(hostname): $result"
}

checkDeviceStats() {
  reportTargetToHa ${destHa}_errors_only
  #write test $dest to check if device is stuck
  timeout 10 dd if=/dev/urandom of=$dest/.testtmp bs=10M count=1 status=none
  #sync so the write operations won't be buffered
  sync
  #read test
  timeout 10 dd if=$dest/.testtmp of=/dev/null status=none
  if [[ ! $($btrfs device stats $dest | grep -v " 0$") ]]; then
    throwOk "btrfs device stats check passed. No errors reported" | tee -a $scrubOutputFile
    reportStatusToHa NO_ERR
    sendMailNotification="no"
  else
    throwError "btrfs device stats check failed. Errors detected" | tee -a $scrubOutputFile
    reportStatusToHa ERR_DEV
    echo "Statistics:" >> $scrubOutputFile
    $btrfs device stats $dest >> $scrubOutputFile
    subject="btrfs device statistics check failed for $dest at $(hostname)"
    sendHAWarningNotification
  fi
}

sendMailNotification() {
  if [[ $sendMailNotification == "yes" ]]; then
    sendMail >/dev/null 2>&1
  fi
}

sendMail() {
  v=0
  while [[ $v -le $sendMailNoOfRetries ]]; do
      timeout 2 bash -c 'cat < /dev/null > /dev/tcp/$sendMailServer/25'
      if [[ $? -ne 0 ]]; then
        echo "sendmail(): $sendMailServer is unreachable on port 25. Retrying" 1>&0
        ((v++))
        if [[ $v -eq $sendMailNoOfRetries ]]; then
          echo "sendmail(): Exceeded number of retries. Giving up" 1>&0
          break
        fi
        sleep 5
      else
        exec 5<>/dev/tcp/$sendMailServer/$sendMailPort
        echo -e "HELO" >&5
        echo -e "MAIL FROM: $sendMailSender" >&5
        echo -e "RCPT TO: $sendMailRecipient" >&5
        echo -e "DATA" >&5
        echo -e "SUBJECT: $subject" >&5
        echo -e "$(cat $messageFile)" >&5
        echo -e "." >&5
        timeout 0.5 cat <&5
        exec 5>&-
        echo "sendmail(): Mail notification has been successfully sent to $sendMailRecipient" 1>&0
        break
      fi
  done
}

sendHAWarningNotification() {
  if [[ "$haNotificationEnabled" == "true" && $HA_TOKEN_AVAILABLE == "true" ]]; then
    curl -s -o /dev/null -X POST -H "Authorization: Bearer $haAuthToken" -H "Content-Type: application/json" -d '{"state": '1', "attributes": {"friendly_name": "'"${hostname}'" Btrfs Alert Indication"}}' $HARestApiUrl
  fi
}

cleanup() {
  rm $messageFile >/dev/null 2>&1
  #timeout just in case device was stuck in previous function
  timeout 10 rm $dest/.testtmp >/dev/null 2>&1
}

unlock() {
  rm $lockFile
  if [[ "$result" == "FAILED" ]]; then
    exit 1
  else
    exit 0
  fi
}

if [ $# -lt 1 ]
  then
    throwError "Missing argument. See \"help\" for list of commands"
  else
    argument="$1"
    case $argument in
      start)
        shift
        initialChecks
        checkIfDefaultMountPoint $1
        checkIfMountedAsBtrfs
        checkBtrfsScrubStatus
        startBtrfsScrub
        monitorBtrfsScrubStatus
        sendMailNotification
        cleanup
        unlock
      ;;
      errors-only)
        shift
        initialChecks
        checkIfDefaultMountPoint $1
        checkIfMountedAsBtrfs
        checkDeviceStats
        sendMailNotification
        cleanup
        unlock
      ;;
      -h|--help|help)
        printHelp
      ;;
      *)
        throwError "Unrecognized argument. See \"help\" for list of commands"
      ;;
    esac
fi

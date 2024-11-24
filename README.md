# btrfsCheck.sh
btrfs wrapper for scrubbing and mail/home assistant reporting

Default destination mount point is defined in settings section of this script.

Usage: /usr/sbin/btrfsCheck.sh '<option>'

Options:

  start                  Takes mount point as argument. Checks device stats and scrubs entire medium
  
  errors-only            Takes mount point as argument. Only checks device stats
  
  help                   Prints this help

Depends on btrfs, obviously. Also curl.

Purpose of this script is to automate btrfs scrubs and basic tests (errors-only) and provide results to Home Assistant and local mail server. Personally used for controlling external HDD array cooling fan (start/stop) and dashboard notifications when failure is detected. errors-only flag is useful when HDDs are connected via USB and they disconnect without btrfs noticing - this causes i/o errors.

Works best when scheduled via crontab.

HA receives statuses within two helper text entities. They need to be created before running the script.

input_text.${hostname}_btrfs_scrub_status:

ERR_PERMISSIONS, ERR_BTRFS, ERR_LOCK, ERR_MULTI, FAILED, SCRUB_STARTED, SCRUB_PASSED, SCRUB_FAILED, SCRUB_TIMEOUT, NO_ERR, ERR_DEV

input_text.${hostname}_btrfs_scrub_last_target:

${destHa}_scrub and ${destHa}_errors_only

where $destHa is name of mountpoint

![obraz](https://github.com/user-attachments/assets/0176b3d4-f609-4ac8-a509-b300c7f2c61e)

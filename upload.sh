. /home/osl/.keychain/cixug-opencms-sh

. /home/osl/.passphrase
export PASSPHRASE

duplicity --full-if-older-than 7D --encrypt-key D8BFBB5A /var/lib/backups/ scp://oslbackup@193.144.61.76//var/lib/backups/opencms-9.5/ >> /tmp/duplicity.log
duplicity remove-older-than 15D scp://oslbackup@193.144.61.76//var/lib/backups/opencms-9.5/ >> /tmp/duplicity.log

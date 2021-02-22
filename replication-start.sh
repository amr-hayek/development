DB=$MYSQL_DATABASE
DUMP_FILE="/tmp/$DB-export-$(date +"%Y%m%d%H%M%S").sql"

USER=root
PASS=$MYSQL_ROOT_PASSWORD
REPLICATION_USER=repl
REPLICATION_USER_PASS=repl
#CREDENTIALS="-u$USER -p$USER"
CREDENTIALS="--defaults-extra-file=credentials.cnf"

MASTER_HOST="$1"
shift
SLAVE_HOSTS=("$@")

# Wait for mysql to be running, in case of auto-init during container startup
if [[ $AUTO_INIT_MASTER_IP ]]; then
	sleep 10
	for i in {10..0}; do
		DB_CREATED=$(mysql $CREDENTIALS -h 127.0.0.1 -e "SHOW DATABASES;" | grep $DB)
		if [[ ! -z "$DB_CREATED" ]]; then
			break
		fi
		sleep 5
	done
	if [[ "$i" = 0 ]]; then
		echo >&2 'MySQL not started. Cannot initialize replication.'
		exit 1
	fi
fi

##
# MASTER
# ------
# Export database and read log position from master, while locked
##

echo "MASTER: $MASTER_HOST"

# Run these mysql commands in background
mysql $CREDENTIALS -h $MASTER_HOST $DB <<-EOSQL &
	GRANT REPLICATION SLAVE ON *.* TO '$REPLICATION_USER'@'%' IDENTIFIED BY '$REPLICATION_USER_PASS';
	FLUSH PRIVILEGES;
	FLUSH TABLES WITH READ LOCK;
	DO SLEEP(3600);
EOSQL

echo "  - Waiting for database to be locked"
sleep 3

# Dump the database (to the client executing this script) while it is locked
echo "  - Dumping database to $DUMP_FILE"
mysqldump $CREDENTIALS -h $MASTER_HOST --opt $DB > $DUMP_FILE
echo "  - Dump complete."

# Take note of the master log position at the time of dump
MASTER_STATUS=$(mysql $CREDENTIALS -h $MASTER_HOST -ANe "SHOW MASTER STATUS;" | awk '{print $1 " " $2}')
LOG_FILE=$(echo $MASTER_STATUS | cut -f1 -d ' ')
LOG_POS=$(echo $MASTER_STATUS | cut -f2 -d ' ')
echo "  - Current log file is $LOG_FILE and log position is $LOG_POS"

# When finished, kill the background locking command to unlock
kill $! 2>/dev/null
wait $! 2>/dev/null

echo "  - Master database unlocked"

##
# SLAVES
# ------
# Import the dump into slaves and activate replication with
# binary log file and log position obtained from master.
##

for SLAVE_HOST in "${SLAVE_HOSTS[@]}"
do
	echo "SLAVE: $SLAVE_HOST"
	echo "  - Creating database copy"
	mysql $CREDENTIALS -h $SLAVE_HOST -e "DROP DATABASE IF EXISTS $DB; CREATE DATABASE $DB;"
	if [ ! -z "$AUTO_INIT_MASTER_IP" ]; then
		scp $DUMP_FILE $SLAVE_HOST:$DUMP_FILE >/dev/null
	fi
	mysql $CREDENTIALS -h $SLAVE_HOST $DB < $DUMP_FILE

	echo "  - Setting up slave replication"
	mysql $CREDENTIALS -h $SLAVE_HOST $DB <<-EOSQL
		GRANT REPLICATION SLAVE ON *.* TO '$REPLICATION_USER'@'%' IDENTIFIED BY '$REPLICATION_USER_PASS';
		STOP SLAVE;
		CHANGE MASTER TO MASTER_HOST='$MASTER_HOST',
		MASTER_USER='$REPLICATION_USER',
		MASTER_PASSWORD='$REPLICATION_USER_PASS',
		MASTER_LOG_FILE='$LOG_FILE',
		MASTER_LOG_POS=$LOG_POS;
		START SLAVE;
	EOSQL

	# Wait for slave to get started and have the correct status
	sleep 2

	echo "Capturing slave log positions"
	# Take note of the slave log position
          SLAVE_STATUS=$(mysql $CREDENTIALS -h $SLAVE_HOST -ANe "SHOW MASTER STATUS;" | awk '{print $1 " " $2}')
          LOG_FILE_SLAVE=$(echo $SLAVE_STATUS | cut -f1 -d ' ')
          LOG_POS_SLAVE=$(echo $SLAVE_STATUS | cut -f2 -d ' ')
          echo "  - Current log file is $LOG_FILE_SLAVE and log position is $LOG_POS_SLAVE"


	# Check if replication status is OK
	SLAVE_OK=$(mysql $CREDENTIALS -h $SLAVE_HOST -e "SHOW SLAVE STATUS\G;" | grep 'Waiting for master')
	if [ -z "$SLAVE_OK" ]; then
		echo "  - Error ! Wrong slave IO state."
	else
		echo "  - Slave IO state OK"
	fi

	 echo "  - Setting up master master replication"

mysql $CREDENTIALS -h $MASTER_HOST $DB <<-EOSQL &
STOP SLAVE;
CHANGE MASTER TO MASTER_HOST='$SLAVE_HOST',
MASTER_USER='$REPLICATION_USER', 
MASTER_PASSWORD='$REPLICATION_USER_PASS',
MASTER_LOG_FILE='$LOG_FILE_SLAVE',
MASTER_LOG_POS=$LOG_POS_SLAVE;
START SLAVE;
EOSQL

# Check if replication status is ok from Master1
        MASTER_OK=$(mysql $CREDENTIALS -h $MASTER_HOST -e "SHOW SLAVE STATUS\G;" | grep 'Waiting for master')
        if [ -z "$SLAVE_OK" ]; then
                echo "  - Error ! Wrong slave IO state."
        else
                echo "  - Master IO state OK"
        fi
done

echo "Restarting Master..."
mysql $CREDENTIALS -h $MASTER_HOST -e "STOP SLAVE;"
mysql $CREDENTIALS -h $MASTER_HOST -e "Start SLAVE;"

	if [ $? = 0 ]; then
		echo "MASTER is Online"
	else
		echo "Failed to Restart Master"
	fi

echo "Restarting Slave...."
mysql $CREDENTIALS -h $SLAVE_HOST -e "STOP SLAVE;"
mysql $CREDENTIALS -h $SLAVE_HOST -e "Start SLAVE;"

	if [ $? = 0 ]; then
        	echo "SLAVE is Online"
        else
                echo "Failed to Restart SLAVE"
	fi

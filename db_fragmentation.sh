#!/bin/ksh

DB_UNIQUE_NAME=$1
TIME_PERIOD=$2
SCRIPT_DIR=/oracle/stagenfs/scripts/shell/db_fragmentation_top_block_changes
LOG_DIR=/oracle/stagenfs/scripts/logs/db_fragmentation_top_block_changes
DATETIME=`date +%Y_%m_%d_%H_%M`
DATENOW=`echo $DATETIME`

IS_DB_FRAG_DETECT_SCRIPT_RUNNING=`ps -ef|grep 'db_fragmentation_top_block_changes'|grep "${DB_UNIQUE_NAME}"|grep -v grep|wc -l`

if [[ $IS_DB_FRAG_DETECT_SCRIPT_RUNNING -gt 2 ]]
then
  echo "EXITING AS THE SCRIPT IS ALREADY RUNNING"
  exit 0
fi

. /oracle/stagenfs/scripts/shell/setoraenv.ksh $DB_UNIQUE_NAME > /dev/null


mkdir -p ${LOG_DIR}/${DB_UNIQUE_NAME}
LOG_DIR=${LOG_DIR}/${DB_UNIQUE_NAME}

sqlplus -s / as sysdba <<EOF
set serverout on
set lines 200
define TIME_PERIOD = ${TIME_PERIOD}
spool ${LOG_DIR}/${DB_UNIQUE_NAME}_DB_FRAGMENTATION_BY_TOP_BLOCK_CHANGES_PAST_${TIME_PERIOD}_DAYS_${DATENOW}.log
@@/oracle/stagenfs/scripts/shell/db_fragmentation_top_block_changes/sql/db_fragmentation_top_block_changes.sql
spool off
exit
EOF

mail -s "${DB_UNIQUE_NAME} DB_FRAGMENTATION_DETECTION_BY_TOP_BLOCK_CHANGES FOR PAST ${TIME_PERIOD} DAYS" DBA_ALL@grainger.com,SAP_DBA@grainger.com,badr.laasiri@grainger.com,zainuddin.syed@grainger.com < ${LOG_DIR}/${DB_UNIQUE_NAME}_DB_FRAGMENTATION_BY_TOP_BLOCK_CHANGES_PAST_${TIME_PERIOD}_DAYS_${DATENOW}.log

if [[ $? -ne 0 ]]
then
  mail -s "${DB_UNIQUE_NAME} DB_FRAGMENTATION_DETECTION_BY_TOP_BLOCK_CHANGES FAILED TO EXECUTE " DBA_ALL@grainger.com,SAP_DBA@grainger.com,badr.laasiri@grainger.com,zainuddin.syed@grainger.com
  echo "FAILED"
else
  find ${LOG_DIR}/* -mtime +21 -exec rm {} \;
  exit 0
fi

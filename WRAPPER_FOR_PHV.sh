#!/bin/ksh

DB_UNIQUE_NAME=$1
SCRIPT_DIR=/oracle/stagenfs/scripts/shell/phv_change
LOG_DIR=/oracle/stagenfs/scripts/logs/phv_change
DATETIME=`date +%Y_%m_%d_%H_%M`
DATENOW=`echo $DATETIME`

IS_PHV_SCRIPT_RUNNING=`ps -ef|grep 'phv'|grep "${DB_UNIQUE_NAME}"|grep -v grep|wc -l`

if [[ $IS_PHV_SCRIPT_RUNNING -gt 2 ]]
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
spool ${LOG_DIR}/${DB_UNIQUE_NAME}_PLAN_CHANGES_${DATENOW}.log
@@/oracle/stagenfs/scripts/shell/phv_change/sql/phv_change.sql
spool off
exit
EOF

if grep -q 'POTENTIALLY' ${LOG_DIR}/${DB_UNIQUE_NAME}_PLAN_CHANGES_${DATENOW}.log
then
#  mail -s "POTENTIAL PHV CHANGES" -a ${LOG_DIR}/${DB_UNIQUE_NAME}_PLAN_CHANGES_${DATENOW}.log zainuddin.syed@grainger.com
  echo "NOTHING"
  find ${LOG_DIR}/* -mtime +14 -exec rm {} \;
else
  find ${LOG_DIR}/* -mtime +14 -exec rm {} \;
  exit 0
fi

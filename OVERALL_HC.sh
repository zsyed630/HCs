GREEN="\033[1;32;40m"
RED="\033[1;31;40m"
NORM="\033[0m"
ENDCOLOR="\e[0m"
HOST_NAME=`hostname`
GRID_HOME=`cat /etc/oratab|grep '+ASM'|awk -F ':' '{print $2}'`
SYS_PWD=`cat /oracle/stagenfs/scripts/shell/.key_dbe_mon`
DB=$1



ASM_IS_RUNNING=`${GRID_HOME}/bin/srvctl status asm`

if grep -q "ASM is not running" <<< "${ASM_IS_RUNNING}"
then
    echo -e "${RED}ASM : ASM IS NOT RUNNING${ENDCOLOR}"
else
    echo -e "${GREEN}ASM : ASM IS UP AND RUNNING${ENDCOLOR}"
fi


LISTENER_IS_RUNNING=`${GRID_HOME}/bin/srvctl status listener -v|awk 'NR==2'`

if grep -q "Listener LISTENER is not running" <<< "${LISTENER_IS_RUNNING}"
then
    echo -e "${RED}LISTENER : LISTENER IS NOT RUNNING${ENDCOLOR}"
else
    echo -e "${GREEN}LISTENER : LISTENER IS UP AND RUNNING${ENDCOLOR}"
fi

if [[ -n $DB ]]
then
    CHECK_SPECIFIC=`${GRID_HOME}/bin/srvctl config database -d $DB|grep 'Database unique name'|awk '{print $4}'`
else
    CHECK_SPECIFIC=`${GRID_HOME}/bin/srvctl config database |grep -v 'AAA_LF\|ARA_LF\|ARF_LF'`
fi

for db in `echo $CHECK_SPECIFIC`
do
    echo ""
#    echo "======================================================================================"
    ORACLE_HOME=`${GRID_HOME}/bin/srvctl config database -d ${db} |grep 'home'|awk '{print $3}'`
    export ORACLE_HOME=$ORACLE_HOME
    INSTANCES=`${ORACLE_HOME}/bin/srvctl config database -d ${db} |grep 'instances'|awk '{print $3}'`
    SERVICES=`${ORACLE_HOME}/bin/srvctl config database -d ${db} |grep 'Service'|awk '{print $2}'`
    DBTYPE=`${ORACLE_HOME}/bin/srvctl config database -d ${db} -v|grep 'Type'|awk '{print $2}'`
    DBROLE=`${ORACLE_HOME}/bin/srvctl config database -d ${db} |grep 'Database role'|awk '{print $3}'`
    echo -e "${GREEN}DB : ${db} STATUS ${ENDCOLOR}"
    echo -e "===>${GREEN} ${db} ROLE : ${DBROLE} DATABASE ${ENDCOLOR}"

    if [[ -z $DBTYPE ]]
    then
        DB_IS_RUNNING=`${ORACLE_HOME}/bin/srvctl status database -d ${db} -v`
        if grep -q "Instance status: Open" <<< "${DB_IS_RUNNING}"
        then
            echo -e "${GREEN}DB : ${db} IS UP AND RUNNING WITH INSTANCE ${ORACLE_SID} ${ENDCOLOR}"
            for SERVICE in $(echo $SERVICES | sed "s/,/ /g")
            do
                IS_SERVICE_RUNNING=`${ORACLE_HOME}/bin/srvctl status service -d ${db} -s ${SERVICE} -v`
                if grep -q "is not running" <<< "${IS_SERVICE_RUNNING}"
                then
                    echo -e "===>${RED} DB_SERVICE : ${SERVICE} IS NOT RUNNING${ENDCOLOR}"
                else
                    echo -e "===>${GREEN} DB_SERVICE : ${SERVICE} IS UP AND RUNNING${ENDCOLOR}"
                fi
            done
        else
            echo -e "${RED}DB : ${db} IS DOWN ${ENDCOLOR}"
            continue
        fi
    else
        DB_IS_RUNNING=`${ORACLE_HOME}/bin/srvctl status database -d ${db} -v`
        
        if grep -q "is running" <<< "${DB_IS_RUNNING}"
        then
            for INSTANCE in $(echo $INSTANCES | sed "s/,/ /g")
            do
                if [[ ${DBROLE} == "PRIMARY" ]] || [[ ${DBROLE} == "SNAPSHOT_STANDBY" ]]
                then
                    INSTANCE_STATUS=`${ORACLE_HOME}/bin/srvctl status instance -d ${db} -i $INSTANCE -v|grep 'Open'|wc -l`
                    if [[ ${INSTANCE_STATUS} -eq 1 ]]
                    then
                        echo -e "===>${GREEN} ${db} INSTANCE : $INSTANCE IS UP AND RUNNING${ENDCOLOR}"
                    else
                        echo -e "===>${RED} ${db} INSTANCE : $INSTANCE IS NOT RUNNING${ENDCOLOR}"
                    fi
                elif [[ ${DBROLE} == "PHYSICAL_STANDBY" ]]
                then
                    INSTANCE_STATUS=`${ORACLE_HOME}/bin/srvctl status instance -d ${db} -i $INSTANCE -v|grep 'Mounted'|wc -l`
                    if [[ ${INSTANCE_STATUS} -eq 1 ]]
                    then
                        echo -e "===>${GREEN} ${db} INSTANCE : $INSTANCE IS UP AND RUNNING IN MOUNT AS PHYSICAL_STANDBY${ENDCOLOR}"
                    else
                        echo -e "===>${RED} ${db} INSTANCE : $INSTANCE IS NOT RUNNING${ENDCOLOR}"
                    fi
                fi
            done

            for SERVICE in $(echo $SERVICES | sed "s/,/ /g")
            do
                if [[ ${DBROLE} == "PRIMARY" ]] || [[ ${DBROLE} == "SNAPSHOT_STANDBY" ]]
                then
                    SERVICE_NOT_RUNNING=`${ORACLE_HOME}/bin/srvctl status service -d ${db} -s $SERVICE -v|grep 'is not running'|wc -l`
                    if [[ ${SERVICE_NOT_RUNNING} -eq 1 ]]
                    then
                        echo -e "===>${RED} ${db} SERVICE : $SERVICE IS NOT RUNNING ON ANY INSTANCES${ENDCOLOR}"
                    else
                        SERVICE_RUNNING_ON_INSTANCES=`${ORACLE_HOME}/bin/srvctl status service -d ${db} -s $SERVICE -v|grep 'is running'|awk '{print $7}'`
                        echo -e "===>${GREEN} ${db} SERVICE : $SERVICE IS RUNNING ON INSTANCES ${SERVICE_RUNNING_ON_INSTANCES}${ENDCOLOR}"
                        SERVICE_PREF_INSTANCES=`${ORACLE_HOME}/bin/srvctl config service -d ${db} -s $SERVICE -v|grep 'Preferred instances'|awk '{print $3}'`
                        for SERVICE_PREF_INSTANCE in $(echo $SERVICE_PREF_INSTANCES | sed "s/,/ /g")
                        do
                            if grep -q "${SERVICE_PREF_INSTANCE}" <<< "${SERVICE_RUNNING_ON_INSTANCES}"
                            then
                                continue
                            else
                                echo -e "   ===>${RED} ${db} SERVICE : $SERVICE IS RUNNING BUT PREFERRED INSTANCE ${SERVICE_PREF_INSTANCE} DOESNT HAVE ${SERVICE} RUNNING ${ENDCOLOR}"
                            fi
                        done
                    fi
                else [[ ${DBROLE} == "PHYSICAL_STANDBY" ]]
                    echo -e "===>${GREEN} ${db} SERVICES : ${db} IS A PHYSICAL_STANDBY${ENDCOLOR}"
                fi
            done
        else
            echo -e "${RED}DB : ${db} IS DOWN ${ENDCOLOR}"
            continue
        fi
    fi

    SCAN_NAME=`${GRID_HOME}/bin/srvctl config scan |grep 'SCAN name:'|awk '{print $3}'|sed "s/,/ /g"|xargs`
    SCAN_PORT=`${GRID_HOME}/bin/srvctl config scan_listener|grep 'Endpoints: TCP'|awk '{print $2}'|awk -F ":" '{print $2}'`
    DB_UNIQ_SERVICE=`${ORACLE_HOME}/bin/srvctl config database -d ${db} -v|grep 'Database unique name'|awk '{print $4}'`

    if [[ -z $DBTYPE ]] 
    then
        SQLPLUS_STRING=`echo "sqlplus -s / as sysdba"`
    else
        SQLPLUS_STRING=`echo "sqlplus -s DBE_MON/${SYS_PWD}@${SCAN_NAME}:${SCAN_PORT}/${DB_UNIQ_SERVICE} as sysdg"`
    fi








    ANY_ORA_ERRORS=$($ORACLE_HOME/bin/${SQLPLUS_STRING} <<EOF
    set heading off feedback off pagesize 0 trimspool on
    select count(*) from v\$diag_alert_ext where originating_timestamp > systimestamp-1/24 and message_text not like 'Result = ORA-0' and message_text like 'ORA-%' order by ORIGINATING_TIMESTAMP desc;
    exit
EOF
)
    if [[ ${ANY_ORA_ERRORS} -ne 0 ]]
    then
        echo -e "===>${RED} ORA_ERRORS_PAST_HOUR : ${ANY_ORA_ERRORS} ERRORS${ENDCOLOR}"
    else
        echo -e "===>${GREEN} ORA_ERRORS_PAST_HOUR : ${ANY_ORA_ERRORS} ERRORS${ENDCOLOR}"
    fi


    if [[ ${DBROLE} == "PHYSICAL_STANDBY" ]]
    then
        continue
    else  
        AAS_PAST_FIFTEEN_MINS=$($ORACLE_HOME/bin/${SQLPLUS_STRING} <<EOF
        set heading off feedback off pagesize 0 trimspool on
        select round(AAS) from ( select ( select count(*) from gv\$active_session_history where sample_time > sysdate - interval '15' minute AND user_id <> 0 and session_type = 'FOREGROUND' and session_state in ('WAITING','CPU'))/(2*60) as AAS from dual);
        exit
EOF
)

        CPU_COUNT=$($ORACLE_HOME/bin/${SQLPLUS_STRING} <<EOF
        set heading off feedback off pagesize 0 trimspool on
        select value from v\$parameter where name = 'cpu_count';
        exit
EOF
)


        INSTANCE_COUNT=$($ORACLE_HOME/bin/${SQLPLUS_STRING} <<EOF
        set heading off feedback off pagesize 0 trimspool on
        select count(*) from gv\$instance;
        exit
EOF
)
        ALL_DB_CPU_COUNT=$((INSTANCE_COUNT * CPU_COUNT))

        echo -e "===>${GREEN} ALL_DB_CPU_COUNT : $ALL_DB_CPU_COUNT ${ENDCOLOR}"
        if [[ $AAS_PAST_FIFTEEN_MINS -gt $ALL_DB_CPU_COUNT ]]
        then
            echo -e "===>${RED} DB_PERFORMANCE_WAIT_PAST_15_MINS : YES, METRIC_AVG_ACTIVE_SESSIONS AT ${AAS_PAST_FIFTEEN_MINS} ${ENDCOLOR}"
        else
            echo -e "===>${GREEN} DB_PERFORMANCE_WAIT_PAST_15_MINS : NO ${ENDCOLOR}"
        fi

        FIFTEEN_MINS_AGO_LINUX_FORMAT=`date -d "15 minutes ago" +"%F %T"`
        CURRENT_MIN_LINUX_FORMAT=`date +"%F %T"`

        TOP_WAIT_EVENTS=$($ORACLE_HOME/bin/${SQLPLUS_STRING} <<EOF
        set lines 100 heading off feedback off pagesize 0 trimspool off
        select 'TOP_WAIT_EVENT_PAST_15_MINS : '||event||' WAIT_COUNT : '||cnt||',' from (select event_id, event, count(*) cnt from gv\$active_session_history where sample_time BETWEEN TIMESTAMP '${FIFTEEN_MINS_AGO_LINUX_FORMAT}' AND TIMESTAMP '${CURRENT_MIN_LINUX_FORMAT}' and wait_class_id in (select wait_class_id from (select wait_class_id, wait_class, count(*) cnt from gv\$active_session_history where sample_time BETWEEN TIMESTAMP '${FIFTEEN_MINS_AGO_LINUX_FORMAT}' AND TIMESTAMP '${CURRENT_MIN_LINUX_FORMAT}' and wait_class_id is not null group by wait_class_id, wait_class order by 3 desc) where rownum <=3 ) group by event_id, event order by 3 desc) where rownum <=3;
        exit
EOF
)
        FIRST_EVENT=`echo $TOP_WAIT_EVENTS |awk -F',' '{print $1}'`
        SECOND_EVENT=`echo $TOP_WAIT_EVENTS |awk -F',' '{print $2}'`
        THIRD_EVENT=`echo $TOP_WAIT_EVENTS |awk -F',' '{print $3}'`

        if [[ -n "${FIRST_EVENT}" ]]
        then
            echo -e "===> ${GREEN}${FIRST_EVENT}${ENDCOLOR}"
        fi

        if [[ -n "${SECOND_EVENT}" ]]
        then
            echo -e "===>${GREEN}${SECOND_EVENT}${ENDCOLOR}"
        fi

        if [[ -n "${THIRD_EVENT}" ]]
        then
            echo -e "===>${GREEN}${THIRD_EVENT}${ENDCOLOR}"
        fi


        TOP_SQL_IDS_BY_WAIT_EVENTS=$($ORACLE_HOME/bin/${SQLPLUS_STRING} <<EOF
        set lines 200 heading off feedback off pagesize 0 trimspool off
        select 'TOP_SQL_ID_BY_WAIT : '||SQL_ID||' WITH WAIT_EVENT : '||EVENT||' AND WAIT_COUNT : '||cnt||',' from (select sql_id,event,count(*) cnt from gv\$active_session_history where sample_time BETWEEN TIMESTAMP '${FIFTEEN_MINS_AGO_LINUX_FORMAT}' AND TIMESTAMP '${CURRENT_MIN_LINUX_FORMAT}' and  event_id in (select event_id from (select event_id, event, count(*) cnt from gv\$active_session_history where sample_time BETWEEN TIMESTAMP '${FIFTEEN_MINS_AGO_LINUX_FORMAT}' AND TIMESTAMP '${CURRENT_MIN_LINUX_FORMAT}' and wait_class_id in (select wait_class_id from (select wait_class_id, wait_class, count(*) cnt from gv\$active_session_history where sample_time BETWEEN TIMESTAMP '${FIFTEEN_MINS_AGO_LINUX_FORMAT}' AND TIMESTAMP '${CURRENT_MIN_LINUX_FORMAT}' and wait_class_id is not null group by wait_class_id, wait_class order by 3 desc) where rownum <=5 ) group by event_id, event order by 3 desc) where rownum <=5) and sql_id is not null group by sql_id,event  order by 3 desc) where rownum <=3;
        exit
EOF
)

        FIRST_SQL_ID=`echo $TOP_SQL_IDS_BY_WAIT_EVENTS |awk -F',' '{print $1}'`
        SECOND_SQL_ID=`echo $TOP_SQL_IDS_BY_WAIT_EVENTS |awk -F',' '{print $2}'`
        THIRD_SQL_ID=`echo $TOP_SQL_IDS_BY_WAIT_EVENTS |awk -F',' '{print $3}'`

        if [[ -n "${FIRST_SQL_ID}" ]]
        then
            echo -e "===> ${GREEN}${FIRST_SQL_ID}${ENDCOLOR}"
        fi

        if [[ -n "${SECOND_SQL_ID}" ]]
        then
            echo -e "===>${GREEN}${SECOND_SQL_ID}${ENDCOLOR}"
        fi

        if [[ -n "${THIRD_SQL_ID}" ]]
        then
            echo -e "===>${GREEN}${THIRD_SQL_ID}${ENDCOLOR}"
        fi

        PRIMARY_DB_UNIQUE_NAME=$($ORACLE_HOME/bin/${SQLPLUS_STRING} <<EOF
        set lines 100 heading off feedback off pagesize 0 trimspool off
        select value from v\$parameter where name = 'db_unique_name';
        exit
EOF
)

        LOG_ARCHIVE_CONF_NAMES=$($ORACLE_HOME/bin/${SQLPLUS_STRING} <<EOF
        set lines 100 heading off feedback off pagesize 0 trimspool off
        select value from v\$parameter where name = 'log_archive_config';
        exit
EOF
)

        if grep -q "DG_CONFIG=" <<< "${LOG_ARCHIVE_CONF_NAMES}"
        then
            EDITED_DG_CONFIG=`echo "${LOG_ARCHIVE_CONF_NAMES//DG_CONFIG=(}"`
            NEWLY_EDITED_DG_CONFIG=`echo "${EDITED_DG_CONFIG//)}"`
        else
            EDITED_DG_CONFIG=`echo "${LOG_ARCHIVE_CONF_NAMES//dg_config=(}"`
            NEWLY_EDITED_DG_CONFIG=`echo "${EDITED_DG_CONFIG//)}"`
        fi

        PRIMARY_DB_CURRENT_TIME=`date +"%m/%d/%Y %T" -d "30 seconds ago"`

        IFS=","
        for STANDBY_DB_UNIQUE_NAME in $NEWLY_EDITED_DG_CONFIG
        do
            if [[ "${STANDBY_DB_UNIQUE_NAME}" == "${PRIMARY_DB_UNIQUE_NAME}" ]]
            then
                continue
                echo "SAME"
            else
                echo "exit" | sqlplus -s sys/${SYS_PWD}@${STANDBY_DB_UNIQUE_NAME} as sysdba
                if [[ $? -ne 0 ]]
                then
                    echo -e "===>${RED} STANDBY_DB : ${STANDBY_DB_UNIQUE_NAME} CANT CONNECT ${ENDCOLOR}"
                    continue
                else

                    IS_APPLYING_LOG=$($ORACLE_HOME/bin/sqlplus -s sys/${SYS_PWD}@${STANDBY_DB_UNIQUE_NAME} as sysdba <<EOF
                    set lines 100 heading off feedback off pagesize 0 trimspool off
                    select status from v\$managed_standby where process like 'MRP%';
                    exit
EOF
)

                    if [[ "${IS_APPLYING_LOG}" != "APPLYING_LOG" ]]
                    then
                        echo -e "===>${RED} STANDBY_DB : ${STANDBY_DB_UNIQUE_NAME} MRP IS NOT RUNNING ${ENDCOLOR}"
                        continue
                    fi

                    STANDBY_DATUM_TIME=$($ORACLE_HOME/bin/sqlplus -s sys/${SYS_PWD}@${STANDBY_DB_UNIQUE_NAME} as sysdba <<EOF
                    set lines 100 heading off feedback off pagesize 0 trimspool off
                    select datum_time from v\$dataguard_stats where name = 'apply lag';
                    exit
EOF
)
                    if grep -q "ORA-" <<< "${STANDBY_DATUM_TIME}"
                    then
                        echo -e "===>${RED} STANDBY_DB : ${STANDBY_DB_UNIQUE_NAME} CANT CONNECT ${ENDCOLOR}"
                        continue
                    fi

                    if [[ $STANDBY_DATUM_TIME > $PRIMARY_DB_CURRENT_TIME ]] && [[ "${IS_APPLYING_LOG}" == "APPLYING_LOG" ]]
                    then
                        echo -e "===>${GREEN} STANDBY_DB : ${STANDBY_DB_UNIQUE_NAME} IS IN SYNC WITH PRIMARY ${STANDBY_DATUM_TIME} ${ENDCOLOR}"
                    else
                        echo -e "===>${RED} STANDBY_DB : ${STANDBY_DB_UNIQUE_NAME} IS BEHIND PRIMARY ${STANDBY_DATUM_TIME} ${ENDCOLOR}"
                    fi
                fi
            fi
        done
    fi
        unset IFS    
done



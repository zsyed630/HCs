#!/bin/bash
GREEN="\033[1;32;40m"
RED="\033[1;31;40m"
NORM="\033[0m"
ENDCOLOR="\e[0m"
HOST_NAME=`hostname`
GRID_HOME=`cat /etc/oratab|grep '+ASM'|awk -F ':' '{print $2}'`
SYS_PWD=`cat /home/oracle/dba/scripts/.key_sys`
TBSP_PERCENT_USED=1
ASM_PERCENT_USED=95
FRA_PERCENT_USED=90
MAILLIST=
DB=$1

echo "################################################################################################################################################################################################################"
export ORACLE_HOME=$GRID_HOME
ASM_IS_RUNNING=`${GRID_HOME}/bin/srvctl status asm`

if grep -q "ASM is not running" <<< "${ASM_IS_RUNNING}"
then
    echo -e "${RED}ASM : ASM IS NOT RUNNING${ENDCOLOR}"
else
    echo -e "${GREEN}ASM : ASM IS UP AND RUNNING${ENDCOLOR}"
    ORACLE_SID=`ps -ef|grep pmon|grep '+ASM'|awk '{print $8}'|awk -F "_" '{print $3}'`
    export ORACLE_SID=$ORACLE_SID
    ORACLE_HOME=$GRID_HOME
    ASM_DSKGRP_USAGE=$($ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF
    set lines 200 heading off feedback off pagesize 0 trimspool off
    select '===> ASM_DISKGROUP : '||DGNAME||' PERCENT USED IS GREATER THAN ${ASM_PERCENT_USED}' from (select dg.name "DGNAME", to_char(NVL(dg.total_mb,0)) "Total MB", to_char(NVL(dg.free_mb, 0)) "Free MB", type "Type", to_char(NVL(dg.usable_file_mb, 0)) "Usable Free MB", to_char(NVL(dg.required_mirror_free_mb, 0)) "ReqMirrorFree", decode(type, 'EXTERN', 1, 'NORMAL', 2, 'HIGH', 3, 1) redundancy_factor, (100 - (dg.usable_file_mb/((dg.total_mb - dg.required_mirror_free_mb)/ decode(type, 'EXTERN', 1, 'NORMAL', 2, 'HIGH', 3, 1)))*100) "PERCENT_USED" from V\$ASM_DISKGROUP_STAT dg where state = 'MOUNTED') where PERCENT_USED > ${ASM_PERCENT_USED};
EOF
)
    if [[ -z $ASM_DSKGRP_USAGE ]]
    then
        echo -e "===>${GREEN} ASM_DISKGROUP : PASS, NO ASM_DISKGROUPS OVER ${ASM_PERCENT_USED}% ${ENDCOLOR}"
    else
        echo -e "${RED}$ASM_DSKGRP_USAGE${ENDCOLOR}"|sed 's/ //'
        ASM_ECHOED_MESSAGE=`echo ${RED}$ASM_DSKGRP_USAGE${ENDCOLOR}|sed 's/ //'`
        echo -e "$ASM_ECHOED_MESSAGE" | mail -s "ASM ON ${HOST_NAME} ASM_DISKGROUP : DANGER, OVER ${ASM_PERCENT_USED}% USED" zsyed@deltadentalmi.com
    fi

fi
echo ""

unset ORACLE_HOME
unset ORACLE_SID
echo "################################################################################################################################################################################################################"
LISTENER_IS_RUNNING=`${GRID_HOME}/bin/srvctl status listener -v|awk 'NR==2'`

if grep -q "Listener LISTENER is not running" <<< "${LISTENER_IS_RUNNING}"
then
    echo -e "${RED}LISTENER : LISTENER IS NOT RUNNING${ENDCOLOR}"
else
    echo -e "${GREEN}LISTENER : LISTENER IS UP AND RUNNING${ENDCOLOR}"
fi

echo ""

if [[ -n $DB ]]
then
    CHECK_SPECIFIC=`${GRID_HOME}/bin/srvctl config database -d $DB|grep 'Database unique name'|awk '{print $4}'`
else
    CHECK_SPECIFIC=`${GRID_HOME}/bin/srvctl config database |grep -v 'AAA_LF\|ARA_LF\|ARF_LF'`
fi

for db in `echo $CHECK_SPECIFIC`
do
    echo "################################################################################################################################################################################################################"
    ORACLE_HOME=`${GRID_HOME}/bin/srvctl config database -d ${db} |grep 'Oracle home'|awk '{print $3}'`
    export ORACLE_HOME=$ORACLE_HOME
    INSTANCES=`${ORACLE_HOME}/bin/srvctl config database -d ${db} |grep 'instances'|awk '{print $3}'`
    SERVICES=`${ORACLE_HOME}/bin/srvctl config database -d ${db} |grep 'Service'|awk '{print $2}'`
    DBTYPE=`${ORACLE_HOME}/bin/srvctl config database -d ${db} -v|grep 'Type'|awk '{print $2}'`
    DBROLE=`${ORACLE_HOME}/bin/srvctl config database -d ${db} |grep 'Database role'|awk '{print $3}'`
    echo -e "${GREEN}DB : ${db} STATUS ${ENDCOLOR}"
    echo -e "===>${GREEN} ${db} ROLE : ${DBROLE} DATABASE ${ENDCOLOR}"

    if [[ -z $DBTYPE ]]
    then
        ORACLE_SID=`${ORACLE_HOME}/bin/srvctl config database -d ${db} |grep 'instance'|awk '{print $3}'`
        export ORACLE_SID=$ORACLE_SID
        DB_IS_RUNNING=`${ORACLE_HOME}/bin/srvctl status database -d ${db} -v`
        if grep -q "Instance status: Open" <<< "${DB_IS_RUNNING}"
        then
            echo -e "===>${GREEN} DB : ${db} IS UP AND RUNNING WITH INSTANCE ${ORACLE_SID} ${ENDCOLOR}"
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
                                echo -e "===>${RED} ${db} SERVICE : $SERVICE IS RUNNING BUT PREFERRED INSTANCE ${SERVICE_PREF_INSTANCE} DOESNT HAVE ${SERVICE} RUNNING ${ENDCOLOR}"
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
    if [[ -z $SCAN_NAME ]]
    then
        HOST_NAME=`hostname -s`
        SCAN_NAME=$HOST_NAME
    fi

    SCAN_PORT=`${GRID_HOME}/bin/srvctl config scan_listener|grep 'Endpoints: TCP'|awk '{print $2}'|awk -F ":" '{print $2}'`
    if [[ -z $SCAN_PORT ]]
    then
        LSNR_NAME=`ps -ef|grep lsnr|grep -v grep|awk '{print $9}'|awk 'NR == 1' `
        ADDRESS=`$ORACLE_HOME/bin/lsnrctl status $LSNR_NAME|grep PORT|awk '{print $3}'`
        SCAN_PORT=`echo "${ADDRESS#*PORT=}"|sed 's/)//g'`
    fi
    DB_UNIQ_SERVICE=`${ORACLE_HOME}/bin/srvctl config database -d ${db} -v|grep 'Database unique name'|awk '{print $4}'`

    if [[ -z $DBTYPE ]]
    then
        SQLPLUS_STRING=`echo "sqlplus -s / as sysdba"`
    else
        SQLPLUS_STRING=`echo "sqlplus -s SYS/${SYS_PWD}@${SCAN_NAME}:${SCAN_PORT}/${DB_UNIQ_SERVICE} as sysdba"`
    fi

    IS_PDB=$($ORACLE_HOME/bin/${SQLPLUS_STRING} <<EOF
    set heading off feedback off pagesize 0 trimspool on lines 200
    select cdb from v\$database;
EOF
)

    if [[ ${IS_PDB} == "YES" ]]
    then
        PDB_NAMES=$($ORACLE_HOME/bin/${SQLPLUS_STRING} <<EOF
        set heading off feedback off pagesize 0 trimspool on lines 200
        select name from v\$pdbs where name <> 'PDB\$SEED';
EOF
)
        NEW_PDB_NAMES=`echo ${PDB_NAMES}|tr ' ' '\n'`
        echo -e ""
        for PDB in `echo ${PDB_NAMES}|tr ' ' '\n'`
        do
            export ORACLE_PDB_SID=$PDB
            echo -e "===>${GREEN} DB CHECKS FOR PDB $PDB IN ${db}${ENDCOLOR}"
            TABLESPACE_OUTPUT=$($ORACLE_HOME/bin/${SQLPLUS_STRING} <<EOF
            set heading off feedback off pagesize 0 trimspool on lines 200
            set serverout on
            DECLARE
            NUM_OF_DATAFILES number;
            NUM_OF_NON_AUTOEXTEND_DF number;
            CURRENT_TBSP_SIZE number;
            MAX_EXTENSION_SIZE_GB number;
            temp_tbsp_count number;
            BEGIN
                for v_uniq_tablespace_sizes in (select tablespace_name,"UPERCENT" from (select a.tablespace_name,SUM(a.bytes)/1024/1024 "CurMb",SUM(decode(b.maxextend, null, A.BYTES/1024/1024, b.maxextend*8192/1024/1024)) "MaxMb",(SUM(a.bytes)/1024/1024 - round(c."Free"/1024/1024)) "TotalUsed",(SUM(decode(b.maxextend, null, A.BYTES/1024/1024, b.maxextend*8192/1024/1024)) - (SUM(a.bytes)/1024/1024 - round(c."Free"/1024/1024))) "TotalFree",round(100*(SUM(a.bytes)/1024/1024 - round(c."Free"/1024/1024))/(SUM(decode(b.maxextend, null, A.BYTES/1024/1024, b.maxextend*8192/1024/1024)))) "UPERCENT" from dba_data_files a,sys.filext$ b,(SELECT d.tablespace_name , sum(nvl(c.bytes,0)) "Free" FROM dba_tablespaces d,DBA_FREE_SPACE c where d.tablespace_name = c.tablespace_name(+) group by d.tablespace_name) c where a.file_id = b.file#(+) and a.tablespace_name = c.tablespace_name GROUP by a.tablespace_name, c."Free"/1024 order by round(100*(SUM(a.bytes)/1024/1024 - round(c."Free"/1024/1024))/(SUM(decode(b.maxextend, null, A.BYTES/1024/1024, b.maxextend*8192/1024/1024)))) desc))
                LOOP
                    select count(*) into temp_tbsp_count from dba_temp_files where tablespace_name = v_uniq_tablespace_sizes.tablespace_name;
                    IF temp_tbsp_count > 0 THEN
                        continue;
                    END IF;
                    IF v_uniq_tablespace_sizes.UPERCENT > ${TBSP_PERCENT_USED} THEN
                        dbms_output.put_line('===> TABLESPACE : '||v_uniq_tablespace_sizes.tablespace_name||' NEEDS DATAFILE ADDED AS ${TBSP_PERCENT_USED}% USED WITH NO MORE EXTENSION LEFT');
                    END IF;
                END LOOP;
            END;
            /
EOF
)



            if [[ -z $TABLESPACE_OUTPUT ]]
            then
                echo -e "===>${GREEN} TABLESPACE_SIZE_CHECKS FOR PDB $PDB IN ${db} : PASS, NO TBSPs OVER ${TBSP_PERCENT_USED}% ${ENDCOLOR}"
            else
                echo -e "===>${RED} TABLESPACE_SIZE_CHECKS FOR PDB $PDB IN ${db} : FAILED, TBSPs OVER ${TBSP_PERCENT_USED}% ${ENDCOLOR}"
                echo -e "${RED}$TABLESPACE_OUTPUT${ENDCOLOR}"|sed 's/ //'
                TBSP_ECHOED_MESSAGE=`echo ${RED}$TABLESPACE_OUTPUT${ENDCOLOR}|sed 's/ //'`
                echo -e "$TBSP_ECHOED_MESSAGE FOR PDB $PDB" | mail -s "PDB $PDB IN ${db} TABLESPACE_SIZE_CHECKS : DANGER, OVER ${TBSP_PERCENT_USED}% USED" zsyed@deltadentalmi.com
            fi


            FRA_SPACE_USAGE_PERCENT=$($ORACLE_HOME/bin/${SQLPLUS_STRING} <<EOF
            set heading off feedback off pagesize 0 trimspool on lines 200
            select round((space_used/space_limit)*100) from v\$recovery_file_dest;
EOF
)



            if [[ $FRA_SPACE_USAGE_PERCENT -ge $FRA_PERCENT_USED ]]
            then
                echo -e "===>${RED} FRA_SPACE_CHECK FOR PDB $PDB IN ${db} : DANGER, OVER ${FRA_PERCENT_USED}% USED ${ENDCOLOR}"
                echo "===>${RED} FRA_SPACE_CHECK FOR PDB $PDB IN ${db} : DANGER, OVER ${FRA_PERCENT_USED}% USED ${ENDCOLOR}" | mail -s "${db} FRA_SPACE_CHECK : DANGER, OVER ${FRA_PERCENT_USED}% USED" zsyed@deltadentalmi.com
            else
                echo -e "===>${GREEN} FRA_SPACE_CHECK FOR PDB $PDB IN ${db} : PASS, FRA IS ${FRA_PERCENT_USED}% ${ENDCOLOR}"
            fi




            ANY_ORA_ERRORS=$($ORACLE_HOME/bin/${SQLPLUS_STRING} <<EOF
            set heading off feedback off pagesize 0 trimspool on
            select count(*) from v\$diag_alert_ext where originating_timestamp > systimestamp-1/24 and message_text not like 'Result = ORA-0' and message_text like 'ORA-%' order by ORIGINATING_TIMESTAMP desc;
            exit
EOF
)
            if [[ ${ANY_ORA_ERRORS} -ne 0 ]]
            then
                echo -e "===>${RED} ORA_ERRORS_PAST_HOUR FOR PDB $PDB IN ${db} : ${ANY_ORA_ERRORS} ERRORS${ENDCOLOR}"
            else
                echo -e "===>${GREEN} ORA_ERRORS_PAST_HOUR FOR PDB $PDB IN ${db} : ${ANY_ORA_ERRORS} ERRORS${ENDCOLOR}"
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

                echo -e "===>${GREEN} ALL_DB_CPU_COUNT FOR PDB $PDB IN ${db} : $ALL_DB_CPU_COUNT ${ENDCOLOR}"
                if [[ $AAS_PAST_FIFTEEN_MINS -gt $ALL_DB_CPU_COUNT ]]
                then
                    echo -e "===>${RED} DB_PERFORMANCE_WAIT_PAST_15_MINS FOR PDB $PDB IN ${db} : YES, METRIC_AVG_ACTIVE_SESSIONS AT ${AAS_PAST_FIFTEEN_MINS} ${ENDCOLOR}"
                else
                    echo -e "===>${GREEN} DB_PERFORMANCE_WAIT_PAST_15_MINS FOR PDB $PDB IN ${db} : NO ${ENDCOLOR}"
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
                    echo -e "===> ${GREEN}FIRST_WAIT_EVENT FOR PDB $PDB IN ${db}${ENDCOLOR}"
                    echo -e "===> ${GREEN}${FIRST_EVENT}${ENDCOLOR}"
                fi

                if [[ -n "${SECOND_EVENT}" ]]
                then
                    echo -e "===>${GREEN} SECOND_WAIT_EVENT FOR PDB $PDB IN ${db}${ENDCOLOR}"
                    echo -e "===>${GREEN}${SECOND_EVENT}${ENDCOLOR}"
                fi

                if [[ -n "${THIRD_EVENT}" ]]
                then
                    echo -e "===>${GREEN} THIRD_WAIT_EVENT FOR PDB $PDB IN ${db}${ENDCOLOR}"
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
                    echo -e "===> ${GREEN}FIRST_SQL_ID FOR PDB $PDB IN ${db}${ENDCOLOR}"
                    echo -e "===> ${GREEN}${FIRST_SQL_ID}${ENDCOLOR}"
                fi

                if [[ -n "${SECOND_SQL_ID}" ]]
                then
                    echo -e "===>${GREEN} SECOND_SQL_ID FOR PDB $PDB IN ${db}${ENDCOLOR}"
                    echo -e "===>${GREEN}${SECOND_SQL_ID}${ENDCOLOR}"
                fi

                if [[ -n "${THIRD_SQL_ID}" ]]
                then
                    echo -e "===>${GREEN} THIRD_SQL_ID FOR PDB $PDB IN ${db}${ENDCOLOR}"
                    echo -e "===>${GREEN}${THIRD_SQL_ID}${ENDCOLOR}"
                fi
            fi
            echo -e ""
            echo -e ""
        done
    fi












    TABLESPACE_OUTPUT=$($ORACLE_HOME/bin/${SQLPLUS_STRING} <<EOF
    set heading off feedback off pagesize 0 trimspool on lines 200
    set serverout on
    DECLARE
    NUM_OF_DATAFILES number;
    NUM_OF_NON_AUTOEXTEND_DF number;
    CURRENT_TBSP_SIZE number;
    MAX_EXTENSION_SIZE_GB number;
    temp_tbsp_count number;
    BEGIN
        for v_uniq_tablespace_sizes in (select tablespace_name,"UPERCENT" from (select a.tablespace_name,SUM(a.bytes)/1024/1024 "CurMb",SUM(decode(b.maxextend, null, A.BYTES/1024/1024, b.maxextend*8192/1024/1024)) "MaxMb",(SUM(a.bytes)/1024/1024 - round(c."Free"/1024/1024)) "TotalUsed",(SUM(decode(b.maxextend, null, A.BYTES/1024/1024, b.maxextend*8192/1024/1024)) - (SUM(a.bytes)/1024/1024 - round(c."Free"/1024/1024))) "TotalFree",round(100*(SUM(a.bytes)/1024/1024 - round(c."Free"/1024/1024))/(SUM(decode(b.maxextend, null, A.BYTES/1024/1024, b.maxextend*8192/1024/1024)))) "UPERCENT" from dba_data_files a,sys.filext$ b,(SELECT d.tablespace_name , sum(nvl(c.bytes,0)) "Free" FROM dba_tablespaces d,DBA_FREE_SPACE c where d.tablespace_name = c.tablespace_name(+) group by d.tablespace_name) c where a.file_id = b.file#(+) and a.tablespace_name = c.tablespace_name GROUP by a.tablespace_name, c."Free"/1024 order by round(100*(SUM(a.bytes)/1024/1024 - round(c."Free"/1024/1024))/(SUM(decode(b.maxextend, null, A.BYTES/1024/1024, b.maxextend*8192/1024/1024)))) desc))
        LOOP
            select count(*) into temp_tbsp_count from dba_temp_files where tablespace_name = v_uniq_tablespace_sizes.tablespace_name;
            IF temp_tbsp_count > 0 THEN
                continue;
            END IF;
            IF v_uniq_tablespace_sizes.UPERCENT > ${TBSP_PERCENT_USED} THEN
                dbms_output.put_line('===> TABLESPACE : '||v_uniq_tablespace_sizes.tablespace_name||' NEEDS DATAFILE ADDED AS ${TBSP_PERCENT_USED}% USED WITH NO MORE EXTENSION LEFT');
            END IF;
        END LOOP;
    END;
    /
EOF
)


    echo -e "===>${GREEN} DB CHECKS FOR IN ${db}${ENDCOLOR}"
    if [[ -z $TABLESPACE_OUTPUT ]]
    then
        echo -e "===>${GREEN} TABLESPACE_SIZE_CHECKS : PASS, NO TBSPs OVER ${TBSP_PERCENT_USED}% ${ENDCOLOR}"
    else
        echo -e "${RED}$TABLESPACE_OUTPUT${ENDCOLOR}"|sed 's/ //'
        TBSP_ECHOED_MESSAGE=`echo ${RED}$TABLESPACE_OUTPUT${ENDCOLOR}|sed 's/ //'`
        echo -e "$TBSP_ECHOED_MESSAGE" | mail -s "${db} TABLESPACE_SIZE_CHECKS : DANGER, OVER ${TBSP_PERCENT_USED}% USED" zsyed@deltadentalmi.com
    fi


    FRA_SPACE_USAGE_PERCENT=$($ORACLE_HOME/bin/${SQLPLUS_STRING} <<EOF
    set heading off feedback off pagesize 0 trimspool on lines 200
    select round((space_used/space_limit)*100) from v\$recovery_file_dest;
EOF
)



    if [[ $FRA_SPACE_USAGE_PERCENT -ge $FRA_PERCENT_USED ]]
    then
        echo -e "===>${RED} FRA_SPACE_CHECK : DANGER, OVER ${FRA_PERCENT_USED}% USED ${ENDCOLOR}"
        echo "===>${RED} FRA_SPACE_CHECK : DANGER, OVER ${FRA_PERCENT_USED}% USED ${ENDCOLOR}" | mail -s "${db} FRA_SPACE_CHECK : DANGER, OVER ${FRA_PERCENT_USED}% USED" zsyed@deltadentalmi.com
    else
        echo -e "===>${GREEN} FRA_SPACE_CHECK : PASS, FRA IS ${FRA_PERCENT_USED}% ${ENDCOLOR}"
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
                    select status from gv\$managed_standby where process like 'MRP%';
                    exit
EOF
)

                    if [[ "${IS_APPLYING_LOG}" != "APPLYING_LOG" ]]
                    then
                        echo -e "===>${RED} STANDBY_DB : ${STANDBY_DB_UNIQUE_NAME} MRP IS NOT RUNNING ${ENDCOLOR}"
                        continue
                    fi

                    STANDBY_DATUM_TIME=$($ORACLE_HOME/bin/sqlplus -s sys/${SYS_PWD}@${STANDBY_DB_UNIQUE_NAME} as sysdba <<EOF
                    set lines 200 heading off feedback off pagesize 0 trimspool off
                    select datum_time from gv\$dataguard_stats where name = 'apply lag' and DATUM_TIME is not null;
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
    echo ""
        unset IFS
done

#!/bin/bash
##ORACLE_19C_INTERACTIVE_HEALTH_CHECK_v4

GREEN="\033[1;32;40m"
RED="\033[1;31;40m"
YELLOW="\033[1;33;40m"
CYAN="\033[1;36;40m"
ENDCOLOR="\e[0m"

HOST_NAME=`hostname`

##THRESHOLDS
TBSP_PERCENT_USED=90
ASM_PERCENT_USED=90
FRA_PERCENT_USED=90

##THESE GET SET BY USER AT RUNTIME
CURRENT_DB=""
CURRENT_PDB=""     ##SET IF USER PICKS A PDB INSIDE A CDB
PDB_CTX=""         ##BECOMES "alter session set container=X;" WHEN PDB IS PICKED
TIME_MODE=""       ##REALTIME or HISTORICAL
RT_MINS=30         ##REALTIME WINDOW IN MINUTES
HIST_START=""      ##HISTORICAL START TIME  DD-MON-YYYY HH24:MI
HIST_END=""        ##HISTORICAL END TIME    DD-MON-YYYY HH24:MI
BEGIN_SNAP=0
END_SNAP=0




##===========================================================================
##  PICK DATABASE FROM ORATAB ON THIS HOST
##===========================================================================

pick_db() {
    DB_LIST=`grep -v '^#' /etc/oratab | grep -v '+ASM' | grep -v 'agent' | grep -v '^$' | awk -F: '{print $1}' | sort -u`
    if [[ -z "$DB_LIST" ]]
    then
        echo -e "===>${RED} NO DATABASES FOUND IN /etc/oratab ON ${HOST_NAME} - EXITING${ENDCOLOR}"
        exit 1
    fi

    echo ""
    echo "======================================================="
    echo "   Oracle HC  |  Host: $HOST_NAME"
    echo "======================================================="
    echo "   Databases registered on this host :"
    echo ""
    COUNT=1
    for DB in $DB_LIST
    do
        echo "   [$COUNT]  $DB"
        eval "DB_OPT_${COUNT}=$DB"
        COUNT=$((COUNT + 1))
    done
    echo "   [q]  Quit"
    echo "======================================================="
    echo -n "   Pick a database : "
    read DB_CHOICE

    [[ "$DB_CHOICE" == "q" || "$DB_CHOICE" == "Q" ]] && echo "  Exiting." && exit 0

    CURRENT_DB=`eval echo \\$DB_OPT_${DB_CHOICE}`
    if [[ -z "$CURRENT_DB" ]]
    then
        echo -e "===>${RED} INVALID CHOICE${ENDCOLOR}"
        pick_db
        return
    fi

    set_oracle_env $CURRENT_DB

    CONN_TEST=$($ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF
    set heading off feedback off pagesize 0
    select 'CONN_OK' from dual;
    exit
EOF
)
    if [[ "$CONN_TEST" != *"CONN_OK"* ]]
    then
        echo -e "===>${RED} CANNOT CONNECT TO $CURRENT_DB AS SYSDBA ON THIS HOST - PICK ANOTHER${ENDCOLOR}"
        pick_db
        return
    fi

    echo -e "===>${GREEN} CONNECTED TO : $CURRENT_DB ON $HOST_NAME${ENDCOLOR}"

    ##CHECK IF THIS IS A CDB AND LET USER PICK A PDB IF SO
    CURRENT_PDB=""
    PDB_CTX=""
    IS_CDB=$($ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF
    set heading off feedback off pagesize 0 trimspool on
    select cdb from v\$database;
    exit
EOF
)
    IS_CDB=`echo $IS_CDB | tr -d ' '`

    if [[ "$IS_CDB" == "YES" ]]
    then
        echo -e "===>${CYAN} THIS IS A CDB - LISTING OPEN PDBs${ENDCOLOR}"
        PDB_LIST=$($ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF
        set heading off feedback off pagesize 0 trimspool on
        select name from v\$pdbs where name <> 'PDB\$SEED' and open_mode like 'READ%' order by name;
        exit
EOF
)
        if [[ -z "$PDB_LIST" ]]
        then
            echo -e "===>${YELLOW} NO OPEN PDBs FOUND - STAYING AT CDB ROOT${ENDCOLOR}"
        else
            echo ""
            echo "   PDBs available on $CURRENT_DB :"
            echo "   [0]  CDB Root ( stay at root )"
            PCNT=1
            for PDB in $PDB_LIST
            do
                echo "   [$PCNT]  $PDB"
                eval "PDB_OPT_${PCNT}=$PDB"
                PCNT=$((PCNT + 1))
            done
            echo -n "   Pick a PDB [0 for CDB root] : "
            read PDB_CHOICE

            if [[ "$PDB_CHOICE" != "0" && -n "$PDB_CHOICE" ]]
            then
                CURRENT_PDB=`eval echo \\$PDB_OPT_${PDB_CHOICE}`
                if [[ -z "$CURRENT_PDB" ]]
                then
                    echo -e "===>${RED} INVALID PDB CHOICE - STAYING AT CDB ROOT${ENDCOLOR}"
                    CURRENT_PDB=""
                    PDB_CTX=""
                else
                    PDB_CTX="alter session set container=${CURRENT_PDB};"
                    echo -e "===>${GREEN} CONTAINER SET TO : $CURRENT_PDB${ENDCOLOR}"
                fi
            else
                echo -e "===>${GREEN} STAYING AT CDB ROOT${ENDCOLOR}"
            fi
        fi
    fi
}


##===========================================================================
##  SET ORACLE ENV
##===========================================================================

set_oracle_env() {
    export ORACLE_SID=$1
    export ORAENV_ASK=NO
    . oraenv > /dev/null 2>&1
}


##===========================================================================
##  PICK TIME MODE - REALTIME OR HISTORICAL + WINDOW
##===========================================================================

pick_time_mode() {
    echo ""
    echo "======================================================="
    echo "   Time Mode for : $CURRENT_DB$([ -n "$CURRENT_PDB" ] && echo " / $CURRENT_PDB")"
    echo "======================================================="
    echo "   [1]  Realtime   ( specify last N minutes - uses gv\$ash )"
    echo "   [2]  Historical ( specify start and end time - uses AWR )"
    echo "======================================================="
    echo -n "   Pick time mode : "
    read TM_CHOICE

    if [[ "$TM_CHOICE" == "1" ]]
    then
        TIME_MODE="REALTIME"
        echo -n "   How many minutes back [default 30] : "
        read RT_INPUT
        [[ -n "$RT_INPUT" ]] && RT_MINS=$RT_INPUT
        echo -e "===>${GREEN} TIME MODE : REALTIME | LAST ${RT_MINS} MINS${ENDCOLOR}"

    elif [[ "$TM_CHOICE" == "2" ]]
    then
        TIME_MODE="HISTORICAL"
        echo ""
        echo "   Enter the time window you want to look at"
        echo "   Format : DD-MON-YYYY HH24:MI  ( example : 05-MAR-2026 08:00 )"
        echo ""
        echo -n "   Start Time : "
        read HIST_START
        echo -n "   End Time   : "
        read HIST_END

        if [[ -z "$HIST_START" || -z "$HIST_END" ]]
        then
            echo -e "===>${RED} BOTH START AND END TIME REQUIRED${ENDCOLOR}"
            pick_time_mode
            return
        fi

        get_hist_snaps
        echo -e "===>${GREEN} TIME MODE : HISTORICAL | ${HIST_START} TO ${HIST_END} | SNAPS : ${BEGIN_SNAP} - ${END_SNAP}${ENDCOLOR}"
    else
        echo -e "===>${RED} INVALID - PICK 1 OR 2${ENDCOLOR}"
        pick_time_mode
    fi
}


##===========================================================================
##  GET SNAP IDS FOR HISTORICAL MODE
##===========================================================================

get_hist_snaps() {
    SNAP_OUT=$($ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF
    set heading off feedback off pagesize 0 trimspool on
    ${PDB_CTX}
    select min(snap_id)||' '||max(snap_id)
    from dba_hist_snapshot
    where begin_interval_time >= to_date('${HIST_START}','DD-MON-YYYY HH24:MI')
    and end_interval_time   <= to_date('${HIST_END}','DD-MON-YYYY HH24:MI') + 1/1440;
    exit
EOF
)
    BEGIN_SNAP=`echo $SNAP_OUT | awk '{print $1}'`
    END_SNAP=`echo $SNAP_OUT   | awk '{print $2}'`

    if [[ -z "$BEGIN_SNAP" || "$BEGIN_SNAP" == "null" || -z "$END_SNAP" || "$END_SNAP" == "null" ]]
    then
        echo -e "===>${RED} NO AWR SNAPSHOTS FOUND BETWEEN ${HIST_START} AND ${HIST_END}${ENDCOLOR}"
        echo -e "===>${YELLOW} SHOWING LAST 24 HOURS OF AVAILABLE SNAPSHOTS BELOW :${ENDCOLOR}"
        $ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF
        set heading off feedback off pagesize 0 trimspool on lines 200
        ${PDB_CTX}
        select '  SNAP_ID : '||lpad(snap_id,8)||'  BEGIN : '||to_char(begin_interval_time,'DD-MON-YYYY HH24:MI')||'  END : '||to_char(end_interval_time,'DD-MON-YYYY HH24:MI')
        from dba_hist_snapshot
        where begin_interval_time > sysdate - 1
        order by snap_id desc fetch first 30 rows only;
        exit
EOF
        echo ""
        pick_time_mode
    fi
}


##===========================================================================
##  1. TABLESPACE CHECK
##===========================================================================

check_tablespace() {
    echo ""
    echo -e "===>${CYAN}---------- TABLESPACE CHECK | DB : ${CURRENT_DB}$([ -n "$CURRENT_PDB" ] && echo " / $CURRENT_PDB") ----------${ENDCOLOR}"
    TBSP_OUT=$($ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF
    set heading on feedback off pagesize 100 linesize 200 trimout on trimspool on
    ${PDB_CTX}
    column tablespace_name format a35       heading 'TABLESPACE'
    column used_gb         format 999999.9 heading 'USED_GB'
    column max_gb          format 999999.9 heading 'MAX_GB'
    column used_pct        format 990.0     heading 'USED_%'
    column status          format a25       heading 'STATUS'
    select m.tablespace_name,
           round(m.used_space * t.block_size / 1024/1024/1024, 1) used_gb,
           round(m.tablespace_size * t.block_size / 1024/1024/1024, 1) max_gb,
           round(m.used_percent, 1) used_pct,
           case when round(m.used_percent) > ${TBSP_PERCENT_USED}
                then '*** OVER ${TBSP_PERCENT_USED}% ***' else 'OK' end status
    from dba_tablespace_usage_metrics m, dba_tablespaces t
    where m.tablespace_name = t.tablespace_name
    and m.used_percent > ${TBSP_PERCENT_USED}
    order by m.used_percent desc;
    exit
EOF
)
    if [[ -z "$TBSP_OUT" ]]
    then
        echo -e "===>${GREEN} TABLESPACE_CHECK : PASS - NO TABLESPACES OVER ${TBSP_PERCENT_USED}%${ENDCOLOR}"
    else
        echo -e "${RED}${TBSP_OUT}${ENDCOLOR}"
    fi
}


##===========================================================================
##  2. ASM DISKGROUP CHECK
##===========================================================================

check_asm() {
    echo ""
    echo -e "===>${CYAN}---------- ASM DISKGROUP CHECK ----------${ENDCOLOR}"
    ASM_OUT=$($ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF
    set heading on feedback off pagesize 100 linesize 160 trimout on trimspool on
    column name     format a20            heading 'DISKGROUP'
    column total_gb format 9999999.9    heading 'TOTAL_GB'
    column free_gb  format 9999999.9    heading 'FREE_GB'
    column used_pct format 990            heading 'USED_%'
    column status   format a25            heading 'STATUS'
    select name,
           round(total_mb/1024,1) total_gb,
           round(free_mb/1024,1) free_gb,
           round((total_mb-free_mb)/total_mb*100) used_pct,
           case when round((total_mb-free_mb)/total_mb*100) > ${ASM_PERCENT_USED}
                then '*** OVER THRESHOLD ***' else 'OK' end status
    from v\$asm_diskgroup
    order by 1;
    exit
EOF
)
    if [[ -z "$ASM_OUT" ]]
    then
        echo -e "===>${YELLOW} ASM_CHECK : NO DISKGROUPS VISIBLE FROM THIS DB${ENDCOLOR}"
    else
        while IFS= read -r line
        do
            if echo "$line" | grep -q "OVER THRESHOLD"
            then
                echo -e "${RED}${line}${ENDCOLOR}"
            else
                echo -e "${GREEN}${line}${ENDCOLOR}"
            fi
        done <<< "$ASM_OUT"
    fi
}


##===========================================================================
##  3. TOP WAIT EVENTS
##===========================================================================

check_top_waits() {
    echo ""
    echo -e "===>${CYAN}---------- TOP WAIT EVENTS | TIME MODE : ${TIME_MODE} ----------${ENDCOLOR}"

    if [[ "$TIME_MODE" == "REALTIME" ]]
    then
        WAITS_OUT=$($ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF
        set heading on feedback off pagesize 100 linesize 160 trimout on trimspool on
        ${PDB_CTX}
        column event format a65 heading 'WAIT EVENT'
        column cnt   format 999999999 heading 'COUNT'
        column pct   format 990.00 heading 'PCT%'
        select event, cnt, pct
        from (
            select event, count(*) cnt,
                   round(count(*)*100/sum(count(*)) over(),2) pct
            from gv\$active_session_history
            where sample_time > sysdate - ${RT_MINS}/1440
            and session_type='FOREGROUND' and wait_class <> 'Idle' and wait_class is not null
            group by event order by 2 desc)
        where rownum <= 10;
        exit
EOF
)
    else
        WAITS_OUT=$($ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF
        set heading on feedback off pagesize 100 linesize 160 trimout on trimspool on
        ${PDB_CTX}
        column event format a65 heading 'WAIT EVENT'
        column cnt   format 999999999 heading 'COUNT'
        column pct   format 990.00 heading 'PCT%'
        select event, cnt, pct
        from (
            select event, count(*) cnt,
                   round(count(*)*100/sum(count(*)) over(),2) pct
            from dba_hist_active_sess_history
            where snap_id between ${BEGIN_SNAP} and ${END_SNAP}
            and session_type='FOREGROUND' and wait_class <> 'Idle' and wait_class is not null
            group by event order by 2 desc)
        where rownum <= 10;
        exit
EOF
)
    fi

    if [[ -z "$WAITS_OUT" ]]
    then
        echo -e "===>${GREEN} TOP_WAIT_EVENTS : NO FOREGROUND WAITS FOUND IN THIS WINDOW${ENDCOLOR}"
    else
        echo -e "${YELLOW}${WAITS_OUT}${ENDCOLOR}"
    fi
}


##===========================================================================
##  4. TOP SQLS BY WAIT EVENTS
##===========================================================================

check_top_sqls() {
    echo ""
    echo -e "===>${CYAN}---------- TOP SQLS BY WAIT | TIME MODE : ${TIME_MODE} ----------${ENDCOLOR}"

    if [[ "$TIME_MODE" == "REALTIME" ]]
    then
        SQL_OUT=$($ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF
        set heading on feedback off pagesize 100 linesize 220 trimout on trimspool on
        ${PDB_CTX}
        column sql_id    format a14        heading 'SQL_ID'
        column plan_hash format 9999999999 heading 'PLAN_HASH'
        column event     format a45        heading 'WAIT_EVENT'
        column wait_cnt  format 999999    heading 'WAIT_CNT'
        column wait_pct  format 990.00     heading 'WAIT_%'
        column execs     format 999999    heading 'EXECS'
        column avg_s     format 99999.99  heading 'AVG_EXEC_S'
        column avg_gets  format 99999999999 heading 'AVG_GETS'
        column avg_reads format 9999999999  heading 'AVG_READS'
        select ash.sql_id, ash.sql_plan_hash_value plan_hash, ash.event,
               ash.wait_cnt, ash.wait_pct,
               nvl(st.execs,0) execs,
               nvl(round(st.elapsed_secs/nullif(st.execs,0),2),0) avg_s,
               nvl(round(st.buf_gets/nullif(st.execs,0)),0) avg_gets,
               nvl(round(st.disk_reads/nullif(st.execs,0)),0) avg_reads
        from (
            select sql_id, sql_plan_hash_value, event,
                   count(*) wait_cnt,
                   round(count(*)*100/sum(count(*)) over(),2) wait_pct
            from gv\$active_session_history
            where sample_time > sysdate - ${RT_MINS}/1440
            and session_type='FOREGROUND' and wait_class <> 'Idle'
            and sql_id is not null
            group by sql_id, sql_plan_hash_value, event
            order by 4 desc fetch first 15 rows only) ash,
            (select sql_id, plan_hash_value,
                    sum(executions) execs,
                    sum(elapsed_time)/1000000 elapsed_secs,
                    sum(buffer_gets) buf_gets,
                    sum(disk_reads) disk_reads
             from gv\$sql
             group by sql_id, plan_hash_value) st
        where ash.sql_id = st.sql_id(+)
        and ash.sql_plan_hash_value = st.plan_hash_value(+)
        order by ash.wait_cnt desc;
        exit
EOF
)
    else
        SQL_OUT=$($ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF
        set heading on feedback off pagesize 100 linesize 220 trimout on trimspool on
        ${PDB_CTX}
        column sql_id    format a14        heading 'SQL_ID'
        column plan_hash format 9999999999 heading 'PLAN_HASH'
        column event     format a45        heading 'WAIT_EVENT'
        column wait_cnt  format 999999    heading 'WAIT_CNT'
        column wait_pct  format 990.00     heading 'WAIT_%'
        column execs     format 999999    heading 'EXECS'
        column avg_s     format 99999.99  heading 'AVG_EXEC_S'
        column avg_gets  format 99999999999 heading 'AVG_GETS'
        column avg_reads format 9999999999  heading 'AVG_READS'
        select ash.sql_id, ash.sql_plan_hash_value plan_hash, ash.event,
               ash.wait_cnt, ash.wait_pct,
               nvl(st.execs,0) execs,
               nvl(round(st.elapsed_secs/nullif(st.execs,0),2),0) avg_s,
               nvl(round(st.buf_gets/nullif(st.execs,0)),0) avg_gets,
               nvl(round(st.disk_reads/nullif(st.execs,0)),0) avg_reads
        from (
            select sql_id, sql_plan_hash_value, event,
                   count(*) wait_cnt,
                   round(count(*)*100/sum(count(*)) over(),2) wait_pct
            from dba_hist_active_sess_history
            where snap_id between ${BEGIN_SNAP} and ${END_SNAP}
            and session_type='FOREGROUND' and wait_class <> 'Idle'
            and sql_id is not null
            group by sql_id, sql_plan_hash_value, event
            order by 4 desc fetch first 15 rows only) ash,
            (select sql_id, plan_hash_value,
                    sum(executions_delta) execs,
                    sum(elapsed_time_delta)/1000000 elapsed_secs,
                    sum(buffer_gets_delta) buf_gets,
                    sum(disk_reads_delta) disk_reads
             from dba_hist_sqlstat
             where snap_id between ${BEGIN_SNAP} and ${END_SNAP}
             group by sql_id, plan_hash_value) st
        where ash.sql_id = st.sql_id(+)
        and ash.sql_plan_hash_value = st.plan_hash_value(+)
        order by ash.wait_cnt desc;
        exit
EOF
)
    fi

    if [[ -z "$SQL_OUT" ]]
    then
        echo -e "===>${GREEN} TOP_SQLS_BY_WAIT : NONE FOUND IN THIS WINDOW${ENDCOLOR}"
    else
        echo -e "${YELLOW}${SQL_OUT}${ENDCOLOR}"
    fi
}


##===========================================================================
##  5. TOP OBJECTS BY WAIT
##===========================================================================

check_top_objects() {
    echo ""
    echo -e "===>${CYAN}---------- TOP OBJECTS BY WAIT | TIME MODE : ${TIME_MODE} ----------${ENDCOLOR}"

    if [[ "$TIME_MODE" == "REALTIME" ]]
    then
        OBJ_OUT=$($ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF
        set heading on feedback off pagesize 100 linesize 250 trimout on trimspool on
        ${PDB_CTX}
        column owner    format a20  heading 'OWNER'
        column obj_name format a45  heading 'OBJECT'
        column obj_type format a16  heading 'TYPE'
        column event    format a45  heading 'WAIT_EVENT'
        column wait_cnt format 999999 heading 'WAIT_CNT'
        select nvl(o.owner,'UNKNOWN') owner,
               nvl(o.object_name,'OBJ#'||ash.current_obj#) obj_name,
               nvl(o.object_type,'UNKNOWN') obj_type,
               ash.event, count(*) wait_cnt
        from gv\$active_session_history ash, dba_objects o
        where ash.sample_time > sysdate - ${RT_MINS}/1440
        and ash.current_obj# = o.object_id(+)
        and ash.session_type = 'FOREGROUND'
        and ash.wait_class <> 'Idle'
        and ash.current_obj# > 0
        group by o.owner, o.object_name, o.object_type, ash.event, ash.current_obj#
        order by count(*) desc fetch first 10 rows only;
        exit
EOF
)
    else
        OBJ_OUT=$($ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF
        set heading on feedback off pagesize 100 linesize 250 trimout on trimspool on
        ${PDB_CTX}
        column owner    format a20  heading 'OWNER'
        column obj_name format a45  heading 'OBJECT'
        column obj_type format a16  heading 'TYPE'
        column event    format a45  heading 'WAIT_EVENT'
        column wait_cnt format 999999 heading 'WAIT_CNT'
        select nvl(o.owner,'UNKNOWN') owner,
               nvl(o.object_name,'OBJ#'||ash.current_obj#) obj_name,
               nvl(o.object_type,'UNKNOWN') obj_type,
               ash.event, count(*) wait_cnt
        from dba_hist_active_sess_history ash, dba_objects o
        where ash.snap_id between ${BEGIN_SNAP} and ${END_SNAP}
        and ash.current_obj# = o.object_id(+)
        and ash.session_type = 'FOREGROUND'
        and ash.wait_class <> 'Idle'
        and ash.current_obj# > 0
        group by o.owner, o.object_name, o.object_type, ash.event, ash.current_obj#
        order by count(*) desc fetch first 10 rows only;
        exit
EOF
)
    fi

    if [[ -z "$OBJ_OUT" ]]
    then
        echo -e "===>${GREEN} TOP_OBJECTS_BY_WAIT : NONE FOUND IN THIS WINDOW${ENDCOLOR}"
    else
        echo -e "${YELLOW}${OBJ_OUT}${ENDCOLOR}"
    fi
}


##===========================================================================
##  6. DRILL INTO A SQL_ID - 60 DAY AWR HISTORY
##===========================================================================

drill_sql_id() {
    echo ""
    echo -e "===>${CYAN}---------- SQL_ID DRILL - 60 DAY AWR HISTORY ----------${ENDCOLOR}"
    echo -n "   Enter SQL_ID : "
    read INPUT_SQL_ID

    if [[ -z "$INPUT_SQL_ID" ]]
    then
        echo -e "===>${RED} NO SQL_ID ENTERED${ENDCOLOR}"
        return
    fi

    echo ""
    echo -e "===>${CYAN} AWR PLAN HASH + EXEC HISTORY FOR SQL_ID : $INPUT_SQL_ID ${ENDCOLOR}"

    $ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF
    set heading on feedback off pagesize 100 linesize 200 trimout on trimspool on
    ${PDB_CTX}
    column snap_time  format a20          heading 'SNAP_TIME'
    column inst       format 99            heading 'INST'
    column plan_hash  format 9999999999    heading 'PLAN_HASH'
    column execs      format 999999       heading 'EXECS'
    column avg_s      format 99999.99     heading 'AVG_EXEC_S'
    column avg_cpu    format 99999.99     heading 'AVG_CPU_S'
    column avg_gets   format 99999999999 heading 'AVG_GETS'
    column avg_reads  format 9999999999  heading 'AVG_READS'
    column avg_rows   format 999999999    heading 'AVG_ROWS'
    select to_char(sn.begin_interval_time,'DD-MON-YYYY HH24:MI') snap_time,
           s.instance_number inst,
           s.plan_hash_value plan_hash,
           s.executions_delta execs,
           round(s.elapsed_time_delta/1000000/nullif(s.executions_delta,0),2) avg_s,
           round(s.cpu_time_delta/1000000/nullif(s.executions_delta,0),2) avg_cpu,
           round(s.buffer_gets_delta/nullif(s.executions_delta,0)) avg_gets,
           round(s.disk_reads_delta/nullif(s.executions_delta,0)) avg_reads,
           round(s.rows_processed_delta/nullif(s.executions_delta,0)) avg_rows
    from dba_hist_sqlstat s, dba_hist_snapshot sn
    where s.sql_id = '${INPUT_SQL_ID}'
    and s.snap_id = sn.snap_id
    and s.instance_number = sn.instance_number
    and sn.begin_interval_time > sysdate - 60
    and s.executions_delta > 0
    order by sn.begin_interval_time desc, s.instance_number;
    exit
EOF

    echo ""
    echo -e "===>${CYAN} PLAN HASH SUMMARY - HOW MANY TIMES EACH PLAN EXECUTED LAST 60 DAYS${ENDCOLOR}"
    $ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF
    set heading on feedback off pagesize 100 linesize 180 trimout on trimspool on
    ${PDB_CTX}
    column plan_hash    format 9999999999    heading 'PLAN_HASH'
    column total_execs  format 999999       heading 'TOTAL_EXECS'
    column avg_s        format 99999.99     heading 'AVG_EXEC_S'
    column first_seen   format a22           heading 'FIRST_SEEN'
    column last_seen    format a22           heading 'LAST_SEEN'
    select plan_hash_value plan_hash,
           sum(executions_delta) total_execs,
           round(sum(elapsed_time_delta)/1000000/nullif(sum(executions_delta),0),2) avg_s,
           to_char(min(sn.begin_interval_time),'DD-MON-YYYY HH24:MI') first_seen,
           to_char(max(sn.begin_interval_time),'DD-MON-YYYY HH24:MI') last_seen
    from dba_hist_sqlstat s, dba_hist_snapshot sn
    where s.sql_id = '${INPUT_SQL_ID}'
    and s.snap_id = sn.snap_id
    and s.instance_number = sn.instance_number
    and sn.begin_interval_time > sysdate - 60
    and s.executions_delta > 0
    group by plan_hash_value
    order by 1;
    exit
EOF

    echo ""
    echo -e "===>${CYAN} CURRENT SQL TEXT FOR : $INPUT_SQL_ID ${ENDCOLOR}"
    $ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF
    set heading off feedback off pagesize 0 trimspool on lines 250 long 99999
    ${PDB_CTX}
    select sql_fulltext from v\$sql where sql_id='${INPUT_SQL_ID}' and rownum=1;
    exit
EOF
    echo ""

    ##IF SQL TEXT NOT IN SHARED POOL TRY AWR
    $ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF
    set heading off feedback off pagesize 0 trimspool on lines 250 long 99999
    ${PDB_CTX}
    select sql_text from dba_hist_sqltext where sql_id='${INPUT_SQL_ID}' and rownum=1;
    exit
EOF
}


##===========================================================================
##  7. DATAGUARD CHECK
##===========================================================================

check_dataguard() {
    echo ""
    echo -e "===>${CYAN}---------- DATAGUARD CHECK ----------${ENDCOLOR}"

    ##FIRST CHECK IF DG CONFIG EXISTS
    DG_CHECK=$($ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF
    set heading off feedback off pagesize 0 trimspool on
    select count(*) from v\$archive_dest where target='STANDBY' and dest_id <= 10;
    exit
EOF
)

    if [[ ${DG_CHECK:-0} -eq 0 ]]
    then
        echo -e "===>${YELLOW} DATAGUARD : NO STANDBY DESTINATIONS CONFIGURED ON THIS DB${ENDCOLOR}"
        return
    fi

    DG_ROLE=$($ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF
    set heading off feedback off pagesize 0 trimspool on
    select database_role from v\$database;
    exit
EOF
)

    DB_NAME=$($ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF
    set heading off feedback off pagesize 0 trimspool on
    select db_unique_name||' | PROTECTION MODE : '||protection_mode||' | STATUS : '||open_mode from v\$database;
    exit
EOF
)
    echo -e "===>${GREEN} DB INFO : ${DB_NAME}${ENDCOLOR}"
    echo -e "===>${GREEN} DG ROLE : ${DG_ROLE}${ENDCOLOR}"

    if echo "$DG_ROLE" | grep -q "PRIMARY"
    then
        ##PRIMARY - CHECK STANDBY DESTINATIONS AND TRANSPORT LAG
        echo ""
        echo -e "===>${CYAN} PRIMARY : STANDBY DESTINATION STATUS${ENDCOLOR}"
        $ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF
        set heading on feedback off pagesize 100 linesize 200 trimout on trimspool on
        column dest_name   format a35 heading 'DESTINATION'
        column status      format a12 heading 'STATUS'
        column db_unique   format a20 heading 'STANDBY_DB'
        column gap_status  format a15 heading 'GAP_STATUS'
        column error       format a40 heading 'ERROR'
        select d.dest_name,
               d.status,
               nvl(d.db_unique_name,'N/A')          db_unique,
               nvl(to_char(s.gap_status),'NONE')    gap_status,
               nvl(d.error,'NONE')                  error
        from v\$archive_dest d, v\$archive_dest_status s
        where d.dest_id = s.dest_id
        and d.target = 'STANDBY'
        and d.status <> 'INACTIVE'
        order by d.dest_id;
        exit
EOF

        echo ""
        echo -e "===>${CYAN} PRIMARY : ARCHIVE LOG TRANSPORT - LAST 5 PER THREAD${ENDCOLOR}"
        $ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF
        set heading on feedback off pagesize 100 linesize 160 trimout on trimspool on
        column thr            format 99      heading 'THR'
        column last_archived  format 999999  heading 'LAST_ARCHIVED'
        column last_applied   format 999999  heading 'LAST_APPLIED'
        column gap            format 999999  heading 'GAP'
        select al.thread#                                                                 thr,
               max(al.sequence#)                                                          last_archived,
               nvl(max(s.applied_seq#),0)                                                last_applied,
               max(al.sequence#) - nvl(max(s.applied_seq#),0)                           gap
        from v\$archived_log al,
             (select dest_id, max(applied_seq#) applied_seq#
              from v\$archive_dest_status
              where applied_seq# is not null
              group by dest_id) s
        where al.standby_dest = 'NO'
        and al.dest_id = 1
        and s.dest_id(+) between 1 and 10
        group by al.thread#
        order by al.thread#;
        exit
EOF

    else
        ##STANDBY - CHECK MRP PROCESS, APPLY LAG, LOGS RECEIVED VS APPLIED
        echo ""
        echo -e "===>${CYAN} STANDBY : MRP / APPLY PROCESS STATUS${ENDCOLOR}"
        MRP_OUT=$($ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF
        set heading on feedback off pagesize 100 linesize 140 trimout on trimspool on
        column process    format a10 heading 'PROCESS'
        column status     format a12 heading 'STATUS'
        column thread#    format 99  heading 'THR'
        column sequence#  format 999999 heading 'SEQ#'
        column delay_mins format 9999 heading 'DELAY_MINS'
        select process, status, thread#, sequence#, delay_mins
        from v\$managed_standby
        where process in ('MRP0','RFS','ARCH')
        order by process;
        exit
EOF
)
        if [[ -z "$MRP_OUT" ]]
        then
            echo -e "===>${RED} STANDBY : NO MRP OR RFS PROCESSES FOUND - APPLY MAY BE STOPPED${ENDCOLOR}"
        else
            echo -e "${YELLOW}${MRP_OUT}${ENDCOLOR}"
        fi

        echo ""
        echo -e "===>${CYAN} STANDBY : DG STATS - TRANSPORT LAG / APPLY LAG${ENDCOLOR}"
        DG_STATS=$($ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF
        set heading on feedback off pagesize 100 linesize 140 trimout on trimspool on
        column stat_name format a35 heading 'STAT_NAME'
        column value     format a25 heading 'VALUE'
        column as_of     format a22 heading 'AS_OF'
        select name stat_name,
               nvl(value,'N/A') value,
               nvl(to_char(datum_time,'DD-MON-YYYY HH24:MI'),'N/A') as_of
        from v\$dataguard_stats
        where name in ('transport lag','apply lag','apply finish time','estimated startup time');
        exit
EOF
)
        echo -e "${YELLOW}${DG_STATS}${ENDCOLOR}"

        ##APPLY LAG ALERT IF OVER 5 MINS
        APPLY_LAG_MINS=$($ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF
        set heading off feedback off pagesize 0 trimspool on
        select round(extract(day from to_dsinterval(value))*1440 + extract(hour from to_dsinterval(value))*60 + extract(minute from to_dsinterval(value)))
        from v\$dataguard_stats where name='apply lag';
        exit
EOF
)
        if [[ ${APPLY_LAG_MINS:-0} -gt 5 ]]
        then
            echo -e "===>${RED} APPLY_LAG_ALERT : ${APPLY_LAG_MINS} MINS BEHIND - CHECK MRP PROCESS${ENDCOLOR}"
        else
            echo -e "===>${GREEN} APPLY_LAG : ${APPLY_LAG_MINS} MINS - WITHIN THRESHOLD${ENDCOLOR}"
        fi

        echo ""
        echo -e "===>${CYAN} STANDBY : LOGS RECEIVED VS APPLIED PER THREAD${ENDCOLOR}"
        $ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF
        set heading on feedback off pagesize 100 linesize 120 trimout on trimspool on
        column thread#       format 99     heading 'THR'
        column last_received format 999999 heading 'LAST_RECEIVED'
        column last_applied  format 999999 heading 'LAST_APPLIED'
        column logs_behind   format 999999 heading 'LOGS_BEHIND'
        select a.thread#,
               a.last_received,
               nvl(b.last_applied,0) last_applied,
               (a.last_received - nvl(b.last_applied,0)) logs_behind
        from (select thread#, max(sequence#) last_received from v\$archived_log
              where dest_id=1 group by thread#) a,
             (select thread#, max(sequence#) last_applied from v\$archived_log
              where applied in ('YES','IN-MEMORY') group by thread#) b
        where a.thread# = b.thread#(+)
        order by a.thread#;
        exit
EOF
    fi
}


##===========================================================================
##  8. FRA CHECK
##===========================================================================

check_fra() {
    echo ""
    echo -e "===>${CYAN}---------- FRA CHECK ----------${ENDCOLOR}"
    $ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF
    set heading on feedback off pagesize 100 linesize 120 trimout on trimspool on
    column fra_location    format a30   heading 'FRA_LOCATION'
    column size_gb         format 9999999.9 heading 'SIZE_GB'
    column used_gb         format 9999999.9 heading 'USED_GB'
    column reclaimable_gb  format 9999999.9 heading 'RECLAIMABLE_GB'
    column used_pct        format 990    heading 'USED_%'
    select name fra_location,
           round(space_limit/1024/1024/1024,1) size_gb,
           round(space_used/1024/1024/1024,1) used_gb,
           round(space_reclaimable/1024/1024/1024,1) reclaimable_gb,
           round((space_used/space_limit)*100) used_pct
    from v\$recovery_file_dest;
    exit
EOF

    FRA_PCT=$($ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF
    set heading off feedback off pagesize 0 trimspool on
    select round((space_used/space_limit)*100) from v\$recovery_file_dest;
    exit
EOF
)
    FRA_PCT=`echo $FRA_PCT | tr -d ' '`
    if [[ ${FRA_PCT:-0} -ge $FRA_PERCENT_USED ]]
    then
        echo -e "===>${RED} FRA_ALERT : ${FRA_PCT}% USED - OVER ${FRA_PERCENT_USED}% THRESHOLD${ENDCOLOR}"
    else
        echo -e "===>${GREEN} FRA_CHECK : PASS - ${FRA_PCT}% USED${ENDCOLOR}"
    fi

    echo ""
    echo -e "===>${CYAN} FRA FILE TYPE BREAKDOWN${ENDCOLOR}"
    $ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF
    set heading on feedback off pagesize 100 linesize 120 trimout on trimspool on
    column file_type          format a20   heading 'FILE_TYPE'
    column used_pct           format 990.00 heading 'USED_%'
    column reclaimable_pct    format 990.00 heading 'RECLAIMABLE_%'
    select file_type,
           round(percent_space_used,2) used_pct,
           round(percent_space_reclaimable,2) reclaimable_pct
    from v\$flash_recovery_area_usage
    where percent_space_used > 0
    order by percent_space_used desc;
    exit
EOF
}


##===========================================================================
##  9. PARAMETER DRIFT - SOURCE IS CURRENT DB, TARGET IS REMOTE DB YOU SPECIFY
##===========================================================================

check_param_drift() {
    echo ""
    echo -e "===>${CYAN}---------- PARAMETER DRIFT CHECK ----------${ENDCOLOR}"
    echo -e "===>${CYAN} SOURCE DB : ${CURRENT_DB} ON ${HOST_NAME} ${ENDCOLOR}"
    echo ""
    echo "   Enter target DB connection details"
    echo "   ( this can be any DB anywhere as long as its reachable from this host )"
    echo ""

    echo -n "   Target Hostname or IP  : "
    read TGT_HOST
    echo -n "   Target Port [1521]     : "
    read TGT_PORT
    [[ -z "$TGT_PORT" ]] && TGT_PORT=1521

    echo -n "   Target Service Name    : "
    read TGT_SERVICE

    echo -n "   Target Username        : "
    read TGT_USER

    ##USE -s FLAG ON READ TO HIDE PASSWORD
    echo -n "   Target Password        : "
    read -s TGT_PASS
    echo ""

    if [[ -z "$TGT_HOST" || -z "$TGT_SERVICE" || -z "$TGT_USER" || -z "$TGT_PASS" ]]
    then
        echo -e "===>${RED} PARAM_DRIFT : MISSING CONNECTION DETAILS - HOSTNAME, SERVICE, USER AND PASSWORD ALL REQUIRED${ENDCOLOR}"
        return
    fi

    ##BUILD CONNECT STRING  username/password@//host:port/service
    TGT_CONN="${TGT_USER}/${TGT_PASS}@//${TGT_HOST}:${TGT_PORT}/${TGT_SERVICE}"

    echo ""
    echo -e "===>${CYAN} TESTING CONNECTION TO : ${TGT_HOST}:${TGT_PORT}/${TGT_SERVICE} AS ${TGT_USER}${ENDCOLOR}"

    TGT_CONN_TEST=$($ORACLE_HOME/bin/sqlplus -s "${TGT_CONN}" <<EOF
    set heading off feedback off pagesize 0
    select 'CONN_OK' from dual;
    exit
EOF
)
    if [[ "$TGT_CONN_TEST" != *"CONN_OK"* ]]
    then
        echo -e "===>${RED} PARAM_DRIFT : CANNOT CONNECT TO TARGET ${TGT_HOST}:${TGT_PORT}/${TGT_SERVICE} - CHECK DETAILS AND NETWORK${ENDCOLOR}"
        return
    fi

    ##GET TARGET DB UNIQUE NAME FOR DISPLAY
    TGT_DB_NAME=$($ORACLE_HOME/bin/sqlplus -s "${TGT_CONN}" <<EOF
    set heading off feedback off pagesize 0 trimspool on
    select db_unique_name from v\$database;
    exit
EOF
)
    TGT_DB_NAME=`echo $TGT_DB_NAME | tr -d ' '`

    echo -e "===>${GREEN} CONNECTED TO TARGET : ${TGT_DB_NAME} ON ${TGT_HOST}${ENDCOLOR}"
    echo ""
    echo -e "===>${CYAN} COMPARING PARAMETERS : ${CURRENT_DB} ( SOURCE ) vs ${TGT_DB_NAME} ( TARGET ) - NON-DEFAULT ONLY${ENDCOLOR}"

    ##DUMP SOURCE PARAMS - LOCAL / AS SYSDBA
    $ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF > /tmp/hc_src_params_${CURRENT_DB}.txt
    set heading off feedback off pagesize 0 trimspool on lines 300
    select rpad(name,65)||value from v\$parameter where isdefault='FALSE' order by name;
    exit
EOF

    ##DUMP TARGET PARAMS - REMOTE CONNECT STRING
    $ORACLE_HOME/bin/sqlplus -s "${TGT_CONN}" <<EOF > /tmp/hc_tgt_params_${TGT_DB_NAME}.txt
    set heading off feedback off pagesize 0 trimspool on lines 300
    select rpad(name,65)||value from v\$parameter where isdefault='FALSE' order by name;
    exit
EOF

    echo ""
    echo -e "===>${CYAN} PARAMS SET IN SOURCE ( ${CURRENT_DB} ) BUT DIFFERENT OR MISSING IN TARGET ( ${TGT_DB_NAME} )${ENDCOLOR}"
    DIFF_SRC=`diff /tmp/hc_src_params_${CURRENT_DB}.txt /tmp/hc_tgt_params_${TGT_DB_NAME}.txt | grep '^<' | sed 's/^< //'`
    if [[ -z "$DIFF_SRC" ]]
    then
        echo -e "===>${GREEN} NONE - SOURCE AND TARGET MATCH FOR ALL NON-DEFAULT PARAMS${ENDCOLOR}"
    else
        echo "$DIFF_SRC" | while IFS= read -r line
        do
            PNAME=`echo "$line" | awk '{print $1}'`
            PVAL=`echo "$line"  | sed "s/${PNAME}//"`
            echo -e "===>${YELLOW} SOURCE PARAM : ${PNAME}  =  ${PVAL}${ENDCOLOR}"
        done
    fi

    echo ""
    echo -e "===>${CYAN} PARAMS SET IN TARGET ( ${TGT_DB_NAME} ) BUT DIFFERENT OR MISSING IN SOURCE ( ${CURRENT_DB} )${ENDCOLOR}"
    DIFF_TGT=`diff /tmp/hc_src_params_${CURRENT_DB}.txt /tmp/hc_tgt_params_${TGT_DB_NAME}.txt | grep '^>' | sed 's/^> //'`
    if [[ -z "$DIFF_TGT" ]]
    then
        echo -e "===>${GREEN} NONE - TARGET AND SOURCE MATCH FOR ALL NON-DEFAULT PARAMS${ENDCOLOR}"
    else
        echo "$DIFF_TGT" | while IFS= read -r line
        do
            PNAME=`echo "$line" | awk '{print $1}'`
            PVAL=`echo "$line"  | sed "s/${PNAME}//"`
            echo -e "===>${YELLOW} TARGET PARAM : ${PNAME}  =  ${PVAL}${ENDCOLOR}"
        done
    fi

    DIFF_COUNT=`diff /tmp/hc_src_params_${CURRENT_DB}.txt /tmp/hc_tgt_params_${TGT_DB_NAME}.txt | grep -c '^[<>]'`
    echo ""
    if [[ ${DIFF_COUNT:-0} -eq 0 ]]
    then
        echo -e "===>${GREEN} PARAM_DRIFT : PASS - NO NON-DEFAULT PARAMETER DIFFERENCES FOUND BETWEEN ${CURRENT_DB} AND ${TGT_DB_NAME}${ENDCOLOR}"
    else
        echo -e "===>${RED} PARAM_DRIFT : ${DIFF_COUNT} PARAMETER DIFFERENCES FOUND BETWEEN ${CURRENT_DB} AND ${TGT_DB_NAME}${ENDCOLOR}"
    fi

    rm -f /tmp/hc_src_params_${CURRENT_DB}.txt /tmp/hc_tgt_params_${TGT_DB_NAME}.txt
}


##===========================================================================
##  10. OS CHECKS - LOAD AVG / MEMORY / TOP PROCESSES
##===========================================================================

check_os() {
    echo ""
    echo -e "===>${CYAN}---------- OS CHECKS | HOST : ${HOST_NAME} ----------${ENDCOLOR}"

    CPU_COUNT_OS=`nproc`
    LOAD_AVG=`uptime | awk -F'load average:' '{print $2}' | sed 's/ //g'`
    LOAD_1=`echo $LOAD_AVG | awk -F',' '{print $1}'`
    LOAD_5=`echo $LOAD_AVG | awk -F',' '{print $2}'`
    LOAD_15=`echo $LOAD_AVG | awk -F',' '{print $3}'`

    echo -e "===>${GREEN} CPU_COUNT_OS : ${CPU_COUNT_OS}${ENDCOLOR}"

    ##LOAD 1 MIN OVER CPU COUNT IS WORTH FLAGGING
    LOAD_THRESHOLD=$CPU_COUNT_OS
    if (( $(echo "$LOAD_1 > $LOAD_THRESHOLD" | bc -l) ))
    then
        echo -e "===>${RED} LOAD_AVG : 1MIN=${LOAD_1}  5MIN=${LOAD_5}  15MIN=${LOAD_15} - 1MIN LOAD OVER CPU COUNT${ENDCOLOR}"
    else
        echo -e "===>${GREEN} LOAD_AVG : 1MIN=${LOAD_1}  5MIN=${LOAD_5}  15MIN=${LOAD_15}${ENDCOLOR}"
    fi

    ##MEMORY
    MEM_TOTAL=`free -g | grep Mem | awk '{print $2}'`
    MEM_USED=`free -g  | grep Mem | awk '{print $3}'`
    MEM_FREE=`free -g  | grep Mem | awk '{print $4}'`
    MEM_PCT=`free | grep Mem | awk '{printf "%.0f", $3/$2*100}'`

    if [[ $MEM_PCT -gt 90 ]]
    then
        echo -e "===>${RED} MEMORY : TOTAL=${MEM_TOTAL}G  USED=${MEM_USED}G  FREE=${MEM_FREE}G  USED_PCT=${MEM_PCT}% - OVER 90% USED${ENDCOLOR}"
    else
        echo -e "===>${GREEN} MEMORY : TOTAL=${MEM_TOTAL}G  USED=${MEM_USED}G  FREE=${MEM_FREE}G  USED_PCT=${MEM_PCT}%${ENDCOLOR}"
    fi

    ##SWAP
    SWAP_TOTAL=`free -g | grep Swap | awk '{print $2}'`
    SWAP_USED=`free -g  | grep Swap | awk '{print $3}'`
    if [[ ${SWAP_USED:-0} -gt 0 ]]
    then
        echo -e "===>${YELLOW} SWAP : TOTAL=${SWAP_TOTAL}G  IN_USE=${SWAP_USED}G - SWAP IS BEING USED${ENDCOLOR}"
    else
        echo -e "===>${GREEN} SWAP : TOTAL=${SWAP_TOTAL}G  IN_USE=0 - NOT IN USE${ENDCOLOR}"
    fi

    ##DISK USAGE
    echo ""
    echo -e "===>${CYAN} DISK USAGE (FILESYSTEMS OVER 80%)${ENDCOLOR}"
    df -h | grep -v tmpfs | grep -v Filesystem | awk '$5+0 > 80 {print "===> "$0}' | while IFS= read -r line
    do
        echo -e "${RED}${line}${ENDCOLOR}"
    done
    df -h | grep -v tmpfs | grep -v Filesystem | awk '$5+0 <= 80 {print "===> "$0}' | while IFS= read -r line
    do
        echo -e "${GREEN}${line}${ENDCOLOR}"
    done

    ##TOP 5 CPU PROCESSES
    echo ""
    echo -e "===>${CYAN} TOP 5 PROCESSES BY CPU${ENDCOLOR}"
    ps aux --sort=-%cpu | head -6 | tail -5 | while IFS= read -r line
    do
        echo -e "===>${YELLOW} ${line}${ENDCOLOR}"
    done

    ##TOP 5 MEM PROCESSES
    echo ""
    echo -e "===>${CYAN} TOP 5 PROCESSES BY MEMORY${ENDCOLOR}"
    ps aux --sort=-%mem | head -6 | tail -5 | while IFS= read -r line
    do
        echo -e "===>${YELLOW} ${line}${ENDCOLOR}"
    done
}


##===========================================================================
##  11. ALERT LOG ERRORS
##===========================================================================

check_alert_log() {
    echo ""
    echo -e "===>${CYAN}---------- ALERT LOG ERRORS | TIME MODE : ${TIME_MODE} ----------${ENDCOLOR}"

    ##GET ALERT LOG PATH FROM ADR
    ALERT_LOG_DIR=$($ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF
    set heading off feedback off pagesize 0 trimspool on
    select value from v\$diag_info where name='Diag Alert';
    exit
EOF
)
    ALERT_LOG_FILE="${ALERT_LOG_DIR}/log.xml"
    echo -e "===>${GREEN} ALERT LOG PATH : ${ALERT_LOG_DIR}${ENDCOLOR}"

    if [[ "$TIME_MODE" == "REALTIME" ]]
    then
        ##REALTIME - USE v$diag_alert_ext
        echo -e "===>${CYAN} ORA ERRORS IN LAST ${RT_MINS} MINS${ENDCOLOR}"
        ORA_CNT=$($ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF
        set heading off feedback off pagesize 0 trimspool on
        select count(*) from v\$diag_alert_ext
        where originating_timestamp > systimestamp - ${RT_MINS}/1440
        and message_text not like 'Result = ORA-0%'
        and message_text like 'ORA-%';
        exit
EOF
)
        if [[ ${ORA_CNT:-0} -eq 0 ]]
        then
            echo -e "===>${GREEN} ALERT_LOG_ORA_ERRORS : NONE IN LAST ${RT_MINS} MINS${ENDCOLOR}"
        else
            echo -e "===>${RED} ALERT_LOG_ORA_ERRORS : ${ORA_CNT} ERRORS IN LAST ${RT_MINS} MINS${ENDCOLOR}"
            $ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF
            set heading on feedback off pagesize 100 linesize 220 trimout on trimspool on
            column err_time format a22  heading 'TIME'
            column message  format a180 heading 'MESSAGE'
            select to_char(originating_timestamp,'DD-MON-YYYY HH24:MI:SS') err_time,
                   substr(message_text,1,180) message
            from v\$diag_alert_ext
            where originating_timestamp > systimestamp - ${RT_MINS}/1440
            and message_text not like 'Result = ORA-0%'
            and message_text like 'ORA-%'
            order by originating_timestamp desc fetch first 20 rows only;
            exit
EOF
        fi
    else
        ##HISTORICAL - USE v$diag_alert_ext WITH HIST_START/HIST_END TIMESTAMPS
        echo -e "===>${CYAN} ORA ERRORS BETWEEN ${HIST_START} AND ${HIST_END}${ENDCOLOR}"
        ORA_CNT=$($ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF
        set heading off feedback off pagesize 0 trimspool on
        select count(*) from v\$diag_alert_ext
        where originating_timestamp >= to_timestamp('${HIST_START}','DD-MON-YYYY HH24:MI')
        and originating_timestamp <= to_timestamp('${HIST_END}','DD-MON-YYYY HH24:MI')
        and message_text not like 'Result = ORA-0%'
        and message_text like 'ORA-%';
        exit
EOF
)
        if [[ ${ORA_CNT:-0} -eq 0 ]]
        then
            echo -e "===>${GREEN} ALERT_LOG_ORA_ERRORS : NONE BETWEEN ${HIST_START} AND ${HIST_END}${ENDCOLOR}"
        else
            echo -e "===>${RED} ALERT_LOG_ORA_ERRORS : ${ORA_CNT} ERRORS FOUND${ENDCOLOR}"
            $ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF
            set heading on feedback off pagesize 100 linesize 220 trimout on trimspool on
            column err_time format a22  heading 'TIME'
            column message  format a180 heading 'MESSAGE'
            select to_char(originating_timestamp,'DD-MON-YYYY HH24:MI:SS') err_time,
                   substr(message_text,1,180) message
            from v\$diag_alert_ext
            where originating_timestamp >= to_timestamp('${HIST_START}','DD-MON-YYYY HH24:MI')
            and originating_timestamp <= to_timestamp('${HIST_END}','DD-MON-YYYY HH24:MI')
            and message_text not like 'Result = ORA-0%'
            and message_text like 'ORA-%'
            order by originating_timestamp desc fetch first 30 rows only;
            exit
EOF
            ##SUMMARIZE TOP ERROR TYPES
            echo ""
            echo -e "===>${CYAN} TOP ORA ERROR CODES BY FREQUENCY${ENDCOLOR}"
            $ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF
            set heading on feedback off pagesize 100 linesize 80 trimout on trimspool on
            column error_code format a15 heading 'ERROR_CODE'
            column cnt        format 999999 heading 'COUNT'
            select regexp_substr(message_text,'ORA-[0-9]+') error_code, count(*) cnt
            from v\$diag_alert_ext
            where originating_timestamp >= to_timestamp('${HIST_START}','DD-MON-YYYY HH24:MI')
            and originating_timestamp <= to_timestamp('${HIST_END}','DD-MON-YYYY HH24:MI')
            and message_text not like 'Result = ORA-0%'
            and message_text like 'ORA-%'
            group by regexp_substr(message_text,'ORA-[0-9]+')
            order by 2 desc fetch first 10 rows only;
            exit
EOF
        fi
    fi
}


##===========================================================================
##  12. OBJECT FRAGMENTATION
##===========================================================================

check_fragmentation() {
    echo ""
    echo -e "===>${CYAN}---------- OBJECT FRAGMENTATION CHECK ----------${ENDCOLOR}"
    echo -n "   Enter Schema Owner (or ALL for whole DB) : "
    read FRAG_OWNER

    FRAG_OWNER=`echo $FRAG_OWNER | tr '[:lower:]' '[:upper:]'`

    ##LOOP - ALLOW MULTIPLE OBJECT CHECKS
    while true
    do
        echo -n "   Enter Table Name  (or ALL for all tables, or DONE to exit) : "
        read FRAG_TABLE
        FRAG_TABLE=`echo $FRAG_TABLE | tr '[:lower:]' '[:upper:]'`

        [[ "$FRAG_TABLE" == "DONE" || -z "$FRAG_TABLE" ]] && break

        if [[ "$FRAG_OWNER" == "ALL" ]]
        then
            OWNER_FILTER="t.owner not in ('SYS','SYSTEM','DBSNMP','XDB','WMSYS','ORDSYS','ORDDATA','MDSYS')"
            OWNER_FILTER_DT="owner not in ('SYS','SYSTEM','DBSNMP','XDB','WMSYS','ORDSYS','ORDDATA','MDSYS')"
            OWNER_FILTER_S="s.owner not in ('SYS','SYSTEM','DBSNMP','XDB','WMSYS','ORDSYS','ORDDATA','MDSYS')"
        else
            OWNER_FILTER="t.owner = '${FRAG_OWNER}'"
            OWNER_FILTER_DT="owner = '${FRAG_OWNER}'"
            OWNER_FILTER_S="s.owner = '${FRAG_OWNER}'"
        fi

        if [[ "$FRAG_TABLE" == "ALL" ]]
        then
            TABLE_FILTER_DT="1=1"
            TABLE_FILTER_T="1=1"
        else
            TABLE_FILTER_DT="table_name = '${FRAG_TABLE}'"
            TABLE_FILTER_T="t.table_name = '${FRAG_TABLE}'"
        fi

        echo ""
        echo -e "===>${CYAN} TABLE FRAGMENTATION - HWM WASTE / CHAINED ROWS | OWNER: ${FRAG_OWNER} TABLE: ${FRAG_TABLE}${ENDCOLOR}"
        $ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF
        set heading on feedback off pagesize 100 linesize 200 trimout on trimspool on
        ${PDB_CTX}
        column owner         format a20           heading 'OWNER'
        column table_name    format a35           heading 'TABLE'
        column num_rows      format 9999999999 heading 'ROWS'
        column blocks        format 9999999     heading 'BLOCKS'
        column empty_blocks  format 9999999     heading 'EMPTY_BLKS'
        column chain_pct     format 990.00        heading 'CHAIN_%'
        column last_analyzed format a20           heading 'LAST_ANALYZED'
        select owner, table_name, nvl(num_rows,0) num_rows,
               nvl(blocks,0) blocks, nvl(empty_blocks,0) empty_blocks,
               nvl(round(chain_cnt/nullif(num_rows,0)*100,2),0) chain_pct,
               nvl(to_char(last_analyzed,'DD-MON-YYYY HH24:MI'),'NEVER') last_analyzed
        from dba_tables
        where ${OWNER_FILTER_DT}
        and ${TABLE_FILTER_DT}
        and last_analyzed is not null
        order by chain_cnt desc nulls last
        fetch first 20 rows only;
        exit
EOF

        echo ""
        echo -e "===>${CYAN} SEGMENT HWM WASTE ESTIMATE (>30% WASTE, >10MB)${ENDCOLOR}"
        $ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF
        set heading on feedback off pagesize 100 linesize 200 trimout on trimspool on
        ${PDB_CTX}
        column owner       format a20   heading 'OWNER'
        column table_name  format a35   heading 'TABLE'
        column alloc_mb    format 9999999.9 heading 'ALLOC_MB'
        column used_mb     format 9999999.9 heading 'USED_MB'
        column waste_mb    format 9999999.9 heading 'WASTE_MB'
        column waste_pct   format 990          heading 'WASTE_%'
        select s.owner, s.segment_name table_name,
               round(s.bytes/1024/1024,1) alloc_mb,
               nvl(round(t.blocks*8192/1024/1024,1),0) used_mb,
               round((s.bytes/1024/1024) - nvl(t.blocks*8192/1024/1024,0),1) waste_mb,
               round(((s.bytes - nvl(t.blocks*8192,0))/s.bytes)*100) waste_pct
        from dba_segments s, dba_tables t
        where s.owner = t.owner
        and s.segment_name = t.table_name
        and s.segment_type = 'TABLE'
        and s.bytes > 10*1024*1024
        and round(((s.bytes - nvl(t.blocks*8192,0))/s.bytes)*100) > 30
        and ${OWNER_FILTER_S}
        and ${TABLE_FILTER_T}
        order by (s.bytes - nvl(t.blocks*8192,0)) desc
        fetch first 15 rows only;
        exit
EOF

        ##DBMS_SPACE.SPACE_USAGE - only for specific table (not ALL)
        if [[ "$FRAG_TABLE" != "ALL" && "$FRAG_OWNER" != "ALL" ]]
        then
            echo ""
            echo -e "===>${CYAN} DBMS_SPACE - BLOCK FREE SPACE DISTRIBUTION BELOW HWM${ENDCOLOR}"

            ##CHECK IF TABLE IS PARTITIONED
            IS_PART=$($ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF
            set heading off feedback off pagesize 0 trimspool on
            ${PDB_CTX}
            select partitioned from dba_tables
            where owner='${FRAG_OWNER}' and table_name='${FRAG_TABLE}';
            exit
EOF
)
            IS_PART=`echo $IS_PART | tr -d ' '`

            if [[ "$IS_PART" == "YES" ]]
            then
                ##SHOW TOP PARTITIONS BY SIZE
                echo -e "===>${CYAN} TOP PARTITIONS BY SIZE FOR ${FRAG_OWNER}.${FRAG_TABLE}${ENDCOLOR}"
                $ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF
                set heading on feedback off pagesize 100 linesize 200 trimout on trimspool on
                ${PDB_CTX}
                column partition_name  format a35    heading 'PARTITION'
                column segment_mb      format 99999.0 heading 'SEGMENT_MB'
                column num_rows        format 9999999999 heading 'NUM_ROWS'
                column last_analyzed   format a20    heading 'LAST_ANALYZED'
                select s.partition_name,
                       round(s.bytes/1024/1024,1)                                            segment_mb,
                       nvl(tp.num_rows,0)                                                    num_rows,
                       nvl(to_char(tp.last_analyzed,'DD-MON-YYYY HH24:MI'),'NEVER')          last_analyzed
                from dba_segments s, dba_tab_partitions tp
                where s.owner = '${FRAG_OWNER}'
                and s.segment_name = '${FRAG_TABLE}'
                and s.segment_type = 'TABLE PARTITION'
                and tp.table_owner(+) = s.owner
                and tp.table_name(+) = s.segment_name
                and tp.partition_name(+) = s.partition_name
                order by s.bytes desc
                fetch first 20 rows only;
                exit
EOF

                ##PROMPT FOR PARTITION NAME
                echo -n "   Enter Partition Name to analyze (or SKIP to skip) : "
                read FRAG_PART
                FRAG_PART=`echo $FRAG_PART | tr '[:lower:]' '[:upper:]'`

                if [[ -z "$FRAG_PART" || "$FRAG_PART" == "SKIP" ]]
                then
                    echo -e "===>${YELLOW} DBMS_SPACE : SKIPPED${ENDCOLOR}"
                else
                    echo ""
                    echo -e "===>${CYAN} DBMS_SPACE ANALYSIS FOR PARTITION : ${FRAG_OWNER}.${FRAG_TABLE} PARTITION(${FRAG_PART})${ENDCOLOR}"
                    $ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF
                    set heading off feedback off pagesize 0 trimspool on serveroutput on size 1000000
                    ${PDB_CTX}
                    declare
                      v_fs1b number; v_fs2b number; v_fs3b number; v_fs4b number;
                      v_fs1k number; v_fs2k number; v_fs3k number; v_fs4k number;
                      v_full_bytes number; v_full_blocks number;
                      v_unf_bytes number; v_unf_blocks number;
                    BEGIN
                      dbms_space.space_usage(
                        segment_owner      => '${FRAG_OWNER}',
                        segment_name       => '${FRAG_TABLE}',
                        segment_type       => 'TABLE PARTITION',
                        fs1_bytes          => v_fs1b,  fs1_blocks => v_fs1k,
                        fs2_bytes          => v_fs2b,  fs2_blocks => v_fs2k,
                        fs3_bytes          => v_fs3b,  fs3_blocks => v_fs3k,
                        fs4_bytes          => v_fs4b,  fs4_blocks => v_fs4k,
                        full_bytes         => v_full_bytes,  full_blocks => v_full_blocks,
                        unformatted_blocks => v_unf_blocks,  unformatted_bytes => v_unf_bytes,
                        partition_name     => '${FRAG_PART}');
                      dbms_output.put_line('');
                      dbms_output.put_line('###############################################');
                      dbms_output.put_line('Free Space Below HWM : ${FRAG_OWNER}.${FRAG_TABLE}(${FRAG_PART})');
                      dbms_output.put_line('###############################################');
                      dbms_output.put_line('Blocks with Free Space (0-25%)   = '||v_fs1k||'  ('||round(v_fs1b/1024/1024,1)||' MB)');
                      dbms_output.put_line('Blocks with Free Space (25-50%)  = '||v_fs2k||'  ('||round(v_fs2b/1024/1024,1)||' MB)');
                      dbms_output.put_line('Blocks with Free Space (50-75%)  = '||v_fs3k||'  ('||round(v_fs3b/1024/1024,1)||' MB)');
                      dbms_output.put_line('Blocks with Free Space (75-100%) = '||v_fs4k||'  ('||round(v_fs4b/1024/1024,1)||' MB)');
                      dbms_output.put_line('Number of Full Blocks             = '||v_full_blocks||'  ('||round(v_full_bytes/1024/1024,1)||' MB)');
                      dbms_output.put_line('Unformatted Blocks                = '||v_unf_blocks||'  ('||round(v_unf_bytes/1024/1024,1)||' MB)');
                      dbms_output.put_line('###############################################');
                      dbms_output.put_line('RECOMMENDATION: Enable row movement and shrink:');
                      dbms_output.put_line('  ALTER TABLE ${FRAG_OWNER}.${FRAG_TABLE} ENABLE ROW MOVEMENT;');
                      dbms_output.put_line('  ALTER TABLE ${FRAG_OWNER}.${FRAG_TABLE} SHRINK SPACE;');
                    END;
                    /
                    exit
EOF
                fi
            else
                ##NON-PARTITIONED TABLE - RUN DIRECTLY
                $ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF
                set heading off feedback off pagesize 0 trimspool on serveroutput on size 1000000
                ${PDB_CTX}
                declare
                  v_fs1b number; v_fs2b number; v_fs3b number; v_fs4b number;
                  v_fs1k number; v_fs2k number; v_fs3k number; v_fs4k number;
                  v_full_bytes number; v_full_blocks number;
                  v_unf_bytes number; v_unf_blocks number;
                BEGIN
                  dbms_space.space_usage(
                    segment_owner      => '${FRAG_OWNER}',
                    segment_name       => '${FRAG_TABLE}',
                    segment_type       => 'TABLE',
                    fs1_bytes          => v_fs1b,  fs1_blocks => v_fs1k,
                    fs2_bytes          => v_fs2b,  fs2_blocks => v_fs2k,
                    fs3_bytes          => v_fs3b,  fs3_blocks => v_fs3k,
                    fs4_bytes          => v_fs4b,  fs4_blocks => v_fs4k,
                    full_bytes         => v_full_bytes,  full_blocks => v_full_blocks,
                    unformatted_blocks => v_unf_blocks,  unformatted_bytes => v_unf_bytes);
                  dbms_output.put_line('');
                  dbms_output.put_line('###############################################');
                  dbms_output.put_line('Free Space Below HWM : ${FRAG_OWNER}.${FRAG_TABLE}');
                  dbms_output.put_line('###############################################');
                  dbms_output.put_line('Blocks with Free Space (0-25%)   = '||v_fs1k||'  ('||round(v_fs1b/1024/1024,1)||' MB)');
                  dbms_output.put_line('Blocks with Free Space (25-50%)  = '||v_fs2k||'  ('||round(v_fs2b/1024/1024,1)||' MB)');
                  dbms_output.put_line('Blocks with Free Space (50-75%)  = '||v_fs3k||'  ('||round(v_fs3b/1024/1024,1)||' MB)');
                  dbms_output.put_line('Blocks with Free Space (75-100%) = '||v_fs4k||'  ('||round(v_fs4b/1024/1024,1)||' MB)');
                  dbms_output.put_line('Number of Full Blocks             = '||v_full_blocks||'  ('||round(v_full_bytes/1024/1024,1)||' MB)');
                  dbms_output.put_line('Unformatted Blocks                = '||v_unf_blocks||'  ('||round(v_unf_bytes/1024/1024,1)||' MB)');
                  dbms_output.put_line('###############################################');
                  dbms_output.put_line('RECOMMENDATION: Enable row movement and shrink:');
                  dbms_output.put_line('  ALTER TABLE ${FRAG_OWNER}.${FRAG_TABLE} ENABLE ROW MOVEMENT;');
                  dbms_output.put_line('  ALTER TABLE ${FRAG_OWNER}.${FRAG_TABLE} SHRINK SPACE;');
                END;
                /
                exit
EOF
            fi
        fi
        echo -e "===>${CYAN} TO RECLAIM : ALTER TABLE <OWNER>.<TABLE> MOVE + REBUILD INDEXES${ENDCOLOR}"
        echo ""
        echo -n "   Check another object? (y/n) : "
        read MORE_FRAG
        [[ "$MORE_FRAG" != "y" && "$MORE_FRAG" != "Y" ]] && break

    done
}


##===========================================================================
##  13. STATS CHECK
##===========================================================================

check_stats() {
    echo ""
    echo -e "===>${CYAN}---------- STATS CHECK ----------${ENDCOLOR}"
    echo -n "   Enter Schema Owner : "
    read STATS_OWNER
    echo -n "   Enter Object Name (table/index, or ALL for all stale/missing in owner) : "
    read STATS_OBJ

    STATS_OWNER=`echo $STATS_OWNER | tr '[:lower:]' '[:upper:]'`
    STATS_OBJ=`echo $STATS_OBJ   | tr '[:lower:]' '[:upper:]'`

    if [[ "$STATS_OBJ" == "ALL" ]]
    then
        OBJ_FILTER="1=1"
        echo ""
        echo -e "===>${CYAN} TABLES WITH MISSING OR STALE STATS FOR OWNER : ${STATS_OWNER}${ENDCOLOR}"
        $ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF
        set heading on feedback off pagesize 100 linesize 180 trimout on trimspool on
        ${PDB_CTX}
        column table_name    format a40  heading 'TABLE'
        column num_rows      format 9999999999 heading 'ROWS'
        column last_analyzed format a22  heading 'LAST_ANALYZED'
        column stale_stats   format a5   heading 'STALE'
        select table_name, nvl(num_rows,0) num_rows,
               nvl(to_char(last_analyzed,'DD-MON-YYYY HH24:MI'),'*** NEVER ***') last_analyzed,
               nvl(stale_stats,'YES') stale_stats
        from dba_tab_statistics
        where owner = '${STATS_OWNER}'
        and (last_analyzed is null or stale_stats = 'YES')
        order by last_analyzed nulls first
        fetch first 30 rows only;
        exit
EOF
    else
        echo ""
        echo -e "===>${CYAN} TABLE STATS FOR : ${STATS_OWNER}.${STATS_OBJ}${ENDCOLOR}"
        $ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF
        set heading on feedback off pagesize 100 linesize 200 trimout on trimspool on
        ${PDB_CTX}
        column owner         format a20  heading 'OWNER'
        column table_name    format a40  heading 'TABLE'
        column num_rows      format 9999999999 heading 'ROWS'
        column blocks        format 9999999 heading 'BLOCKS'
        column avg_row_len   format 9999 heading 'AVG_ROW_LEN'
        column last_analyzed format a22  heading 'LAST_ANALYZED'
        column stale_stats   format a5   heading 'STALE'
        select owner, table_name, nvl(num_rows,0) num_rows,
               nvl(blocks,0) blocks, nvl(avg_row_len,0) avg_row_len,
               nvl(to_char(last_analyzed,'DD-MON-YYYY HH24:MI'),'*** NEVER ***') last_analyzed,
               nvl(stale_stats,'NO') stale_stats
        from dba_tab_statistics
        where owner = '${STATS_OWNER}'
        and table_name = '${STATS_OBJ}';
        exit
EOF

        echo ""
        echo -e "===>${CYAN} PARTITION STATS FOR : ${STATS_OWNER}.${STATS_OBJ} (TOP 20 STALE/MISSING)${ENDCOLOR}"
        PART_CNT=$($ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF
        set heading off feedback off pagesize 0 trimspool on
        ${PDB_CTX}
        select count(*) from dba_tab_statistics where owner='${STATS_OWNER}' and table_name='${STATS_OBJ}' and partition_name is not null;
        exit
EOF
)
        if [[ ${PART_CNT:-0} -gt 0 ]]
        then
            $ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF
            set heading on feedback off pagesize 100 linesize 200 trimout on trimspool on
            ${PDB_CTX}
            column partition_name format a35  heading 'PARTITION'
            column num_rows       format 9999999999 heading 'ROWS'
            column last_analyzed  format a22  heading 'LAST_ANALYZED'
            column stale_stats    format a5   heading 'STALE'
            select partition_name, nvl(num_rows,0) num_rows,
                   nvl(to_char(last_analyzed,'DD-MON-YYYY HH24:MI'),'*** NEVER ***') last_analyzed,
                   nvl(stale_stats,'N/A') stale_stats
            from dba_tab_statistics
            where owner = '${STATS_OWNER}'
            and table_name = '${STATS_OBJ}'
            and partition_name is not null
            and (last_analyzed is null or stale_stats = 'YES')
            order by last_analyzed nulls first
            fetch first 20 rows only;
            exit
EOF
        else
            echo -e "===>${GREEN} PARTITION_STATS : NO PARTITIONS ON THIS TABLE${ENDCOLOR}"
        fi

        echo ""
        echo -e "===>${CYAN} INDEX STATS FOR : ${STATS_OWNER}.${STATS_OBJ}${ENDCOLOR}"
        $ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF
        set heading on feedback off pagesize 100 linesize 200 trimout on trimspool on
        ${PDB_CTX}
        column index_name     format a35  heading 'INDEX'
        column index_type     format a15  heading 'TYPE'
        column leaf_blocks    format 9999999 heading 'LEAF_BLKS'
        column distinct_keys  format 9999999999 heading 'DISTINCT_KEYS'
        column clust_factor   format 9999999999 heading 'CLUST_FACTOR'
        column last_analyzed  format a22  heading 'LAST_ANALYZED'
        column stale_stats    format a5   heading 'STALE'
        select s.index_name, nvl(i.index_type,'N/A') index_type,
               nvl(s.leaf_blocks,0) leaf_blocks,
               nvl(s.distinct_keys,0) distinct_keys,
               nvl(s.clustering_factor,0) clust_factor,
               nvl(to_char(s.last_analyzed,'DD-MON-YYYY HH24:MI'),'*** NEVER ***') last_analyzed,
               nvl(s.stale_stats,'NO') stale_stats
        from dba_ind_statistics s, dba_indexes i
        where s.owner = i.owner(+)
        and s.index_name = i.index_name(+)
        and s.owner = '${STATS_OWNER}'
        and s.table_name = '${STATS_OBJ}'
        order by s.last_analyzed nulls first;
        exit
EOF
    fi
}


##===========================================================================
##  15. PLAN CHANGE DETECTION
##      Realtime  : scans gv$active_session_history for RT_MINS window
##      Historical: scans dba_hist_active_sess_history for snap range
##      Detects SQL_IDs with >1 plan hash value, classifies as:
##        NEW PLAN      - PHV in cursor cache but never in AWR
##        OLD PHV BACK  - PHV in AWR but not in last 6 snap rows (regression)
##===========================================================================

check_plan_changes() {
    echo ""
    echo -e "===>${CYAN}---------- PLAN CHANGE DETECTION | TIME MODE : ${TIME_MODE} ----------${ENDCOLOR}"
    echo -e "===>${YELLOW} Scanning for SQL_IDs with multiple plan hashes in window...${ENDCOLOR}"
    echo ""

    if [[ "$TIME_MODE" == "REALTIME" ]]
    then
        $ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF
        set heading off feedback off pagesize 0 trimspool on serveroutput on size unlimited
        ${PDB_CTX}
        DECLARE
          cnt                  number;
          phv_cursor_execcnt   number;
          phv_awr_execcnt      number;
          any_plan_exists      number;
          latest_phv_awr       number;
        BEGIN
          FOR v_unq_sqlids IN (
            select distinct(sql_id)
            from gv\$active_session_history
            where sample_time > sysdate - ${RT_MINS}/(24*60)
            group by sql_id
            order by sql_id
          )
          LOOP
            select count(distinct(sql_plan_hash_value)) into cnt
            from gv\$active_session_history
            where sample_time > sysdate - ${RT_MINS}/(24*60)
            and sql_id = v_unq_sqlids.sql_id
            and sql_plan_hash_value <> 0;

            IF cnt > 1 THEN
              FOR v_unq_phv IN (
                select distinct(sql_plan_hash_value)
                from gv\$active_session_history
                where sample_time > sysdate - ${RT_MINS}/(24*60)
                and sql_id = v_unq_sqlids.sql_id
                and sql_plan_hash_value <> 0
              )
              LOOP
                select sum(executions) into phv_cursor_execcnt
                from gv\$sql
                where sql_id = v_unq_sqlids.sql_id
                and plan_hash_value = v_unq_phv.sql_plan_hash_value;

                select sum(executions_total) into phv_awr_execcnt
                from dba_hist_sqlstat
                where sql_id = v_unq_sqlids.sql_id
                and plan_hash_value = v_unq_phv.sql_plan_hash_value;

                /* ---- NEW PLAN: in cursor cache but never in AWR ---- */
                IF (phv_cursor_execcnt > 0 and phv_cursor_execcnt is not null and phv_awr_execcnt is null) THEN
                  select count(distinct(plan_hash_value)) into any_plan_exists
                  from dba_hist_sqlstat
                  where sql_id = v_unq_sqlids.sql_id;

                  IF (any_plan_exists > 0 and any_plan_exists is not null) THEN
                    dbms_output.put_line('------------------------------------------------------------------------------------------------------------');
                    dbms_output.put_line('SQL_ID : '||v_unq_sqlids.sql_id||' POTENTIALLY CHANGED PHV TO NEW PHV '||v_unq_phv.sql_plan_hash_value||', PLEASE REVIEW THE OLD/NEW PLAN');
                    FOR r IN (
                      select distinct(plan_hash_value),
                             max(time) last_exec_time,
                             sum(executions) execs,
                             round(avg(avg_elapsed_time),4) avgsec
                      from (
                        select plan_hash_value,
                               to_char(last_active_time,'Mon/DD/YYYY HH24:MI:SS') time,
                               executions,
                               round(elapsed_time/greatest(executions,1)/1000/1000,4) avg_elapsed_time
                        from gv\$sql
                        where sql_id = v_unq_sqlids.sql_id
                        and plan_hash_value = v_unq_phv.sql_plan_hash_value
                        order by time asc
                      )
                      group by plan_hash_value
                    )
                    LOOP
                      dbms_output.put_line('POTENTIAL_CHANGED_NEW_PLAN : '||v_unq_sqlids.sql_id||', PHV : '||r.plan_hash_value||', AVGSECS : '||r.avgsec||', EXECS_TOTAL : '||r.execs);
                    END LOOP;
                    FOR r IN (
                      select plan_hash_value, avgsec, execs
                      from (
                        select distinct(plan_hash_value),
                               round(avg("avgsec"),4) avgsec,
                               sum(executions) execs
                        from (
                          select a.instance_number inst_id, a.snap_id, a.plan_hash_value,
                                 begin_interval_time btime,
                                 abs(extract(minute from (end_interval_time-begin_interval_time)) +
                                     extract(hour from (end_interval_time-begin_interval_time))*60 +
                                     extract(day from (end_interval_time-begin_interval_time))*24*60) minutes,
                                 executions_delta executions,
                                 round(elapsed_time_delta/1000000/greatest(executions_delta,1),4) "avgsec"
                          from dba_hist_sqlstat a, dba_hist_snapshot b
                          where a.sql_id = v_unq_sqlids.sql_id
                          and a.snap_id = b.snap_id
                          and a.instance_number = b.instance_number
                          and a.executions_delta is not null
                          and a.executions_delta > 0
                          order by snap_id, a.instance_number
                        )
                        group by plan_hash_value
                        order by 2
                      )
                      where rownum <= 2
                    )
                    LOOP
                      dbms_output.put_line('TOP_PLAN_BY_AVG_EXEC_TIME : '||v_unq_sqlids.sql_id||', PHV : '||r.plan_hash_value||', AVGSECS : '||r.avgsec||', EXECS_TOTAL : '||r.execs);
                    END LOOP;
                    FOR r IN (
                      select plan_hash_value, avgsec, execs
                      from (
                        select distinct(plan_hash_value),
                               round(avg("avgsec"),4) avgsec,
                               sum(executions) execs
                        from (
                          select a.instance_number inst_id, a.snap_id, a.plan_hash_value,
                                 begin_interval_time btime,
                                 abs(extract(minute from (end_interval_time-begin_interval_time)) +
                                     extract(hour from (end_interval_time-begin_interval_time))*60 +
                                     extract(day from (end_interval_time-begin_interval_time))*24*60) minutes,
                                 executions_delta executions,
                                 round(elapsed_time_delta/1000000/greatest(executions_delta,1),4) "avgsec"
                          from dba_hist_sqlstat a, dba_hist_snapshot b
                          where a.sql_id = v_unq_sqlids.sql_id
                          and a.snap_id = b.snap_id
                          and a.instance_number = b.instance_number
                          and a.executions_delta is not null
                          and a.executions_delta > 0
                          order by snap_id, a.instance_number
                        )
                        group by plan_hash_value
                        order by 3 desc
                      )
                      where rownum <= 2
                    )
                    LOOP
                      dbms_output.put_line('TOP_PLAN_BY_MOST_EXECS : '||v_unq_sqlids.sql_id||', PHV : '||r.plan_hash_value||', AVGSECS : '||r.avgsec||', EXECS_TOTAL : '||r.execs);
                    END LOOP;
                    dbms_output.put_line('------------------------------------------------------------------------------------------------------------');
                  END IF;
                END IF;

                /* ---- OLD PHV BACK: in AWR but not in last 6 snap rows (regression) ---- */
                select sum(executions_total) into phv_awr_execcnt
                from dba_hist_sqlstat
                where sql_id = v_unq_sqlids.sql_id
                and plan_hash_value = v_unq_phv.sql_plan_hash_value
                and executions_total > 10;

                IF (phv_cursor_execcnt > 0 and phv_cursor_execcnt is not null and phv_awr_execcnt is not null) THEN
                  select count(*) into latest_phv_awr
                  from (
                    select distinct(plan_hash_value)
                    from (
                      select plan_hash_value
                      from (
                        select *
                        from (
                          select a.instance_number inst_id, a.snap_id, a.plan_hash_value,
                                 to_char(begin_interval_time,'dd-mon-yy hh24:mi') btime,
                                 abs(extract(minute from (end_interval_time-begin_interval_time)) +
                                     extract(hour from (end_interval_time-begin_interval_time))*60 +
                                     extract(day from (end_interval_time-begin_interval_time))*24*60) minutes,
                                 executions_delta executions,
                                 round(elapsed_time_delta/1000000/greatest(executions_delta,1),4) "avg duration (sec)"
                          from dba_hist_sqlstat a, dba_hist_snapshot b
                          where a.sql_id = v_unq_sqlids.sql_id
                          and a.snap_id = b.snap_id
                          and a.instance_number = b.instance_number
                          order by snap_id desc, a.instance_number desc
                        )
                        where rownum <= 6
                      )
                    )
                  )
                  where plan_hash_value = v_unq_phv.sql_plan_hash_value;

                  IF (latest_phv_awr = 0) THEN
                    dbms_output.put_line('------------------------------------------------------------------------------------------------------------');
                    dbms_output.put_line('SQL_ID : '||v_unq_sqlids.sql_id||' POTENTIALLY CHANGED PHV TO OLD PHV '||v_unq_phv.sql_plan_hash_value||', PLEASE REVIEW BOTH OF THE OLD PLANS');
                    FOR r IN (
                      select distinct(plan_hash_value),
                             max(time) last_exec_time,
                             sum(executions) execs,
                             round(avg(avg_elapsed_time),4) avgsec
                      from (
                        select plan_hash_value,
                               to_char(last_active_time,'Mon/DD/YYYY HH24:MI:SS') time,
                               executions,
                               round(elapsed_time/greatest(executions,1)/1000/1000,4) avg_elapsed_time
                        from gv\$sql
                        where sql_id = v_unq_sqlids.sql_id
                        and plan_hash_value = v_unq_phv.sql_plan_hash_value
                        order by time asc
                      )
                      group by plan_hash_value
                    )
                    LOOP
                      dbms_output.put_line('POTENTIAL_CHANGED_NEW_PLAN : '||v_unq_sqlids.sql_id||', PHV : '||r.plan_hash_value||', AVGSECS : '||r.avgsec||', EXECS_TOTAL : '||r.execs);
                    END LOOP;
                    FOR r IN (
                      select plan_hash_value, avgsec, execs
                      from (
                        select distinct(plan_hash_value),
                               round(avg("avgsec"),4) avgsec,
                               sum(executions) execs
                        from (
                          select a.instance_number inst_id, a.snap_id, a.plan_hash_value,
                                 begin_interval_time btime,
                                 abs(extract(minute from (end_interval_time-begin_interval_time)) +
                                     extract(hour from (end_interval_time-begin_interval_time))*60 +
                                     extract(day from (end_interval_time-begin_interval_time))*24*60) minutes,
                                 executions_delta executions,
                                 round(elapsed_time_delta/1000000/greatest(executions_delta,1),4) "avgsec"
                          from dba_hist_sqlstat a, dba_hist_snapshot b
                          where a.sql_id = v_unq_sqlids.sql_id
                          and a.snap_id = b.snap_id
                          and a.instance_number = b.instance_number
                          and a.executions_delta is not null
                          and a.executions_delta > 0
                          order by snap_id, a.instance_number
                        )
                        group by plan_hash_value
                        order by 2
                      )
                      where rownum <= 2
                    )
                    LOOP
                      dbms_output.put_line('TOP_PLAN_BY_AVG_EXEC_TIME : '||v_unq_sqlids.sql_id||', PHV : '||r.plan_hash_value||', AVGSECS : '||r.avgsec||', EXECS_TOTAL : '||r.execs);
                    END LOOP;
                    FOR r IN (
                      select plan_hash_value, avgsec, execs
                      from (
                        select distinct(plan_hash_value),
                               round(avg("avgsec"),4) avgsec,
                               sum(executions) execs
                        from (
                          select a.instance_number inst_id, a.snap_id, a.plan_hash_value,
                                 begin_interval_time btime,
                                 abs(extract(minute from (end_interval_time-begin_interval_time)) +
                                     extract(hour from (end_interval_time-begin_interval_time))*60 +
                                     extract(day from (end_interval_time-begin_interval_time))*24*60) minutes,
                                 executions_delta executions,
                                 round(elapsed_time_delta/1000000/greatest(executions_delta,1),4) "avgsec"
                          from dba_hist_sqlstat a, dba_hist_snapshot b
                          where a.sql_id = v_unq_sqlids.sql_id
                          and a.snap_id = b.snap_id
                          and a.instance_number = b.instance_number
                          and a.executions_delta is not null
                          and a.executions_delta > 0
                          order by snap_id, a.instance_number
                        )
                        group by plan_hash_value
                        order by 3 desc
                      )
                      where rownum <= 2
                    )
                    LOOP
                      dbms_output.put_line('TOP_PLAN_BY_MOST_EXECS : '||v_unq_sqlids.sql_id||', PHV : '||r.plan_hash_value||', AVGSECS : '||r.avgsec||', EXECS_TOTAL : '||r.execs);
                    END LOOP;
                    dbms_output.put_line('------------------------------------------------------------------------------------------------------------');
                  END IF;
                END IF;

              END LOOP; /* v_unq_phv */
            END IF;
          END LOOP; /* v_unq_sqlids */
          dbms_output.put_line('');
          dbms_output.put_line('===> PLAN_CHANGE_SCAN COMPLETE | WINDOW : LAST ${RT_MINS} MINS');
        END;
        /
        exit
EOF

    else
        ##HISTORICAL - same logic but driven off dba_hist_active_sess_history snap range
        ##Both plan types collapse to: SQL had >1 PHV in the snap window
        ##We compare each PHV against last 6 rows in dba_hist_sqlstat to flag regression
        $ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF
        set heading off feedback off pagesize 0 trimspool on serveroutput on size unlimited
        ${PDB_CTX}
        DECLARE
          cnt                  number;
          phv_awr_execcnt      number;
          any_plan_exists      number;
          latest_phv_awr       number;
        BEGIN
          FOR v_unq_sqlids IN (
            select distinct sql_id
            from dba_hist_active_sess_history
            where snap_id between ${BEGIN_SNAP} and ${END_SNAP}
            and sql_id is not null
            group by sql_id
            order by sql_id
          )
          LOOP
            select count(distinct sql_plan_hash_value) into cnt
            from dba_hist_active_sess_history
            where snap_id between ${BEGIN_SNAP} and ${END_SNAP}
            and sql_id = v_unq_sqlids.sql_id
            and sql_plan_hash_value <> 0;

            IF cnt > 1 THEN
              FOR v_unq_phv IN (
                select distinct sql_plan_hash_value
                from dba_hist_active_sess_history
                where snap_id between ${BEGIN_SNAP} and ${END_SNAP}
                and sql_id = v_unq_sqlids.sql_id
                and sql_plan_hash_value <> 0
              )
              LOOP
                select count(distinct plan_hash_value) into any_plan_exists
                from dba_hist_sqlstat
                where sql_id = v_unq_sqlids.sql_id;

                select nvl(sum(executions_delta),0) into phv_awr_execcnt
                from dba_hist_sqlstat
                where sql_id = v_unq_sqlids.sql_id
                and plan_hash_value = v_unq_phv.sql_plan_hash_value
                and snap_id between ${BEGIN_SNAP} and ${END_SNAP};

                /* Check if this PHV appears in last 6 snap rows globally */
                select count(*) into latest_phv_awr
                from (
                  select distinct plan_hash_value
                  from (
                    select plan_hash_value
                    from (
                      select *
                      from (
                        select a.instance_number inst_id, a.snap_id, a.plan_hash_value,
                               to_char(begin_interval_time,'dd-mon-yy hh24:mi') btime,
                               executions_delta executions,
                               round(elapsed_time_delta/1000000/greatest(executions_delta,1),4) "avg duration (sec)"
                        from dba_hist_sqlstat a, dba_hist_snapshot b
                        where a.sql_id = v_unq_sqlids.sql_id
                        and a.snap_id = b.snap_id
                        and a.instance_number = b.instance_number
                        order by snap_id desc, a.instance_number desc
                      )
                      where rownum <= 6
                    )
                  )
                )
                where plan_hash_value = v_unq_phv.sql_plan_hash_value;

                IF (any_plan_exists > 0) THEN
                  IF (phv_awr_execcnt > 0 and latest_phv_awr = 0) THEN
                    /* PHV active in this window but not in last 6 snaps = regression */
                    dbms_output.put_line('------------------------------------------------------------------------------------------------------------');
                    dbms_output.put_line('SQL_ID : '||v_unq_sqlids.sql_id||' POTENTIALLY CHANGED PHV TO OLD PHV '||v_unq_phv.sql_plan_hash_value||', PLEASE REVIEW BOTH OF THE OLD PLANS');
                  ELSIF (phv_awr_execcnt = 0) THEN
                    /* PHV seen in ASH but no executions in snap range = brand new */
                    dbms_output.put_line('------------------------------------------------------------------------------------------------------------');
                    dbms_output.put_line('SQL_ID : '||v_unq_sqlids.sql_id||' POTENTIALLY CHANGED PHV TO NEW PHV '||v_unq_phv.sql_plan_hash_value||', PLEASE REVIEW THE OLD/NEW PLAN');
                  END IF;

                  IF (phv_awr_execcnt = 0 or latest_phv_awr = 0) THEN
                    FOR r IN (
                      select plan_hash_value, avgsec, execs
                      from (
                        select distinct(plan_hash_value),
                               round(avg("avgsec"),4) avgsec,
                               sum(executions) execs
                        from (
                          select a.instance_number inst_id, a.snap_id, a.plan_hash_value,
                                 begin_interval_time btime,
                                 executions_delta executions,
                                 round(elapsed_time_delta/1000000/greatest(executions_delta,1),4) "avgsec"
                          from dba_hist_sqlstat a, dba_hist_snapshot b
                          where a.sql_id = v_unq_sqlids.sql_id
                          and a.snap_id = b.snap_id
                          and a.instance_number = b.instance_number
                          and a.executions_delta is not null
                          and a.executions_delta > 0
                          order by snap_id, a.instance_number
                        )
                        group by plan_hash_value
                        order by 2
                      )
                      where rownum <= 2
                    )
                    LOOP
                      dbms_output.put_line('TOP_PLAN_BY_AVG_EXEC_TIME : '||v_unq_sqlids.sql_id||', PHV : '||r.plan_hash_value||', AVGSECS : '||r.avgsec||', EXECS_TOTAL : '||r.execs);
                    END LOOP;
                    FOR r IN (
                      select plan_hash_value, avgsec, execs
                      from (
                        select distinct(plan_hash_value),
                               round(avg("avgsec"),4) avgsec,
                               sum(executions) execs
                        from (
                          select a.instance_number inst_id, a.snap_id, a.plan_hash_value,
                                 begin_interval_time btime,
                                 executions_delta executions,
                                 round(elapsed_time_delta/1000000/greatest(executions_delta,1),4) "avgsec"
                          from dba_hist_sqlstat a, dba_hist_snapshot b
                          where a.sql_id = v_unq_sqlids.sql_id
                          and a.snap_id = b.snap_id
                          and a.instance_number = b.instance_number
                          and a.executions_delta is not null
                          and a.executions_delta > 0
                          order by snap_id, a.instance_number
                        )
                        group by plan_hash_value
                        order by 3 desc
                      )
                      where rownum <= 2
                    )
                    LOOP
                      dbms_output.put_line('TOP_PLAN_BY_MOST_EXECS : '||v_unq_sqlids.sql_id||', PHV : '||r.plan_hash_value||', AVGSECS : '||r.avgsec||', EXECS_TOTAL : '||r.execs);
                    END LOOP;
                    dbms_output.put_line('------------------------------------------------------------------------------------------------------------');
                  END IF;
                END IF;

              END LOOP; /* v_unq_phv */
            END IF;
          END LOOP; /* v_unq_sqlids */
          dbms_output.put_line('');
          dbms_output.put_line('===> PLAN_CHANGE_SCAN COMPLETE | WINDOW : ${HIST_START} TO ${HIST_END}');
        END;
        /
        exit
EOF
    fi
}


##===========================================================================
##  16. PIN PLAN HASH VALUE (SQL PLAN MANAGEMENT - SPM BASELINE)
##      1. Prompt for SQL_ID
##      2. Show all known PHVs from AWR + cursor cache with stats
##      3. User picks a row number or types a PHV directly
##      4. Load plan into SPM: tries cursor cache first, falls back to AWR
##      5. Fixes the baseline (FIXED=YES) so optimizer must use it
##===========================================================================

pin_plan_hash() {
    echo ""
    echo -e "===>${CYAN}---------- PIN PLAN HASH VALUE (SPM BASELINE) ----------${ENDCOLOR}"
    echo -n "   Enter SQL_ID : "
    read PIN_SQLID
    PIN_SQLID=`echo $PIN_SQLID | tr -d ' '`

    if [[ -z "$PIN_SQLID" ]]
    then
        echo -e "===>${RED} No SQL_ID entered. Returning to menu.${ENDCOLOR}"
        return
    fi

    echo ""
    echo -e "===>${CYAN} KNOWN PLAN HASH VALUES FOR SQL_ID : ${PIN_SQLID}${ENDCOLOR}"
    echo ""

    ##SHOW ALL PHVs FROM AWR + CURSOR CACHE WITH STATS, NUMBERED FOR SELECTION
    PIN_PHV_LIST=$($ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF
    set heading on feedback off pagesize 100 linesize 220 trimout on trimspool on
    ${PDB_CTX}
    column rowno       format 99         heading '#'
    column source      format a8         heading 'SOURCE'
    column plan_hash   format 9999999999 heading 'PLAN_HASH_VALUE'
    column total_execs format 9999999    heading 'TOTAL_EXECS'
    column avg_secs    format 99990.00   heading 'AVG_SECS'
    column first_seen  format a20        heading 'FIRST_SEEN'
    column last_seen   format a20        heading 'LAST_SEEN'
    column in_cache    format a8         heading 'IN_CACHE'
    select row_number() over (order by last_seen desc) rowno, source, plan_hash, total_execs, avg_secs, first_seen, last_seen, in_cache
    from (
      select 'AWR'                                                                         source,
             a.plan_hash_value                                                             plan_hash,
             sum(a.executions_delta)                                                       total_execs,
             round(sum(a.elapsed_time_delta)/1000000/greatest(sum(a.executions_delta),1),2) avg_secs,
             to_char(min(b.begin_interval_time),'DD-MON-YYYY HH24:MI')                   first_seen,
             to_char(max(b.begin_interval_time),'DD-MON-YYYY HH24:MI')                   last_seen,
             case when exists (
               select 1 from gv\$sql s
               where s.sql_id = a.sql_id
               and s.plan_hash_value = a.plan_hash_value
             ) then 'YES' else 'NO' end                                                   in_cache
      from dba_hist_sqlstat a, dba_hist_snapshot b
      where a.sql_id = '${PIN_SQLID}'
      and a.snap_id = b.snap_id
      and a.instance_number = b.instance_number
      and a.executions_delta > 0
      group by a.plan_hash_value, a.sql_id
      union
      select 'CACHE'                                                                        source,
             s.plan_hash_value                                                              plan_hash,
             sum(s.executions)                                                              total_execs,
             round(sum(s.elapsed_time)/1000000/greatest(sum(s.executions),1),2)            avg_secs,
             to_char(min(s.last_active_time),'DD-MON-YYYY HH24:MI')                       first_seen,
             to_char(max(s.last_active_time),'DD-MON-YYYY HH24:MI')                       last_seen,
             'YES'                                                                          in_cache
      from gv\$sql s
      where s.sql_id = '${PIN_SQLID}'
      and s.plan_hash_value not in (
        select plan_hash_value from dba_hist_sqlstat where sql_id='${PIN_SQLID}'
      )
      group by s.plan_hash_value
    )
    order by last_seen desc;
    exit
EOF
)

    if [[ -z "$PIN_PHV_LIST" ]]
    then
        echo -e "===>${RED} No plan hash values found for SQL_ID : ${PIN_SQLID}${ENDCOLOR}"
        echo -e "===>${YELLOW} SQL_ID may not exist in AWR or cursor cache on this instance.${ENDCOLOR}"
        return
    fi

    echo "$PIN_PHV_LIST"
    echo ""
    echo -e "===>${YELLOW} Enter row # from list above, OR type a plan hash value directly :${ENDCOLOR}"
    echo -n "   Choice : "
    read PIN_CHOICE

    ##IF SHORT NUMBER (<= 3 DIGITS) = ROW NUMBER, ELSE = DIRECT PHV
    if [[ "$PIN_CHOICE" =~ ^[0-9]+$ && ${#PIN_CHOICE} -le 3 ]]
    then
        PIN_PHV=$(echo "$PIN_PHV_LIST" | grep -v '^$\|PLAN_HASH\|^-\|^#' | awk 'NR=='${PIN_CHOICE}'{print $3}')
    else
        PIN_PHV="$PIN_CHOICE"
    fi

    PIN_PHV=`echo $PIN_PHV | tr -d ' '`

    if [[ -z "$PIN_PHV" || ! "$PIN_PHV" =~ ^[0-9]+$ ]]
    then
        echo -e "===>${RED} Invalid plan hash value : ${PIN_PHV}. Returning to menu.${ENDCOLOR}"
        return
    fi

    echo ""
    echo -e "===>${CYAN} Pinning PHV ${PIN_PHV} for SQL_ID ${PIN_SQLID} via SPM baseline...${ENDCOLOR}"

    ##CHECK IF PLAN IS IN CURSOR CACHE
    IN_CACHE=$($ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF
    set heading off feedback off pagesize 0 trimspool on
    ${PDB_CTX}
    select count(*) from gv\$sql
    where sql_id='${PIN_SQLID}' and plan_hash_value=${PIN_PHV};
    exit
EOF
)
    IN_CACHE=`echo $IN_CACHE | tr -d ' '`

    ##GET AWR SNAP RANGE FOR THIS PHV (FIRST + LAST SNAP WHERE IT APPEARS)
    AWR_SNAPS=$($ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF
    set heading off feedback off pagesize 0 trimspool on
    ${PDB_CTX}
    select min(snap_id)||' '||max(snap_id)
    from dba_hist_sqlstat
    where sql_id='${PIN_SQLID}' and plan_hash_value=${PIN_PHV};
    exit
EOF
)
    AWR_BEGIN=`echo $AWR_SNAPS | awk '{print $1}'`
    AWR_END=`echo $AWR_SNAPS | awk '{print $2}'`

    ##STEP 1: LOAD + FIX BASELINE, CAPTURE SQL_HANDLE AND PLAN_NAME AS SHELL VARS
    SPM_RESULT=$($ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF
    set heading off feedback off pagesize 0 trimspool on serveroutput on size 1000000
    ${PDB_CTX}
    DECLARE
      v_plans_loaded   pls_integer := 0;
      v_plans_fixed    pls_integer := 0;
      v_sql_handle     dba_sql_plan_baselines.sql_handle%TYPE;
      v_plan_name      dba_sql_plan_baselines.plan_name%TYPE;
      v_in_cache       number := ${IN_CACHE:-0};
      v_awr_begin      number := nvl(to_number(nullif('${AWR_BEGIN}','')),0);
      v_awr_end        number := nvl(to_number(nullif('${AWR_END}','')),0);
    BEGIN
      IF v_in_cache > 0 THEN
        dbms_output.put_line('SOURCE=CURSOR_CACHE');
        v_plans_loaded := dbms_spm.load_plans_from_cursor_cache(
          sql_id          => '${PIN_SQLID}',
          plan_hash_value => ${PIN_PHV}
        );
      ELSIF v_awr_begin > 0 THEN
        dbms_output.put_line('SOURCE=AWR snap '||v_awr_begin||' to '||v_awr_end);
        v_plans_loaded := dbms_spm.load_plans_from_awr(
          begin_snap   => v_awr_begin,
          end_snap     => v_awr_end,
          basic_filter => 'sql_id = ''${PIN_SQLID}'' and plan_hash_value = ${PIN_PHV}'
        );
      ELSE
        dbms_output.put_line('ERROR=PHV ${PIN_PHV} not found in cursor cache or AWR');
        RETURN;
      END IF;

      dbms_output.put_line('PLANS_LOADED='||v_plans_loaded);

      IF v_plans_loaded = 0 THEN
        dbms_output.put_line('WARNING=0 plans loaded - PHV may have expired from source');
        RETURN;
      END IF;

      FOR r IN (
        select sql_handle, plan_name
        from dba_sql_plan_baselines
        where fixed != 'YES'
        and created >= sysdate - 1/24
        and origin in ('MANUAL-LOAD-FROM-CURSOR-CACHE','MANUAL-LOAD-FROM-AWR')
      )
      LOOP
        v_plans_fixed := v_plans_fixed + dbms_spm.alter_sql_plan_baseline(
          sql_handle      => r.sql_handle,
          plan_name       => r.plan_name,
          attribute_name  => 'fixed',
          attribute_value => 'YES'
        );
        v_sql_handle := r.sql_handle;
        v_plan_name  := r.plan_name;
      END LOOP;

      dbms_output.put_line('PLANS_FIXED='||v_plans_fixed);

      FOR r IN (
        select sql_handle, plan_name, enabled, accepted, fixed, origin,
               to_char(created,'DD-MON-YYYY HH24:MI') created
        from dba_sql_plan_baselines
        where created >= sysdate - 1/24
        and origin in ('MANUAL-LOAD-FROM-CURSOR-CACHE','MANUAL-LOAD-FROM-AWR')
        order by created desc
        fetch first 1 rows only
      )
      LOOP
        dbms_output.put_line('HANDLE='||r.sql_handle);
        dbms_output.put_line('PLANNAME='||r.plan_name);
        dbms_output.put_line('ENABLED='||r.enabled);
        dbms_output.put_line('ACCEPTED='||r.accepted);
        dbms_output.put_line('FIXED='||r.fixed);
        dbms_output.put_line('ORIGIN='||r.origin);
        dbms_output.put_line('CREATED='||r.created);
      END LOOP;
    END;
    /
    exit
EOF
)

    ##PARSE KEY=VALUE OUTPUT INTO SHELL VARS
    SPM_SOURCE=$(echo    "$SPM_RESULT" | grep '^SOURCE='   | cut -d= -f2-)
    SPM_LOADED=$(echo    "$SPM_RESULT" | grep '^PLANS_LOADED=' | cut -d= -f2)
    SPM_FIXED=$(echo     "$SPM_RESULT" | grep '^PLANS_FIXED='  | cut -d= -f2)
    SPM_HANDLE=$(echo    "$SPM_RESULT" | grep '^HANDLE='    | cut -d= -f2)
    SPM_PLANNAME=$(echo  "$SPM_RESULT" | grep '^PLANNAME='  | cut -d= -f2)
    SPM_ENABLED=$(echo   "$SPM_RESULT" | grep '^ENABLED='   | cut -d= -f2)
    SPM_ACCEPTED=$(echo  "$SPM_RESULT" | grep '^ACCEPTED='  | cut -d= -f2)
    SPM_FIXEDF=$(echo    "$SPM_RESULT" | grep '^FIXED='     | cut -d= -f2)
    SPM_ORIGIN=$(echo    "$SPM_RESULT" | grep '^ORIGIN='    | cut -d= -f2)
    SPM_CREATED=$(echo   "$SPM_RESULT" | grep '^CREATED='   | cut -d= -f2)
    SPM_WARN=$(echo      "$SPM_RESULT" | grep '^WARNING=\|^ERROR=' | cut -d= -f2-)

    echo -e "===>${CYAN} SOURCE      : ${SPM_SOURCE}${ENDCOLOR}"
    echo -e "===>${CYAN} PLANS LOADED: ${SPM_LOADED}${ENDCOLOR}"

    if [[ -n "$SPM_WARN" ]]; then
        echo -e "===>${RED} ${SPM_WARN}${ENDCOLOR}"
        return
    fi

    echo -e "===>${CYAN} PLANS FIXED : ${SPM_FIXED}${ENDCOLOR}"
    echo ""
    echo -e "===>${CYAN}---------- SPM BASELINE RESULT ----------${ENDCOLOR}"
    echo "   SQL_ID     : ${PIN_SQLID}"
    echo "   PHV PINNED : ${PIN_PHV}"
    echo "   SQL_HANDLE : ${SPM_HANDLE}"
    echo "   PLAN_NAME  : ${SPM_PLANNAME}"
    echo "   ENABLED    : ${SPM_ENABLED}  |  ACCEPTED : ${SPM_ACCEPTED}  |  FIXED : ${SPM_FIXEDF}"
    echo "   ORIGIN     : ${SPM_ORIGIN}  |  CREATED : ${SPM_CREATED}"
    echo ""

    ##STEP 2: PURGE SQL FROM SHARED POOL ON ALL INSTANCES
    if [[ -n "$SPM_HANDLE" ]]; then
        echo -e "===>${CYAN}---------- PURGING SQL FROM SHARED POOL (ALL INSTANCES) ----------${ENDCOLOR}"
        $ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF
        set heading off feedback off pagesize 0 trimspool on serveroutput on size 1000000
        ${PDB_CTX}
        DECLARE
          v_addr   varchar2(100);
          v_hash   varchar2(100);
          v_purged number := 0;
        BEGIN
          FOR r IN (
            select inst_id, address, hash_value
            from gv\$sqlarea
            where sql_id = '${PIN_SQLID}'
          )
          LOOP
            begin
              sys.dbms_shared_pool.purge(r.address||','||r.hash_value, 'C', 1);
              dbms_output.put_line('===> PURGED from instance '||r.inst_id||' addr='||r.address||' hash='||r.hash_value);
              v_purged := v_purged + 1;
            exception
              when others then
                dbms_output.put_line('===> PURGE FAILED inst '||r.inst_id||' : '||sqlerrm);
            end;
          END LOOP;
          IF v_purged = 0 THEN
            dbms_output.put_line('===> SQL not found in shared pool - already aged out or never cached');
          ELSE
            dbms_output.put_line('===> TOTAL CURSORS PURGED : '||v_purged);
          END IF;
          dbms_output.put_line('===> Next execution will use pinned PHV : ${PIN_PHV}');
        END;
        /
        exit
EOF
    fi

    ##STEP 3: PRINT MANAGEMENT COMMANDS AS CLEAN SINGLE LINES FROM BASH
    echo ""
    echo -e "===>${YELLOW}---------- MANAGEMENT COMMANDS (copy/paste ready) ----------${ENDCOLOR}"
    echo ""
    echo "-- VERIFY:"
    echo "SELECT plan_name, enabled, accepted, fixed, origin, created FROM dba_sql_plan_baselines WHERE sql_handle='${SPM_HANDLE}';"
    echo ""
    echo "-- UNPIN (keep baseline, remove FIXED=YES):"
    echo "declare v number; begin v := dbms_spm.alter_sql_plan_baseline(sql_handle=>'${SPM_HANDLE}', plan_name=>'${SPM_PLANNAME}', attribute_name=>'fixed', attribute_value=>'NO'); dbms_output.put_line('unpinned: '||v); end;"
    echo "/"
    echo ""
    echo "-- DROP BASELINE ENTIRELY:"
    echo "declare v number; begin v := dbms_spm.drop_sql_plan_baseline(sql_handle=>'${SPM_HANDLE}', plan_name=>'${SPM_PLANNAME}'); dbms_output.put_line('dropped: '||v); end;"
    echo "/"
    echo ""
    echo "-- RE-PURGE CURSOR CACHE (if needed):"
    echo "exec sys.dbms_shared_pool.purge('<address>,<hash_value>', 'C', 1);"
    echo "-- (get address+hash from: SELECT address, hash_value FROM gv\$sqlarea WHERE sql_id='${PIN_SQLID}';)"
}


##  MAIN MENU
##  MAIN MENU
##===========================================================================

main_menu() {
    while true
    do
        echo ""
        echo "======================================================="
        echo "   Oracle HC  |  DB: $CURRENT_DB$([ -n "$CURRENT_PDB" ] && echo " / $CURRENT_PDB")  |  Host: $HOST_NAME"
        if [[ "$TIME_MODE" == "REALTIME" ]]
        then
            echo "   Time Mode  : REALTIME  |  Last ${RT_MINS} Mins"
        else
            echo "   Time Mode  : HISTORICAL  |  ${HIST_START} TO ${HIST_END}"
        fi
        echo "======================================================="
        echo "   [1]   Tablespace Check"
        echo "   [2]   ASM Diskgroup Check"
        echo "   [3]   Top Wait Events"
        echo "   [4]   Top SQLs by Wait"
        echo "   [5]   Top Objects by Wait"
        echo "   [6]   Drill Into SQL_ID  (60 Day AWR History)"
        echo "   [7]   Dataguard Check"
        echo "   [8]   FRA Check"
        echo "   [9]   Parameter Drift"
        echo "   [10]  OS Checks"
        echo "   [11]  Alert Log Errors"
        echo "   [12]  Object Fragmentation"
        echo "   [13]  Stats Check"
        echo "   [15]  Plan Change Detection"
        echo "   [16]  Pin Plan Hash Value (SPM Baseline)"
        echo "   [14]  Run All Checks"
        echo "   [t]   Change Time Mode / Window"
        echo "   [d]   Change Database"
        echo "   [q]   Quit"
        echo "======================================================="
        echo -n "   Pick a check : "
        read MENU_CHOICE

        case $MENU_CHOICE in
            1)  check_tablespace ;;
            2)  check_asm ;;
            3)  check_top_waits ;;
            4)  check_top_sqls ;;
            5)  check_top_objects ;;
            6)  drill_sql_id ;;
            7)  check_dataguard ;;
            8)  check_fra ;;
            9)  check_param_drift ;;
            10) check_os ;;
            11) check_alert_log ;;
            12) check_fragmentation ;;
            13) check_stats ;;
            15) check_plan_changes ;;
            16) pin_plan_hash ;;
            14)
                check_tablespace
                check_asm
                check_top_waits
                check_top_sqls
                check_top_objects
                check_dataguard
                check_fra
                check_os
                check_alert_log
                ;;
            t|T) pick_time_mode ;;
            d|D) pick_db && pick_time_mode ;;
            q|Q) echo "  Exiting." && exit 0 ;;
            *)   echo -e "===>${RED} INVALID CHOICE${ENDCOLOR}" ;;
        esac
    done
}


##===========================================================================
##  START
##===========================================================================

pick_db
pick_time_mode
main_menu

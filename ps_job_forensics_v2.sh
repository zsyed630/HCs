#!/bin/bash
# =============================================================================
# ps_job_forensics_v2.sh
# PeopleSoft on Oracle 19c RAC - DBA-side job/process forensics, end to end.
# Written for a DBA with no PeopleSoft admin access: everything is read from
# the database (PS metadata tables + Oracle cursor cache/ASH/AWR).
#
#   ./ps_job_forensics_v2.sh -l <PATTERN>                  # discovery
#   ./ps_job_forensics_v2.sh -j <JOB_OR_PROCESS> [-d DAYS] # full report
#   ./ps_job_forensics_v2.sh -j <NAME> -a                  # + App Engine step SQL
#   ./ps_job_forensics_v2.sh -j <NAME> -t                  # + Tuning Advisor
#
#     -l  list/search PS process + job definitions and recent run history
#     -j  PeopleSoft job or process name (substring, case-insensitive)
#     -d  lookback days for AWR/ASH (default 30, clamped to AWR retention)
#     -o  PeopleSoft owner schema (default SYSADM, or $PS_OWNER)
#     -a  dump static App Engine step SQL from PSAESTMT
#     -t  interactive SQL Tuning Advisor after the report
#
# No DB names hardcoded. Requires Diagnostics Pack; -t requires Tuning Pack.
# =============================================================================

set -u

JOB=""; LIST=""; DAYS=30; PS_OWNER="${PS_OWNER:-SYSADM}"; RUN_STA=0; DUMP_AE=0

usage() {
  cat <<'USAGE'
Usage:
  ps_job_forensics_v2.sh -l <PATTERN>                 discover job/process names
  ps_job_forensics_v2.sh -j <NAME> [-d DAYS] [-o SCHEMA] [-a] [-t]

  -l  search PS_PRCSDEFN / PS_PRCSJOBDEFN / PSPRCSRQST for a name
  -j  PeopleSoft job or process name (substring match)
  -d  lookback days for AWR + ASH (default 30)
  -o  PeopleSoft owner schema (default SYSADM)
  -a  dump App Engine step SQL text from PSAESTMT
  -t  run interactive SQL Tuning Advisor after the report
  -h  this help
USAGE
  exit 1
}

while getopts ":j:l:d:o:ath" opt; do
  case "$opt" in
    j) JOB="$OPTARG" ;;
    l) LIST="$OPTARG" ;;
    d) DAYS="$OPTARG" ;;
    o) PS_OWNER="$OPTARG" ;;
    a) DUMP_AE=1 ;;
    t) RUN_STA=1 ;;
    h) usage ;;
    *) usage ;;
  esac
done

[ -z "$JOB" ] && [ -z "$LIST" ] && usage

if [ -z "${ORACLE_SID:-}" ] || [ -z "${ORACLE_HOME:-}" ]; then
  echo "ERROR: ORACLE_SID / ORACLE_HOME not set. Source your env (. oraenv) first."
  exit 1
fi
export PATH="$ORACLE_HOME/bin:$PATH"

case "$DAYS" in ''|*[!0-9]*) echo "ERROR: -d must be an integer."; exit 1 ;; esac

PS_OWNER_UC=$(printf '%s' "$PS_OWNER" | tr '[:lower:]' '[:upper:]')

TMPD=$(mktemp -d /tmp/psjf.XXXXXX)
trap 'rm -rf "$TMPD"' EXIT

# =============================================================================
# DISCOVERY MODE
# =============================================================================
if [ -n "$LIST" ]; then
  PAT=$(printf '%s' "$LIST" | tr '[:lower:]' '[:upper:]')
  cat > "$TMPD/list.sql" <<'SQLEOF'
SET FEEDBACK OFF VERIFY OFF HEADING ON TAB OFF LINESIZE 220 PAGESIZE 200
DEFINE PAT     = '&1'
DEFINE PSOWNER = '&2'
WHENEVER SQLERROR CONTINUE

PROMPT
PROMPT === PROCESS DEFINITIONS MATCHING "&PAT" ===
COLUMN prcstype FORMAT A20 HEADING 'PRCS_TYPE'
COLUMN prcsname FORMAT A22 HEADING 'PRCS_NAME'
COLUMN runlocation FORMAT A8 HEADING 'RUN_LOC'
COLUMN descr    FORMAT A44 HEADING 'DESCRIPTION'
SELECT d.prcstype, d.prcsname, d.runlocation,
       (SELECT MIN(x.descr) FROM &PSOWNER..ps_prcsdefnxlat x
         WHERE x.prcstype = d.prcstype AND x.prcsname = d.prcsname) AS descr
  FROM &PSOWNER..ps_prcsdefn d
 WHERE UPPER(d.prcsname) LIKE '%&PAT%'
 ORDER BY d.prcstype, d.prcsname;

PROMPT
PROMPT === JOB DEFINITIONS MATCHING "&PAT"  (a PSJob is a container of processes) ===
COLUMN prcsjobname FORMAT A22 HEADING 'JOB_NAME'
COLUMN item_seq    FORMAT 999 HEADING 'SEQ'
COLUMN item_type   FORMAT A20 HEADING 'ITEM_TYPE'
COLUMN item_name   FORMAT A22 HEADING 'ITEM_NAME'
SELECT ji.prcsjobname, ji.prcsjobseq AS item_seq,
       ji.prcstype AS item_type, ji.prcsname AS item_name
  FROM &PSOWNER..ps_prcsjobitem ji
 WHERE UPPER(ji.prcsjobname) LIKE '%&PAT%'
    OR UPPER(ji.prcsname)    LIKE '%&PAT%'
 ORDER BY ji.prcsjobname, ji.prcsjobseq;

PROMPT
PROMPT === RECENT RUNS MATCHING "&PAT"  (last 90 days) ===
COLUMN prcsinstance FORMAT 99999999 HEADING 'PRCS_INST'
COLUMN jobinstance  FORMAT 99999999 HEADING 'JOB_INST'
COLUMN prcsname     FORMAT A22 HEADING 'PRCS_NAME'
COLUMN oprid        FORMAT A12 HEADING 'PS_USER'
COLUMN run_status   FORMAT A13 HEADING 'STATUS'
COLUMN beg_dt       FORMAT A19 HEADING 'BEGIN'
COLUMN run_sec      FORMAT 999,990.9 HEADING 'RUN_SEC'
SELECT r.prcsinstance, r.jobinstance, r.prcsname, r.oprid,
       DECODE(r.runstatus,'1','Cancelled','2','Deleted','3','Error','4','Hold',
                          '5','Queued','6','Initiated','7','Processing',
                          '8','Cancelled','9','Success','10','Not Success',
                          '16','Pending','17','Success/Warn', r.runstatus) AS run_status,
       TO_CHAR(r.begindttm,'YYYY-MM-DD HH24:MI:SS') AS beg_dt,
       ROUND((CAST(r.enddttm AS DATE)-CAST(r.begindttm AS DATE))*86400,1) AS run_sec
  FROM &PSOWNER..psprcsrqst r
 WHERE UPPER(r.prcsname) LIKE '%&PAT%'
   AND r.rundttm >= SYSTIMESTAMP - NUMTODSINTERVAL(90,'DAY')
 ORDER BY r.begindttm DESC NULLS LAST
 FETCH FIRST 40 ROWS ONLY;
EXIT;
SQLEOF
  echo ""
  echo "--- DISCOVERY: pattern '${PAT}' on ${ORACLE_SID} (schema ${PS_OWNER_UC}) ---"
  sqlplus -s "/ as sysdba" @"$TMPD/list.sql" "$PAT" "$PS_OWNER_UC"
  exit 0
fi

JOB_UC=$(printf '%s' "$JOB" | tr '[:lower:]' '[:upper:]')

# =============================================================================
# MAIN REPORT
# =============================================================================
cat > "$TMPD/main.sql" <<'SQLEOF'
SET FEEDBACK OFF VERIFY OFF TRIMSPOOL ON TRIMOUT ON HEADING ON TAB OFF
SET LINESIZE 250 PAGESIZE 200 TIMING OFF SERVEROUTPUT ON SIZE UNLIMITED
SET LONG 200000 LONGCHUNKSIZE 20000
DEFINE JOB     = '&1'
DEFINE DAYS    = &2
DEFINE PSOWNER = '&3'
WHENEVER SQLERROR CONTINUE

PROMPT
PROMPT =========================================================================
PROMPT === 0. TARGET ENVIRONMENT
PROMPT =========================================================================
COLUMN db_name FORMAT A12 HEADING 'DB_NAME'
COLUMN db_unique_name FORMAT A16 HEADING 'DB_UNIQUE_NAME'
COLUMN open_mode FORMAT A12 HEADING 'OPEN_MODE'
COLUMN db_role FORMAT A16 HEADING 'ROLE'
COLUMN rac_nodes FORMAT 999 HEADING 'NODES'
COLUMN awr_ret_days FORMAT 999 HEADING 'AWR_RET_D'
COLUMN eff_window FORMAT 999 HEADING 'WINDOW_D'
SELECT d.name AS db_name, d.db_unique_name, d.open_mode,
       d.database_role AS db_role,
       (SELECT COUNT(*) FROM gv$instance) AS rac_nodes,
       (SELECT EXTRACT(DAY FROM retention) FROM dba_hist_wr_control
         WHERE dbid = d.dbid) AS awr_ret_days,
       LEAST(&DAYS, NVL((SELECT EXTRACT(DAY FROM retention)
                           FROM dba_hist_wr_control WHERE dbid = d.dbid),
                        &DAYS)) AS eff_window
  FROM v$database d;
PROMPT (If WINDOW_D < your -d value, AWR retention is the binding limit.)

PROMPT
PROMPT =========================================================================
PROMPT === 1. JOB DECOMPOSITION - every process name this report will chase
PROMPT =========================================================================
COLUMN pname   FORMAT A24 HEADING 'PROCESS_NAME'
COLUMN ptype   FORMAT A20 HEADING 'PRCS_TYPE'
COLUMN origin  FORMAT A26 HEADING 'HOW_IT_MATCHED'
COLUMN lvl     FORMAT 999 HEADING 'DEPTH'

WITH jobset AS (
  SELECT UPPER('&JOB') pname, 'literal argument' origin, 0 lvl FROM dual
  UNION
  SELECT UPPER(d.prcsname), 'PS_PRCSDEFN name match', 0
    FROM &PSOWNER..ps_prcsdefn d
   WHERE UPPER(d.prcsname) LIKE '%&JOB%'
  UNION
  SELECT UPPER(ji.prcsname), 'child of PSJob', LEVEL
    FROM &PSOWNER..ps_prcsjobitem ji
   START WITH UPPER(ji.prcsjobname) LIKE '%&JOB%'
  CONNECT BY NOCYCLE PRIOR UPPER(ji.prcsname) = UPPER(ji.prcsjobname)
  UNION
  SELECT DISTINCT UPPER(r.prcsname), 'observed in PSPRCSRQST', 0
    FROM &PSOWNER..psprcsrqst r
   WHERE r.rundttm >= SYSTIMESTAMP - NUMTODSINTERVAL(&DAYS,'DAY')
     AND r.jobinstance IN (SELECT j.jobinstance
                             FROM &PSOWNER..psprcsrqst j
                            WHERE UPPER(j.prcsname) LIKE '%&JOB%'
                              AND j.jobinstance > 0)
)
SELECT js.pname,
       (SELECT MIN(d.prcstype) FROM &PSOWNER..ps_prcsdefn d
         WHERE UPPER(d.prcsname) = js.pname) AS ptype,
       MIN(js.origin) AS origin,
       MIN(js.lvl)    AS lvl
  FROM jobset js
 GROUP BY js.pname
 ORDER BY lvl, pname;

PROMPT
PROMPT =========================================================================
PROMPT === 2. RUN HISTORY (parent job + children, last &DAYS days)
PROMPT =========================================================================
COLUMN jobinstance  FORMAT 99999999 HEADING 'JOB_INST'
COLUMN prcsinstance FORMAT 99999999 HEADING 'PRCS_INST'
COLUMN prcsname     FORMAT A22 HEADING 'PRCS_NAME'
COLUMN prcstype     FORMAT A18 HEADING 'PRCS_TYPE'
COLUMN oprid        FORMAT A12 HEADING 'PS_USER'
COLUMN run_status   FORMAT A13 HEADING 'STATUS'
COLUMN servername   FORMAT A10 HEADING 'SERVER'
COLUMN beg_dt       FORMAT A19 HEADING 'BEGIN'
COLUMN end_dt       FORMAT A19 HEADING 'END'
COLUMN run_sec      FORMAT 999,990.9 HEADING 'RUN_SEC'

WITH jobset AS (
  SELECT UPPER('&JOB') pname FROM dual
  UNION
  SELECT UPPER(d.prcsname) FROM &PSOWNER..ps_prcsdefn d
   WHERE UPPER(d.prcsname) LIKE '%&JOB%'
  UNION
  SELECT UPPER(ji.prcsname) FROM &PSOWNER..ps_prcsjobitem ji
   START WITH UPPER(ji.prcsjobname) LIKE '%&JOB%'
  CONNECT BY NOCYCLE PRIOR UPPER(ji.prcsname) = UPPER(ji.prcsjobname)
)
SELECT r.jobinstance, r.prcsinstance, r.prcsname, r.prcstype, r.oprid,
       DECODE(r.runstatus,'1','Cancelled','2','Deleted','3','Error','4','Hold',
                          '5','Queued','6','Initiated','7','Processing',
                          '8','Cancelled','9','Success','10','Not Success',
                          '16','Pending','17','Success/Warn', r.runstatus) AS run_status,
       r.servernamerun AS servername,
       TO_CHAR(r.begindttm,'YYYY-MM-DD HH24:MI:SS') AS beg_dt,
       TO_CHAR(r.enddttm  ,'YYYY-MM-DD HH24:MI:SS') AS end_dt,
       ROUND((CAST(r.enddttm AS DATE)-CAST(r.begindttm AS DATE))*86400,1) AS run_sec
  FROM &PSOWNER..psprcsrqst r
 WHERE UPPER(r.prcsname) IN (SELECT pname FROM jobset)
   AND r.rundttm >= SYSTIMESTAMP - NUMTODSINTERVAL(&DAYS,'DAY')
 ORDER BY r.begindttm DESC NULLS LAST, r.jobinstance, r.prcsinstance
 FETCH FIRST 60 ROWS ONLY;

PROMPT
PROMPT --- runtime variance per process (is it degrading?) ---
COLUMN prcsname FORMAT A24 HEADING 'PRCS_NAME'
COLUMN runs     FORMAT 9,999 HEADING 'RUNS'
COLUMN min_sec  FORMAT 999,990.9 HEADING 'MIN_SEC'
COLUMN avg_sec  FORMAT 999,990.9 HEADING 'AVG_SEC'
COLUMN p90_sec  FORMAT 999,990.9 HEADING 'P90_SEC'
COLUMN max_sec  FORMAT 999,990.9 HEADING 'MAX_SEC'
COLUMN last_sec FORMAT 999,990.9 HEADING 'LAST_SEC'

WITH jobset AS (
  SELECT UPPER('&JOB') pname FROM dual
  UNION
  SELECT UPPER(ji.prcsname) FROM &PSOWNER..ps_prcsjobitem ji
   START WITH UPPER(ji.prcsjobname) LIKE '%&JOB%'
  CONNECT BY NOCYCLE PRIOR UPPER(ji.prcsname) = UPPER(ji.prcsjobname)
  UNION
  SELECT UPPER(d.prcsname) FROM &PSOWNER..ps_prcsdefn d
   WHERE UPPER(d.prcsname) LIKE '%&JOB%'
),
runs AS (
  SELECT r.prcsname,
         (CAST(r.enddttm AS DATE)-CAST(r.begindttm AS DATE))*86400 secs,
         r.begindttm
    FROM &PSOWNER..psprcsrqst r
   WHERE UPPER(r.prcsname) IN (SELECT pname FROM jobset)
     AND r.rundttm >= SYSTIMESTAMP - NUMTODSINTERVAL(&DAYS,'DAY')
     AND r.enddttm IS NOT NULL AND r.begindttm IS NOT NULL
)
SELECT prcsname,
       COUNT(*) runs,
       ROUND(MIN(secs),1) min_sec,
       ROUND(AVG(secs),1) avg_sec,
       ROUND(PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY secs),1) p90_sec,
       ROUND(MAX(secs),1) max_sec,
       ROUND(MAX(secs) KEEP (DENSE_RANK LAST ORDER BY begindttm),1) last_sec
  FROM runs
 GROUP BY prcsname
 ORDER BY avg_sec DESC;

PROMPT
PROMPT =========================================================================
PROMPT === 3. LIVE SESSIONS + RUNNING SQL (real-time, all RAC nodes)
PROMPT =========================================================================
COLUMN inst_id FORMAT 999 HEADING 'NODE'
COLUMN sid_serial FORMAT A14 HEADING 'SID,SERIAL#'
COLUMN oprid FORMAT A12 HEADING 'PS_USER'
COLUMN prcsinst FORMAT 99999999 HEADING 'PRCS_INST'
COLUMN sql_id FORMAT A14 HEADING 'SQL_ID'
COLUMN phv FORMAT 9999999999 HEADING 'PLAN_HASH'
COLUMN sess_state FORMAT A10 HEADING 'STATE'
COLUMN event FORMAT A28 HEADING 'WAIT_EVENT'
COLUMN elapsed_sec FORMAT 999,990.99 HEADING 'ELAPSED_S'
COLUMN cpu_sec FORMAT 999,990.99 HEADING 'CPU_S'
COLUMN io_sec FORMAT 999,990.99 HEADING 'IO_S'
COLUMN opt_cost FORMAT 999,999,999 HEADING 'OPT_COST'
COLUMN sql_preview FORMAT A45 HEADING 'SQL_TEXT_PREVIEW'

WITH jobset AS (
  SELECT UPPER('&JOB') pname FROM dual
  UNION
  SELECT UPPER(ji.prcsname) FROM &PSOWNER..ps_prcsjobitem ji
   START WITH UPPER(ji.prcsjobname) LIKE '%&JOB%'
  CONNECT BY NOCYCLE PRIOR UPPER(ji.prcsname) = UPPER(ji.prcsjobname)
  UNION
  SELECT UPPER(d.prcsname) FROM &PSOWNER..ps_prcsdefn d
   WHERE UPPER(d.prcsname) LIKE '%&JOB%'
),
livepid AS (
  SELECT TO_CHAR(p.prcsinstance) pid, p.prcsinstance, p.oprid
    FROM &PSOWNER..psprcsrqst p
   WHERE p.runstatus IN ('6','7')
     AND UPPER(p.prcsname) IN (SELECT pname FROM jobset)
)
SELECT s.inst_id,
       s.sid || ',' || s.serial# AS sid_serial,
       lp.oprid,
       lp.prcsinstance AS prcsinst,
       s.sql_id,
       q.plan_hash_value AS phv,
       s.state AS sess_state,
       s.event,
       ROUND(q.elapsed_time/1e6,2)      AS elapsed_sec,
       ROUND(q.cpu_time/1e6,2)          AS cpu_sec,
       ROUND(q.user_io_wait_time/1e6,2) AS io_sec,
       q.optimizer_cost AS opt_cost,
       SUBSTR(REGEXP_REPLACE(q.sql_text,'[[:space:]]+',' '),1,45) AS sql_preview
  FROM gv$session s
  JOIN gv$sql q
    ON q.sql_id = s.sql_id AND q.inst_id = s.inst_id
   AND q.child_number = s.sql_child_number
  LEFT JOIN livepid lp
    ON UPPER(s.module) LIKE '%'||lp.pid||'%'
    OR UPPER(s.action) LIKE '%'||lp.pid||'%'
    OR UPPER(s.client_info) LIKE '%'||lp.pid||'%'
 WHERE s.status = 'ACTIVE'
   AND s.sql_id IS NOT NULL
   AND ( lp.pid IS NOT NULL
         OR EXISTS (SELECT 1 FROM jobset j
                     WHERE UPPER(s.module)      LIKE '%'||j.pname||'%'
                        OR UPPER(s.action)      LIKE '%'||j.pname||'%'
                        OR UPPER(s.client_info) LIKE '%'||j.pname||'%'
                        OR UPPER(s.program)     LIKE '%'||j.pname||'%') )
 ORDER BY elapsed_sec DESC;

PROMPT
PROMPT =========================================================================
PROMPT === 4. SQL INVENTORY FOR THE JOB (cursor cache + ASH mem + ASH hist + AWR)
PROMPT =========================================================================
COLUMN sql_id FORMAT A14 HEADING 'SQL_ID'
COLUMN phv FORMAT 9999999999 HEADING 'PLAN_HASH'
COLUMN sources FORMAT A26 HEADING 'SEEN_IN'
COLUMN first_seen FORMAT A19 HEADING 'FIRST_SEEN'
COLUMN last_seen FORMAT A19 HEADING 'LAST_SEEN'
COLUMN sql_preview FORMAT A64 HEADING 'SQL_TEXT_PREVIEW'

WITH jobset AS (
  SELECT UPPER('&JOB') pname FROM dual
  UNION
  SELECT UPPER(ji.prcsname) FROM &PSOWNER..ps_prcsjobitem ji
   START WITH UPPER(ji.prcsjobname) LIKE '%&JOB%'
  CONNECT BY NOCYCLE PRIOR UPPER(ji.prcsname) = UPPER(ji.prcsjobname)
  UNION
  SELECT UPPER(d.prcsname) FROM &PSOWNER..ps_prcsdefn d
   WHERE UPPER(d.prcsname) LIKE '%&JOB%'
),
pids AS (
  SELECT DISTINCT TO_CHAR(r.prcsinstance) pid
    FROM &PSOWNER..psprcsrqst r
   WHERE UPPER(r.prcsname) IN (SELECT pname FROM jobset)
     AND r.rundttm >= SYSTIMESTAMP - NUMTODSINTERVAL(&DAYS,'DAY')
),
raw AS (
  SELECT q.sql_id, q.plan_hash_value phv, 'CURSOR' src, CAST(NULL AS DATE) ts
    FROM gv$sql q
   WHERE EXISTS (SELECT 1 FROM jobset j
                  WHERE UPPER(q.module) LIKE '%'||j.pname||'%'
                     OR UPPER(q.action) LIKE '%'||j.pname||'%')
      OR EXISTS (SELECT 1 FROM pids
                  WHERE UPPER(q.module) LIKE '%'||pids.pid||'%'
                     OR UPPER(q.action) LIKE '%'||pids.pid||'%')
  UNION ALL
  SELECT a.sql_id, a.sql_plan_hash_value, 'ASH_MEM', CAST(a.sample_time AS DATE)
    FROM gv$active_session_history a
   WHERE a.sql_id IS NOT NULL
     AND ( EXISTS (SELECT 1 FROM jobset j
                    WHERE UPPER(a.module)    LIKE '%'||j.pname||'%'
                       OR UPPER(a.action)    LIKE '%'||j.pname||'%'
                       OR UPPER(a.client_id) LIKE '%'||j.pname||'%')
        OR EXISTS (SELECT 1 FROM pids
                    WHERE UPPER(a.module)    LIKE '%'||pids.pid||'%'
                       OR UPPER(a.action)    LIKE '%'||pids.pid||'%'
                       OR UPPER(a.client_id) LIKE '%'||pids.pid||'%') )
  UNION ALL
  SELECT h.sql_id, h.sql_plan_hash_value, 'ASH_HIST', CAST(h.sample_time AS DATE)
    FROM dba_hist_active_sess_history h
   WHERE h.sql_id IS NOT NULL
     AND h.sample_time >= SYSTIMESTAMP - NUMTODSINTERVAL(&DAYS,'DAY')
     AND ( EXISTS (SELECT 1 FROM jobset j
                    WHERE UPPER(h.module)    LIKE '%'||j.pname||'%'
                       OR UPPER(h.action)    LIKE '%'||j.pname||'%'
                       OR UPPER(h.client_id) LIKE '%'||j.pname||'%')
        OR EXISTS (SELECT 1 FROM pids
                    WHERE UPPER(h.module)    LIKE '%'||pids.pid||'%'
                       OR UPPER(h.action)    LIKE '%'||pids.pid||'%'
                       OR UPPER(h.client_id) LIKE '%'||pids.pid||'%') )
  UNION ALL
  SELECT st.sql_id, st.plan_hash_value, 'AWR_SQLSTAT',
         CAST(sn.end_interval_time AS DATE)
    FROM dba_hist_sqlstat st
    JOIN dba_hist_snapshot sn
      ON sn.snap_id = st.snap_id AND sn.dbid = st.dbid
     AND sn.instance_number = st.instance_number
   WHERE sn.end_interval_time >= SYSTIMESTAMP - NUMTODSINTERVAL(&DAYS,'DAY')
     AND ( EXISTS (SELECT 1 FROM jobset j
                    WHERE UPPER(st.module) LIKE '%'||j.pname||'%'
                       OR UPPER(st.action) LIKE '%'||j.pname||'%')
        OR EXISTS (SELECT 1 FROM pids
                    WHERE UPPER(st.module) LIKE '%'||pids.pid||'%'
                       OR UPPER(st.action) LIKE '%'||pids.pid||'%') )
)
SELECT r.sql_id, r.phv,
       LISTAGG(DISTINCT r.src, ',') WITHIN GROUP (ORDER BY r.src) AS sources,
       TO_CHAR(MIN(r.ts),'YYYY-MM-DD HH24:MI:SS') AS first_seen,
       TO_CHAR(MAX(r.ts),'YYYY-MM-DD HH24:MI:SS') AS last_seen,
       SUBSTR(REGEXP_REPLACE(
         NVL((SELECT MIN(t.sql_text) FROM gv$sql t WHERE t.sql_id = r.sql_id),
             (SELECT MIN(TO_CHAR(SUBSTR(x.sql_text,1,200)))
                FROM dba_hist_sqltext x WHERE x.sql_id = r.sql_id)),
         '[[:space:]]+',' '),1,64) AS sql_preview
  FROM raw r
 GROUP BY r.sql_id, r.phv
 ORDER BY r.sql_id, r.phv;

PROMPT
PROMPT =========================================================================
PROMPT === 5. HISTORICAL COST PER SQL_ID / PLAN  (AWR, last &DAYS days)
PROMPT =========================================================================
COLUMN sql_id FORMAT A14 HEADING 'SQL_ID'
COLUMN phv FORMAT 9999999999 HEADING 'PLAN_HASH'
COLUMN node FORMAT 999 HEADING 'NODE'
COLUMN execs FORMAT 999,999,999 HEADING 'EXECS'
COLUMN avg_elap_sec FORMAT 999,990.99 HEADING 'AVG_ELAP_S'
COLUMN avg_cpu_sec FORMAT 999,990.99 HEADING 'AVG_CPU_S'
COLUMN avg_io_sec FORMAT 999,990.99 HEADING 'AVG_IO_S'
COLUMN tot_elap_sec FORMAT 999,999,990.9 HEADING 'TOT_ELAP_S'
COLUMN avg_bgets FORMAT 999,999,999 HEADING 'AVG_BUF_GETS'
COLUMN avg_preads FORMAT 999,999,999 HEADING 'AVG_DISK_RD'
COLUMN avg_rows FORMAT 999,999,999 HEADING 'AVG_ROWS'
COLUMN opt_cost FORMAT 999,999,999 HEADING 'OPT_COST'

WITH jobset AS (
  SELECT UPPER('&JOB') pname FROM dual
  UNION
  SELECT UPPER(ji.prcsname) FROM &PSOWNER..ps_prcsjobitem ji
   START WITH UPPER(ji.prcsjobname) LIKE '%&JOB%'
  CONNECT BY NOCYCLE PRIOR UPPER(ji.prcsname) = UPPER(ji.prcsjobname)
  UNION
  SELECT UPPER(d.prcsname) FROM &PSOWNER..ps_prcsdefn d
   WHERE UPPER(d.prcsname) LIKE '%&JOB%'
),
pids AS (
  SELECT DISTINCT TO_CHAR(r.prcsinstance) pid
    FROM &PSOWNER..psprcsrqst r
   WHERE UPPER(r.prcsname) IN (SELECT pname FROM jobset)
     AND r.rundttm >= SYSTIMESTAMP - NUMTODSINTERVAL(&DAYS,'DAY')
)
SELECT st.sql_id, st.plan_hash_value AS phv, st.instance_number AS node,
       SUM(st.executions_delta) AS execs,
       ROUND(SUM(st.elapsed_time_delta)/1e6/GREATEST(SUM(st.executions_delta),1),2) AS avg_elap_sec,
       ROUND(SUM(st.cpu_time_delta)/1e6/GREATEST(SUM(st.executions_delta),1),2)     AS avg_cpu_sec,
       ROUND(SUM(st.iowait_delta)/1e6/GREATEST(SUM(st.executions_delta),1),2)       AS avg_io_sec,
       ROUND(SUM(st.elapsed_time_delta)/1e6,1) AS tot_elap_sec,
       ROUND(SUM(st.buffer_gets_delta)/GREATEST(SUM(st.executions_delta),1))    AS avg_bgets,
       ROUND(SUM(st.disk_reads_delta)/GREATEST(SUM(st.executions_delta),1))     AS avg_preads,
       ROUND(SUM(st.rows_processed_delta)/GREATEST(SUM(st.executions_delta),1)) AS avg_rows,
       MAX(st.optimizer_cost) AS opt_cost
  FROM dba_hist_sqlstat st
  JOIN dba_hist_snapshot sn
    ON sn.snap_id = st.snap_id AND sn.dbid = st.dbid
   AND sn.instance_number = st.instance_number
 WHERE sn.end_interval_time >= SYSTIMESTAMP - NUMTODSINTERVAL(&DAYS,'DAY')
   AND ( EXISTS (SELECT 1 FROM jobset j
                  WHERE UPPER(st.module) LIKE '%'||j.pname||'%'
                     OR UPPER(st.action) LIKE '%'||j.pname||'%')
      OR EXISTS (SELECT 1 FROM pids
                  WHERE UPPER(st.module) LIKE '%'||pids.pid||'%'
                     OR UPPER(st.action) LIKE '%'||pids.pid||'%') )
 GROUP BY st.sql_id, st.plan_hash_value, st.instance_number
HAVING SUM(st.elapsed_time_delta) > 0
 ORDER BY tot_elap_sec DESC
 FETCH FIRST 40 ROWS ONLY;

PROMPT
PROMPT --- 5b. PLAN INSTABILITY (same SQL_ID, more than one plan) ---
COLUMN sql_id FORMAT A14 HEADING 'SQL_ID'
COLUMN plans FORMAT 999 HEADING 'PLANS'
COLUMN best_phv FORMAT 9999999999 HEADING 'BEST_PLAN'
COLUMN best_sec FORMAT 999,990.99 HEADING 'BEST_AVG_S'
COLUMN worst_phv FORMAT 9999999999 HEADING 'WORST_PLAN'
COLUMN worst_sec FORMAT 999,990.99 HEADING 'WORST_AVG_S'
COLUMN regress_x FORMAT 9,990.9 HEADING 'REGRESS_X'

WITH jobset AS (
  SELECT UPPER('&JOB') pname FROM dual
  UNION
  SELECT UPPER(ji.prcsname) FROM &PSOWNER..ps_prcsjobitem ji
   START WITH UPPER(ji.prcsjobname) LIKE '%&JOB%'
  CONNECT BY NOCYCLE PRIOR UPPER(ji.prcsname) = UPPER(ji.prcsjobname)
  UNION
  SELECT UPPER(d.prcsname) FROM &PSOWNER..ps_prcsdefn d
   WHERE UPPER(d.prcsname) LIKE '%&JOB%'
),
perplan AS (
  SELECT st.sql_id, st.plan_hash_value phv,
         SUM(st.elapsed_time_delta)/1e6/GREATEST(SUM(st.executions_delta),1) avg_sec
    FROM dba_hist_sqlstat st
    JOIN dba_hist_snapshot sn
      ON sn.snap_id = st.snap_id AND sn.dbid = st.dbid
     AND sn.instance_number = st.instance_number
   WHERE sn.end_interval_time >= SYSTIMESTAMP - NUMTODSINTERVAL(&DAYS,'DAY')
     AND st.plan_hash_value > 0
     AND EXISTS (SELECT 1 FROM jobset j
                  WHERE UPPER(st.module) LIKE '%'||j.pname||'%'
                     OR UPPER(st.action) LIKE '%'||j.pname||'%')
   GROUP BY st.sql_id, st.plan_hash_value
   HAVING SUM(st.executions_delta) > 0
)
SELECT sql_id, COUNT(*) plans,
       MIN(phv) KEEP (DENSE_RANK FIRST ORDER BY avg_sec) best_phv,
       ROUND(MIN(avg_sec),2) best_sec,
       MIN(phv) KEEP (DENSE_RANK LAST ORDER BY avg_sec) worst_phv,
       ROUND(MAX(avg_sec),2) worst_sec,
       ROUND(MAX(avg_sec)/GREATEST(MIN(avg_sec),0.01),1) regress_x
  FROM perplan
 GROUP BY sql_id
HAVING COUNT(*) > 1
 ORDER BY regress_x DESC;

PROMPT
PROMPT =========================================================================
PROMPT === 6. OBJECTS TOUCHED + STATS FRESHNESS
PROMPT =========================================================================
COLUMN obj_name FORMAT A46 HEADING 'OBJECT'
COLUMN obj_type FORMAT A10 HEADING 'TYPE'
COLUMN access_path FORMAT A26 HEADING 'ACCESS_PATH'
COLUMN num_rows FORMAT 999,999,999,999 HEADING 'NUM_ROWS'
COLUMN last_analyzed FORMAT A19 HEADING 'LAST_ANALYZED'
COLUMN stale FORMAT A6 HEADING 'STALE'

WITH jobset AS (
  SELECT UPPER('&JOB') pname FROM dual
  UNION
  SELECT UPPER(ji.prcsname) FROM &PSOWNER..ps_prcsjobitem ji
   START WITH UPPER(ji.prcsjobname) LIKE '%&JOB%'
  CONNECT BY NOCYCLE PRIOR UPPER(ji.prcsname) = UPPER(ji.prcsjobname)
  UNION
  SELECT UPPER(d.prcsname) FROM &PSOWNER..ps_prcsdefn d
   WHERE UPPER(d.prcsname) LIKE '%&JOB%'
),
sqlset AS (
  SELECT DISTINCT sql_id FROM (
    SELECT q.sql_id FROM gv$sql q
     WHERE EXISTS (SELECT 1 FROM jobset j
                    WHERE UPPER(q.module) LIKE '%'||j.pname||'%'
                       OR UPPER(q.action) LIKE '%'||j.pname||'%')
    UNION
    SELECT h.sql_id FROM dba_hist_active_sess_history h
     WHERE h.sample_time >= SYSTIMESTAMP - NUMTODSINTERVAL(&DAYS,'DAY')
       AND h.sql_id IS NOT NULL
       AND EXISTS (SELECT 1 FROM jobset j
                    WHERE UPPER(h.module)    LIKE '%'||j.pname||'%'
                       OR UPPER(h.action)    LIKE '%'||j.pname||'%'
                       OR UPPER(h.client_id) LIKE '%'||j.pname||'%')
    UNION
    SELECT st.sql_id FROM dba_hist_sqlstat st
      JOIN dba_hist_snapshot sn
        ON sn.snap_id = st.snap_id AND sn.dbid = st.dbid
       AND sn.instance_number = st.instance_number
     WHERE sn.end_interval_time >= SYSTIMESTAMP - NUMTODSINTERVAL(&DAYS,'DAY')
       AND EXISTS (SELECT 1 FROM jobset j
                    WHERE UPPER(st.module) LIKE '%'||j.pname||'%'
                       OR UPPER(st.action) LIKE '%'||j.pname||'%')
  )
),
plans AS (
  SELECT p.object_owner owner, p.object_name name, p.object_type otype,
         p.operation||' '||NVL(p.options,' ') path
    FROM gv$sql_plan p
   WHERE p.object_owner IS NOT NULL
     AND p.sql_id IN (SELECT sql_id FROM sqlset)
  UNION
  SELECT hp.object_owner, hp.object_name, hp.object_type,
         hp.operation||' '||NVL(hp.options,' ')
    FROM dba_hist_sql_plan hp
   WHERE hp.object_owner IS NOT NULL
     AND hp.sql_id IN (SELECT sql_id FROM sqlset)
)
SELECT pl.owner||'.'||pl.name AS obj_name,
       MAX(pl.otype) AS obj_type,
       LISTAGG(DISTINCT TRIM(pl.path),'; ') WITHIN GROUP (ORDER BY TRIM(pl.path)) AS access_path,
       ts.num_rows,
       TO_CHAR(ts.last_analyzed,'YYYY-MM-DD HH24:MI:SS') AS last_analyzed,
       ts.stale_stats AS stale
  FROM plans pl
  LEFT JOIN dba_tab_statistics ts
    ON ts.owner = pl.owner AND ts.table_name = pl.name
   AND ts.object_type IN ('TABLE','PARTITION')
 GROUP BY pl.owner, pl.name, ts.num_rows, ts.last_analyzed, ts.stale_stats
 ORDER BY ts.last_analyzed NULLS FIRST, obj_name;

PROMPT
PROMPT =========================================================================
PROMPT Report complete.
PROMPT =========================================================================
EXIT;
SQLEOF

echo ""
echo "--------------------------------------------------------------------------"
echo " PS JOB FORENSICS v2 | SID: ${ORACLE_SID} | JOB: ${JOB_UC} | WINDOW: ${DAYS}d"
echo " PS owner schema: ${PS_OWNER_UC}"
echo "--------------------------------------------------------------------------"

sqlplus -s "/ as sysdba" @"$TMPD/main.sql" "$JOB_UC" "$DAYS" "$PS_OWNER_UC"

# =============================================================================
# APP ENGINE STATIC STEP SQL  (-a)
# =============================================================================
if [ "$DUMP_AE" -eq 1 ]; then
  cat > "$TMPD/ae.sql" <<'SQLEOF'
SET FEEDBACK OFF VERIFY OFF HEADING ON TAB OFF LINESIZE 200 PAGESIZE 5000
SET LONG 200000 LONGCHUNKSIZE 20000
DEFINE JOB = '&1'
DEFINE PSOWNER = '&2'
WHENEVER SQLERROR CONTINUE

PROMPT
PROMPT =========================================================================
PROMPT === APP ENGINE STATIC STEP SQL (PSAESTMT) - what the program WILL run
PROMPT =========================================================================
COLUMN ae_applid   FORMAT A18 HEADING 'AE_PROGRAM'
COLUMN ae_section  FORMAT A18 HEADING 'SECTION'
COLUMN ae_step     FORMAT A14 HEADING 'STEP'
COLUMN ae_stmt_type FORMAT A6 HEADING 'TYPE'
COLUMN ae_stmt_text FORMAT A120 HEADING 'STATEMENT'

SELECT s.ae_applid, s.ae_section, s.ae_step, s.ae_stmt_type, s.ae_stmt_text
  FROM &PSOWNER..psaestmt s
 WHERE UPPER(s.ae_applid) LIKE '%&JOB%'
 ORDER BY s.ae_applid, s.ae_section, s.ae_step, s.ae_seq_num;
EXIT;
SQLEOF
  sqlplus -s "/ as sysdba" @"$TMPD/ae.sql" "$JOB_UC" "$PS_OWNER_UC"
fi

# =============================================================================
# SQL TUNING ADVISOR  (-t)
# =============================================================================
[ "$RUN_STA" -eq 0 ] && exit 0

echo ""
echo "=========================================================================="
echo " SQL TUNING ADVISOR  (requires Oracle Tuning Pack license)"
echo "=========================================================================="
read -r -p "Run the SQL Tuning Advisor now? (y/n): " ANS
case "$ANS" in [Yy]*) ;; *) echo "Skipped."; exit 0 ;; esac

read -r -p "Enter TARGET SQL_ID: " TARGET_SQL_ID
[ -z "$TARGET_SQL_ID" ] && { echo "ERROR: SQL_ID cannot be empty."; exit 1; }

echo ""
echo "Source for the SQL text:"
echo "  1) Cursor cache (real-time)"
echo "  2) AWR repository (historical)"
read -r -p "Choose 1 or 2: " SOURCE_OPT

PLAN_FILTER=""
[ "$SOURCE_OPT" = "2" ] && read -r -p "Restrict to a PLAN_HASH_VALUE? (blank = all): " PLAN_FILTER

TASK_NAME="STA_${TARGET_SQL_ID}_$$"

cat > "$TMPD/sta.sql" <<'SQLEOF'
SET SERVEROUTPUT ON SIZE UNLIMITED
SET LONG 5000000 LONGCHUNKSIZE 5000 PAGESIZE 0 LINESIZE 200 FEEDBACK OFF VERIFY OFF
WHENEVER SQLERROR EXIT FAILURE
DEFINE TSQL = '&1'
DEFINE TASK = '&2'
DEFINE SRC  = '&3'
DEFINE PHV  = '&4'

DECLARE
  v_exists NUMBER;
  v_task   VARCHAR2(128);
  v_beg    NUMBER;
  v_end    NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_exists FROM dba_advisor_tasks WHERE task_name = '&TASK';
  IF v_exists > 0 THEN
    DBMS_SQLTUNE.DROP_TUNING_TASK(task_name => '&TASK');
  END IF;

  IF '&SRC' = '1' THEN
    v_task := DBMS_SQLTUNE.CREATE_TUNING_TASK(
                sql_id      => '&TSQL',
                task_name   => '&TASK',
                scope       => DBMS_SQLTUNE.scope_comprehensive,
                time_limit  => 1800,
                description => 'STA from cursor cache - ps_job_forensics');
    DBMS_OUTPUT.PUT_LINE('Task created from cursor cache.');
  ELSE
    SELECT MIN(snap_id), MAX(snap_id) INTO v_beg, v_end
      FROM dba_hist_sqlstat
     WHERE sql_id = '&TSQL'
       AND ('&PHV' IS NULL OR TO_CHAR(plan_hash_value) = '&PHV');
    IF v_beg IS NULL THEN
      DBMS_OUTPUT.PUT_LINE('No AWR snapshots hold SQL_ID &TSQL. Aborting.');
      RETURN;
    END IF;
    v_task := DBMS_SQLTUNE.CREATE_TUNING_TASK(
                begin_snap  => v_beg,
                end_snap    => v_end,
                sql_id      => '&TSQL',
                task_name   => '&TASK',
                scope       => DBMS_SQLTUNE.scope_comprehensive,
                time_limit  => 1800,
                description => 'STA from AWR - ps_job_forensics');
    DBMS_OUTPUT.PUT_LINE('Task created from AWR snaps '||v_beg||'-'||v_end||'.');
  END IF;

  DBMS_SQLTUNE.EXECUTE_TUNING_TASK(task_name => '&TASK');
  DBMS_OUTPUT.PUT_LINE('Execution complete.');
END;
/

PROMPT
PROMPT =========================================================================
PROMPT === SQL TUNING ADVISOR REPORT: &TASK
PROMPT =========================================================================
SELECT DBMS_SQLTUNE.REPORT_TUNING_TASK('&TASK') FROM dual;

BEGIN
  DBMS_SQLTUNE.DROP_TUNING_TASK(task_name => '&TASK');
EXCEPTION WHEN OTHERS THEN NULL;
END;
/
EXIT;
SQLEOF

sqlplus -s "/ as sysdba" @"$TMPD/sta.sql" "$TARGET_SQL_ID" "$TASK_NAME" "$SOURCE_OPT" "$PLAN_FILTER"
exit 0

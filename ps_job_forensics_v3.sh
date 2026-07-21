#!/bin/bash
# =============================================================================
# ps_job_forensics_v3.sh
# PeopleSoft on Oracle 19c RAC - DBA-side job forensics.
#
# v3 performance model:
#   Run windows come from PSPRCSRQST first, are converted to per-run snap_id
#   ranges, and every AWR/ASH read is bounded by BOTH snap_id (partition
#   pruning) and sample_time (selectivity). The SQL_ID set is derived once
#   into a private temporary table and reused. No unbounded DBA_HIST scans,
#   no double-sided LIKE in a hot predicate.
#
#   ./ps_job_forensics_v3.sh -l <PATTERN>                discovery
#   ./ps_job_forensics_v3.sh -j <NAME> [-d DAYS]         full report
#   ./ps_job_forensics_v3.sh -j <NAME> -i <PRCS_INST>    drill one run
#   ./ps_job_forensics_v3.sh -j <NAME> -a                App Engine step SQL
#   ./ps_job_forensics_v3.sh -j <NAME> -t                Tuning Advisor
#
# Private temp tables only (ora$ptt_*) - session scoped, no persistent DDL.
# Requires Diagnostics Pack; -t requires Tuning Pack.
# =============================================================================

set -u

JOB=""; LIST=""; DAYS=30; PS_OWNER="${PS_OWNER:-SYSADM}"
RUN_STA=0; DUMP_AE=0; ONE_INST=0

usage() {
  cat <<'USAGE'
Usage:
  ps_job_forensics_v3.sh -l <PATTERN>
  ps_job_forensics_v3.sh -j <NAME> [-d DAYS] [-i PRCS_INST] [-o SCHEMA] [-a] [-t]

  -l  search PS process / job definitions and recent runs
  -j  PeopleSoft job or process name (substring match)
  -d  lookback days (default 30)
  -i  restrict all analysis to a single PRCSINSTANCE
  -o  PeopleSoft owner schema (default SYSADM)
  -a  dump App Engine step SQL from PSAESTMT
  -t  interactive SQL Tuning Advisor
  -h  help
USAGE
  exit 1
}

while getopts ":j:l:d:i:o:ath" opt; do
  case "$opt" in
    j) JOB="$OPTARG" ;;
    l) LIST="$OPTARG" ;;
    d) DAYS="$OPTARG" ;;
    i) ONE_INST="$OPTARG" ;;
    o) PS_OWNER="$OPTARG" ;;
    a) DUMP_AE=1 ;;
    t) RUN_STA=1 ;;
    h) usage ;;
    *) usage ;;
  esac
done

[ -z "$JOB" ] && [ -z "$LIST" ] && usage

if [ -z "${ORACLE_SID:-}" ] || [ -z "${ORACLE_HOME:-}" ]; then
  echo "ERROR: ORACLE_SID / ORACLE_HOME not set. Source your env first."
  exit 1
fi
export PATH="$ORACLE_HOME/bin:$PATH"

case "$DAYS" in ''|*[!0-9]*) echo "ERROR: -d must be an integer."; exit 1 ;; esac
case "$ONE_INST" in ''|*[!0-9]*) echo "ERROR: -i must be an integer."; exit 1 ;; esac

PS_OWNER_UC=$(printf '%s' "$PS_OWNER" | tr '[:lower:]' '[:upper:]')
TMPD=$(mktemp -d /tmp/psjf3.XXXXXX)
trap 'rm -rf "$TMPD"' EXIT

# =============================================================================
# DISCOVERY
# =============================================================================
if [ -n "$LIST" ]; then
  PAT=$(printf '%s' "$LIST" | tr '[:lower:]' '[:upper:]')
  cat > "$TMPD/list.sql" <<'SQLEOF'
SET FEEDBACK OFF VERIFY OFF HEADING ON TAB OFF LINESIZE 220 PAGESIZE 200
DEFINE PAT = '&1'
DEFINE PSOWNER = '&2'
WHENEVER SQLERROR CONTINUE

PROMPT
PROMPT === PROCESS DEFINITIONS MATCHING "&PAT" ===
COLUMN prcstype FORMAT A20 HEADING 'PRCS_TYPE'
COLUMN prcsname FORMAT A24 HEADING 'PRCS_NAME'
COLUMN runlocation FORMAT A8 HEADING 'RUN_LOC'
SELECT d.prcstype, d.prcsname, d.runlocation
  FROM &PSOWNER..ps_prcsdefn d
 WHERE UPPER(d.prcsname) LIKE '%&PAT%'
 ORDER BY d.prcstype, d.prcsname;

PROMPT
PROMPT === JOB DEFINITIONS / MEMBERSHIP MATCHING "&PAT" ===
COLUMN prcsjobname FORMAT A24 HEADING 'JOB_NAME'
COLUMN item_seq FORMAT 999 HEADING 'SEQ'
COLUMN item_type FORMAT A20 HEADING 'ITEM_TYPE'
COLUMN item_name FORMAT A24 HEADING 'ITEM_NAME'
SELECT ji.prcsjobname, ji.prcsjobseq item_seq, ji.prcstype item_type,
       ji.prcsname item_name
  FROM &PSOWNER..ps_prcsjobitem ji
 WHERE UPPER(ji.prcsjobname) LIKE '%&PAT%'
    OR UPPER(ji.prcsname) LIKE '%&PAT%'
 ORDER BY ji.prcsjobname, ji.prcsjobseq;

PROMPT
PROMPT === RECENT RUNS MATCHING "&PAT" (90 days) ===
COLUMN prcsinstance FORMAT 99999999 HEADING 'PRCS_INST'
COLUMN prcsname FORMAT A24 HEADING 'PRCS_NAME'
COLUMN oprid FORMAT A12 HEADING 'PS_USER'
COLUMN run_status FORMAT A13 HEADING 'STATUS'
COLUMN beg_dt FORMAT A19 HEADING 'BEGIN'
COLUMN run_sec FORMAT 999,990.9 HEADING 'RUN_SEC'
SELECT r.prcsinstance, r.prcsname, r.oprid,
       DECODE(r.runstatus,'3','Error','5','Queued','6','Initiated',
                          '7','Processing','9','Success','10','Not Success',
                          '17','Success/Warn', r.runstatus) run_status,
       TO_CHAR(r.begindttm,'YYYY-MM-DD HH24:MI:SS') beg_dt,
       ROUND((CAST(r.enddttm AS DATE)-CAST(r.begindttm AS DATE))*86400,1) run_sec
  FROM &PSOWNER..psprcsrqst r
 WHERE UPPER(r.prcsname) LIKE '%&PAT%'
   AND r.rundttm >= SYSTIMESTAMP - NUMTODSINTERVAL(90,'DAY')
 ORDER BY r.begindttm DESC NULLS LAST
 FETCH FIRST 40 ROWS ONLY;
EXIT;
SQLEOF
  echo ""
  echo "--- DISCOVERY: '${PAT}' on ${ORACLE_SID} (${PS_OWNER_UC}) ---"
  sqlplus -s "/ as sysdba" @"$TMPD/list.sql" "$PAT" "$PS_OWNER_UC"
  exit 0
fi

JOB_UC=$(printf '%s' "$JOB" | tr '[:lower:]' '[:upper:]')

# =============================================================================
# MAIN
# =============================================================================
cat > "$TMPD/main.sql" <<'SQLEOF'
SET FEEDBACK OFF VERIFY OFF TRIMSPOOL ON TRIMOUT ON HEADING ON TAB OFF
SET LINESIZE 240 PAGESIZE 300 TIMING OFF SERVEROUTPUT ON SIZE UNLIMITED
DEFINE JOB     = '&1'
DEFINE DAYS    = &2
DEFINE PSOWNER = '&3'
DEFINE ONEINST = &4
WHENEVER SQLERROR CONTINUE

PROMPT
PROMPT =========================================================================
PROMPT === 0. ENVIRONMENT
PROMPT =========================================================================
COLUMN db_name FORMAT A12 HEADING 'DB_NAME'
COLUMN open_mode FORMAT A12 HEADING 'OPEN_MODE'
COLUMN db_role FORMAT A16 HEADING 'ROLE'
COLUMN nodes FORMAT 999 HEADING 'NODES'
COLUMN awr_ret FORMAT 999 HEADING 'AWR_RET_D'
COLUMN ash_int FORMAT 999 HEADING 'ASH_SAMPLE_S'
SELECT d.name db_name, d.open_mode, d.database_role db_role,
       (SELECT COUNT(*) FROM gv$instance) nodes,
       (SELECT EXTRACT(DAY FROM retention) FROM dba_hist_wr_control
         WHERE dbid=d.dbid) awr_ret,
       10 ash_int
  FROM v$database d;
PROMPT (DBA_HIST ASH samples every 10s - each ASH row below = ~10s of DB time.)

-- =====================================================================
-- Build run windows once. Everything downstream is bounded by these.
-- =====================================================================
CREATE PRIVATE TEMPORARY TABLE ora$ptt_runs
ON COMMIT PRESERVE DEFINITION AS
SELECT r.prcsinstance,
       r.prcsname,
       r.servernamerun,
       CAST(r.begindttm AS TIMESTAMP) beg_ts,
       CAST(r.enddttm   AS TIMESTAMP) end_ts,
       (CAST(r.enddttm AS DATE)-CAST(r.begindttm AS DATE))*86400 run_sec,
       (SELECT MIN(s.snap_id) FROM dba_hist_snapshot s
         WHERE s.end_interval_time >= r.begindttm) min_snap,
       (SELECT MAX(s.snap_id) FROM dba_hist_snapshot s
         WHERE s.begin_interval_time <= r.enddttm) max_snap
  FROM &PSOWNER..psprcsrqst r
 WHERE UPPER(r.prcsname) LIKE '%&JOB%'
   AND r.rundttm >= SYSTIMESTAMP - NUMTODSINTERVAL(&DAYS,'DAY')
   AND r.begindttm IS NOT NULL
   AND r.enddttm   IS NOT NULL
   AND (&ONEINST = 0 OR r.prcsinstance = &ONEINST);

PROMPT
PROMPT =========================================================================
PROMPT === 1. RUN PROFILE + FAST/SLOW CLASSIFICATION
PROMPT =========================================================================
COLUMN prcsinstance FORMAT 99999999 HEADING 'PRCS_INST'
COLUMN servernamerun FORMAT A10 HEADING 'SERVER'
COLUMN beg FORMAT A19 HEADING 'BEGIN'
COLUMN run_sec FORMAT 999,990.9 HEADING 'RUN_SEC'
COLUMN run_min FORMAT 9,990.9 HEADING 'RUN_MIN'
COLUMN band FORMAT A6 HEADING 'BAND'
COLUMN snaps FORMAT A15 HEADING 'SNAP_RANGE'

SELECT prcsinstance, servernamerun,
       TO_CHAR(beg_ts,'YYYY-MM-DD HH24:MI:SS') beg,
       ROUND(run_sec,1) run_sec,
       ROUND(run_sec/60,1) run_min,
       CASE WHEN run_sec >= (SELECT PERCENTILE_CONT(0.75)
                               WITHIN GROUP (ORDER BY run_sec)
                               FROM ora$ptt_runs)
            THEN 'SLOW' ELSE 'FAST' END band,
       min_snap||'-'||max_snap snaps
  FROM ora$ptt_runs
 ORDER BY run_sec DESC;

PROMPT
PROMPT --- distribution ---
COLUMN runs FORMAT 9,999 HEADING 'RUNS'
COLUMN min_s FORMAT 999,990 HEADING 'MIN_S'
COLUMN p50_s FORMAT 999,990 HEADING 'MEDIAN_S'
COLUMN avg_s FORMAT 999,990 HEADING 'MEAN_S'
COLUMN p90_s FORMAT 999,990 HEADING 'P90_S'
COLUMN max_s FORMAT 999,990 HEADING 'MAX_S'
COLUMN skew FORMAT 990.9 HEADING 'MEAN/MED'
COLUMN slow_share FORMAT 990.9 HEADING 'SLOW_%TIME'

SELECT COUNT(*) runs,
       ROUND(MIN(run_sec)) min_s,
       ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY run_sec)) p50_s,
       ROUND(AVG(run_sec)) avg_s,
       ROUND(PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY run_sec)) p90_s,
       ROUND(MAX(run_sec)) max_s,
       ROUND(AVG(run_sec)/NULLIF(PERCENTILE_CONT(0.5)
             WITHIN GROUP (ORDER BY run_sec),0),1) skew,
       ROUND(100*SUM(CASE WHEN run_sec >= (SELECT PERCENTILE_CONT(0.75)
                                             WITHIN GROUP (ORDER BY run_sec)
                                             FROM ora$ptt_runs)
                          THEN run_sec ELSE 0 END)/NULLIF(SUM(run_sec),0),1) slow_share
  FROM ora$ptt_runs;
PROMPT (MEAN/MED well above 1.0 = bimodal workload. SLOW_%TIME = share of total
PROMPT  runtime burned by the top quartile of runs.)

-- =====================================================================
-- Derive the SQL_ID set ONCE, bounded by run windows + snap ranges.
-- This is the query that used to hang; it is now partition-pruned.
-- =====================================================================
CREATE PRIVATE TEMPORARY TABLE ora$ptt_ash
ON COMMIT PRESERVE DEFINITION AS
SELECT h.sql_id,
       h.sql_plan_hash_value phv,
       h.module,
       h.action,
       h.event,
       h.wait_class,
       h.session_state,
       h.instance_number,
       r.prcsinstance,
       r.run_sec,
       CASE WHEN r.run_sec >= (SELECT PERCENTILE_CONT(0.75)
                                 WITHIN GROUP (ORDER BY run_sec)
                                 FROM ora$ptt_runs)
            THEN 'SLOW' ELSE 'FAST' END band
  FROM ora$ptt_runs r
  JOIN dba_hist_active_sess_history h
    ON  h.snap_id     BETWEEN r.min_snap AND r.max_snap
    AND h.sample_time BETWEEN r.beg_ts   AND r.end_ts
 WHERE h.sql_id IS NOT NULL
   AND (   UPPER(h.module)    LIKE '%&JOB%'
        OR UPPER(h.action)    LIKE '%&JOB%'
        OR UPPER(h.client_id) LIKE '%&JOB%'
        OR UPPER(h.module)    LIKE '%'||TO_CHAR(r.prcsinstance)||'%'
        OR UPPER(h.action)    LIKE '%'||TO_CHAR(r.prcsinstance)||'%'
        OR UPPER(h.client_id) LIKE '%'||TO_CHAR(r.prcsinstance)||'%');

CREATE PRIVATE TEMPORARY TABLE ora$ptt_sqlid
ON COMMIT PRESERVE DEFINITION AS
SELECT DISTINCT sql_id FROM ora$ptt_ash;

PROMPT
PROMPT =========================================================================
PROMPT === 2. WHERE THE DB TIME GOES - BY APP ENGINE STEP (ASH ACTION)
PROMPT =========================================================================
PROMPT (PeopleSoft App Engine stamps ACTION with section.step. This is the
PROMPT  step-level profile you would otherwise have to ask an app admin for.)
COLUMN action FORMAT A34 HEADING 'AE_SECTION.STEP'
COLUMN db_time_s FORMAT 999,999,990 HEADING 'DB_TIME_S'
COLUMN pct FORMAT 990.9 HEADING 'PCT'
COLUMN cpu_s FORMAT 999,999,990 HEADING 'CPU_S'
COLUMN wait_s FORMAT 999,999,990 HEADING 'WAIT_S'
COLUMN sqls FORMAT 9,990 HEADING 'DISTINCT_SQL'
COLUMN top_event FORMAT A30 HEADING 'TOP_WAIT_EVENT'

SELECT NVL(a.action,'(not set)') action,
       COUNT(*)*10 db_time_s,
       ROUND(100*COUNT(*)/NULLIF(SUM(COUNT(*)) OVER (),0),1) pct,
       SUM(CASE WHEN a.session_state='ON CPU' THEN 10 ELSE 0 END) cpu_s,
       SUM(CASE WHEN a.session_state='WAITING' THEN 10 ELSE 0 END) wait_s,
       COUNT(DISTINCT a.sql_id) sqls,
       MAX(a.event) KEEP (DENSE_RANK FIRST
             ORDER BY COUNT(*) OVER (PARTITION BY a.action, a.event) DESC) top_event
  FROM ora$ptt_ash a
 GROUP BY a.action
 ORDER BY db_time_s DESC
 FETCH FIRST 25 ROWS ONLY;

PROMPT
PROMPT =========================================================================
PROMPT === 3. TOP SQL BY DB TIME INSIDE THE RUN WINDOWS
PROMPT =========================================================================
COLUMN sql_id FORMAT A14 HEADING 'SQL_ID'
COLUMN phv FORMAT 9999999999 HEADING 'PLAN_HASH'
COLUMN db_time_s FORMAT 999,999,990 HEADING 'DB_TIME_S'
COLUMN pct FORMAT 990.9 HEADING 'PCT'
COLUMN cpu_pct FORMAT 990.9 HEADING 'CPU_%'
COLUMN top_class FORMAT A14 HEADING 'TOP_WAIT_CLS'
COLUMN step FORMAT A26 HEADING 'AE_STEP'
COLUMN runs_seen FORMAT 990 HEADING 'RUNS'
COLUMN sql_preview FORMAT A50 HEADING 'SQL_TEXT_PREVIEW'

SELECT a.sql_id,
       a.phv,
       COUNT(*)*10 db_time_s,
       ROUND(100*COUNT(*)/NULLIF(SUM(COUNT(*)) OVER (),0),1) pct,
       ROUND(100*SUM(CASE WHEN a.session_state='ON CPU' THEN 1 ELSE 0 END)
             /NULLIF(COUNT(*),0),1) cpu_pct,
       MAX(a.wait_class) KEEP (DENSE_RANK FIRST
             ORDER BY COUNT(*) OVER (PARTITION BY a.sql_id, a.wait_class) DESC) top_class,
       SUBSTR(MAX(a.action),1,26) step,
       COUNT(DISTINCT a.prcsinstance) runs_seen,
       SUBSTR(REGEXP_REPLACE(
         NVL((SELECT MIN(t.sql_text) FROM gv$sql t WHERE t.sql_id=a.sql_id),
             (SELECT MIN(TO_CHAR(SUBSTR(x.sql_text,1,300)))
                FROM dba_hist_sqltext x WHERE x.sql_id=a.sql_id)),
         '[[:space:]]+',' '),1,50) sql_preview
  FROM ora$ptt_ash a
 GROUP BY a.sql_id, a.phv
 ORDER BY db_time_s DESC
 FETCH FIRST 25 ROWS ONLY;

PROMPT
PROMPT =========================================================================
PROMPT === 4. FAST RUNS vs SLOW RUNS - WHAT ACTUALLY DIFFERS
PROMPT =========================================================================
PROMPT (Same SQL in both bands = volume driven. SQL or plan only in SLOW =
PROMPT  plan flip or contention. This is the section that tells you which.)
COLUMN sql_id FORMAT A14 HEADING 'SQL_ID'
COLUMN phv FORMAT 9999999999 HEADING 'PLAN_HASH'
COLUMN fast_s FORMAT 999,999,990 HEADING 'FAST_DBT_S'
COLUMN slow_s FORMAT 999,999,990 HEADING 'SLOW_DBT_S'
COLUMN fast_runs FORMAT 990 HEADING 'FAST_RUNS'
COLUMN slow_runs FORMAT 990 HEADING 'SLOW_RUNS'
COLUMN per_fast FORMAT 999,990 HEADING 'S/FAST_RUN'
COLUMN per_slow FORMAT 999,990 HEADING 'S/SLOW_RUN'
COLUMN verdict FORMAT A22 HEADING 'VERDICT'

WITH agg AS (
  SELECT sql_id, phv,
         SUM(CASE WHEN band='FAST' THEN 10 ELSE 0 END) fast_s,
         SUM(CASE WHEN band='SLOW' THEN 10 ELSE 0 END) slow_s,
         COUNT(DISTINCT CASE WHEN band='FAST' THEN prcsinstance END) fr,
         COUNT(DISTINCT CASE WHEN band='SLOW' THEN prcsinstance END) sr
    FROM ora$ptt_ash
   GROUP BY sql_id, phv
)
SELECT sql_id, phv, fast_s, slow_s, fr fast_runs, sr slow_runs,
       ROUND(fast_s/NULLIF(fr,0)) per_fast,
       ROUND(slow_s/NULLIF(sr,0)) per_slow,
       CASE
         WHEN fr = 0 THEN 'SLOW RUNS ONLY'
         WHEN sr = 0 THEN 'fast runs only'
         WHEN (slow_s/NULLIF(sr,0)) > 4*(fast_s/NULLIF(fr,0)) THEN 'BLOWS UP WHEN SLOW'
         ELSE 'scales with volume'
       END verdict
  FROM agg
 WHERE fast_s + slow_s > 0
 ORDER BY slow_s DESC
 FETCH FIRST 25 ROWS ONLY;

PROMPT
PROMPT =========================================================================
PROMPT === 5. AWR EXECUTION STATS  (snap+sql_id bounded - indexed access)
PROMPT =========================================================================
COLUMN sql_id FORMAT A14 HEADING 'SQL_ID'
COLUMN phv FORMAT 9999999999 HEADING 'PLAN_HASH'
COLUMN execs FORMAT 999,999,990 HEADING 'EXECS'
COLUMN avg_elap FORMAT 999,990.99 HEADING 'AVG_ELAP_S'
COLUMN avg_cpu FORMAT 999,990.99 HEADING 'AVG_CPU_S'
COLUMN avg_io FORMAT 999,990.99 HEADING 'AVG_IO_S'
COLUMN tot_elap FORMAT 999,999,990 HEADING 'TOT_ELAP_S'
COLUMN avg_bg FORMAT 999,999,990 HEADING 'AVG_BUF_GETS'
COLUMN avg_rows FORMAT 999,999,990 HEADING 'AVG_ROWS'
COLUMN gets_per_row FORMAT 999,990.9 HEADING 'GETS/ROW'

SELECT st.sql_id, st.plan_hash_value phv,
       SUM(st.executions_delta) execs,
       ROUND(SUM(st.elapsed_time_delta)/1e6/GREATEST(SUM(st.executions_delta),1),2) avg_elap,
       ROUND(SUM(st.cpu_time_delta)/1e6/GREATEST(SUM(st.executions_delta),1),2) avg_cpu,
       ROUND(SUM(st.iowait_delta)/1e6/GREATEST(SUM(st.executions_delta),1),2) avg_io,
       ROUND(SUM(st.elapsed_time_delta)/1e6) tot_elap,
       ROUND(SUM(st.buffer_gets_delta)/GREATEST(SUM(st.executions_delta),1)) avg_bg,
       ROUND(SUM(st.rows_processed_delta)/GREATEST(SUM(st.executions_delta),1)) avg_rows,
       ROUND(SUM(st.buffer_gets_delta)/GREATEST(SUM(st.rows_processed_delta),1),1) gets_per_row
  FROM dba_hist_sqlstat st
 WHERE st.sql_id IN (SELECT sql_id FROM ora$ptt_sqlid)
   AND st.snap_id BETWEEN (SELECT MIN(min_snap) FROM ora$ptt_runs)
                      AND (SELECT MAX(max_snap) FROM ora$ptt_runs)
 GROUP BY st.sql_id, st.plan_hash_value
HAVING SUM(st.executions_delta) > 0
 ORDER BY tot_elap DESC
 FETCH FIRST 30 ROWS ONLY;
PROMPT (GETS/ROW is the efficiency tell: high gets per row returned = bad access
PROMPT  path or missing predicate, regardless of how fast it feels.)

PROMPT
PROMPT =========================================================================
PROMPT === 6. PLAN INSTABILITY FOR THIS JOB'S SQL
PROMPT =========================================================================
COLUMN sql_id FORMAT A14 HEADING 'SQL_ID'
COLUMN plans FORMAT 990 HEADING 'PLANS'
COLUMN best_phv FORMAT 9999999999 HEADING 'BEST_PLAN'
COLUMN best_s FORMAT 999,990.99 HEADING 'BEST_AVG_S'
COLUMN worst_phv FORMAT 9999999999 HEADING 'WORST_PLAN'
COLUMN worst_s FORMAT 999,990.99 HEADING 'WORST_AVG_S'
COLUMN regress FORMAT 9,990.9 HEADING 'REGRESS_X'
COLUMN last_phv FORMAT 9999999999 HEADING 'CURRENT_PLAN'

WITH pp AS (
  SELECT st.sql_id, st.plan_hash_value phv,
         SUM(st.elapsed_time_delta)/1e6/GREATEST(SUM(st.executions_delta),1) avg_s,
         MAX(st.snap_id) last_snap
    FROM dba_hist_sqlstat st
   WHERE st.sql_id IN (SELECT sql_id FROM ora$ptt_sqlid)
     AND st.snap_id BETWEEN (SELECT MIN(min_snap) FROM ora$ptt_runs)
                        AND (SELECT MAX(max_snap) FROM ora$ptt_runs)
     AND st.plan_hash_value > 0
   GROUP BY st.sql_id, st.plan_hash_value
  HAVING SUM(st.executions_delta) > 0
)
SELECT sql_id, COUNT(*) plans,
       MIN(phv) KEEP (DENSE_RANK FIRST ORDER BY avg_s) best_phv,
       ROUND(MIN(avg_s),2) best_s,
       MIN(phv) KEEP (DENSE_RANK LAST ORDER BY avg_s) worst_phv,
       ROUND(MAX(avg_s),2) worst_s,
       ROUND(MAX(avg_s)/GREATEST(MIN(avg_s),0.01),1) regress,
       MIN(phv) KEEP (DENSE_RANK LAST ORDER BY last_snap) last_phv
  FROM pp
 GROUP BY sql_id
HAVING COUNT(*) > 1
 ORDER BY regress DESC;
PROMPT (If CURRENT_PLAN = WORST_PLAN, you have a live regression - candidate for
PROMPT  a SQL plan baseline on BEST_PLAN.)

PROMPT
PROMPT =========================================================================
PROMPT === 7. OBJECTS TOUCHED + STATS FRESHNESS
PROMPT =========================================================================
COLUMN obj_name FORMAT A48 HEADING 'OBJECT'
COLUMN obj_type FORMAT A10 HEADING 'TYPE'
COLUMN access_path FORMAT A28 HEADING 'ACCESS_PATH'
COLUMN num_rows FORMAT 999,999,999,990 HEADING 'NUM_ROWS'
COLUMN last_analyzed FORMAT A19 HEADING 'LAST_ANALYZED'
COLUMN age_d FORMAT 9,990 HEADING 'STATS_AGE_D'
COLUMN stale FORMAT A6 HEADING 'STALE'

WITH plans AS (
  SELECT p.object_owner owner, p.object_name name, p.object_type otype,
         p.operation||' '||NVL(p.options,' ') path
    FROM gv$sql_plan p
   WHERE p.object_owner IS NOT NULL
     AND p.sql_id IN (SELECT sql_id FROM ora$ptt_sqlid)
  UNION
  SELECT hp.object_owner, hp.object_name, hp.object_type,
         hp.operation||' '||NVL(hp.options,' ')
    FROM dba_hist_sql_plan hp
   WHERE hp.object_owner IS NOT NULL
     AND hp.sql_id IN (SELECT sql_id FROM ora$ptt_sqlid)
)
SELECT pl.owner||'.'||pl.name obj_name,
       MAX(pl.otype) obj_type,
       LISTAGG(DISTINCT TRIM(pl.path),'; ')
         WITHIN GROUP (ORDER BY TRIM(pl.path)) access_path,
       ts.num_rows,
       TO_CHAR(ts.last_analyzed,'YYYY-MM-DD HH24:MI:SS') last_analyzed,
       ROUND(SYSDATE - ts.last_analyzed) age_d,
       ts.stale_stats stale
  FROM plans pl
  LEFT JOIN dba_tab_statistics ts
    ON ts.owner = pl.owner AND ts.table_name = pl.name
   AND ts.object_type IN ('TABLE','PARTITION')
 GROUP BY pl.owner, pl.name, ts.num_rows, ts.last_analyzed, ts.stale_stats
 ORDER BY ts.last_analyzed NULLS FIRST, obj_name;

PROMPT
PROMPT --- PeopleSoft temp table check (AE working storage often has no stats) ---
COLUMN tt FORMAT A48 HEADING 'PS_TEMP_TABLE'
COLUMN num_rows FORMAT 999,999,999,990 HEADING 'NUM_ROWS'
COLUMN last_analyzed FORMAT A19 HEADING 'LAST_ANALYZED'
SELECT ts.owner||'.'||ts.table_name tt, ts.num_rows,
       TO_CHAR(ts.last_analyzed,'YYYY-MM-DD HH24:MI:SS') last_analyzed
  FROM dba_tab_statistics ts
 WHERE ts.object_type='TABLE'
   AND (ts.owner, ts.table_name) IN (
        SELECT DISTINCT p.object_owner, p.object_name
          FROM dba_hist_sql_plan p
         WHERE p.sql_id IN (SELECT sql_id FROM ora$ptt_sqlid)
           AND p.object_type='TABLE')
   AND REGEXP_LIKE(ts.table_name,'[0-9]$')
 ORDER BY ts.last_analyzed NULLS FIRST;
PROMPT (Tables ending in a digit are usually AE temp-table instances. Stale or
PROMPT  NULL stats here is a classic cause of bimodal AE runtimes.)

PROMPT
PROMPT =========================================================================
PROMPT Report complete.
PROMPT =========================================================================
EXIT;
SQLEOF

echo ""
echo "-------------------------------------------------------------------------"
echo " PS JOB FORENSICS v3 | SID: ${ORACLE_SID} | JOB: ${JOB_UC} | ${DAYS}d"
echo " Schema: ${PS_OWNER_UC} | Single instance filter: ${ONE_INST}"
echo "-------------------------------------------------------------------------"

time sqlplus -s "/ as sysdba" @"$TMPD/main.sql" "$JOB_UC" "$DAYS" "$PS_OWNER_UC" "$ONE_INST"

# =============================================================================
# APP ENGINE STATIC STEP SQL
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
PROMPT === APP ENGINE SECTIONS / STEPS (PSAESTEPDEFN)
PROMPT =========================================================================
COLUMN ae_applid FORMAT A18 HEADING 'AE_PROGRAM'
COLUMN ae_section FORMAT A20 HEADING 'SECTION'
COLUMN ae_step FORMAT A16 HEADING 'STEP'
SELECT DISTINCT s.ae_applid, s.ae_section, s.ae_step
  FROM &PSOWNER..psaestepdefn s
 WHERE UPPER(s.ae_applid) LIKE '%&JOB%'
 ORDER BY s.ae_applid, s.ae_section, s.ae_step;

PROMPT
PROMPT =========================================================================
PROMPT === APP ENGINE STEP SQL (PSAESTMT)
PROMPT =========================================================================
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
# SQL TUNING ADVISOR
# =============================================================================
[ "$RUN_STA" -eq 0 ] && exit 0

echo ""
echo "========================================================================="
echo " SQL TUNING ADVISOR (requires Oracle Tuning Pack license)"
echo "========================================================================="
read -r -p "Run it now? (y/n): " ANS
case "$ANS" in [Yy]*) ;; *) echo "Skipped."; exit 0 ;; esac

read -r -p "TARGET SQL_ID: " TARGET_SQL_ID
[ -z "$TARGET_SQL_ID" ] && { echo "ERROR: SQL_ID cannot be empty."; exit 1; }

echo ""
echo "  1) Cursor cache (real-time)"
echo "  2) AWR repository (historical)"
read -r -p "Source (1 or 2): " SOURCE_OPT

PLAN_FILTER=""
[ "$SOURCE_OPT" = "2" ] && read -r -p "Restrict to PLAN_HASH_VALUE? (blank = all): " PLAN_FILTER

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
  SELECT COUNT(*) INTO v_exists FROM dba_advisor_tasks WHERE task_name='&TASK';
  IF v_exists > 0 THEN
    DBMS_SQLTUNE.DROP_TUNING_TASK(task_name => '&TASK');
  END IF;

  IF '&SRC' = '1' THEN
    v_task := DBMS_SQLTUNE.CREATE_TUNING_TASK(
                sql_id      => '&TSQL',
                task_name   => '&TASK',
                scope       => DBMS_SQLTUNE.scope_comprehensive,
                time_limit  => 1800,
                description => 'STA cursor cache - ps_job_forensics');
    DBMS_OUTPUT.PUT_LINE('Task created from cursor cache.');
  ELSE
    SELECT MIN(snap_id), MAX(snap_id) INTO v_beg, v_end
      FROM dba_hist_sqlstat
     WHERE sql_id='&TSQL'
       AND ('&PHV' IS NULL OR TO_CHAR(plan_hash_value)='&PHV');
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
                description => 'STA AWR - ps_job_forensics');
    DBMS_OUTPUT.PUT_LINE('Task created from AWR snaps '||v_beg||'-'||v_end||'.');
  END IF;

  DBMS_SQLTUNE.EXECUTE_TUNING_TASK(task_name => '&TASK');
  DBMS_OUTPUT.PUT_LINE('Execution complete.');
END;
/

PROMPT
PROMPT === SQL TUNING ADVISOR REPORT: &TASK ===
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

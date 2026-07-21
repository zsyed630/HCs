#!/bin/bash
# =============================================================================
# ps_job_forensics_v5.sh
# PeopleSoft on Oracle 19c RAC - DBA-side job forensics.
#
# v5 CORRELATION FIX (this is the whole ballgame):
#   FPRD Process Scheduler does NOT call DBMS_APPLICATION_INFO for AE domains.
#   Evidence from ASH:
#       MODULE    = 'psae@<host> (TNS V1-V3)'   <- OS program, not process name
#       ACTION    = NULL                        <- no step attribution available
#       CLIENT_ID = '<OPRID>'                   <- the PeopleSoft operator id
#   So the join is:  time window (PSPRCSRQST) + CLIENT_ID = OPRID + psae program.
#   Matching on process name (v2-v4) returned zero rows. Fixed here.
#
#   Because OPRID is not unique per process, section 1b flags any run where the
#   same OPRID had another process overlapping - attribution there is BLENDED,
#   and the report says so instead of pretending otherwise.
#
#   ./ps_job_forensics_v5.sh -j <NAME> [-d DAYS]      full report
#   ./ps_job_forensics_v5.sh -j <NAME> -i <PRCS_INST> drill one run
#   ./ps_job_forensics_v5.sh -j <NAME> -p             + real execution plans
#   ./ps_job_forensics_v5.sh -j <NAME> -r             + real-time (live) section
#   ./ps_job_forensics_v5.sh -j <NAME> -t             + SQL Tuning Advisor
#
# No DDL. All reads bounded by snap_id + sample_time.
# =============================================================================

set -u

JOB=""; DAYS=30; PS_OWNER="${PS_OWNER:-SYSADM}"
ONE_INST=0; SHOW_PLANS=0; SHOW_RT=0; RUN_STA=0; TOPN=8

usage() {
  cat <<'USAGE'
Usage: ps_job_forensics_v5.sh -j <NAME> [-d DAYS] [-i PRCS_INST] [-o SCHEMA]
                              [-n TOP_N] [-p] [-r] [-t]
  -j  PeopleSoft process name (substring match)
  -d  lookback days (default 30)
  -i  restrict to one PRCSINSTANCE
  -o  PeopleSoft owner schema (default SYSADM)
  -n  how many top SQL to pull plans for with -p (default 8)
  -p  print real execution plans (DBMS_XPLAN.DISPLAY_AWR / DISPLAY_CURSOR)
  -r  include real-time live session section
  -t  interactive SQL Tuning Advisor
  -h  help
USAGE
  exit 1
}

while getopts ":j:d:i:o:n:prth" opt; do
  case "$opt" in
    j) JOB="$OPTARG" ;;
    d) DAYS="$OPTARG" ;;
    i) ONE_INST="$OPTARG" ;;
    o) PS_OWNER="$OPTARG" ;;
    n) TOPN="$OPTARG" ;;
    p) SHOW_PLANS=1 ;;
    r) SHOW_RT=1 ;;
    t) RUN_STA=1 ;;
    h) usage ;;
    *) usage ;;
  esac
done

[ -z "$JOB" ] && usage
if [ -z "${ORACLE_SID:-}" ] || [ -z "${ORACLE_HOME:-}" ]; then
  echo "ERROR: ORACLE_SID / ORACLE_HOME not set."
  exit 1
fi
export PATH="$ORACLE_HOME/bin:$PATH"

case "$DAYS"     in ''|*[!0-9]*) echo "ERROR: -d integer"; exit 1 ;; esac
case "$ONE_INST" in ''|*[!0-9]*) echo "ERROR: -i integer"; exit 1 ;; esac
case "$TOPN"     in ''|*[!0-9]*) echo "ERROR: -n integer"; exit 1 ;; esac

JOB_UC=$(printf '%s' "$JOB" | tr '[:lower:]' '[:upper:]')
PS_OWNER_UC=$(printf '%s' "$PS_OWNER" | tr '[:lower:]' '[:upper:]')
TMPD=$(mktemp -d /tmp/psjf5.XXXXXX)
trap 'rm -rf "$TMPD"' EXIT

# -----------------------------------------------------------------------------
# The correlation block, reused verbatim in every section.
# -----------------------------------------------------------------------------
read -r -d '' CORR <<'CORREOF' || true
runs AS (
  SELECT /*+ MATERIALIZE */
         r.prcsinstance, r.prcsname, r.oprid, r.servernamerun,
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
     AND r.begindttm IS NOT NULL AND r.enddttm IS NOT NULL
     AND (&ONEINST = 0 OR r.prcsinstance = &ONEINST)
),
thr AS (
  SELECT PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY run_sec) p75 FROM runs
),
banded AS (
  SELECT r.*, CASE WHEN r.run_sec >= t.p75 THEN 'SLOW' ELSE 'FAST' END band
    FROM runs r CROSS JOIN thr t
),
ash AS (
  SELECT /*+ MATERIALIZE */
         h.sql_id, h.sql_plan_hash_value phv, h.instance_number node,
         h.event, h.wait_class, h.session_state, h.module, h.action,
         h.machine, h.program, h.blocking_session, h.current_obj#,
         b.prcsinstance, b.band, b.run_sec, b.servernamerun
    FROM banded b
    JOIN dba_hist_active_sess_history h
      ON  h.snap_id     BETWEEN b.min_snap AND b.max_snap
      AND h.sample_time BETWEEN b.beg_ts   AND b.end_ts
      AND UPPER(h.client_id) = UPPER(b.oprid)
   WHERE h.sql_id IS NOT NULL
     AND (   LOWER(h.program) LIKE 'psae@%'
          OR LOWER(h.module)  LIKE 'psae@%'
          OR UPPER(h.module)  LIKE 'PSAE%'
          OR UPPER(h.action)  LIKE '%'||UPPER(b.prcsname)||'%'
          OR UPPER(h.module)  LIKE '%'||UPPER(b.prcsname)||'%')
)
CORREOF

cat > "$TMPD/main.sql" <<SQLEOF
SET FEEDBACK OFF VERIFY OFF TRIMSPOOL ON TRIMOUT ON HEADING ON TAB OFF
SET LINESIZE 250 PAGESIZE 400 TIMING ON SERVEROUTPUT ON SIZE UNLIMITED
DEFINE JOB     = '&1'
DEFINE DAYS    = &2
DEFINE PSOWNER = '&3'
DEFINE ONEINST = &4
DEFINE TOPN    = &5
WHENEVER SQLERROR CONTINUE

PROMPT
PROMPT =========================================================================
PROMPT === 0. ENVIRONMENT
PROMPT =========================================================================
COLUMN db_name FORMAT A10 HEADING 'DB_NAME'
COLUMN open_mode FORMAT A11 HEADING 'OPEN_MODE'
COLUMN db_role FORMAT A16 HEADING 'ROLE'
COLUMN nodes FORMAT 999 HEADING 'NODES'
COLUMN awr_ret FORMAT 9999 HEADING 'AWR_RET_D'
SELECT d.name db_name, d.open_mode, d.database_role db_role,
       (SELECT COUNT(*) FROM gv\$instance) nodes,
       (SELECT EXTRACT(DAY FROM retention) FROM dba_hist_wr_control
         WHERE dbid=d.dbid) awr_ret
  FROM v\$database d;
PROMPT Correlation key on this DB: CLIENT_ID = OPRID + run window + psae program.
PROMPT (Process Scheduler AE domains do not set MODULE/ACTION here.)

PROMPT
PROMPT =========================================================================
PROMPT === 1. RUN PROFILE
PROMPT =========================================================================
COLUMN prcsinstance FORMAT 99999999 HEADING 'PRCS_INST'
COLUMN oprid FORMAT A11 HEADING 'OPRID'
COLUMN servernamerun FORMAT A8 HEADING 'SERVER'
COLUMN beg FORMAT A19 HEADING 'BEGIN'
COLUMN run_sec FORMAT 999,990 HEADING 'RUN_SEC'
COLUMN band FORMAT A5 HEADING 'BAND'
COLUMN snaps FORMAT A14 HEADING 'SNAPS'
WITH $CORR
SELECT b.prcsinstance, b.oprid, b.servernamerun,
       TO_CHAR(b.beg_ts,'YYYY-MM-DD HH24:MI:SS') beg,
       ROUND(b.run_sec) run_sec, b.band,
       b.min_snap||'-'||b.max_snap snaps
  FROM banded b
 ORDER BY b.run_sec DESC;

PROMPT
PROMPT --- 1b. ATTRIBUTION CONFIDENCE (other processes same OPRID, overlapping) ---
COLUMN prcsinstance FORMAT 99999999 HEADING 'PRCS_INST'
COLUMN overlaps FORMAT 990 HEADING 'OVERLAPPING'
COLUMN other_names FORMAT A54 HEADING 'OTHER_PROCESSES_SAME_OPRID'
COLUMN confidence FORMAT A9 HEADING 'CONFIDENCE'
WITH $CORR
SELECT b.prcsinstance,
       COUNT(o.prcsinstance) overlaps,
       SUBSTR(LISTAGG(DISTINCT o.prcsname,',')
              WITHIN GROUP (ORDER BY o.prcsname),1,54) other_names,
       CASE WHEN COUNT(o.prcsinstance)=0 THEN 'CLEAN' ELSE 'BLENDED' END confidence
  FROM banded b
  LEFT JOIN &PSOWNER..psprcsrqst o
    ON  o.oprid = b.oprid
    AND o.prcsinstance <> b.prcsinstance
    AND o.begindttm < b.end_ts
    AND o.enddttm   > b.beg_ts
 GROUP BY b.prcsinstance
 ORDER BY overlaps DESC, b.prcsinstance;
PROMPT (BLENDED = ASH in that window includes other work by the same operator.)

PROMPT
PROMPT =========================================================================
PROMPT === 2. CORRELATION HEALTH - did we actually match ASH per run?
PROMPT =========================================================================
COLUMN prcsinstance FORMAT 99999999 HEADING 'PRCS_INST'
COLUMN run_sec FORMAT 999,990 HEADING 'RUN_SEC'
COLUMN samples FORMAT 999,990 HEADING 'ASH_SAMPLES'
COLUMN db_time_s FORMAT 999,999,990 HEADING 'DB_TIME_S'
COLUMN aas FORMAT 990.9 HEADING 'AVG_ACT_SESS'
COLUMN sqls FORMAT 9,990 HEADING 'SQLS'
COLUMN plans FORMAT 9,990 HEADING 'PLANS'
COLUMN nodes_used FORMAT A9 HEADING 'RAC_NODES'
WITH $CORR
SELECT a.prcsinstance,
       ROUND(MAX(a.run_sec)) run_sec,
       COUNT(*) samples,
       COUNT(*)*10 db_time_s,
       ROUND(COUNT(*)*10/NULLIF(MAX(a.run_sec),0),1) aas,
       COUNT(DISTINCT a.sql_id) sqls,
       COUNT(DISTINCT a.phv) plans,
       LISTAGG(DISTINCT TO_CHAR(a.node),',')
         WITHIN GROUP (ORDER BY TO_CHAR(a.node)) nodes_used
  FROM ash a
 GROUP BY a.prcsinstance
 ORDER BY db_time_s DESC;
PROMPT (AVG_ACT_SESS = DB time / wall clock. If this is ~0, correlation failed.)

PROMPT
PROMPT =========================================================================
PROMPT === 3. WAIT PROFILE BY RAC NODE (is one instance carrying the pain?)
PROMPT =========================================================================
COLUMN node FORMAT 999 HEADING 'NODE'
COLUMN band FORMAT A5 HEADING 'BAND'
COLUMN wait_class FORMAT A16 HEADING 'WAIT_CLASS'
COLUMN db_time_s FORMAT 999,999,990 HEADING 'DB_TIME_S'
COLUMN pct FORMAT 990.9 HEADING 'PCT'
COLUMN top_event FORMAT A34 HEADING 'TOP_EVENT'
WITH $CORR,
agg AS (
  SELECT node, band, NVL(wait_class,'CPU') wc, COUNT(*) n
    FROM ash GROUP BY node, band, NVL(wait_class,'CPU')
),
ev AS (
  SELECT node, band, wc, event FROM (
    SELECT node, band, NVL(wait_class,'CPU') wc, NVL(event,'CPU') event,
           ROW_NUMBER() OVER (PARTITION BY node, band, NVL(wait_class,'CPU')
                              ORDER BY COUNT(*) DESC) rn
      FROM ash
     GROUP BY node, band, NVL(wait_class,'CPU'), NVL(event,'CPU')
  ) WHERE rn=1
)
SELECT g.node, g.band, g.wc wait_class,
       g.n*10 db_time_s,
       ROUND(100*g.n/NULLIF(SUM(g.n) OVER (),0),1) pct,
       e.event top_event
  FROM agg g LEFT JOIN ev e
    ON e.node=g.node AND e.band=g.band AND e.wc=g.wc
 ORDER BY db_time_s DESC;
PROMPT (Cluster class = global cache. High Cluster on SLOW only = interconnect
PROMPT  or cross-node block contention, not a SQL problem.)

PROMPT
PROMPT =========================================================================
PROMPT === 4. TOP SQL_ID x PLAN_HASH x NODE  (historical, from ASH)
PROMPT =========================================================================
COLUMN sql_id FORMAT A14 HEADING 'SQL_ID'
COLUMN phv FORMAT 9999999999 HEADING 'PLAN_HASH'
COLUMN node FORMAT 999 HEADING 'NODE'
COLUMN db_time_s FORMAT 999,999,990 HEADING 'DB_TIME_S'
COLUMN pct FORMAT 990.9 HEADING 'PCT'
COLUMN cpu_pct FORMAT 990.9 HEADING 'CPU_%'
COLUMN top_class FORMAT A13 HEADING 'TOP_WAIT_CLS'
COLUMN top_event FORMAT A28 HEADING 'TOP_EVENT'
COLUMN runs_seen FORMAT 990 HEADING 'RUNS'
WITH $CORR,
agg AS (
  SELECT sql_id, phv, node, COUNT(*) n,
         SUM(CASE WHEN session_state='ON CPU' THEN 1 ELSE 0 END) cpu_n,
         COUNT(DISTINCT prcsinstance) runs_seen
    FROM ash GROUP BY sql_id, phv, node
),
ev AS (
  SELECT sql_id, phv, node, wc, event FROM (
    SELECT sql_id, phv, node, NVL(wait_class,'CPU') wc, NVL(event,'CPU') event,
           ROW_NUMBER() OVER (PARTITION BY sql_id, phv, node
                              ORDER BY COUNT(*) DESC) rn
      FROM ash
     GROUP BY sql_id, phv, node, NVL(wait_class,'CPU'), NVL(event,'CPU')
  ) WHERE rn=1
)
SELECT g.sql_id, g.phv, g.node,
       g.n*10 db_time_s,
       ROUND(100*g.n/NULLIF(SUM(g.n) OVER (),0),1) pct,
       ROUND(100*g.cpu_n/NULLIF(g.n,0),1) cpu_pct,
       e.wc top_class, e.event top_event, g.runs_seen
  FROM agg g LEFT JOIN ev e
    ON e.sql_id=g.sql_id AND NVL(e.phv,-1)=NVL(g.phv,-1) AND e.node=g.node
 ORDER BY db_time_s DESC
 FETCH FIRST 30 ROWS ONLY;

PROMPT
PROMPT =========================================================================
PROMPT === 5. PLAN TIMELINE - which PLAN_HASH ran in which run, and cost
PROMPT =========================================================================
PROMPT (This is the direct answer to "did the plan change on the slow runs?")
COLUMN sql_id FORMAT A14 HEADING 'SQL_ID'
COLUMN phv FORMAT 9999999999 HEADING 'PLAN_HASH'
COLUMN prcsinstance FORMAT 99999999 HEADING 'PRCS_INST'
COLUMN band FORMAT A5 HEADING 'BAND'
COLUMN run_sec FORMAT 999,990 HEADING 'RUN_SEC'
COLUMN db_time_s FORMAT 999,999,990 HEADING 'DB_TIME_S'
COLUMN pct_of_run FORMAT 990.9 HEADING 'PCT_OF_RUN'
WITH $CORR,
top AS (
  SELECT sql_id FROM (
    SELECT sql_id, COUNT(*) n,
           ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC) rn
      FROM ash GROUP BY sql_id
  ) WHERE rn <= &TOPN
)
SELECT a.sql_id, a.phv, a.prcsinstance, a.band,
       ROUND(MAX(a.run_sec)) run_sec,
       COUNT(*)*10 db_time_s,
       ROUND(100*COUNT(*)*10/NULLIF(MAX(a.run_sec),0),1) pct_of_run
  FROM ash a
 WHERE a.sql_id IN (SELECT sql_id FROM top)
 GROUP BY a.sql_id, a.phv, a.prcsinstance, a.band
 ORDER BY a.sql_id, run_sec DESC, db_time_s DESC;

PROMPT
PROMPT =========================================================================
PROMPT === 6. AWR EXECUTION STATS  x PLAN_HASH x NODE
PROMPT =========================================================================
COLUMN sql_id FORMAT A14 HEADING 'SQL_ID'
COLUMN phv FORMAT 9999999999 HEADING 'PLAN_HASH'
COLUMN node FORMAT 999 HEADING 'NODE'
COLUMN execs FORMAT 999,999,990 HEADING 'EXECS'
COLUMN avg_elap FORMAT 999,990.99 HEADING 'AVG_ELAP_S'
COLUMN avg_cpu FORMAT 999,990.99 HEADING 'AVG_CPU_S'
COLUMN avg_io FORMAT 999,990.99 HEADING 'AVG_IO_S'
COLUMN avg_cc FORMAT 999,990.99 HEADING 'AVG_CLU_S'
COLUMN tot_elap FORMAT 999,999,990 HEADING 'TOT_ELAP_S'
COLUMN avg_bg FORMAT 999,999,990 HEADING 'AVG_BUF_GETS'
COLUMN avg_rows FORMAT 999,999,990 HEADING 'AVG_ROWS'
COLUMN gets_row FORMAT 999,990.9 HEADING 'GETS/ROW'
WITH $CORR,
sqlset AS (SELECT /*+ MATERIALIZE */ DISTINCT sql_id FROM ash),
bounds AS (SELECT MIN(min_snap) lo, MAX(max_snap) hi FROM runs)
SELECT st.sql_id, st.plan_hash_value phv, st.instance_number node,
       SUM(st.executions_delta) execs,
       ROUND(SUM(st.elapsed_time_delta)/1e6/GREATEST(SUM(st.executions_delta),1),2) avg_elap,
       ROUND(SUM(st.cpu_time_delta)/1e6/GREATEST(SUM(st.executions_delta),1),2) avg_cpu,
       ROUND(SUM(st.iowait_delta)/1e6/GREATEST(SUM(st.executions_delta),1),2) avg_io,
       ROUND(SUM(st.clwait_delta)/1e6/GREATEST(SUM(st.executions_delta),1),2) avg_cc,
       ROUND(SUM(st.elapsed_time_delta)/1e6) tot_elap,
       ROUND(SUM(st.buffer_gets_delta)/GREATEST(SUM(st.executions_delta),1)) avg_bg,
       ROUND(SUM(st.rows_processed_delta)/GREATEST(SUM(st.executions_delta),1)) avg_rows,
       ROUND(SUM(st.buffer_gets_delta)/GREATEST(SUM(st.rows_processed_delta),1),1) gets_row
  FROM dba_hist_sqlstat st, bounds b
 WHERE st.sql_id IN (SELECT sql_id FROM sqlset)
   AND st.snap_id BETWEEN b.lo AND b.hi
 GROUP BY st.sql_id, st.plan_hash_value, st.instance_number
HAVING SUM(st.executions_delta) > 0
 ORDER BY tot_elap DESC
 FETCH FIRST 40 ROWS ONLY;
PROMPT (AVG_CLU_S = cluster wait per exec. Nonzero and rising = RAC contention.)

PROMPT
PROMPT =========================================================================
PROMPT === 7. PLAN INSTABILITY + CURRENT PLAN
PROMPT =========================================================================
COLUMN sql_id FORMAT A14 HEADING 'SQL_ID'
COLUMN plans FORMAT 990 HEADING 'PLANS'
COLUMN best_phv FORMAT 9999999999 HEADING 'BEST_PLAN'
COLUMN best_s FORMAT 999,990.99 HEADING 'BEST_AVG_S'
COLUMN worst_phv FORMAT 9999999999 HEADING 'WORST_PLAN'
COLUMN worst_s FORMAT 999,990.99 HEADING 'WORST_AVG_S'
COLUMN regress FORMAT 9,990.9 HEADING 'REGRESS_X'
COLUMN last_phv FORMAT 9999999999 HEADING 'CURRENT_PLAN'
COLUMN live_phv FORMAT A30 HEADING 'IN_MEMORY_NOW'
WITH $CORR,
sqlset AS (SELECT /*+ MATERIALIZE */ DISTINCT sql_id FROM ash),
bounds AS (SELECT MIN(min_snap) lo, MAX(max_snap) hi FROM runs),
pp AS (
  SELECT st.sql_id, st.plan_hash_value phv,
         SUM(st.elapsed_time_delta)/1e6/GREATEST(SUM(st.executions_delta),1) avg_s,
         MAX(st.snap_id) last_snap
    FROM dba_hist_sqlstat st, bounds b
   WHERE st.sql_id IN (SELECT sql_id FROM sqlset)
     AND st.snap_id BETWEEN b.lo AND b.hi
     AND st.plan_hash_value > 0
   GROUP BY st.sql_id, st.plan_hash_value
  HAVING SUM(st.executions_delta) > 0
)
SELECT p.sql_id, COUNT(*) plans,
       MIN(p.phv) KEEP (DENSE_RANK FIRST ORDER BY p.avg_s) best_phv,
       ROUND(MIN(p.avg_s),2) best_s,
       MIN(p.phv) KEEP (DENSE_RANK LAST ORDER BY p.avg_s) worst_phv,
       ROUND(MAX(p.avg_s),2) worst_s,
       ROUND(MAX(p.avg_s)/GREATEST(MIN(p.avg_s),0.01),1) regress,
       MIN(p.phv) KEEP (DENSE_RANK LAST ORDER BY p.last_snap) last_phv,
       (SELECT LISTAGG(DISTINCT TO_CHAR(q.plan_hash_value),',')
                 WITHIN GROUP (ORDER BY TO_CHAR(q.plan_hash_value))
          FROM gv\$sql q WHERE q.sql_id = p.sql_id) live_phv
  FROM pp p
 GROUP BY p.sql_id
HAVING COUNT(*) > 1
 ORDER BY regress DESC;
PROMPT (IN_MEMORY_NOW = plans currently in the shared pool across all nodes.)

PROMPT
PROMPT =========================================================================
PROMPT === 8. OBJECTS + STATS FRESHNESS
PROMPT =========================================================================
COLUMN obj_name FORMAT A46 HEADING 'OBJECT'
COLUMN obj_type FORMAT A9 HEADING 'TYPE'
COLUMN access_path FORMAT A26 HEADING 'ACCESS_PATH'
COLUMN num_rows FORMAT 999,999,999,990 HEADING 'NUM_ROWS'
COLUMN last_analyzed FORMAT A19 HEADING 'LAST_ANALYZED'
COLUMN age_d FORMAT 9,990 HEADING 'AGE_D'
COLUMN stale FORMAT A5 HEADING 'STALE'
WITH $CORR,
sqlset AS (SELECT /*+ MATERIALIZE */ DISTINCT sql_id FROM ash),
plns AS (
  SELECT p.object_owner owner, p.object_name name, p.object_type otype,
         p.operation||' '||NVL(p.options,' ') path
    FROM gv\$sql_plan p
   WHERE p.object_owner IS NOT NULL
     AND p.sql_id IN (SELECT sql_id FROM sqlset)
  UNION
  SELECT hp.object_owner, hp.object_name, hp.object_type,
         hp.operation||' '||NVL(hp.options,' ')
    FROM dba_hist_sql_plan hp
   WHERE hp.object_owner IS NOT NULL
     AND hp.sql_id IN (SELECT sql_id FROM sqlset)
)
SELECT pl.owner||'.'||pl.name obj_name,
       MAX(pl.otype) obj_type,
       SUBSTR(LISTAGG(DISTINCT TRIM(pl.path),'; ')
         WITHIN GROUP (ORDER BY TRIM(pl.path)),1,26) access_path,
       ts.num_rows,
       TO_CHAR(ts.last_analyzed,'YYYY-MM-DD HH24:MI:SS') last_analyzed,
       ROUND(SYSDATE - ts.last_analyzed) age_d,
       ts.stale_stats stale
  FROM plns pl
  LEFT JOIN dba_tab_statistics ts
    ON ts.owner = pl.owner AND ts.table_name = pl.name
   AND ts.object_type IN ('TABLE','PARTITION')
 GROUP BY pl.owner, pl.name, ts.num_rows, ts.last_analyzed, ts.stale_stats
 ORDER BY ts.last_analyzed NULLS FIRST, obj_name;

PROMPT
PROMPT === TOP SQL_ID / PLAN_HASH LIST (for -p plan dump) ===
SET HEADING OFF
WITH $CORR,
t AS (
  SELECT sql_id, phv, COUNT(*) n,
         ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC) rn
    FROM ash WHERE phv > 0 GROUP BY sql_id, phv
)
SELECT 'PLANKEY '||sql_id||' '||phv FROM t WHERE rn <= &TOPN;
SET HEADING ON

PROMPT
PROMPT =========================================================================
PROMPT Report complete.
PROMPT =========================================================================
EXIT;
SQLEOF

echo ""
echo "------------------------------------------------------------------------"
echo " PS JOB FORENSICS v5 | SID: ${ORACLE_SID} | JOB: ${JOB_UC} | ${DAYS}d"
echo " Correlation: CLIENT_ID=OPRID + run window + psae program"
echo "------------------------------------------------------------------------"

sqlplus -s "/ as sysdba" @"$TMPD/main.sql" \
   "$JOB_UC" "$DAYS" "$PS_OWNER_UC" "$ONE_INST" "$TOPN" | tee "$TMPD/main.out"

# =============================================================================
# REAL-TIME SECTION
# =============================================================================
if [ "$SHOW_RT" -eq 1 ]; then
  cat > "$TMPD/rt.sql" <<SQLEOF2
SET FEEDBACK OFF VERIFY OFF HEADING ON TAB OFF LINESIZE 250 PAGESIZE 200
DEFINE JOB = '&1'
DEFINE PSOWNER = '&2'
WHENEVER SQLERROR CONTINUE

PROMPT
PROMPT =========================================================================
PROMPT === REAL-TIME: LIVE SESSIONS FOR THIS JOB (all RAC nodes)
PROMPT =========================================================================
COLUMN node FORMAT 999 HEADING 'NODE'
COLUMN sid_serial FORMAT A14 HEADING 'SID,SERIAL#'
COLUMN prcsinst FORMAT 99999999 HEADING 'PRCS_INST'
COLUMN oprid FORMAT A11 HEADING 'OPRID'
COLUMN sql_id FORMAT A14 HEADING 'SQL_ID'
COLUMN phv FORMAT 9999999999 HEADING 'PLAN_HASH'
COLUMN state FORMAT A9 HEADING 'STATE'
COLUMN event FORMAT A30 HEADING 'EVENT'
COLUMN elap_s FORMAT 999,990.9 HEADING 'SQL_ELAP_S'
COLUMN sess_min FORMAT 9,990.9 HEADING 'SESS_MIN'
SELECT s.inst_id node, s.sid||','||s.serial# sid_serial,
       p.prcsinstance prcsinst, p.oprid,
       s.sql_id, q.plan_hash_value phv, s.state, s.event,
       ROUND(q.elapsed_time/1e6,1) elap_s,
       ROUND(s.last_call_et/60,1) sess_min
  FROM gv\$session s
  JOIN gv\$sql q ON q.sql_id=s.sql_id AND q.inst_id=s.inst_id
   AND q.child_number=s.sql_child_number
  JOIN &PSOWNER..psprcsrqst p
    ON  p.runstatus IN ('6','7')
    AND UPPER(s.client_info) = UPPER(p.oprid)
 WHERE s.status='ACTIVE'
   AND UPPER(p.prcsname) LIKE '%&JOB%'
 ORDER BY elap_s DESC;

PROMPT
PROMPT --- in-memory ASH (last hour, not yet in AWR) ---
COLUMN sql_id FORMAT A14 HEADING 'SQL_ID'
COLUMN phv FORMAT 9999999999 HEADING 'PLAN_HASH'
COLUMN node FORMAT 999 HEADING 'NODE'
COLUMN samples FORMAT 999,990 HEADING 'SAMPLES'
COLUMN top_event FORMAT A34 HEADING 'TOP_EVENT'
WITH live AS (
  SELECT a.sql_id, a.sql_plan_hash_value phv, a.inst_id node, a.event
    FROM gv\$active_session_history a
    JOIN &PSOWNER..psprcsrqst p
      ON  p.runstatus IN ('6','7')
      AND UPPER(a.client_id) = UPPER(p.oprid)
   WHERE a.sql_id IS NOT NULL
     AND UPPER(p.prcsname) LIKE '%&JOB%'
),
agg AS (SELECT sql_id, phv, node, COUNT(*) n FROM live GROUP BY sql_id, phv, node),
ev AS (
  SELECT sql_id, phv, node, event FROM (
    SELECT sql_id, phv, node, NVL(event,'CPU') event,
           ROW_NUMBER() OVER (PARTITION BY sql_id, phv, node
                              ORDER BY COUNT(*) DESC) rn
      FROM live GROUP BY sql_id, phv, node, NVL(event,'CPU')
  ) WHERE rn=1
)
SELECT g.sql_id, g.phv, g.node, g.n samples, e.event top_event
  FROM agg g LEFT JOIN ev e
    ON e.sql_id=g.sql_id AND NVL(e.phv,-1)=NVL(g.phv,-1) AND e.node=g.node
 ORDER BY samples DESC
 FETCH FIRST 25 ROWS ONLY;
EXIT;
SQLEOF2
  sqlplus -s "/ as sysdba" @"$TMPD/rt.sql" "$JOB_UC" "$PS_OWNER_UC"
fi

# =============================================================================
# REAL EXECUTION PLANS
# =============================================================================
if [ "$SHOW_PLANS" -eq 1 ]; then
  grep '^PLANKEY ' "$TMPD/main.out" | awk '{print $2, $3}' > "$TMPD/keys.txt"
  if [ ! -s "$TMPD/keys.txt" ]; then
    echo ""
    echo "No SQL_ID/PLAN_HASH pairs captured - nothing to explain."
  else
    cat > "$TMPD/plan.sql" <<'SQLEOF3'
SET FEEDBACK OFF VERIFY OFF HEADING OFF PAGESIZE 0 LINESIZE 200 LONG 2000000
WHENEVER SQLERROR CONTINUE
PROMPT
PROMPT =========================================================================
PROMPT === AWR PLAN: SQL_ID &1  PLAN_HASH &2
PROMPT =========================================================================
SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY_AWR('&1', &2, NULL, 'ALL'));
PROMPT
PROMPT --- in-memory version of the same cursor (if still cached) ---
SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY_CURSOR('&1', NULL, 'ALLSTATS LAST +PEEKED_BINDS'));
EXIT;
SQLEOF3
    while read -r SID PHV; do
      sqlplus -s "/ as sysdba" @"$TMPD/plan.sql" "$SID" "$PHV"
    done < "$TMPD/keys.txt"
  fi
fi

# =============================================================================
# SQL TUNING ADVISOR
# =============================================================================
[ "$RUN_STA" -eq 0 ] && exit 0

echo ""
echo "========================================================================"
echo " SQL TUNING ADVISOR (requires Tuning Pack license)"
echo "========================================================================"
read -r -p "Run it now? (y/n): " ANS
case "$ANS" in [Yy]*) ;; *) echo "Skipped."; exit 0 ;; esac
read -r -p "TARGET SQL_ID: " TARGET_SQL_ID
[ -z "$TARGET_SQL_ID" ] && { echo "ERROR: empty SQL_ID."; exit 1; }
echo "  1) Cursor cache   2) AWR"
read -r -p "Source (1 or 2): " SOURCE_OPT
PLAN_FILTER=""
[ "$SOURCE_OPT" = "2" ] && read -r -p "Restrict to PLAN_HASH_VALUE? (blank=all): " PLAN_FILTER
TASK_NAME="STA_${TARGET_SQL_ID}_$$"

cat > "$TMPD/sta.sql" <<'SQLEOF4'
SET SERVEROUTPUT ON SIZE UNLIMITED
SET LONG 5000000 LONGCHUNKSIZE 5000 PAGESIZE 0 LINESIZE 200 FEEDBACK OFF VERIFY OFF
WHENEVER SQLERROR EXIT FAILURE
DEFINE TSQL = '&1'
DEFINE TASK = '&2'
DEFINE SRC  = '&3'
DEFINE PHV  = '&4'
DECLARE
  v_exists NUMBER; v_task VARCHAR2(128); v_beg NUMBER; v_end NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_exists FROM dba_advisor_tasks WHERE task_name='&TASK';
  IF v_exists > 0 THEN DBMS_SQLTUNE.DROP_TUNING_TASK(task_name=>'&TASK'); END IF;
  IF '&SRC' = '1' THEN
    v_task := DBMS_SQLTUNE.CREATE_TUNING_TASK(
                sql_id=>'&TSQL', task_name=>'&TASK',
                scope=>DBMS_SQLTUNE.scope_comprehensive, time_limit=>1800,
                description=>'STA cursor cache');
    DBMS_OUTPUT.PUT_LINE('Task created from cursor cache.');
  ELSE
    SELECT MIN(snap_id), MAX(snap_id) INTO v_beg, v_end
      FROM dba_hist_sqlstat
     WHERE sql_id='&TSQL'
       AND ('&PHV' IS NULL OR TO_CHAR(plan_hash_value)='&PHV');
    IF v_beg IS NULL THEN
      DBMS_OUTPUT.PUT_LINE('No AWR snapshots for &TSQL.'); RETURN;
    END IF;
    v_task := DBMS_SQLTUNE.CREATE_TUNING_TASK(
                begin_snap=>v_beg, end_snap=>v_end, sql_id=>'&TSQL',
                task_name=>'&TASK', scope=>DBMS_SQLTUNE.scope_comprehensive,
                time_limit=>1800, description=>'STA AWR');
    DBMS_OUTPUT.PUT_LINE('Task created from snaps '||v_beg||'-'||v_end||'.');
  END IF;
  DBMS_SQLTUNE.EXECUTE_TUNING_TASK(task_name=>'&TASK');
END;
/
PROMPT === TUNING ADVISOR REPORT: &TASK ===
SELECT DBMS_SQLTUNE.REPORT_TUNING_TASK('&TASK') FROM dual;
BEGIN DBMS_SQLTUNE.DROP_TUNING_TASK(task_name=>'&TASK');
EXCEPTION WHEN OTHERS THEN NULL; END;
/
EXIT;
SQLEOF4

sqlplus -s "/ as sysdba" @"$TMPD/sta.sql" "$TARGET_SQL_ID" "$TASK_NAME" "$SOURCE_OPT" "$PLAN_FILTER"
exit 0

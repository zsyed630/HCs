#!/bin/bash
# =============================================================================
# ps_forensics_v3.sh - COMPLETE unified PeopleSoft on Oracle 19c RAC forensics
#
# ONE ENTRY POINT for any of:
#   Process / Job name    (<=12 chars)   e.g. FS_CEBD
#   RUN CONTROL ID        (<=30 chars)   e.g. NMH_DAILY  (auto-detected)
#   App Engine program    (<=12 chars)
#   Query Manager query   (<=30 chars)   e.g. NMH_AP_CAP_PROJ_PAY_DTL
#   Record name           (<=15 chars)
#   Oracle table/view
#   SQL_ID                (13 chars)     e.g. f4v8yvxn8pn1p
#
# Usage:
#   ./ps_forensics_v3.sh -n <ANY_NAME> [options]
#
#   -n NAME     what to investigate (required)
#   -d DAYS     lookback, default 30
#   -o SCHEMA   PeopleSoft owner, default SYSADM
#   -i INST     restrict to one PRCSINSTANCE
#   -m MODE     force: auto|process|runctl|query|record|sqlid
#   -v PHV      restrict to one PLAN_HASH_VALUE
#   -N TOPN     top SQL to detail / dump plans for, default 5
#   -w          resolve the name only, then stop
#   -a          dump App Engine static step SQL (PSAESTMT)
#   -p          execution plans: AWR history + in-memory on EVERY RAC node
#   -r          real-time: live sessions, cursor state, in-memory ASH
#   -t          interactive SQL Tuning Advisor (Tuning Pack)
#   -h          help
#
# Modes:
#   process  runs of a process/job name       (PSPRCSRQST.PRCSNAME)
#   runctl   runs under a Run Control ID      (PSPRCSRQST.RUNCNTLID)
#            - same full analysis; a run control can span many process names
#   query    PS Query -> base tables -> candidate SQL (inference, labeled)
#   record   a table/record -> SQL touching it
#   sqlid    one statement directly
#
# Correlation for process/runctl on this DB: Process Scheduler AE domains do
# NOT set MODULE/ACTION. Join = run window + CLIENT_ID=OPRID + psae program.
# Auto-detect precedence: sqlid > process > runctl > query > record.
#
# No DDL. All DBA_HIST reads bounded by snap_id + sample_time.
# =============================================================================

set -u

NAME=""; DAYS=30; PS_OWNER="${PS_OWNER:-SYSADM}"
ONE_INST=0; MODE="auto"; PHVF=0; TOPN=5
WHATIS_ONLY=0; DUMP_AE=0; SHOW_PLANS=0; SHOW_RT=0; RUN_STA=0

usage() { sed -n '2,44p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

while getopts ":n:d:o:i:m:v:N:waprth" opt; do
  case "$opt" in
    n) NAME="$OPTARG" ;;  d) DAYS="$OPTARG" ;;   o) PS_OWNER="$OPTARG" ;;
    i) ONE_INST="$OPTARG" ;; m) MODE="$OPTARG" ;; v) PHVF="$OPTARG" ;;
    N) TOPN="$OPTARG" ;;  w) WHATIS_ONLY=1 ;;   a) DUMP_AE=1 ;;
    p) SHOW_PLANS=1 ;;    r) SHOW_RT=1 ;;       t) RUN_STA=1 ;;
    *) usage ;;
  esac
done

[ -z "$NAME" ] && usage
if [ -z "${ORACLE_SID:-}" ] || [ -z "${ORACLE_HOME:-}" ]; then
  echo "ERROR: ORACLE_SID / ORACLE_HOME not set. Source your env first."; exit 1
fi
export PATH="$ORACLE_HOME/bin:$PATH"
for v in DAYS ONE_INST PHVF TOPN; do
  eval "val=\$$v"
  case "$val" in ''|*[!0-9]*) echo "ERROR: -$v must be integer."; exit 1 ;; esac
done
case "$MODE" in auto|process|runctl|query|record|sqlid) ;; 
  *) echo "ERROR: -m must be auto|process|runctl|query|record|sqlid"; exit 1 ;; esac

NAME_RAW="$NAME"
NAME_UC=$(printf '%s' "$NAME" | tr '[:lower:]' '[:upper:]')
PS_OWNER_UC=$(printf '%s' "$PS_OWNER" | tr '[:lower:]' '[:upper:]')
NLEN=${#NAME_UC}
TMPD=$(mktemp -d /tmp/psfx3.XXXXXX)
trap 'rm -rf "$TMPD"' EXIT

banner() { echo ""; echo "======================================================================="; echo " $*"; echo "======================================================================="; }

# =============================================================================
# SECTION 0 - ENVIRONMENT (always)
# =============================================================================
cat > "$TMPD/env.sql" <<'SQLEOF'
SET FEEDBACK OFF VERIFY OFF HEADING ON TAB OFF LINESIZE 220 PAGESIZE 100
WHENEVER SQLERROR CONTINUE
COLUMN db_name FORMAT A10 HEADING 'DB_NAME'
COLUMN db_unique_name FORMAT A14 HEADING 'DB_UNIQUE'
COLUMN open_mode FORMAT A11 HEADING 'OPEN_MODE'
COLUMN db_role FORMAT A16 HEADING 'ROLE'
COLUMN nodes FORMAT 999 HEADING 'NODES'
COLUMN this_inst FORMAT A10 HEADING 'THIS_INST'
COLUMN awr_ret FORMAT 9999 HEADING 'AWR_RET_D'
COLUMN snap_int FORMAT A10 HEADING 'SNAP_INTVL'
SELECT d.name db_name, d.db_unique_name, d.open_mode, d.database_role db_role,
       (SELECT COUNT(*) FROM gv$instance) nodes,
       (SELECT instance_name FROM v$instance) this_inst,
       (SELECT EXTRACT(DAY FROM retention) FROM dba_hist_wr_control
         WHERE dbid=d.dbid) awr_ret,
       (SELECT EXTRACT(HOUR FROM snap_interval)||'h'||
               EXTRACT(MINUTE FROM snap_interval)||'m'
          FROM dba_hist_wr_control WHERE dbid=d.dbid) snap_int
  FROM v$database d;
PROMPT (DBA_HIST ASH samples every 10s; each ASH row = ~10s of DB time.
PROMPT  DISPLAY_CURSOR row-source stats only work on THIS_INST - plans on the
PROMPT  other node are pulled via GV$SQL_PLAN instead.)
EXIT;
SQLEOF

banner "PS FORENSICS v3 | SID: ${ORACLE_SID} | NAME: ${NAME_UC} (${NLEN} chars) | ${DAYS}d"
sqlplus -s "/ as sysdba" @"$TMPD/env.sql"

# =============================================================================
# STEP 1 - RESOLVE
# =============================================================================
cat > "$TMPD/resolve.sql" <<'SQLEOF'
SET FEEDBACK OFF VERIFY OFF HEADING ON TAB OFF LINESIZE 220 PAGESIZE 300
DEFINE N='&1'
DEFINE NRAW='&2'
DEFINE PSOWNER='&3'
DEFINE DAYS=&4
WHENEVER SQLERROR CONTINUE

PROMPT
PROMPT === COLUMN LENGTH REALITY CHECK ===
COLUMN ps_column FORMAT A40 HEADING 'PS_COLUMN'
COLUMN maxlen FORMAT 999 HEADING 'MAXLEN'
COLUMN fits FORMAT A16 HEADING 'NAME_CAN_FIT'
SELECT c.owner||'.'||c.table_name||'.'||c.column_name ps_column, c.data_length maxlen,
       CASE WHEN LENGTH('&N') <= c.data_length THEN 'yes' ELSE 'NO - impossible' END fits
  FROM dba_tab_columns c
 WHERE c.owner='&PSOWNER'
   AND ( (c.table_name='PSPRCSRQST' AND c.column_name IN ('PRCSNAME','RUNCNTLID'))
      OR (c.table_name='PS_PRCSDEFN' AND c.column_name='PRCSNAME')
      OR (c.table_name='PS_PRCSJOBITEM' AND c.column_name='PRCSJOBNAME')
      OR (c.table_name='PSAEAPPLDEFN' AND c.column_name='AE_APPLID')
      OR (c.table_name='PSRECDEFN' AND c.column_name='RECNAME')
      OR (c.table_name='PSQRYDEFN' AND c.column_name='QRYNAME') )
 ORDER BY c.table_name, c.column_name;

PROMPT
PROMPT === WHAT MATCHES THIS NAME ===
COLUMN kind FORMAT A14 HEADING 'KIND'
COLUMN nm FORMAT A32 HEADING 'NAME'
COLUMN detail FORMAT A50 HEADING 'DETAIL'
SELECT * FROM (
  SELECT 'PROCESS' kind, d.prcsname nm, 'type='||d.prcstype detail
    FROM &PSOWNER..ps_prcsdefn d WHERE UPPER(d.prcsname) LIKE '%&N%'
  UNION ALL
  SELECT 'JOB', ji.prcsjobname, 'contains '||ji.prcsname
    FROM &PSOWNER..ps_prcsjobitem ji WHERE UPPER(ji.prcsjobname) LIKE '%&N%'
  UNION ALL
  SELECT 'RUN_CONTROL', r.runcntlid,
         'used by '||COUNT(DISTINCT r.prcsname)||' process(es), '||
         COUNT(*)||' run(s) in &DAYS d'
    FROM &PSOWNER..psprcsrqst r
   WHERE UPPER(r.runcntlid) LIKE '%&N%'
     AND r.rundttm >= SYSTIMESTAMP - NUMTODSINTERVAL(&DAYS,'DAY')
   GROUP BY r.runcntlid
  UNION ALL
  SELECT 'AE_PROGRAM', a.ae_applid, 'App Engine'
    FROM &PSOWNER..psaeappldefn a WHERE UPPER(a.ae_applid) LIKE '%&N%'
  UNION ALL
  SELECT 'QUERY', q.qryname, 'owner='||q.oprid||' '||SUBSTR(q.descr,1,30)
    FROM &PSOWNER..psqrydefn q WHERE UPPER(q.qryname) LIKE '%&N%'
  UNION ALL
  SELECT 'RECORD', r.recname,
         DECODE(r.rectype,0,'SQL Table',1,'SQL View',2,'Derived',3,'SubRecord',
                5,'Dynamic View',6,'Query View',7,'Temp Table',TO_CHAR(r.rectype))
    FROM &PSOWNER..psrecdefn r WHERE UPPER(r.recname) LIKE '%&N%'
  UNION ALL
  SELECT 'ORACLE_OBJ', o.object_name, o.owner||' '||o.object_type
    FROM dba_objects o WHERE UPPER(o.object_name) LIKE '%&N%'
     AND o.object_type IN ('TABLE','VIEW') AND o.owner IN ('&PSOWNER','SYS')
  UNION ALL
  SELECT 'SQL_ID', '&NRAW', 'found in AWR' FROM dual
   WHERE EXISTS (SELECT 1 FROM dba_hist_sqltext WHERE sql_id='&NRAW')
) ORDER BY kind, nm FETCH FIRST 50 ROWS ONLY;

PROMPT
SET HEADING OFF
SELECT 'MODEHINT|SQLID' FROM dual
 WHERE EXISTS (SELECT 1 FROM dba_hist_sqltext WHERE sql_id='&NRAW');
SELECT 'MODEHINT|PROCESS' FROM dual
 WHERE EXISTS (SELECT 1 FROM &PSOWNER..ps_prcsdefn WHERE UPPER(prcsname)='&N')
    OR EXISTS (SELECT 1 FROM &PSOWNER..psprcsrqst WHERE UPPER(prcsname)='&N')
    OR EXISTS (SELECT 1 FROM &PSOWNER..ps_prcsjobitem WHERE UPPER(prcsjobname)='&N');
SELECT 'MODEHINT|RUNCTL' FROM dual
 WHERE EXISTS (SELECT 1 FROM &PSOWNER..psprcsrqst WHERE UPPER(runcntlid)='&N');
SELECT 'MODEHINT|QUERY' FROM dual
 WHERE EXISTS (SELECT 1 FROM &PSOWNER..psqrydefn WHERE UPPER(qryname)='&N');
SELECT 'MODEHINT|RECORD' FROM dual
 WHERE EXISTS (SELECT 1 FROM &PSOWNER..psrecdefn WHERE UPPER(recname)='&N')
    OR EXISTS (SELECT 1 FROM dba_objects WHERE owner='&PSOWNER'
                AND object_name='&N' AND object_type IN ('TABLE','VIEW'));
SET HEADING ON
EXIT;
SQLEOF

sqlplus -s "/ as sysdba" @"$TMPD/resolve.sql" \
  "$NAME_UC" "$NAME_RAW" "$PS_OWNER_UC" "$DAYS" | tee "$TMPD/resolve.out"

if [ "$MODE" = "auto" ]; then
  if   grep -q 'MODEHINT|SQLID'   "$TMPD/resolve.out"; then MODE="sqlid"
  elif grep -q 'MODEHINT|PROCESS' "$TMPD/resolve.out"; then MODE="process"
  elif grep -q 'MODEHINT|RUNCTL'  "$TMPD/resolve.out"; then MODE="runctl"
  elif grep -q 'MODEHINT|QUERY'   "$TMPD/resolve.out"; then MODE="query"
  elif grep -q 'MODEHINT|RECORD'  "$TMPD/resolve.out"; then MODE="record"
  else MODE="none"; fi
fi
echo ""; echo " RESOLVED MODE: ${MODE}"
[ "$WHATIS_ONLY" -eq 1 ] && exit 0
if [ "$MODE" = "none" ]; then
  echo ""; echo " No exact match in PS catalogs, run controls, or AWR."
  echo " Use an exact name, or force with -m process|runctl|query|record|sqlid."
  exit 0
fi

# -----------------------------------------------------------------------------
# Correlation block. RUNFILTER differs: process matches PRCSNAME, runctl
# matches RUNCNTLID (one run control can drive many different processes).
# -----------------------------------------------------------------------------
if [ "$MODE" = "runctl" ]; then
  RUNFILTER="UPPER(r.runcntlid) LIKE '%&N%'"
else
  RUNFILTER="UPPER(r.prcsname) LIKE '%&N%'"
fi

read -r -d '' CORR <<CORREOF || true
runs AS (
  SELECT /*+ MATERIALIZE */
         r.prcsinstance, r.prcsname, r.runcntlid, r.oprid, r.servernamerun,
         CAST(r.begindttm AS TIMESTAMP) beg_ts,
         CAST(r.enddttm   AS TIMESTAMP) end_ts,
         (CAST(r.enddttm AS DATE)-CAST(r.begindttm AS DATE))*86400 run_sec,
         (SELECT MIN(s.snap_id) FROM dba_hist_snapshot s
           WHERE s.end_interval_time >= r.begindttm) min_snap,
         (SELECT MAX(s.snap_id) FROM dba_hist_snapshot s
           WHERE s.begin_interval_time <= r.enddttm) max_snap
    FROM &PSOWNER..psprcsrqst r
   WHERE $RUNFILTER
     AND r.rundttm >= SYSTIMESTAMP - NUMTODSINTERVAL(&DAYS,'DAY')
     AND r.begindttm IS NOT NULL AND r.enddttm IS NOT NULL
     AND (&ONEINST = 0 OR r.prcsinstance = &ONEINST)),
thr AS (SELECT PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY run_sec) p75 FROM runs),
banded AS (SELECT r.*, CASE WHEN r.run_sec >= t.p75 THEN 'SLOW' ELSE 'FAST' END band
             FROM runs r CROSS JOIN thr t),
ash AS (
  SELECT /*+ MATERIALIZE */
         h.sql_id, h.sql_plan_hash_value phv, h.instance_number node,
         h.event, h.wait_class, h.session_state, h.sample_time,
         b.prcsinstance, b.prcsname, b.band, b.run_sec
    FROM banded b
    JOIN dba_hist_active_sess_history h
      ON  h.snap_id     BETWEEN b.min_snap AND b.max_snap
      AND h.sample_time BETWEEN b.beg_ts   AND b.end_ts
      AND UPPER(h.client_id) = UPPER(b.oprid)
   WHERE h.sql_id IS NOT NULL
     AND (   LOWER(h.program) LIKE 'psae@%' OR LOWER(h.module) LIKE 'psae@%'
          OR UPPER(h.module) LIKE 'PSAE%'
          OR UPPER(h.action) LIKE '%'||UPPER(b.prcsname)||'%'
          OR UPPER(h.module) LIKE '%'||UPPER(b.prcsname)||'%'))
CORREOF

# =============================================================================
# STEP 2 - MODE CONTEXT
# =============================================================================
case "$MODE" in

process|runctl)
cat > "$TMPD/ctx.sql" <<SQLEOF
SET FEEDBACK OFF VERIFY OFF HEADING ON TAB OFF LINESIZE 245 PAGESIZE 400 TIMING ON
DEFINE N='&1'
DEFINE DAYS=&2
DEFINE PSOWNER='&3'
DEFINE ONEINST=&4
WHENEVER SQLERROR CONTINUE

PROMPT
PROMPT === P1. RUN PROFILE ===
COLUMN prcsinstance FORMAT 99999999 HEADING 'PRCS_INST'
COLUMN prcsname FORMAT A13 HEADING 'PRCS_NAME'
COLUMN runcntlid FORMAT A18 HEADING 'RUN_CONTROL'
COLUMN oprid FORMAT A11 HEADING 'OPRID'
COLUMN servernamerun FORMAT A8 HEADING 'SERVER'
COLUMN beg FORMAT A19 HEADING 'BEGIN'
COLUMN fin FORMAT A19 HEADING 'END'
COLUMN run_sec FORMAT 999,990 HEADING 'RUN_SEC'
COLUMN band FORMAT A5 HEADING 'BAND'
WITH $CORR
SELECT b.prcsinstance, b.prcsname, b.runcntlid, b.oprid, b.servernamerun,
       TO_CHAR(b.beg_ts,'YYYY-MM-DD HH24:MI:SS') beg,
       TO_CHAR(b.end_ts,'YYYY-MM-DD HH24:MI:SS') fin,
       ROUND(b.run_sec) run_sec, b.band
  FROM banded b ORDER BY b.beg_ts DESC;

PROMPT
PROMPT === P1b. ATTRIBUTION CONFIDENCE ===
COLUMN prcsinstance FORMAT 99999999 HEADING 'PRCS_INST'
COLUMN overlaps FORMAT 990 HEADING 'OVERLAP'
COLUMN other_names FORMAT A50 HEADING 'OTHER_PROCESSES_SAME_OPRID'
COLUMN confidence FORMAT A9 HEADING 'CONFIDENCE'
WITH $CORR
SELECT b.prcsinstance, COUNT(o.prcsinstance) overlaps,
       SUBSTR(LISTAGG(DISTINCT o.prcsname,',') WITHIN GROUP (ORDER BY o.prcsname),1,50) other_names,
       CASE WHEN COUNT(o.prcsinstance)=0 THEN 'CLEAN' ELSE 'BLENDED' END confidence
  FROM banded b LEFT JOIN &PSOWNER..psprcsrqst o
    ON o.oprid=b.oprid AND o.prcsinstance<>b.prcsinstance
   AND o.begindttm < b.end_ts AND o.enddttm > b.beg_ts
 GROUP BY b.prcsinstance ORDER BY overlaps DESC;
PROMPT (BLENDED = ASH in that window includes other work by the same operator.)

PROMPT
PROMPT === P2. CORRELATION HEALTH ===
COLUMN prcsinstance FORMAT 99999999 HEADING 'PRCS_INST'
COLUMN prcsname FORMAT A13 HEADING 'PRCS_NAME'
COLUMN run_sec FORMAT 999,990 HEADING 'RUN_SEC'
COLUMN db_time_s FORMAT 999,999,990 HEADING 'DB_TIME_S'
COLUMN aas FORMAT 990.9 HEADING 'AVG_ACT_SESS'
COLUMN sqls FORMAT 9,990 HEADING 'SQLS'
COLUMN plans FORMAT 9,990 HEADING 'PLANS'
COLUMN nodes_used FORMAT A9 HEADING 'RAC_NODES'
WITH $CORR
SELECT a.prcsinstance, MAX(a.prcsname) prcsname, ROUND(MAX(a.run_sec)) run_sec,
       COUNT(*)*10 db_time_s,
       ROUND(COUNT(*)*10/NULLIF(MAX(a.run_sec),0),1) aas,
       COUNT(DISTINCT a.sql_id) sqls, COUNT(DISTINCT a.phv) plans,
       LISTAGG(DISTINCT TO_CHAR(a.node),',') WITHIN GROUP (ORDER BY TO_CHAR(a.node)) nodes_used
  FROM ash a GROUP BY a.prcsinstance ORDER BY db_time_s DESC;
PROMPT (AVG_ACT_SESS ~0 = correlation failed for that run.)

PROMPT
PROMPT === P3. WAIT PROFILE BY RAC NODE AND BAND ===
COLUMN node FORMAT 999 HEADING 'NODE'
COLUMN band FORMAT A5 HEADING 'BAND'
COLUMN wait_class FORMAT A16 HEADING 'WAIT_CLASS'
COLUMN db_time_s FORMAT 999,999,990 HEADING 'DB_TIME_S'
COLUMN pct FORMAT 990.9 HEADING 'PCT'
COLUMN top_event FORMAT A34 HEADING 'TOP_EVENT'
WITH $CORR,
g AS (SELECT node, band, NVL(wait_class,'CPU') wc, COUNT(*) n FROM ash
       GROUP BY node, band, NVL(wait_class,'CPU')),
e AS (SELECT node,band,wc,event FROM (
        SELECT node, band, NVL(wait_class,'CPU') wc, NVL(event,'CPU') event,
               ROW_NUMBER() OVER (PARTITION BY node,band,NVL(wait_class,'CPU')
                                  ORDER BY COUNT(*) DESC) rn
          FROM ash GROUP BY node,band,NVL(wait_class,'CPU'),NVL(event,'CPU')) WHERE rn=1)
SELECT g.node, g.band, g.wc wait_class, g.n*10 db_time_s,
       ROUND(100*g.n/NULLIF(SUM(g.n) OVER (),0),1) pct, e.event top_event
  FROM g LEFT JOIN e ON e.node=g.node AND e.band=g.band AND e.wc=g.wc
 ORDER BY db_time_s DESC;
PROMPT (Cluster class = global cache. High Cluster on SLOW only = interconnect
PROMPT  or cross-node block contention, not a SQL problem.)

PROMPT
PROMPT === P4. PLAN TIMELINE - which plan ran in which run ===
COLUMN sql_id FORMAT A14 HEADING 'SQL_ID'
COLUMN phv FORMAT 9999999999 HEADING 'PLAN_HASH'
COLUMN prcsinstance FORMAT 99999999 HEADING 'PRCS_INST'
COLUMN band FORMAT A5 HEADING 'BAND'
COLUMN run_sec FORMAT 999,990 HEADING 'RUN_SEC'
COLUMN db_time_s FORMAT 999,999,990 HEADING 'DB_TIME_S'
COLUMN pct_of_run FORMAT 990.9 HEADING 'PCT_OF_RUN'
COLUMN last_seen FORMAT A19 HEADING 'LAST_SEEN_IN_RUN'
WITH $CORR,
t AS (SELECT sql_id FROM (SELECT sql_id, ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC) rn
        FROM ash GROUP BY sql_id) WHERE rn <= 10)
SELECT a.sql_id, a.phv, a.prcsinstance, a.band, ROUND(MAX(a.run_sec)) run_sec,
       COUNT(*)*10 db_time_s,
       ROUND(100*COUNT(*)*10/NULLIF(MAX(a.run_sec),0),1) pct_of_run,
       TO_CHAR(MAX(a.sample_time),'YYYY-MM-DD HH24:MI:SS') last_seen
  FROM ash a WHERE a.sql_id IN (SELECT sql_id FROM t)
 GROUP BY a.sql_id, a.phv, a.prcsinstance, a.band
 ORDER BY a.sql_id, run_sec DESC;
PROMPT (Direct answer to "did the plan change on the slow runs?")

PROMPT
PROMPT === P5. FAST vs SLOW VERDICT ===
COLUMN sql_id FORMAT A14 HEADING 'SQL_ID'
COLUMN phv FORMAT 9999999999 HEADING 'PLAN_HASH'
COLUMN fast_s FORMAT 999,999,990 HEADING 'FAST_DBT_S'
COLUMN slow_s FORMAT 999,999,990 HEADING 'SLOW_DBT_S'
COLUMN per_fast FORMAT 999,990 HEADING 'S/FAST_RUN'
COLUMN per_slow FORMAT 999,990 HEADING 'S/SLOW_RUN'
COLUMN verdict FORMAT A22 HEADING 'VERDICT'
WITH $CORR,
g AS (SELECT sql_id, phv,
        SUM(CASE WHEN band='FAST' THEN 10 ELSE 0 END) fast_s,
        SUM(CASE WHEN band='SLOW' THEN 10 ELSE 0 END) slow_s,
        COUNT(DISTINCT CASE WHEN band='FAST' THEN prcsinstance END) fr,
        COUNT(DISTINCT CASE WHEN band='SLOW' THEN prcsinstance END) sr
      FROM ash GROUP BY sql_id, phv)
SELECT sql_id, phv, fast_s, slow_s,
       ROUND(fast_s/NULLIF(fr,0)) per_fast, ROUND(slow_s/NULLIF(sr,0)) per_slow,
       CASE WHEN fr=0 THEN 'SLOW RUNS ONLY' WHEN sr=0 THEN 'fast runs only'
            WHEN (slow_s/NULLIF(sr,0)) > 4*(fast_s/NULLIF(fr,0)) THEN 'BLOWS UP WHEN SLOW'
            ELSE 'scales with volume' END verdict
  FROM g WHERE fast_s+slow_s > 0 ORDER BY slow_s DESC FETCH FIRST 25 ROWS ONLY;

PROMPT
PROMPT === P6. TOP SQL_ID x PLAN_HASH x NODE (ASH DB-time ranking) ===
COLUMN sql_id FORMAT A14 HEADING 'SQL_ID'
COLUMN phv FORMAT 9999999999 HEADING 'PLAN_HASH'
COLUMN node FORMAT 999 HEADING 'NODE'
COLUMN db_time_s FORMAT 999,999,990 HEADING 'DB_TIME_S'
COLUMN pct FORMAT 990.9 HEADING 'PCT'
COLUMN cpu_pct FORMAT 990.9 HEADING 'CPU_%'
COLUMN top_class FORMAT A13 HEADING 'TOP_WAIT_CLS'
COLUMN top_event FORMAT A26 HEADING 'TOP_EVENT'
COLUMN runs_seen FORMAT 990 HEADING 'RUNS'
WITH $CORR,
g AS (SELECT sql_id, phv, node, COUNT(*) n,
        SUM(CASE WHEN session_state='ON CPU' THEN 1 ELSE 0 END) cpu_n,
        COUNT(DISTINCT prcsinstance) runs_seen
      FROM ash GROUP BY sql_id, phv, node),
e AS (SELECT sql_id,phv,node,wc,event FROM (
        SELECT sql_id, phv, node, NVL(wait_class,'CPU') wc, NVL(event,'CPU') event,
               ROW_NUMBER() OVER (PARTITION BY sql_id,phv,node ORDER BY COUNT(*) DESC) rn
          FROM ash GROUP BY sql_id,phv,node,NVL(wait_class,'CPU'),NVL(event,'CPU')) WHERE rn=1)
SELECT g.sql_id, g.phv, g.node, g.n*10 db_time_s,
       ROUND(100*g.n/NULLIF(SUM(g.n) OVER (),0),1) pct,
       ROUND(100*g.cpu_n/NULLIF(g.n,0),1) cpu_pct,
       e.wc top_class, e.event top_event, g.runs_seen
  FROM g LEFT JOIN e ON e.sql_id=g.sql_id AND NVL(e.phv,-1)=NVL(g.phv,-1) AND e.node=g.node
 ORDER BY db_time_s DESC FETCH FIRST 30 ROWS ONLY;

SET HEADING OFF
WITH $CORR,
t AS (SELECT sql_id, ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC) rn FROM ash GROUP BY sql_id)
SELECT 'SQLKEY '||sql_id FROM t WHERE rn <= 100;
WITH $CORR
SELECT DISTINCT 'AEKEY '||prcsname FROM ash WHERE prcsname IS NOT NULL;
SET HEADING ON
EXIT;
SQLEOF
sqlplus -s "/ as sysdba" @"$TMPD/ctx.sql" "$NAME_UC" "$DAYS" "$PS_OWNER_UC" "$ONE_INST" | tee "$TMPD/ctx.out"
;;

query|record)
[ "$MODE" = "query" ] && OBJSRC="query" || OBJSRC="record"
cat > "$TMPD/ctx.sql" <<'SQLEOF'
SET FEEDBACK OFF VERIFY OFF HEADING ON TAB OFF LINESIZE 245 PAGESIZE 400 TIMING ON
DEFINE N='&1'
DEFINE DAYS=&2
DEFINE PSOWNER='&3'
DEFINE SRC='&4'
WHENEVER SQLERROR CONTINUE

PROMPT
PROMPT === Q1. DEFINITION ===
COLUMN qryname FORMAT A32 HEADING 'QUERY_NAME'
COLUMN oprid FORMAT A12 HEADING 'OWNER'
COLUMN descr FORMAT A44 HEADING 'DESCRIPTION'
COLUMN lastupd FORMAT A19 HEADING 'LAST_UPDATED'
SELECT q.qryname, q.oprid, q.descr,
       TO_CHAR(q.lastupddttm,'YYYY-MM-DD HH24:MI:SS') lastupd
  FROM &PSOWNER..psqrydefn q WHERE UPPER(q.qryname)='&N';

PROMPT
PROMPT === Q2. BASE TABLES + STATS ===
COLUMN seq FORMAT 990 HEADING 'SEQ'
COLUMN ps_record FORMAT A20 HEADING 'PS_RECORD'
COLUMN phys FORMAT A26 HEADING 'PHYSICAL_TABLE'
COLUMN num_rows FORMAT 999,999,999,990 HEADING 'NUM_ROWS'
COLUMN last_analyzed FORMAT A19 HEADING 'LAST_ANALYZED'
COLUMN age_d FORMAT 9,990 HEADING 'AGE_D'
COLUMN stale FORMAT A5 HEADING 'STALE'
SELECT s.rcdnum seq, s.recname ps_record, 'PS_'||s.recname phys, ts.num_rows,
       TO_CHAR(ts.last_analyzed,'YYYY-MM-DD HH24:MI:SS') last_analyzed,
       ROUND(SYSDATE-ts.last_analyzed) age_d, ts.stale_stats stale
  FROM &PSOWNER..psqryrecord s
  LEFT JOIN dba_tab_statistics ts ON ts.owner='&PSOWNER'
   AND ts.table_name='PS_'||s.recname AND ts.object_type='TABLE'
 WHERE UPPER(s.qryname)='&N' AND '&SRC'='query'
UNION ALL
SELECT 1, '&N', ts.table_name, ts.num_rows,
       TO_CHAR(ts.last_analyzed,'YYYY-MM-DD HH24:MI:SS'),
       ROUND(SYSDATE-ts.last_analyzed), ts.stale_stats
  FROM dba_tab_statistics ts WHERE ts.owner='&PSOWNER'
   AND ts.table_name IN ('PS_&N','&N') AND ts.object_type='TABLE' AND '&SRC'='record'
 ORDER BY 1;

PROMPT
PROMPT === Q3. CANDIDATE SQL (plan touches those base tables) ===
PROMPT (Inference: PS never stamps a query name in ASH. HITS/OF_TOTAL = how many
PROMPT  of the base tables that statement references.)
COLUMN sql_id FORMAT A14 HEADING 'SQL_ID'
COLUMN hits FORMAT 990 HEADING 'HITS'
COLUMN total FORMAT 990 HEADING 'OF_TOTAL'
COLUMN execs FORMAT 999,999,990 HEADING 'EXECS'
COLUMN tot_elap FORMAT 999,999,990 HEADING 'TOT_ELAP_S'
COLUMN last_exec FORMAT A19 HEADING 'LAST_EXEC'
COLUMN sql_preview FORMAT A44 HEADING 'SQL_TEXT_PREVIEW'
WITH qt AS (
  SELECT DISTINCT 'PS_'||recname tab FROM &PSOWNER..psqryrecord
   WHERE UPPER(qryname)='&N' AND '&SRC'='query'
  UNION SELECT t FROM (SELECT 'PS_&N' t FROM dual UNION SELECT '&N' FROM dual)
   WHERE '&SRC'='record'),
b AS (SELECT MIN(snap_id) lo, MAX(snap_id) hi FROM dba_hist_snapshot
       WHERE end_interval_time >= SYSTIMESTAMP - NUMTODSINTERVAL(&DAYS,'DAY')),
cand AS (SELECT p.sql_id, COUNT(DISTINCT p.object_name) hits
           FROM dba_hist_sql_plan p
          WHERE p.object_owner='&PSOWNER' AND p.object_name IN (SELECT tab FROM qt)
            AND p.timestamp >= SYSDATE - &DAYS
          GROUP BY p.sql_id),
sc AS (SELECT st.sql_id, SUM(st.executions_delta) execs,
              SUM(st.elapsed_time_delta)/1e6 tot_elap,
              MAX(sn.end_interval_time) last_exec
         FROM dba_hist_sqlstat st
         JOIN dba_hist_snapshot sn ON sn.snap_id=st.snap_id AND sn.dbid=st.dbid
          AND sn.instance_number=st.instance_number
         CROSS JOIN b
        WHERE st.snap_id BETWEEN b.lo AND b.hi
          AND st.sql_id IN (SELECT sql_id FROM cand) AND st.executions_delta > 0
        GROUP BY st.sql_id)
SELECT c.sql_id, c.hits, (SELECT COUNT(*) FROM qt) total, sc.execs,
       ROUND(sc.tot_elap) tot_elap,
       TO_CHAR(sc.last_exec,'YYYY-MM-DD HH24:MI:SS') last_exec,
       SUBSTR(REGEXP_REPLACE((SELECT MIN(TO_CHAR(SUBSTR(x.sql_text,1,300)))
         FROM dba_hist_sqltext x WHERE x.sql_id=c.sql_id),'[[:space:]]+',' '),1,44) sql_preview
  FROM cand c LEFT JOIN sc ON sc.sql_id=c.sql_id
 WHERE c.hits >= GREATEST(1, CEIL((SELECT COUNT(*) FROM qt)*0.6))
 ORDER BY sc.tot_elap DESC NULLS LAST FETCH FIRST 25 ROWS ONLY;

PROMPT
PROMPT === Q4. WHO RAN THOSE STATEMENTS ===
COLUMN module FORMAT A32 HEADING 'MODULE'
COLUMN client_id FORMAT A14 HEADING 'CLIENT_ID'
COLUMN node FORMAT 999 HEADING 'NODE'
COLUMN db_time_s FORMAT 999,999,990 HEADING 'DB_TIME_S'
WITH qt AS (
  SELECT DISTINCT 'PS_'||recname tab FROM &PSOWNER..psqryrecord
   WHERE UPPER(qryname)='&N' AND '&SRC'='query'
  UNION SELECT t FROM (SELECT 'PS_&N' t FROM dual UNION SELECT '&N' FROM dual)
   WHERE '&SRC'='record'),
b AS (SELECT MIN(snap_id) lo, MAX(snap_id) hi FROM dba_hist_snapshot
       WHERE end_interval_time >= SYSTIMESTAMP - NUMTODSINTERVAL(&DAYS,'DAY')),
cand AS (SELECT p.sql_id FROM dba_hist_sql_plan p
          WHERE p.object_owner='&PSOWNER' AND p.object_name IN (SELECT tab FROM qt)
            AND p.timestamp >= SYSDATE - &DAYS
          GROUP BY p.sql_id
         HAVING COUNT(DISTINCT p.object_name) >= GREATEST(1, CEIL((SELECT COUNT(*) FROM qt)*0.6)))
SELECT h.module, h.client_id, h.instance_number node, COUNT(*)*10 db_time_s
  FROM dba_hist_active_sess_history h, b
 WHERE h.snap_id BETWEEN b.lo AND b.hi AND h.sql_id IN (SELECT sql_id FROM cand)
 GROUP BY h.module, h.client_id, h.instance_number
 ORDER BY db_time_s DESC FETCH FIRST 20 ROWS ONLY;

SET HEADING OFF
WITH qt AS (
  SELECT DISTINCT 'PS_'||recname tab FROM &PSOWNER..psqryrecord
   WHERE UPPER(qryname)='&N' AND '&SRC'='query'
  UNION SELECT t FROM (SELECT 'PS_&N' t FROM dual UNION SELECT '&N' FROM dual)
   WHERE '&SRC'='record'),
b AS (SELECT MIN(snap_id) lo, MAX(snap_id) hi FROM dba_hist_snapshot
       WHERE end_interval_time >= SYSTIMESTAMP - NUMTODSINTERVAL(&DAYS,'DAY')),
cand AS (SELECT p.sql_id FROM dba_hist_sql_plan p
          WHERE p.object_owner='&PSOWNER' AND p.object_name IN (SELECT tab FROM qt)
            AND p.timestamp >= SYSDATE - &DAYS
          GROUP BY p.sql_id
         HAVING COUNT(DISTINCT p.object_name) >= GREATEST(1, CEIL((SELECT COUNT(*) FROM qt)*0.6))),
r AS (SELECT c.sql_id, ROW_NUMBER() OVER (
        ORDER BY NVL((SELECT SUM(st.elapsed_time_delta) FROM dba_hist_sqlstat st, b
                       WHERE st.sql_id=c.sql_id AND st.snap_id BETWEEN b.lo AND b.hi),0) DESC) rn
        FROM cand c)
SELECT 'SQLKEY '||sql_id FROM r WHERE rn <= 100;
SET HEADING ON
EXIT;
SQLEOF
sqlplus -s "/ as sysdba" @"$TMPD/ctx.sql" "$NAME_UC" "$DAYS" "$PS_OWNER_UC" "$OBJSRC" | tee "$TMPD/ctx.out"
;;

sqlid) echo "SQLKEY ${NAME_RAW}" > "$TMPD/ctx.out" ;;
esac

# =============================================================================
# APP ENGINE STATIC STEP SQL  (-a)
# =============================================================================
if [ "$DUMP_AE" -eq 1 ]; then
  # In runctl mode the AE programs come from the runs; otherwise use the name.
  grep '^AEKEY ' "$TMPD/ctx.out" 2>/dev/null | awk '{print $2}' | sort -u > "$TMPD/ae.txt"
  [ ! -s "$TMPD/ae.txt" ] && echo "$NAME_UC" > "$TMPD/ae.txt"
cat > "$TMPD/ae.sql" <<'SQLEOF'
SET FEEDBACK OFF VERIFY OFF HEADING ON TAB OFF LINESIZE 200 PAGESIZE 5000
SET LONG 200000 LONGCHUNKSIZE 20000
DEFINE AE='&1'
DEFINE PSOWNER='&2'
WHENEVER SQLERROR CONTINUE
PROMPT
PROMPT === APP ENGINE STATIC STEP SQL: &AE (PSAESTMT) ===
COLUMN ae_applid FORMAT A16 HEADING 'AE_PROGRAM'
COLUMN ae_section FORMAT A18 HEADING 'SECTION'
COLUMN ae_step FORMAT A12 HEADING 'STEP'
COLUMN ae_stmt_type FORMAT A6 HEADING 'TYPE'
COLUMN ae_stmt_text FORMAT A120 HEADING 'STATEMENT'
SELECT s.ae_applid, s.ae_section, s.ae_step, s.ae_stmt_type, s.ae_stmt_text
  FROM &PSOWNER..psaestmt s
 WHERE UPPER(s.ae_applid) LIKE '%&AE%'
 ORDER BY s.ae_applid, s.ae_section, s.ae_step, s.ae_seq_num;
EXIT;
SQLEOF
  banner "APP ENGINE STATIC STEP SQL"
  while read -r AE; do
    sqlplus -s "/ as sysdba" @"$TMPD/ae.sql" "$AE" "$PS_OWNER_UC"
  done < "$TMPD/ae.txt"
fi

# =============================================================================
# STEP 3 - DEEP ANALYSIS
# =============================================================================
grep '^SQLKEY ' "$TMPD/ctx.out" | awk '{print $2}' | sort -u | head -200 > "$TMPD/ids.txt"
[ ! -s "$TMPD/ids.txt" ] && { banner "No SQL_IDs correlated. Nothing further."; exit 0; }
IDLIST=$(awk '{printf "%s'\''%s'\''", (NR>1 ? "," : ""), $1}' "$TMPD/ids.txt")
NIDS=$(wc -l < "$TMPD/ids.txt")
banner "DEEP SQL ANALYSIS - ${NIDS} statement(s)"

cat > "$TMPD/deep.sql" <<SQLEOF
SET FEEDBACK OFF VERIFY OFF HEADING ON TAB OFF LINESIZE 250 PAGESIZE 500 TIMING ON
DEFINE DAYS=&1
DEFINE PSOWNER='&2'
DEFINE PHVF=&3
DEFINE TOPN=&4
WHENEVER SQLERROR CONTINUE

PROMPT
PROMPT === D1. AWR EXECUTION STATS x PLAN_HASH x NODE (with run times) ===
COLUMN sql_id FORMAT A14 HEADING 'SQL_ID'
COLUMN phv FORMAT 9999999999 HEADING 'PLAN_HASH'
COLUMN node FORMAT 999 HEADING 'NODE'
COLUMN execs FORMAT 999,999,990 HEADING 'EXECS'
COLUMN avg_elap FORMAT 999,990.99 HEADING 'AVG_ELAP_S'
COLUMN avg_cpu FORMAT 999,990.99 HEADING 'AVG_CPU_S'
COLUMN avg_io FORMAT 999,990.99 HEADING 'AVG_IO_S'
COLUMN avg_clu FORMAT 999,990.99 HEADING 'AVG_CLU_S'
COLUMN tot_elap FORMAT 999,999,990 HEADING 'TOT_ELAP_S'
COLUMN avg_bg FORMAT 999,999,990 HEADING 'AVG_BUF_GETS'
COLUMN avg_rows FORMAT 999,999,990 HEADING 'AVG_ROWS'
COLUMN first_exec FORMAT A17 HEADING 'FIRST_EXEC'
COLUMN last_exec FORMAT A17 HEADING 'LAST_EXEC'
WITH b AS (SELECT MIN(snap_id) lo, MAX(snap_id) hi FROM dba_hist_snapshot
            WHERE end_interval_time >= SYSTIMESTAMP - NUMTODSINTERVAL(&DAYS,'DAY'))
SELECT st.sql_id, st.plan_hash_value phv, st.instance_number node,
       SUM(st.executions_delta) execs,
       ROUND(SUM(st.elapsed_time_delta)/1e6/GREATEST(SUM(st.executions_delta),1),2) avg_elap,
       ROUND(SUM(st.cpu_time_delta)/1e6/GREATEST(SUM(st.executions_delta),1),2) avg_cpu,
       ROUND(SUM(st.iowait_delta)/1e6/GREATEST(SUM(st.executions_delta),1),2) avg_io,
       ROUND(SUM(st.clwait_delta)/1e6/GREATEST(SUM(st.executions_delta),1),2) avg_clu,
       ROUND(SUM(st.elapsed_time_delta)/1e6) tot_elap,
       ROUND(SUM(st.buffer_gets_delta)/GREATEST(SUM(st.executions_delta),1)) avg_bg,
       ROUND(SUM(st.rows_processed_delta)/GREATEST(SUM(st.executions_delta),1)) avg_rows,
       TO_CHAR(MIN(sn.begin_interval_time),'MM-DD HH24:MI') first_exec,
       TO_CHAR(MAX(sn.end_interval_time),'MM-DD HH24:MI') last_exec
  FROM dba_hist_sqlstat st
  JOIN dba_hist_snapshot sn ON sn.snap_id=st.snap_id AND sn.dbid=st.dbid
   AND sn.instance_number=st.instance_number
  CROSS JOIN b
 WHERE st.sql_id IN ($IDLIST) AND st.snap_id BETWEEN b.lo AND b.hi
   AND st.executions_delta > 0 AND (&PHVF = 0 OR st.plan_hash_value = &PHVF)
 GROUP BY st.sql_id, st.plan_hash_value, st.instance_number
 ORDER BY tot_elap DESC FETCH FIRST 40 ROWS ONLY;
PROMPT (GETS/ROW pathology: millions of gets for few rows = broken access path.)

PROMPT
PROMPT === D2. PLAN INSTABILITY + CURRENT PLAN ===
COLUMN sql_id FORMAT A14 HEADING 'SQL_ID'
COLUMN plans FORMAT 990 HEADING 'PLANS'
COLUMN best_phv FORMAT 9999999999 HEADING 'BEST_PLAN'
COLUMN best_s FORMAT 999,990.99 HEADING 'BEST_AVG_S'
COLUMN worst_phv FORMAT 9999999999 HEADING 'WORST_PLAN'
COLUMN worst_s FORMAT 999,990.99 HEADING 'WORST_AVG_S'
COLUMN regress FORMAT 9,990.9 HEADING 'REGRESS_X'
COLUMN last_phv FORMAT 9999999999 HEADING 'CURRENT_PLAN'
WITH b AS (SELECT MIN(snap_id) lo, MAX(snap_id) hi FROM dba_hist_snapshot
            WHERE end_interval_time >= SYSTIMESTAMP - NUMTODSINTERVAL(&DAYS,'DAY')),
pp AS (SELECT st.sql_id, st.plan_hash_value phv,
              SUM(st.elapsed_time_delta)/1e6/GREATEST(SUM(st.executions_delta),1) avg_s,
              MAX(st.snap_id) last_snap
         FROM dba_hist_sqlstat st, b
        WHERE st.sql_id IN ($IDLIST) AND st.snap_id BETWEEN b.lo AND b.hi
          AND st.plan_hash_value > 0
        GROUP BY st.sql_id, st.plan_hash_value HAVING SUM(st.executions_delta) > 0)
SELECT sql_id, COUNT(*) plans,
       MIN(phv) KEEP (DENSE_RANK FIRST ORDER BY avg_s) best_phv, ROUND(MIN(avg_s),2) best_s,
       MIN(phv) KEEP (DENSE_RANK LAST ORDER BY avg_s) worst_phv, ROUND(MAX(avg_s),2) worst_s,
       ROUND(MAX(avg_s)/GREATEST(MIN(avg_s),0.01),1) regress,
       MIN(phv) KEEP (DENSE_RANK LAST ORDER BY last_snap) last_phv
  FROM pp GROUP BY sql_id HAVING COUNT(*) > 1 ORDER BY regress DESC;
PROMPT (CURRENT_PLAN = WORST_PLAN means a live regression - SQL plan baseline
PROMPT  on BEST_PLAN is the candidate fix.)

PROMPT
PROMPT === D3. WHICH PLAN LINE BURNS THE TIME ===
COLUMN sql_id FORMAT A14 HEADING 'SQL_ID'
COLUMN phv FORMAT 9999999999 HEADING 'PLAN_HASH'
COLUMN line_id FORMAT 9990 HEADING 'LINE'
COLUMN operation FORMAT A24 HEADING 'OPERATION'
COLUMN options FORMAT A20 HEADING 'OPTIONS'
COLUMN db_time_s FORMAT 999,999,990 HEADING 'DB_TIME_S'
COLUMN pct FORMAT 990.9 HEADING 'PCT'
COLUMN cpu_pct FORMAT 990.9 HEADING 'CPU_%'
COLUMN top_event FORMAT A24 HEADING 'TOP_EVENT'
WITH b AS (SELECT MIN(snap_id) lo, MAX(snap_id) hi FROM dba_hist_snapshot
            WHERE end_interval_time >= SYSTIMESTAMP - NUMTODSINTERVAL(&DAYS,'DAY')),
a AS (SELECT /*+ MATERIALIZE */ h.sql_id, h.sql_plan_hash_value phv,
             h.sql_plan_line_id line_id, h.sql_plan_operation operation,
             h.sql_plan_options options, h.session_state, NVL(h.event,'CPU') event
        FROM dba_hist_active_sess_history h, b
       WHERE h.sql_id IN ($IDLIST) AND h.snap_id BETWEEN b.lo AND b.hi
         AND (&PHVF = 0 OR h.sql_plan_hash_value = &PHVF)),
g AS (SELECT sql_id, phv, line_id, operation, options, COUNT(*) n,
             SUM(CASE WHEN session_state='ON CPU' THEN 1 ELSE 0 END) cpu_n
        FROM a GROUP BY sql_id, phv, line_id, operation, options),
e AS (SELECT sql_id,phv,line_id,event FROM (
        SELECT sql_id, phv, line_id, event,
               ROW_NUMBER() OVER (PARTITION BY sql_id,phv,line_id ORDER BY COUNT(*) DESC) rn
          FROM a GROUP BY sql_id,phv,line_id,event) WHERE rn=1)
SELECT g.sql_id, g.phv, g.line_id, g.operation, g.options, g.n*10 db_time_s,
       ROUND(100*g.n/NULLIF(SUM(g.n) OVER (),0),1) pct,
       ROUND(100*g.cpu_n/NULLIF(g.n,0),1) cpu_pct, e.event top_event
  FROM g LEFT JOIN e ON e.sql_id=g.sql_id AND NVL(e.phv,-1)=NVL(g.phv,-1)
     AND NVL(e.line_id,-1)=NVL(g.line_id,-1)
 ORDER BY db_time_s DESC FETCH FIRST 30 ROWS ONLY;

PROMPT
PROMPT === D4. HOT SEGMENTS ===
COLUMN obj FORMAT A46 HEADING 'OBJECT'
COLUMN object_type FORMAT A12 HEADING 'TYPE'
COLUMN db_time_s FORMAT 999,999,990 HEADING 'DB_TIME_S'
COLUMN pct FORMAT 990.9 HEADING 'PCT'
COLUMN top_event FORMAT A26 HEADING 'TOP_EVENT'
COLUMN num_rows FORMAT 999,999,999,990 HEADING 'NUM_ROWS'
COLUMN last_analyzed FORMAT A16 HEADING 'LAST_ANALYZED'
WITH b AS (SELECT MIN(snap_id) lo, MAX(snap_id) hi FROM dba_hist_snapshot
            WHERE end_interval_time >= SYSTIMESTAMP - NUMTODSINTERVAL(&DAYS,'DAY')),
a AS (SELECT /*+ MATERIALIZE */ h.current_obj# oid, NVL(h.event,'CPU') event
        FROM dba_hist_active_sess_history h, b
       WHERE h.sql_id IN ($IDLIST) AND h.snap_id BETWEEN b.lo AND b.hi
         AND h.current_obj# > 0),
g AS (SELECT oid, COUNT(*) n FROM a GROUP BY oid),
e AS (SELECT oid,event FROM (SELECT oid, event,
        ROW_NUMBER() OVER (PARTITION BY oid ORDER BY COUNT(*) DESC) rn
        FROM a GROUP BY oid,event) WHERE rn=1)
SELECT o.owner||'.'||o.object_name obj, o.object_type, g.n*10 db_time_s,
       ROUND(100*g.n/NULLIF(SUM(g.n) OVER (),0),1) pct, e.event top_event,
       ts.num_rows, TO_CHAR(ts.last_analyzed,'YYYY-MM-DD HH24:MI') last_analyzed
  FROM g JOIN dba_objects o ON o.object_id=g.oid
  LEFT JOIN e ON e.oid=g.oid
  LEFT JOIN dba_tab_statistics ts ON ts.owner=o.owner AND ts.table_name=o.object_name
   AND ts.object_type='TABLE'
 ORDER BY db_time_s DESC FETCH FIRST 25 ROWS ONLY;

PROMPT
PROMPT === D5. WAIT PROFILE ===
COLUMN sql_id FORMAT A14 HEADING 'SQL_ID'
COLUMN wait_class FORMAT A15 HEADING 'WAIT_CLASS'
COLUMN event FORMAT A34 HEADING 'EVENT'
COLUMN node FORMAT 999 HEADING 'NODE'
COLUMN db_time_s FORMAT 999,999,990 HEADING 'DB_TIME_S'
WITH b AS (SELECT MIN(snap_id) lo, MAX(snap_id) hi FROM dba_hist_snapshot
            WHERE end_interval_time >= SYSTIMESTAMP - NUMTODSINTERVAL(&DAYS,'DAY'))
SELECT h.sql_id, NVL(h.wait_class,'CPU') wait_class, NVL(h.event,'CPU') event,
       h.instance_number node, COUNT(*)*10 db_time_s
  FROM dba_hist_active_sess_history h, b
 WHERE h.sql_id IN ($IDLIST) AND h.snap_id BETWEEN b.lo AND b.hi
 GROUP BY h.sql_id, NVL(h.wait_class,'CPU'), NVL(h.event,'CPU'), h.instance_number
 ORDER BY db_time_s DESC FETCH FIRST 25 ROWS ONLY;

PROMPT
PROMPT === D6. TEMP / PGA ===
COLUMN sql_id FORMAT A14 HEADING 'SQL_ID'
COLUMN phv FORMAT 9999999999 HEADING 'PLAN_HASH'
COLUMN node FORMAT 999 HEADING 'NODE'
COLUMN max_temp_gb FORMAT 999,990.99 HEADING 'MAX_TEMP_GB'
COLUMN max_pga_gb FORMAT 999,990.99 HEADING 'MAX_PGA_GB'
WITH b AS (SELECT MIN(snap_id) lo, MAX(snap_id) hi FROM dba_hist_snapshot
            WHERE end_interval_time >= SYSTIMESTAMP - NUMTODSINTERVAL(&DAYS,'DAY'))
SELECT h.sql_id, h.sql_plan_hash_value phv, h.instance_number node,
       ROUND(MAX(h.temp_space_allocated)/1024/1024/1024,2) max_temp_gb,
       ROUND(MAX(h.pga_allocated)/1024/1024/1024,2) max_pga_gb
  FROM dba_hist_active_sess_history h, b
 WHERE h.sql_id IN ($IDLIST) AND h.snap_id BETWEEN b.lo AND b.hi
 GROUP BY h.sql_id, h.sql_plan_hash_value, h.instance_number
HAVING MAX(h.temp_space_allocated) > 0 OR MAX(h.pga_allocated) > 0
 ORDER BY max_temp_gb DESC NULLS LAST FETCH FIRST 20 ROWS ONLY;

PROMPT
PROMPT === D7. BLOCKING ===
COLUMN sql_id FORMAT A14 HEADING 'SQL_ID'
COLUMN blocker FORMAT A16 HEADING 'BLOCKER_I:SID'
COLUMN event FORMAT A34 HEADING 'BLOCKED_ON'
COLUMN blocked_s FORMAT 999,999,990 HEADING 'BLOCKED_S'
WITH b AS (SELECT MIN(snap_id) lo, MAX(snap_id) hi FROM dba_hist_snapshot
            WHERE end_interval_time >= SYSTIMESTAMP - NUMTODSINTERVAL(&DAYS,'DAY'))
SELECT h.sql_id, h.blocking_inst_id||':'||h.blocking_session blocker,
       NVL(h.event,'CPU') event, COUNT(*)*10 blocked_s
  FROM dba_hist_active_sess_history h, b
 WHERE h.sql_id IN ($IDLIST) AND h.snap_id BETWEEN b.lo AND b.hi
   AND h.blocking_session IS NOT NULL
 GROUP BY h.sql_id, h.blocking_inst_id, h.blocking_session, NVL(h.event,'CPU')
 ORDER BY blocked_s DESC FETCH FIRST 15 ROWS ONLY;

PROMPT
PROMPT === D8. DAY BY DAY TREND ===
COLUMN day FORMAT A11 HEADING 'DAY'
COLUMN sql_id FORMAT A14 HEADING 'SQL_ID'
COLUMN phv FORMAT 9999999999 HEADING 'PLAN_HASH'
COLUMN execs FORMAT 999,999,990 HEADING 'EXECS'
COLUMN avg_elap FORMAT 999,990.99 HEADING 'AVG_ELAP_S'
COLUMN avg_bg FORMAT 999,999,990 HEADING 'AVG_BUF_GETS'
COLUMN avg_rows FORMAT 999,999,990 HEADING 'AVG_ROWS'
WITH b AS (SELECT MIN(snap_id) lo, MAX(snap_id) hi FROM dba_hist_snapshot
            WHERE end_interval_time >= SYSTIMESTAMP - NUMTODSINTERVAL(&DAYS,'DAY')),
top AS (SELECT sql_id FROM (SELECT st.sql_id,
          ROW_NUMBER() OVER (ORDER BY SUM(st.elapsed_time_delta) DESC) rn
          FROM dba_hist_sqlstat st, b
         WHERE st.sql_id IN ($IDLIST) AND st.snap_id BETWEEN b.lo AND b.hi
         GROUP BY st.sql_id) WHERE rn <= &TOPN)
SELECT TO_CHAR(sn.end_interval_time,'YYYY-MM-DD') day, st.sql_id,
       st.plan_hash_value phv, SUM(st.executions_delta) execs,
       ROUND(SUM(st.elapsed_time_delta)/1e6/GREATEST(SUM(st.executions_delta),1),2) avg_elap,
       ROUND(SUM(st.buffer_gets_delta)/GREATEST(SUM(st.executions_delta),1)) avg_bg,
       ROUND(SUM(st.rows_processed_delta)/GREATEST(SUM(st.executions_delta),1)) avg_rows
  FROM dba_hist_sqlstat st
  JOIN dba_hist_snapshot sn ON sn.snap_id=st.snap_id AND sn.dbid=st.dbid
   AND sn.instance_number=st.instance_number
  CROSS JOIN b
 WHERE st.sql_id IN (SELECT sql_id FROM top) AND st.snap_id BETWEEN b.lo AND b.hi
   AND st.executions_delta > 0
 GROUP BY TO_CHAR(sn.end_interval_time,'YYYY-MM-DD'), st.sql_id, st.plan_hash_value
 ORDER BY st.sql_id, day;
PROMPT (AVG_ROWS flat while AVG_BUF_GETS climbs = losing selectivity.
PROMPT  Both climbing together = data volume growth.)

PROMPT
PROMPT === D9. OBJECTS + STATS FRESHNESS ===
COLUMN obj_name FORMAT A46 HEADING 'OBJECT'
COLUMN obj_type FORMAT A9 HEADING 'TYPE'
COLUMN access_path FORMAT A26 HEADING 'ACCESS_PATH'
COLUMN num_rows FORMAT 999,999,999,990 HEADING 'NUM_ROWS'
COLUMN last_analyzed FORMAT A19 HEADING 'LAST_ANALYZED'
COLUMN age_d FORMAT 9,990 HEADING 'AGE_D'
COLUMN stale FORMAT A5 HEADING 'STALE'
WITH plns AS (
  SELECT p.object_owner owner, p.object_name name, p.object_type otype,
         p.operation||' '||NVL(p.options,' ') path
    FROM gv\$sql_plan p WHERE p.object_owner IS NOT NULL AND p.sql_id IN ($IDLIST)
  UNION
  SELECT hp.object_owner, hp.object_name, hp.object_type,
         hp.operation||' '||NVL(hp.options,' ')
    FROM dba_hist_sql_plan hp WHERE hp.object_owner IS NOT NULL AND hp.sql_id IN ($IDLIST))
SELECT pl.owner||'.'||pl.name obj_name, MAX(pl.otype) obj_type,
       SUBSTR(LISTAGG(DISTINCT TRIM(pl.path),'; ') WITHIN GROUP (ORDER BY TRIM(pl.path)),1,26) access_path,
       ts.num_rows, TO_CHAR(ts.last_analyzed,'YYYY-MM-DD HH24:MI:SS') last_analyzed,
       ROUND(SYSDATE - ts.last_analyzed) age_d, ts.stale_stats stale
  FROM plns pl LEFT JOIN dba_tab_statistics ts
    ON ts.owner=pl.owner AND ts.table_name=pl.name
   AND ts.object_type IN ('TABLE','PARTITION')
 GROUP BY pl.owner, pl.name, ts.num_rows, ts.last_analyzed, ts.stale_stats
 ORDER BY ts.last_analyzed NULLS FIRST, obj_name;

PROMPT
PROMPT =========================================================================
PROMPT === M. SQL MANIFEST - every statement belonging to this target
PROMPT =========================================================================
PROMPT WHERE: AWR = history only. MEM = shared pool only (too new for AWR).
PROMPT BOTH = both. NODES = RAC instances holding the cursor now.
COLUMN sql_id FORMAT A14 HEADING 'SQL_ID'
COLUMN phv FORMAT 9999999999 HEADING 'PLAN_HASH'
COLUMN whr FORMAT A5 HEADING 'WHERE'
COLUMN nodes FORMAT A7 HEADING 'NODES'
COLUMN execs FORMAT 999,999,990 HEADING 'EXECS'
COLUMN tot_elap FORMAT 999,999,990 HEADING 'TOT_ELAP_S'
COLUMN pct FORMAT 990.9 HEADING 'PCT_TIME'
COLUMN last_exec FORMAT A19 HEADING 'LAST_EXEC_AWR'
COLUMN last_active FORMAT A19 HEADING 'LAST_ACTIVE_MEM'
COLUMN sql_preview FORMAT A50 HEADING 'SQL_TEXT_PREVIEW'
WITH b AS (SELECT MIN(snap_id) lo, MAX(snap_id) hi FROM dba_hist_snapshot
            WHERE end_interval_time >= SYSTIMESTAMP - NUMTODSINTERVAL(&DAYS,'DAY')),
awr AS (SELECT st.sql_id, st.plan_hash_value phv, SUM(st.executions_delta) execs,
               SUM(st.elapsed_time_delta)/1e6 tot_elap, MAX(sn.end_interval_time) last_exec
          FROM dba_hist_sqlstat st
          JOIN dba_hist_snapshot sn ON sn.snap_id=st.snap_id AND sn.dbid=st.dbid
           AND sn.instance_number=st.instance_number
          CROSS JOIN b
         WHERE st.sql_id IN ($IDLIST) AND st.snap_id BETWEEN b.lo AND b.hi
           AND st.executions_delta > 0
         GROUP BY st.sql_id, st.plan_hash_value),
mem AS (SELECT q.sql_id, q.plan_hash_value phv,
               LISTAGG(DISTINCT TO_CHAR(q.inst_id),',')
                 WITHIN GROUP (ORDER BY TO_CHAR(q.inst_id)) nodes,
               MAX(q.last_active_time) last_active
          FROM gv\$sql q WHERE q.sql_id IN ($IDLIST)
         GROUP BY q.sql_id, q.plan_hash_value),
j AS (SELECT NVL(a.sql_id,m.sql_id) sql_id, NVL(a.phv,m.phv) phv,
             a.execs, a.tot_elap, a.last_exec, m.nodes, m.last_active,
             CASE WHEN a.sql_id IS NOT NULL AND m.sql_id IS NOT NULL THEN 'BOTH'
                  WHEN a.sql_id IS NOT NULL THEN 'AWR' ELSE 'MEM' END whr
        FROM awr a FULL OUTER JOIN mem m
          ON m.sql_id=a.sql_id AND NVL(m.phv,-1)=NVL(a.phv,-1))
SELECT j.sql_id, j.phv, j.whr, j.nodes, j.execs, ROUND(j.tot_elap) tot_elap,
       ROUND(100*j.tot_elap/NULLIF(SUM(j.tot_elap) OVER (),0),1) pct,
       TO_CHAR(j.last_exec,'YYYY-MM-DD HH24:MI:SS') last_exec,
       TO_CHAR(j.last_active,'YYYY-MM-DD HH24:MI:SS') last_active,
       SUBSTR(REGEXP_REPLACE(
         NVL((SELECT MIN(TO_CHAR(SUBSTR(x.sql_text,1,300))) FROM dba_hist_sqltext x
               WHERE x.sql_id=j.sql_id),
             (SELECT MIN(g.sql_text) FROM gv\$sql g WHERE g.sql_id=j.sql_id)),
         '[[:space:]]+',' '),1,50) sql_preview
  FROM j ORDER BY j.tot_elap DESC NULLS LAST, j.sql_id;

PROMPT
PROMPT === M2. PLAN AVAILABILITY MATRIX ===
COLUMN sql_id FORMAT A14 HEADING 'SQL_ID'
COLUMN phv FORMAT 9999999999 HEADING 'PLAN_HASH'
COLUMN in_awr FORMAT A7 HEADING 'IN_AWR'
COLUMN in_mem FORMAT A16 HEADING 'IN_MEM_ON_NODES'
WITH b AS (SELECT MIN(snap_id) lo, MAX(snap_id) hi FROM dba_hist_snapshot
            WHERE end_interval_time >= SYSTIMESTAMP - NUMTODSINTERVAL(&DAYS,'DAY')),
k AS (SELECT DISTINCT st.sql_id, st.plan_hash_value phv
        FROM dba_hist_sqlstat st, b
       WHERE st.sql_id IN ($IDLIST) AND st.snap_id BETWEEN b.lo AND b.hi
         AND st.plan_hash_value > 0
      UNION
      SELECT DISTINCT q.sql_id, q.plan_hash_value FROM gv\$sql q
       WHERE q.sql_id IN ($IDLIST) AND q.plan_hash_value > 0)
SELECT k.sql_id, k.phv,
       CASE WHEN EXISTS (SELECT 1 FROM dba_hist_sql_plan p
                          WHERE p.sql_id=k.sql_id AND p.plan_hash_value=k.phv)
            THEN 'yes' ELSE 'no' END in_awr,
       NVL((SELECT LISTAGG(DISTINCT TO_CHAR(p.inst_id),',')
                     WITHIN GROUP (ORDER BY TO_CHAR(p.inst_id))
              FROM gv\$sql_plan p
             WHERE p.sql_id=k.sql_id AND p.plan_hash_value=k.phv),'-') in_mem
  FROM k ORDER BY k.sql_id, k.phv;

SET HEADING OFF
WITH b AS (SELECT MIN(snap_id) lo, MAX(snap_id) hi FROM dba_hist_snapshot
            WHERE end_interval_time >= SYSTIMESTAMP - NUMTODSINTERVAL(&DAYS,'DAY')),
t AS (SELECT st.sql_id, st.plan_hash_value phv,
             ROW_NUMBER() OVER (ORDER BY SUM(st.elapsed_time_delta) DESC) rn
        FROM dba_hist_sqlstat st, b
       WHERE st.sql_id IN ($IDLIST) AND st.snap_id BETWEEN b.lo AND b.hi
         AND st.plan_hash_value > 0
       GROUP BY st.sql_id, st.plan_hash_value)
SELECT 'PLANKEY '||sql_id||' '||phv FROM t WHERE rn <= &TOPN;
SELECT DISTINCT 'RTKEY '||q.sql_id||' '||q.plan_hash_value||' '||q.inst_id||' '||q.child_number
  FROM gv\$sql q WHERE q.sql_id IN ($IDLIST) AND q.plan_hash_value > 0;
SET HEADING ON
EXIT;
SQLEOF

sqlplus -s "/ as sysdba" @"$TMPD/deep.sql" "$DAYS" "$PS_OWNER_UC" "$PHVF" "$TOPN" | tee "$TMPD/deep.out"

# =============================================================================
# STEP 4 - REAL TIME  (-r)
# =============================================================================
if [ "$SHOW_RT" -eq 1 ]; then
cat > "$TMPD/rt.sql" <<SQLEOF
SET FEEDBACK OFF VERIFY OFF HEADING ON TAB OFF LINESIZE 245 PAGESIZE 200
WHENEVER SQLERROR CONTINUE
PROMPT
PROMPT === R1. LIVE SESSIONS (all nodes) ===
COLUMN node FORMAT 999 HEADING 'NODE'
COLUMN sid_serial FORMAT A14 HEADING 'SID,SERIAL#'
COLUMN sql_id FORMAT A14 HEADING 'SQL_ID'
COLUMN phv FORMAT 9999999999 HEADING 'PLAN_HASH'
COLUMN client_id FORMAT A14 HEADING 'CLIENT_ID'
COLUMN state FORMAT A9 HEADING 'STATE'
COLUMN event FORMAT A30 HEADING 'EVENT'
COLUMN elap_s FORMAT 999,990.9 HEADING 'SQL_ELAP_S'
SELECT s.inst_id node, s.sid||','||s.serial# sid_serial, s.sql_id,
       q.plan_hash_value phv, s.client_info client_id, s.state, s.event,
       ROUND(q.elapsed_time/1e6,1) elap_s
  FROM gv\$session s JOIN gv\$sql q
    ON q.sql_id=s.sql_id AND q.inst_id=s.inst_id AND q.child_number=s.sql_child_number
 WHERE s.status='ACTIVE' AND s.sql_id IN ($IDLIST) ORDER BY elap_s DESC;

PROMPT
PROMPT === R2. CURSOR STATE IN SHARED POOL (all nodes) ===
COLUMN sql_id FORMAT A14 HEADING 'SQL_ID'
COLUMN phv FORMAT 9999999999 HEADING 'PLAN_HASH'
COLUMN node FORMAT 999 HEADING 'NODE'
COLUMN child FORMAT 9990 HEADING 'CHILD'
COLUMN execs FORMAT 999,999,990 HEADING 'EXECS'
COLUMN first_load FORMAT A19 HEADING 'FIRST_LOAD'
COLUMN last_active FORMAT A19 HEADING 'LAST_ACTIVE'
SELECT q.sql_id, q.plan_hash_value phv, q.inst_id node, q.child_number child,
       q.executions execs, q.first_load_time first_load,
       TO_CHAR(q.last_active_time,'YYYY-MM-DD HH24:MI:SS') last_active
  FROM gv\$sql q WHERE q.sql_id IN ($IDLIST)
 ORDER BY q.last_active_time DESC NULLS LAST;

PROMPT
PROMPT === R3. IN-MEMORY ASH (since last AWR snapshot) ===
COLUMN sql_id FORMAT A14 HEADING 'SQL_ID'
COLUMN phv FORMAT 9999999999 HEADING 'PLAN_HASH'
COLUMN node FORMAT 999 HEADING 'NODE'
COLUMN samples FORMAT 999,990 HEADING 'SAMPLES'
COLUMN last_seen FORMAT A19 HEADING 'LAST_SEEN'
COLUMN top_event FORMAT A30 HEADING 'TOP_EVENT'
WITH live AS (SELECT a.sql_id, a.sql_plan_hash_value phv, a.inst_id node,
                     NVL(a.event,'CPU') event, a.sample_time
                FROM gv\$active_session_history a WHERE a.sql_id IN ($IDLIST)),
g AS (SELECT sql_id, phv, node, COUNT(*) n, MAX(sample_time) last_seen
        FROM live GROUP BY sql_id, phv, node),
e AS (SELECT sql_id,phv,node,event FROM (SELECT sql_id, phv, node, event,
        ROW_NUMBER() OVER (PARTITION BY sql_id,phv,node ORDER BY COUNT(*) DESC) rn
        FROM live GROUP BY sql_id,phv,node,event) WHERE rn=1)
SELECT g.sql_id, g.phv, g.node, g.n samples,
       TO_CHAR(g.last_seen,'YYYY-MM-DD HH24:MI:SS') last_seen, e.event top_event
  FROM g LEFT JOIN e ON e.sql_id=g.sql_id AND NVL(e.phv,-1)=NVL(g.phv,-1) AND e.node=g.node
 ORDER BY samples DESC FETCH FIRST 25 ROWS ONLY;
EXIT;
SQLEOF
banner "REAL-TIME"
sqlplus -s "/ as sysdba" @"$TMPD/rt.sql"
fi

# =============================================================================
# STEP 5 - PLANS: AWR + in-memory across ALL RAC nodes  (-p)
# =============================================================================
if [ "$SHOW_PLANS" -eq 1 ]; then
  grep '^PLANKEY ' "$TMPD/deep.out" | awk '{print $2, $3}' | sort -u > "$TMPD/awrkeys.txt"
  grep '^RTKEY '   "$TMPD/deep.out" | awk '{print $2, $3, $4, $5}' | sort -u > "$TMPD/rtkeys.txt"

  banner "EXECUTION PLANS - HISTORICAL (AWR)"
  if [ ! -s "$TMPD/awrkeys.txt" ]; then echo " No SQL_ID/PLAN_HASH pairs in AWR."
  else
cat > "$TMPD/xa.sql" <<'SQLEOF'
SET FEEDBACK OFF VERIFY OFF HEADING OFF PAGESIZE 0 LINESIZE 200 LONG 2000000
WHENEVER SQLERROR CONTINUE
PROMPT
PROMPT -----------------------------------------------------------------------
PROMPT AWR PLAN | SQL_ID &1 | PLAN_HASH &2
PROMPT -----------------------------------------------------------------------
SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY_AWR('&1', &2, NULL, 'ALL'));
EXIT;
SQLEOF
    while read -r S P; do
      sqlplus -s "/ as sysdba" @"$TMPD/xa.sql" "$S" "$P"
    done < "$TMPD/awrkeys.txt"
  fi

  banner "EXECUTION PLANS - IN MEMORY (every RAC node via GV\$SQL_PLAN)"
  if [ ! -s "$TMPD/rtkeys.txt" ]; then
    echo " No cursors in the shared pool on any node - aged out. AWR only."
  else
cat > "$TMPD/xr.sql" <<'SQLEOF'
SET FEEDBACK OFF VERIFY OFF HEADING OFF PAGESIZE 0 LINESIZE 200 LONG 2000000
WHENEVER SQLERROR CONTINUE
PROMPT
PROMPT -----------------------------------------------------------------------
PROMPT IN-MEMORY | SQL_ID &1 | PLAN_HASH &2 | NODE &3 | CHILD &4
PROMPT -----------------------------------------------------------------------
SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY('GV$SQL_PLAN', NULL, 'ALL',
  'sql_id=''&1'' AND plan_hash_value=&2 AND inst_id=&3 AND child_number=&4'));
EXIT;
SQLEOF
    while read -r S P I C; do
      sqlplus -s "/ as sysdba" @"$TMPD/xr.sql" "$S" "$P" "$I" "$C"
    done < "$TMPD/rtkeys.txt"

    banner "ROW-SOURCE STATS (local node ${ORACLE_SID} only)"
    echo " DISPLAY_CURSOR reads this instance's V\$ views only; cursors on the"
    echo " other node show nothing here - use the GV\$ plans above for those."
cat > "$TMPD/xc.sql" <<'SQLEOF'
SET FEEDBACK OFF VERIFY OFF HEADING OFF PAGESIZE 0 LINESIZE 200 LONG 2000000
WHENEVER SQLERROR CONTINUE
PROMPT
PROMPT --- DISPLAY_CURSOR SQL_ID &1 (E-Rows vs A-Rows) ---
SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY_CURSOR('&1', NULL,
                    'ALLSTATS LAST +PEEKED_BINDS'));
EXIT;
SQLEOF
    awk '{print $1}' "$TMPD/rtkeys.txt" | sort -u | while read -r S; do
      sqlplus -s "/ as sysdba" @"$TMPD/xc.sql" "$S"
    done
  fi
fi

# =============================================================================
# STEP 6 - SQL TUNING ADVISOR  (-t)
# =============================================================================
[ "$RUN_STA" -eq 0 ] && exit 0
banner "SQL TUNING ADVISOR (requires Tuning Pack license)"
read -r -p "Run it now? (y/n): " ANS
case "$ANS" in [Yy]*) ;; *) echo "Skipped."; exit 0 ;; esac
echo "Candidates:"; cat "$TMPD/ids.txt"
read -r -p "TARGET SQL_ID: " TSQL
[ -z "$TSQL" ] && { echo "ERROR: empty."; exit 1; }
echo "  1) Cursor cache   2) AWR"
read -r -p "Source (1 or 2): " SRC
PF=""
[ "$SRC" = "2" ] && read -r -p "Restrict to PLAN_HASH_VALUE? (blank=all): " PF
TASK="STA_${TSQL}_$$"
cat > "$TMPD/sta.sql" <<'SQLEOF'
SET SERVEROUTPUT ON SIZE UNLIMITED
SET LONG 5000000 LONGCHUNKSIZE 5000 PAGESIZE 0 LINESIZE 200 FEEDBACK OFF VERIFY OFF
WHENEVER SQLERROR EXIT FAILURE
DEFINE TSQL='&1'
DEFINE TASK='&2'
DEFINE SRC='&3'
DEFINE PHV='&4'
DECLARE
  v_exists NUMBER; v_task VARCHAR2(128); v_beg NUMBER; v_end NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_exists FROM dba_advisor_tasks WHERE task_name='&TASK';
  IF v_exists>0 THEN DBMS_SQLTUNE.DROP_TUNING_TASK(task_name=>'&TASK'); END IF;
  IF '&SRC'='1' THEN
    v_task := DBMS_SQLTUNE.CREATE_TUNING_TASK(sql_id=>'&TSQL', task_name=>'&TASK',
                scope=>DBMS_SQLTUNE.scope_comprehensive, time_limit=>1800,
                description=>'STA cursor cache');
  ELSE
    SELECT MIN(snap_id),MAX(snap_id) INTO v_beg,v_end FROM dba_hist_sqlstat
     WHERE sql_id='&TSQL' AND ('&PHV' IS NULL OR TO_CHAR(plan_hash_value)='&PHV');
    IF v_beg IS NULL THEN DBMS_OUTPUT.PUT_LINE('No AWR snaps.'); RETURN; END IF;
    v_task := DBMS_SQLTUNE.CREATE_TUNING_TASK(begin_snap=>v_beg, end_snap=>v_end,
                sql_id=>'&TSQL', task_name=>'&TASK',
                scope=>DBMS_SQLTUNE.scope_comprehensive, time_limit=>1800,
                description=>'STA AWR');
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
SQLEOF
sqlplus -s "/ as sysdba" @"$TMPD/sta.sql" "$TSQL" "$TASK" "$SRC" "$PF"
exit 0

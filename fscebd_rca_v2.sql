-- =====================================================================
-- fscebd_rca_v2.sql   FS_CEBD ROOT CAUSE + BEFORE / AFTER, self contained
--
-- v2 changes, both were real defects in v1:
--   * PAGESIZE was 60000, the SQL*Plus maximum is 50000  -> SP2-0267
--   * private temporary tables were built by CTAS containing bind
--     variables. Oracle does not accept binds in DDL, so every
--     CREATE PRIVATE TEMPORARY TABLE failed ORA-14451 and every later
--     section then failed ORA-00942.
--
-- v2 uses no temp tables and no binds. Values come from DEFINE and from
-- COLUMN NEW_VALUE, which are substituted textually before Oracle parses,
-- so they are legal everywhere.
--
-- Cost control: AWR ASH is only read for snapshots that actually overlap
-- an FS_CEBD run, which is a few percent of the retention window, and
-- every ASH access carries a SNAP_ID plus DBID predicate.
-- =====================================================================
SET DEFINE ON
SET ESCAPE OFF
SET FEEDBACK OFF VERIFY OFF ECHO OFF TRIMSPOOL ON TRIMOUT ON
SET LINESIZE 210 PAGESIZE 50000 NUMWIDTH 13 LONG 8000 LONGCHUNKSIZE 8000
SET TIMING ON
WHENEVER SQLERROR CONTINUE NONE
WHENEVER OSERROR CONTINUE NONE

ALTER SESSION SET nls_date_format='YYYY-MM-DD HH24:MI:SS';
ALTER SESSION DISABLE PARALLEL QUERY;

-- ---------------------------------------------------------------------
-- knobs
-- ---------------------------------------------------------------------
DEFINE d_prcs   = FS_CEBD
DEFINE d_master = FDC_COMBO_BUILD_MASTER_RUNCNTL
DEFINE d_look   = 120
DEFINE d_upg    = 2026-06-26 00:00:00
DEFINE d_fix    = 2026-07-28 12:00:00

COL era        FOR A18
COL runcntlid  FOR A30
COL oprid      FOR A9
COL stat       FOR A11
COL kind       FOR A14
COL sql_id     FOR A14
COL txt        FOR A72
COL sig        FOR A72
COL info       FOR A140
COL obj        FOR A34
COL otype      FOR A6
COL operation  FOR A22
COL options    FOR A18
COL object_name FOR A24
COL index_name FOR A22
COL ev         FOR A32
COL wclass     FOR A12
COL tbl        FOR A20
COL phvs       FOR A44
COL bar        FOR A34
COL target     FOR A32
COL lever      FOR A56
COL started    FOR A16

PROMPT
PROMPT ####################################################################
PROMPT #  FS_CEBD  ROOT CAUSE AND BEFORE / AFTER ANALYSIS   v2
PROMPT ####################################################################

PROMPT
PROMPT ==== 0. PREFLIGHT ====
PROMPT
SELECT 'db='||d.name||'  dbid='||TO_CHAR(d.dbid)||'  role='||d.database_role||
       '  run_at='||TO_CHAR(SYSDATE,'YYYY-MM-DD HH24:MI:SS') info
FROM   v$database d;

SELECT 'AWR retention days='||TO_CHAR(EXTRACT(DAY FROM retention))||
       '  snap_min='||TO_CHAR(EXTRACT(HOUR FROM snap_interval)*60
                             +EXTRACT(MINUTE FROM snap_interval))||
       '  snaps_total='||TO_CHAR((SELECT COUNT(*) FROM dba_hist_snapshot
                                 WHERE dbid=(SELECT dbid FROM v$database))) info
FROM   dba_hist_wr_control WHERE dbid=(SELECT dbid FROM v$database);

-- pick the most recent MASTER run control, not merely the most recent FS_CEBD.
-- pre-declared so that a zero-row picker cannot leave the variable unset,
-- which would make SQL*Plus stop and prompt.
DEFINE d_pi   = 0
DEFINE d_mins = 0
COLUMN pi_pick   NEW_VALUE d_pi   NOPRINT
COLUMN pi_mins   NEW_VALUE d_mins NOPRINT
SELECT prcsinstance pi_pick,
       TO_CHAR(ROUND((CAST(NVL(enddttm,SYSTIMESTAMP) AS DATE)
                     -CAST(begindttm AS DATE))*1440,1)) pi_mins
FROM ( SELECT prcsinstance, begindttm, enddttm
       FROM   sysadm.psprcsrqst
       WHERE  prcsname  = '&d_prcs'
       AND    runcntlid = '&d_master'
       AND    begindttm IS NOT NULL
       ORDER  BY begindttm DESC )
WHERE ROWNUM = 1;

SELECT 'target master run = &d_pi   elapsed = &d_mins min   lookback = &d_look days'
       ||'   upgrade = '||'&d_upg'||'   fix = '||'&d_fix' info FROM dual;

PROMPT
PROMPT ####################################################################
PROMPT #  1. RUN INVENTORY   PSPRCSRQST only, no ASH, cheap
PROMPT ####################################################################
PROMPT
WITH runs AS (
  SELECT r.prcsinstance, r.oprid, r.runcntlid, r.runstatus,
         CAST(r.begindttm AS DATE) b,
         CAST(NVL(r.enddttm,SYSTIMESTAMP) AS DATE) e,
         ROUND((CAST(NVL(r.enddttm,SYSTIMESTAMP) AS DATE)
               -CAST(r.begindttm AS DATE))*86400) run_sec,
         CASE WHEN CAST(r.begindttm AS DATE)
                   < TO_DATE('&d_upg','YYYY-MM-DD HH24:MI:SS') THEN '1-PRE-UPGRADE'
              WHEN CAST(r.begindttm AS DATE)
                   < TO_DATE('&d_fix','YYYY-MM-DD HH24:MI:SS') THEN '2-POST-UPG-PREFIX'
              ELSE                                                '3-POST-FIX' END era
  FROM   sysadm.psprcsrqst r
  WHERE  r.prcsname = '&d_prcs'
  AND    r.begindttm IS NOT NULL
  AND    r.begindttm > SYSTIMESTAMP - &d_look
  AND    r.runstatus NOT IN (2,5,8))
SELECT era, runcntlid, prcsinstance, oprid,
       DECODE(runstatus,3,'ERROR',7,'PROCESSING',9,'SUCCESS',
                        10,'NOTSUCCESS',17,'SUCC_WARN',TO_CHAR(runstatus)) stat,
       TO_CHAR(b,'MM-DD HH24:MI') started,
       run_sec, ROUND(run_sec/60,1) run_min
FROM   runs
ORDER  BY era, runcntlid, b;

PROMPT
PROMPT ==== 1b. HEADLINE   runtime per run control per era ====
PROMPT
WITH runs AS (
  SELECT r.runcntlid,
         ROUND((CAST(NVL(r.enddttm,SYSTIMESTAMP) AS DATE)
               -CAST(r.begindttm AS DATE))*86400) run_sec,
         CASE WHEN CAST(r.begindttm AS DATE)
                   < TO_DATE('&d_upg','YYYY-MM-DD HH24:MI:SS') THEN '1-PRE-UPGRADE'
              WHEN CAST(r.begindttm AS DATE)
                   < TO_DATE('&d_fix','YYYY-MM-DD HH24:MI:SS') THEN '2-POST-UPG-PREFIX'
              ELSE                                                '3-POST-FIX' END era
  FROM   sysadm.psprcsrqst r
  WHERE  r.prcsname = '&d_prcs'
  AND    r.begindttm IS NOT NULL
  AND    r.begindttm > SYSTIMESTAMP - &d_look
  AND    r.runstatus NOT IN (2,5,8))
SELECT runcntlid, era, COUNT(*) runs,
       ROUND(MIN(run_sec)/60,1) min_min,
       ROUND(AVG(run_sec)/60,1) avg_min,
       ROUND(MAX(run_sec)/60,1) max_min
FROM   runs
GROUP  BY runcntlid, era
ORDER  BY runcntlid, era;
PROMPT ---- this is the table for management. Run controls are never averaged together ----

PROMPT
PROMPT ==== 1c. HOW MANY AWR SNAPSHOTS OVERLAP AN FS_CEBD RUN ====
PROMPT      every ASH section below reads only these snapshots
PROMPT
WITH runs AS (
  SELECT CAST(r.begindttm AS DATE) b,
         CAST(NVL(r.enddttm,SYSTIMESTAMP) AS DATE) e
  FROM   sysadm.psprcsrqst r
  WHERE  r.prcsname = '&d_prcs' AND r.begindttm IS NOT NULL
  AND    r.begindttm > SYSTIMESTAMP - &d_look
  AND    r.runstatus NOT IN (2,5,8))
SELECT COUNT(DISTINCT sn.snap_id) snaps_of_interest,
       (SELECT COUNT(*) FROM dba_hist_snapshot
        WHERE dbid=(SELECT dbid FROM v$database)) snaps_total,
       ROUND(COUNT(DISTINCT sn.snap_id)*100
             /(SELECT COUNT(*) FROM dba_hist_snapshot
               WHERE dbid=(SELECT dbid FROM v$database)),2) pct_scanned
FROM   dba_hist_snapshot sn, runs r
WHERE  sn.dbid = (SELECT dbid FROM v$database)
AND    sn.end_interval_time   >= CAST(r.b AS TIMESTAMP)
AND    sn.begin_interval_time <= CAST(r.e AS TIMESTAMP);

PROMPT
PROMPT ####################################################################
PROMPT #  2. DB TIME PER RUN   ASH correlated by CLIENT_ID = OPRID
PROMPT #     PeopleSoft AE does not populate MODULE or ACTION here
PROMPT ####################################################################
PROMPT
WITH runs AS (
  SELECT /*+ materialize */
         r.prcsinstance, r.oprid, r.runcntlid,
         CAST(r.begindttm AS DATE) b,
         CAST(NVL(r.enddttm,SYSTIMESTAMP) AS DATE) e,
         ROUND((CAST(NVL(r.enddttm,SYSTIMESTAMP) AS DATE)
               -CAST(r.begindttm AS DATE))*86400) run_sec,
         CASE WHEN CAST(r.begindttm AS DATE)
                   < TO_DATE('&d_upg','YYYY-MM-DD HH24:MI:SS') THEN '1-PRE-UPGRADE'
              WHEN CAST(r.begindttm AS DATE)
                   < TO_DATE('&d_fix','YYYY-MM-DD HH24:MI:SS') THEN '2-POST-UPG-PREFIX'
              ELSE                                                '3-POST-FIX' END era
  FROM   sysadm.psprcsrqst r
  WHERE  r.prcsname = '&d_prcs' AND r.begindttm IS NOT NULL
  AND    r.begindttm > SYSTIMESTAMP - &d_look
  AND    r.runstatus NOT IN (2,5,8)),
snaps AS (
  SELECT /*+ materialize */ DISTINCT sn.snap_id
  FROM   dba_hist_snapshot sn, runs r
  WHERE  sn.dbid = (SELECT dbid FROM v$database)
  AND    sn.end_interval_time   >= CAST(r.b AS TIMESTAMP)
  AND    sn.begin_interval_time <= CAST(r.e AS TIMESTAMP)),
ash AS (
  SELECT /*+ materialize */
         r.prcsinstance, r.runcntlid, r.era, r.run_sec,
         h.sql_id, h.session_state
  FROM   dba_hist_active_sess_history h, runs r
  WHERE  h.snap_id IN (SELECT snap_id FROM snaps)
  AND    h.dbid = (SELECT dbid FROM v$database)
  AND    h.sample_time BETWEEN CAST(r.b AS TIMESTAMP) AND CAST(r.e AS TIMESTAMP)
  AND    h.client_id = r.oprid),
stats_flag AS (
  SELECT a.prcsinstance, a.runcntlid, a.era, a.run_sec, a.session_state,
         CASE WHEN UPPER(NVL(DBMS_LOB.SUBSTR(t.sql_text,200,1),'X'))
                   LIKE '%DBMS_STATS%'
               OR UPPER(NVL(DBMS_LOB.SUBSTR(t.sql_text,200,1),'X'))
                   LIKE '%SQL ANALYZE%' THEN 1 ELSE 0 END is_stats
  FROM   ash a
  LEFT   JOIN dba_hist_sqltext t
         ON t.sql_id = a.sql_id AND t.dbid = (SELECT dbid FROM v$database))
SELECT era, runcntlid, prcsinstance,
       ROUND(MAX(run_sec)/60,1) run_min,
       COUNT(*)*10 db_secs,
       ROUND(COUNT(*)*10/GREATEST(MAX(run_sec),1),2) aas,
       SUM(is_stats)*10 stats_secs,
       ROUND(SUM(is_stats)*100/COUNT(*),1) stats_pct,
       SUM(CASE WHEN session_state='ON CPU' THEN 10 ELSE 0 END) cpu_secs
FROM   stats_flag
GROUP  BY era, runcntlid, prcsinstance
ORDER  BY era, runcntlid, 5 DESC;
PROMPT ---- statistics share was 82 pct on the slow run 26068516 ----
PROMPT ---- AAS near 1.0 means the App Engine is single threaded ----

PROMPT
PROMPT ####################################################################
PROMPT #  3. EVERY SQL_ID THE JOB RAN, BY ERA
PROMPT ####################################################################
PROMPT
WITH runs AS (
  SELECT /*+ materialize */ r.prcsinstance, r.oprid,
         CAST(r.begindttm AS DATE) b,
         CAST(NVL(r.enddttm,SYSTIMESTAMP) AS DATE) e,
         CASE WHEN CAST(r.begindttm AS DATE)
                   < TO_DATE('&d_upg','YYYY-MM-DD HH24:MI:SS') THEN '1-PRE-UPGRADE'
              WHEN CAST(r.begindttm AS DATE)
                   < TO_DATE('&d_fix','YYYY-MM-DD HH24:MI:SS') THEN '2-POST-UPG-PREFIX'
              ELSE                                                '3-POST-FIX' END era
  FROM   sysadm.psprcsrqst r
  WHERE  r.prcsname = '&d_prcs' AND r.begindttm IS NOT NULL
  AND    r.begindttm > SYSTIMESTAMP - &d_look
  AND    r.runstatus NOT IN (2,5,8)),
snaps AS (
  SELECT /*+ materialize */ DISTINCT sn.snap_id
  FROM   dba_hist_snapshot sn, runs r
  WHERE  sn.dbid = (SELECT dbid FROM v$database)
  AND    sn.end_interval_time   >= CAST(r.b AS TIMESTAMP)
  AND    sn.begin_interval_time <= CAST(r.e AS TIMESTAMP)),
ash AS (
  SELECT /*+ materialize */ r.era, r.prcsinstance,
         h.sql_id, h.sql_plan_hash_value phv, h.session_state, h.sample_time
  FROM   dba_hist_active_sess_history h, runs r
  WHERE  h.snap_id IN (SELECT snap_id FROM snaps)
  AND    h.dbid = (SELECT dbid FROM v$database)
  AND    h.sample_time BETWEEN CAST(r.b AS TIMESTAMP) AND CAST(r.e AS TIMESTAMP)
  AND    h.client_id = r.oprid
  AND    h.sql_id IS NOT NULL)
SELECT * FROM (
  SELECT a.era, a.sql_id,
         COUNT(*)*10 db_secs,
         SUM(CASE WHEN a.session_state='ON CPU' THEN 10 ELSE 0 END) cpu_secs,
         COUNT(DISTINCT a.phv) plans,
         COUNT(DISTINCT a.prcsinstance) runs,
         TO_CHAR(MIN(a.sample_time),'MM-DD HH24:MI') first_seen,
         TO_CHAR(MAX(a.sample_time),'MM-DD HH24:MI') last_seen,
         CASE
           WHEN t.sql_text IS NULL                                     THEN 'AGED-OUT'
           WHEN UPPER(DBMS_LOB.SUBSTR(t.sql_text,300,1)) LIKE '%SQL ANALYZE%'
                                                                       THEN 'STATS-ANALYZE'
           WHEN UPPER(DBMS_LOB.SUBSTR(t.sql_text,300,1)) LIKE '%DBMS_STATS%'
                                                                       THEN 'STATS-GATHER'
           WHEN UPPER(DBMS_LOB.SUBSTR(t.sql_text,300,1))
                LIKE 'DELETE FROM PS_COMBO_DATA_TBL%'                  THEN 'PURGE'
           WHEN UPPER(DBMS_LOB.SUBSTR(t.sql_text,300,1))
                LIKE 'INSERT INTO PS_COMBO_DATA_TBL%'                  THEN 'BUILD-INSERT'
           WHEN UPPER(DBMS_LOB.SUBSTR(t.sql_text,300,1)) LIKE '%PS_COMBO_DATA_BUDG%'
                                                                       THEN 'BUDG'
           WHEN UPPER(DBMS_LOB.SUBSTR(t.sql_text,300,1)) LIKE '%PS_FS_CEBD_TAO%'
                                                                       THEN 'TAO-WORK'
           ELSE 'APP-OTHER'
         END kind,
         SUBSTR(REGEXP_REPLACE(
           NVL(DBMS_LOB.SUBSTR(t.sql_text,400,1),'(aged out)'),
           '[[:space:]]+',' '),1,72) txt
  FROM   ash a
  LEFT   JOIN dba_hist_sqltext t
         ON t.sql_id = a.sql_id AND t.dbid = (SELECT dbid FROM v$database)
  GROUP  BY a.era, a.sql_id, t.sql_text
  ORDER  BY a.era, 3 DESC)
WHERE  ROWNUM <= 140;

PROMPT
PROMPT ####################################################################
PROMPT #  4. STATEMENT COMPARISON ACROSS ERAS, GROUPED BY SIGNATURE
PROMPT #     FS_CEBD embeds PROCESS_INSTANCE as a literal, so SQL_ID
PROMPT #     changes every run. SIG is the text with standalone numbers
PROMPT #     replaced by #, which IS stable across runs and across the
PROMPT #     upgrade. This is the section that answers what changed.
PROMPT ####################################################################
PROMPT
WITH runs AS (
  SELECT /*+ materialize */ r.prcsinstance, r.oprid,
         CAST(r.begindttm AS DATE) b,
         CAST(NVL(r.enddttm,SYSTIMESTAMP) AS DATE) e,
         CASE WHEN CAST(r.begindttm AS DATE)
                   < TO_DATE('&d_upg','YYYY-MM-DD HH24:MI:SS') THEN '1-PRE-UPGRADE'
              WHEN CAST(r.begindttm AS DATE)
                   < TO_DATE('&d_fix','YYYY-MM-DD HH24:MI:SS') THEN '2-POST-UPG-PREFIX'
              ELSE                                                '3-POST-FIX' END era
  FROM   sysadm.psprcsrqst r
  WHERE  r.prcsname = '&d_prcs' AND r.begindttm IS NOT NULL
  AND    r.begindttm > SYSTIMESTAMP - &d_look
  AND    r.runstatus NOT IN (2,5,8)),
snaps AS (
  SELECT /*+ materialize */ DISTINCT sn.snap_id
  FROM   dba_hist_snapshot sn, runs r
  WHERE  sn.dbid = (SELECT dbid FROM v$database)
  AND    sn.end_interval_time   >= CAST(r.b AS TIMESTAMP)
  AND    sn.begin_interval_time <= CAST(r.e AS TIMESTAMP)),
ash AS (
  SELECT /*+ materialize */ r.era, r.prcsinstance, h.sql_id, h.sql_plan_hash_value phv
  FROM   dba_hist_active_sess_history h, runs r
  WHERE  h.snap_id IN (SELECT snap_id FROM snaps)
  AND    h.dbid = (SELECT dbid FROM v$database)
  AND    h.sample_time BETWEEN CAST(r.b AS TIMESTAMP) AND CAST(r.e AS TIMESTAMP)
  AND    h.client_id = r.oprid
  AND    h.sql_id IS NOT NULL),
sig AS (
  SELECT a.era, a.prcsinstance, a.sql_id, a.phv,
         SUBSTR(REGEXP_REPLACE(
           REGEXP_REPLACE(UPPER(NVL(DBMS_LOB.SUBSTR(t.sql_text,400,1),'AGED OUT')),
                          '[[:space:]]+',' '),
           '(^|[^A-Z0-9_])[0-9]+','\1#'),1,200) sg
  FROM   ash a
  LEFT   JOIN dba_hist_sqltext t
         ON t.sql_id = a.sql_id AND t.dbid = (SELECT dbid FROM v$database))
SELECT * FROM (
  SELECT COUNT(*)*10 tot_secs,
         SUM(CASE WHEN era='1-PRE-UPGRADE'     THEN 10 ELSE 0 END) pre_secs,
         SUM(CASE WHEN era='2-POST-UPG-PREFIX' THEN 10 ELSE 0 END) upg_secs,
         SUM(CASE WHEN era='3-POST-FIX'        THEN 10 ELSE 0 END) fix_secs,
         COUNT(DISTINCT sql_id) sqlids,
         COUNT(DISTINCT phv)    plans,
         COUNT(DISTINCT prcsinstance) runs,
         SUBSTR(MIN(sg),1,72) sig
  FROM   sig
  GROUP  BY sg
  ORDER  BY 1 DESC)
WHERE  ROWNUM <= 45;
PROMPT ---- sqlids greater than 1 for one signature = literal not bound, hard parse ----
PROMPT ---- high upg_secs with low pre_secs = what the upgrade broke ----
PROMPT ---- low fix_secs against high upg_secs = what our change repaired ----
PROMPT ---- high fix_secs = what is still costing you today ----

PROMPT
PROMPT ####################################################################
PROMPT #  5. AWR EXECUTION METRICS PER SQL_ID PER PLAN PER ERA
PROMPT #     real executions and seconds per execution, from DBA_HIST_SQLSTAT
PROMPT ####################################################################
PROMPT
WITH runs AS (
  SELECT /*+ materialize */ r.oprid,
         CAST(r.begindttm AS DATE) b,
         CAST(NVL(r.enddttm,SYSTIMESTAMP) AS DATE) e
  FROM   sysadm.psprcsrqst r
  WHERE  r.prcsname = '&d_prcs' AND r.begindttm IS NOT NULL
  AND    r.begindttm > SYSTIMESTAMP - &d_look
  AND    r.runstatus NOT IN (2,5,8)),
snaps AS (
  SELECT /*+ materialize */ DISTINCT sn.snap_id
  FROM   dba_hist_snapshot sn, runs r
  WHERE  sn.dbid = (SELECT dbid FROM v$database)
  AND    sn.end_interval_time   >= CAST(r.b AS TIMESTAMP)
  AND    sn.begin_interval_time <= CAST(r.e AS TIMESTAMP)),
myids AS (
  SELECT /*+ materialize */ DISTINCT h.sql_id
  FROM   dba_hist_active_sess_history h, runs r
  WHERE  h.snap_id IN (SELECT snap_id FROM snaps)
  AND    h.dbid = (SELECT dbid FROM v$database)
  AND    h.sample_time BETWEEN CAST(r.b AS TIMESTAMP) AND CAST(r.e AS TIMESTAMP)
  AND    h.client_id = r.oprid
  AND    h.sql_id IS NOT NULL)
SELECT * FROM (
  SELECT CASE WHEN sn.end_interval_time
                   < TO_TIMESTAMP('&d_upg','YYYY-MM-DD HH24:MI:SS') THEN '1-PRE-UPGRADE'
              WHEN sn.end_interval_time
                   < TO_TIMESTAMP('&d_fix','YYYY-MM-DD HH24:MI:SS') THEN '2-POST-UPG-PREFIX'
              ELSE                                                     '3-POST-FIX' END era,
         st.sql_id, st.plan_hash_value phv,
         SUM(st.executions_delta) execs,
         ROUND(SUM(st.elapsed_time_delta)/1e6,1) elapsed_s,
         ROUND(SUM(st.elapsed_time_delta)/1e6
               /NULLIF(SUM(st.executions_delta),0),3) s_per_exec,
         ROUND(SUM(st.cpu_time_delta)/1e6,1) cpu_s,
         ROUND(SUM(st.iowait_delta)/1e6,1)   io_s,
         ROUND(SUM(st.clwait_delta)/1e6,1)   clu_s,
         SUM(st.buffer_gets_delta)    bgets,
         SUM(st.disk_reads_delta)     dreads,
         SUM(st.rows_processed_delta) rows_proc,
         ROUND(SUM(st.buffer_gets_delta)
               /NULLIF(SUM(st.rows_processed_delta),0),2) gets_row
  FROM   dba_hist_sqlstat st, dba_hist_snapshot sn
  WHERE  st.snap_id IN (SELECT snap_id FROM snaps)
  AND    st.dbid = (SELECT dbid FROM v$database)
  AND    sn.snap_id = st.snap_id
  AND    sn.dbid    = st.dbid
  AND    sn.instance_number = st.instance_number
  AND    st.sql_id IN (SELECT sql_id FROM myids)
  GROUP  BY CASE WHEN sn.end_interval_time
                      < TO_TIMESTAMP('&d_upg','YYYY-MM-DD HH24:MI:SS') THEN '1-PRE-UPGRADE'
                 WHEN sn.end_interval_time
                      < TO_TIMESTAMP('&d_fix','YYYY-MM-DD HH24:MI:SS') THEN '2-POST-UPG-PREFIX'
                 ELSE                                                     '3-POST-FIX' END,
            st.sql_id, st.plan_hash_value
  ORDER  BY 5 DESC)
WHERE  ROWNUM <= 70;
PROMPT ---- s_per_exec is the number to quote. gets_row in millions for few rows ----
PROMPT ---- means a broken access path ----

PROMPT
PROMPT ####################################################################
PROMPT #  6. THE DDL MODEL CALL   the single cleanest before / after proof
PROMPT #     One PL/SQL wrapper, identical text on both sides of the fix.
PROMPT ####################################################################
PROMPT
SELECT era, sql_id, SUM(execs) execs,
       ROUND(SUM(elapsed_s),1) total_s,
       ROUND(SUM(elapsed_s)/NULLIF(SUM(execs),0),2) s_per_exec
FROM (
  SELECT CASE WHEN sn.end_interval_time
                   < TO_TIMESTAMP('&d_upg','YYYY-MM-DD HH24:MI:SS') THEN '1-PRE-UPGRADE'
              WHEN sn.end_interval_time
                   < TO_TIMESTAMP('&d_fix','YYYY-MM-DD HH24:MI:SS') THEN '2-POST-UPG-PREFIX'
              ELSE                                                     '3-POST-FIX' END era,
         st.sql_id, st.executions_delta execs,
         st.elapsed_time_delta/1e6 elapsed_s
  FROM   dba_hist_sqlstat st, dba_hist_snapshot sn
  WHERE  st.dbid = (SELECT dbid FROM v$database)
  AND    sn.snap_id = st.snap_id
  AND    sn.dbid    = st.dbid
  AND    sn.instance_number = st.instance_number
  AND    sn.end_interval_time > SYSTIMESTAMP - &d_look
  AND    st.sql_id IN (
           SELECT t.sql_id FROM dba_hist_sqltext t
           WHERE  t.dbid = (SELECT dbid FROM v$database)
           AND    DBMS_LOB.INSTR(t.sql_text,'GATHER_TABLE_STATS') > 0
           AND    DBMS_LOB.INSTR(t.sql_text,'PS_COMBO_DATA_TBL')  > 0))
GROUP  BY era, sql_id
ORDER  BY era, 4 DESC;
PROMPT ---- expect roughly 101 sec per exec before the fix, about 5.5 after ----

PROMPT
PROMPT ####################################################################
PROMPT #  7. TODAY'S RUN   five minute timeline with an activity bar
PROMPT ####################################################################
PROMPT
WITH r AS (
  SELECT oprid, CAST(begindttm AS DATE) b,
         CAST(NVL(enddttm,SYSTIMESTAMP) AS DATE) e
  FROM   sysadm.psprcsrqst WHERE prcsinstance = &d_pi),
snaps AS (
  SELECT DISTINCT sn.snap_id
  FROM   dba_hist_snapshot sn, r
  WHERE  sn.dbid = (SELECT dbid FROM v$database)
  AND    sn.end_interval_time   >= CAST(r.b AS TIMESTAMP)
  AND    sn.begin_interval_time <= CAST(r.e AS TIMESTAMP)),
ash AS (
  SELECT /*+ materialize */
         TRUNC((CAST(h.sample_time AS DATE) - r.b)*1440/5) bucket,
         h.sql_id, h.session_state, h.event
  FROM   dba_hist_active_sess_history h, r
  WHERE  h.snap_id IN (SELECT snap_id FROM snaps)
  AND    h.dbid = (SELECT dbid FROM v$database)
  AND    h.sample_time BETWEEN CAST(r.b AS TIMESTAMP) AND CAST(r.e AS TIMESTAMP)
  AND    h.client_id = r.oprid),
agg AS (
  SELECT bucket, COUNT(*)*10 db_secs, ROUND(COUNT(*)*10/300,2) aas
  FROM   ash GROUP BY bucket),
dom AS (
  SELECT bucket, sql_id FROM (
    SELECT bucket, sql_id,
           ROW_NUMBER() OVER (PARTITION BY bucket ORDER BY COUNT(*) DESC) rn
    FROM   ash WHERE sql_id IS NOT NULL GROUP BY bucket, sql_id)
  WHERE rn = 1),
dev AS (
  SELECT bucket, ev FROM (
    SELECT bucket, DECODE(session_state,'ON CPU','CPU',event) ev,
           ROW_NUMBER() OVER (PARTITION BY bucket ORDER BY COUNT(*) DESC) rn
    FROM   ash GROUP BY bucket, DECODE(session_state,'ON CPU','CPU',event))
  WHERE rn = 1)
SELECT a.bucket seg, a.bucket*5 from_min, a.bucket*5+5 to_min,
       a.db_secs, a.aas,
       RPAD('#',LEAST(GREATEST(ROUND(a.aas*8),1),32),'#') bar,
       d.sql_id dominant_sql, e.ev dominant_event
FROM   agg a
LEFT   JOIN dom d ON d.bucket = a.bucket
LEFT   JOIN dev e ON e.bucket = a.bucket
ORDER  BY a.bucket;
PROMPT ---- AAS 1.0 for a long stretch = one session, nothing to parallelise away ----

PROMPT
PROMPT ####################################################################
PROMPT #  8. WHICH PLAN LINE BURNS THE TIME   today's run
PROMPT ####################################################################
PROMPT
WITH r AS (
  SELECT oprid, CAST(begindttm AS DATE) b,
         CAST(NVL(enddttm,SYSTIMESTAMP) AS DATE) e
  FROM   sysadm.psprcsrqst WHERE prcsinstance = &d_pi),
snaps AS (
  SELECT DISTINCT sn.snap_id
  FROM   dba_hist_snapshot sn, r
  WHERE  sn.dbid = (SELECT dbid FROM v$database)
  AND    sn.end_interval_time   >= CAST(r.b AS TIMESTAMP)
  AND    sn.begin_interval_time <= CAST(r.e AS TIMESTAMP)),
ash AS (
  SELECT /*+ materialize */ h.sql_id, h.sql_plan_hash_value phv,
         h.sql_plan_line_id line, h.session_state
  FROM   dba_hist_active_sess_history h, r
  WHERE  h.snap_id IN (SELECT snap_id FROM snaps)
  AND    h.dbid = (SELECT dbid FROM v$database)
  AND    h.sample_time BETWEEN CAST(r.b AS TIMESTAMP) AND CAST(r.e AS TIMESTAMP)
  AND    h.client_id = r.oprid
  AND    h.sql_plan_line_id IS NOT NULL)
SELECT * FROM (
  SELECT a.sql_id, a.phv, a.line, p.operation, p.options, p.object_name,
         COUNT(*)*10 db_secs,
         ROUND(SUM(CASE WHEN a.session_state='ON CPU' THEN 1 ELSE 0 END)
               *100/COUNT(*),1) cpu_pct
  FROM   ash a
  LEFT   JOIN (SELECT DISTINCT sql_id, plan_hash_value, id,
                      operation, options, object_name
               FROM   dba_hist_sql_plan
               WHERE  dbid = (SELECT dbid FROM v$database)) p
         ON  p.sql_id = a.sql_id AND p.plan_hash_value = a.phv AND p.id = a.line
  GROUP  BY a.sql_id, a.phv, a.line, p.operation, p.options, p.object_name
  ORDER  BY 7 DESC)
WHERE  ROWNUM <= 30;
PROMPT ---- OPTIMIZER STATISTICS GATHERING as a row source = AUTO_SAMPLE_SIZE ----
PROMPT ---- LOAD TABLE CONVENTIONAL = row by row insert, full index maintenance ----

PROMPT
PROMPT ####################################################################
PROMPT #  9. WAIT PROFILE PER ERA AND PER RAC NODE
PROMPT ####################################################################
PROMPT
WITH runs AS (
  SELECT /*+ materialize */ r.oprid,
         CAST(r.begindttm AS DATE) b,
         CAST(NVL(r.enddttm,SYSTIMESTAMP) AS DATE) e,
         CASE WHEN CAST(r.begindttm AS DATE)
                   < TO_DATE('&d_upg','YYYY-MM-DD HH24:MI:SS') THEN '1-PRE-UPGRADE'
              WHEN CAST(r.begindttm AS DATE)
                   < TO_DATE('&d_fix','YYYY-MM-DD HH24:MI:SS') THEN '2-POST-UPG-PREFIX'
              ELSE                                                '3-POST-FIX' END era
  FROM   sysadm.psprcsrqst r
  WHERE  r.prcsname = '&d_prcs' AND r.begindttm IS NOT NULL
  AND    r.begindttm > SYSTIMESTAMP - &d_look
  AND    r.runstatus NOT IN (2,5,8)),
snaps AS (
  SELECT /*+ materialize */ DISTINCT sn.snap_id
  FROM   dba_hist_snapshot sn, runs r
  WHERE  sn.dbid = (SELECT dbid FROM v$database)
  AND    sn.end_interval_time   >= CAST(r.b AS TIMESTAMP)
  AND    sn.begin_interval_time <= CAST(r.e AS TIMESTAMP)),
ash AS (
  SELECT /*+ materialize */ r.era, h.instance_number inst,
         h.wait_class, h.session_state, h.event, h.current_obj#
  FROM   dba_hist_active_sess_history h, runs r
  WHERE  h.snap_id IN (SELECT snap_id FROM snaps)
  AND    h.dbid = (SELECT dbid FROM v$database)
  AND    h.sample_time BETWEEN CAST(r.b AS TIMESTAMP) AND CAST(r.e AS TIMESTAMP)
  AND    h.client_id = r.oprid)
SELECT era, inst node, NVL(wait_class,'CPU') wclass,
       COUNT(*)*10 db_secs,
       ROUND(COUNT(*)*100/SUM(COUNT(*)) OVER (PARTITION BY era),1) pct_of_era,
       MAX(DECODE(session_state,'ON CPU','CPU',event)) sample_event
FROM   ash
GROUP  BY era, inst, NVL(wait_class,'CPU')
ORDER  BY era, 4 DESC;

PROMPT
PROMPT ####################################################################
PROMPT #  10. THE TWO TABLES AND THEIR INDEXES
PROMPT ####################################################################
PROMPT
SELECT t.table_name tbl, t.num_rows, t.sample_size,
       ROUND(t.sample_size/NULLIF(t.num_rows,0)*100,2) pct_sampled,
       t.last_analyzed,
       (SELECT ROUND(SUM(sg.bytes)/1024/1024) FROM dba_segments sg
        WHERE  sg.owner=t.owner AND sg.segment_name=t.table_name
        AND    sg.segment_type LIKE 'TABLE%') table_mb
FROM   dba_tab_statistics t
WHERE  t.owner='SYSADM' AND t.object_type='TABLE'
AND    t.table_name IN ('PS_COMBO_DATA_TBL','PS_COMBO_DATA_BUDG')
ORDER  BY 1;

PROMPT
SELECT i.index_name, i.num_rows, i.sample_size,
       ROUND(i.sample_size/NULLIF(i.num_rows,0)*100,2) pct_sampled,
       i.clustering_factor cf,
       ROUND(i.clustering_factor/NULLIF(i.num_rows,0),3) cf_ratio,
       i.blevel, i.last_analyzed,
       (SELECT ROUND(SUM(sg.bytes)/1024/1024) FROM dba_segments sg
        WHERE  sg.owner='SYSADM' AND sg.segment_name=i.index_name
        AND    sg.segment_type='INDEX') index_mb
FROM   dba_ind_statistics i
WHERE  i.owner='SYSADM'
AND    i.table_name IN ('PS_COMBO_DATA_TBL','PS_COMBO_DATA_BUDG')
ORDER  BY 9 DESC NULLS LAST;
PROMPT ---- total index MB versus table MB drives insert and delete cost, because ----
PROMPT ---- every row inserted or deleted maintains every index ----

PROMPT
PROMPT ####################################################################
PROMPT #  11. VALIDATION AND DRIFT
PROMPT ####################################################################
PROMPT
SELECT 'table prefs on PS_COMBO_DATA_TBL (want 4)' info, TO_CHAR(COUNT(*)) val
FROM   dba_tab_stat_prefs
WHERE  owner='SYSADM' AND table_name='PS_COMBO_DATA_TBL'
UNION ALL SELECT 'ESTIMATE_PERCENT numeric (want 1)',
       TO_CHAR(TO_NUMBER(DBMS_STATS.GET_PREFS('ESTIMATE_PERCENT',
               'SYSADM','PS_COMBO_DATA_TBL'))) FROM dual
UNION ALL SELECT 'PREFERENCE_OVERRIDES_PARAMETER (want TRUE)',
       DBMS_STATS.GET_PREFS('PREFERENCE_OVERRIDES_PARAMETER',
               'SYSADM','PS_COMBO_DATA_TBL') FROM dual
UNION ALL SELECT 'CASCADE (want TRUE)',
       DBMS_STATS.GET_PREFS('CASCADE','SYSADM','PS_COMBO_DATA_TBL') FROM dual
UNION ALL SELECT 'METHOD_OPT',
       SUBSTR(DBMS_STATS.GET_PREFS('METHOD_OPT',
               'SYSADM','PS_COMBO_DATA_TBL'),1,55) FROM dual
UNION ALL SELECT 'GLOBAL ESTIMATE_PERCENT (should be AUTO)',
       DBMS_STATS.GET_PREFS('ESTIMATE_PERCENT') FROM dual
UNION ALL SELECT 'GLOBAL override (should be FALSE)',
       DBMS_STATS.GET_PREFS('PREFERENCE_OVERRIDES_PARAMETER') FROM dual
UNION ALL SELECT 'other SYSADM tables carrying prefs',
       TO_CHAR(COUNT(DISTINCT table_name)) FROM dba_tab_stat_prefs
       WHERE owner='SYSADM' AND table_name <> 'PS_COMBO_DATA_TBL'
UNION ALL SELECT 'SQL patches / profiles / baselines',
       TO_CHAR((SELECT COUNT(*) FROM dba_sql_patches))||' / '||
       TO_CHAR((SELECT COUNT(*) FROM dba_sql_profiles))||' / '||
       TO_CHAR((SELECT COUNT(*) FROM dba_sql_plan_baselines)) FROM dual;

PROMPT
PROMPT ---- PSDDLMODEL as delivered by 8.62. We never touched it ----
PROMPT
SELECT statement_type, platform, LENGTH(model_statement) len,
       SUBSTR(REPLACE(REPLACE(model_statement,CHR(10),' '),CHR(13),' '),1,150) txt
FROM   sysadm.psddlmodel
WHERE  statement_type = 4 AND platform = 2;
PROMPT ---- len 154 with AUTO_SAMPLE_SIZE is the 8.62 model. The fix overrides it ----
PROMPT ---- through table preferences, so a future upgrade cannot revert it ----

PROMPT
PROMPT ####################################################################
PROMPT #  END OF REPORT
PROMPT ####################################################################
EXIT

-- =====================================================================
-- fscebd_rca.sql   POST-RUN DEEP RCA
--
-- Compares three eras for FS_CEBD:
--   1-PRE-UPGRADE      before 2026-06-26  (PeopleTools 8.59)
--   2-POST-UPG-PREFIX  06-26 to 07-28     (8.62, DDL model regressed)
--   3-POST-FIX         after 07-28        (DBMS_STATS table prefs applied)
--
-- Uses AWR (DBA_HIST_*) + PeopleSoft SYSADM tables. Needs SYSDBA.
-- Every DBA_HIST_ACTIVE_SESS_HISTORY access carries a SNAP_ID + DBID
-- predicate, otherwise it full scans 365 days of history.
--
-- One heavy ASH scan is materialised into private temp tables, then all
-- sections read from those. Expect 2-10 minutes total, run once.
--
-- Literal-varying statements: FS_CEBD embeds PROCESS_INSTANCE as a
-- literal, so SQL_ID changes every run and cannot be compared directly
-- across eras. Section 7 groups by SIG, the statement text with
-- standalone numbers replaced by #, which IS stable across runs.
-- =====================================================================
SET DEFINE OFF
SET FEEDBACK OFF VERIFY OFF ECHO OFF TRIMSPOOL ON TRIMOUT ON
SET LINESIZE 210 PAGESIZE 60000 NUMWIDTH 13 LONG 8000 LONGCHUNKSIZE 8000
SET TIMING ON
WHENEVER SQLERROR CONTINUE NONE
WHENEVER OSERROR CONTINUE NONE

ALTER SESSION SET nls_date_format='YYYY-MM-DD HH24:MI:SS';
ALTER SESSION DISABLE PARALLEL QUERY;

@fscebd_pin.sql

COL era        FOR A18
COL runcntlid  FOR A30
COL oprid      FOR A9
COL stat       FOR A11
COL kind       FOR A14
COL sql_id     FOR A14
COL txt        FOR A76
COL sig        FOR A74
COL info       FOR A150
COL obj        FOR A36
COL otype      FOR A6
COL operation  FOR A24
COL options    FOR A20
COL object_name FOR A26
COL index_name FOR A22
COL event      FOR A32
COL ev         FOR A32
COL wclass     FOR A12
COL tbl        FOR A20
COL phvs       FOR A46
COL bar        FOR A42
COL target     FOR A34
COL lever      FOR A58

PROMPT
PROMPT ####################################################################
PROMPT #  FS_CEBD  ROOT CAUSE AND BEFORE / AFTER ANALYSIS
PROMPT ####################################################################

PROMPT
PROMPT ==== 0. PREFLIGHT ====
PROMPT
SELECT 'db='||d.name||'  dbid='||TO_CHAR(d.dbid)||'  role='||d.database_role||
       '  version='||(SELECT version FROM v$instance)||
       '  run_at='||TO_CHAR(SYSDATE,'YYYY-MM-DD HH24:MI:SS') info
FROM   v$database d;

SELECT 'private_temp_table_prefix = '||value||
       '   (must be ORA$PTT_ for this script)' info
FROM   v$parameter WHERE name = 'private_temp_table_prefix';

SELECT 'AWR retention days = '||
       TO_CHAR(EXTRACT(DAY FROM retention))||
       '   snap interval min = '||
       TO_CHAR(EXTRACT(HOUR FROM snap_interval)*60
              +EXTRACT(MINUTE FROM snap_interval)) info
FROM   dba_hist_wr_control WHERE dbid = (SELECT dbid FROM v$database);

SELECT 'oldest AWR snapshot = '||TO_CHAR(MIN(begin_interval_time),'YYYY-MM-DD')||
       '   newest = '||TO_CHAR(MAX(end_interval_time),'YYYY-MM-DD HH24:MI')||
       '   snaps = '||TO_CHAR(COUNT(*)) info
FROM   dba_hist_snapshot WHERE dbid = (SELECT dbid FROM v$database);

SELECT 'lookback_days='||TO_CHAR(:v_look)||
       '  upgrade='||:v_upg||
       '  fix='||:v_fix||
       '  target_run='||TO_CHAR(:v_pi) info
FROM   dual;

PROMPT
PROMPT ==== 1. BUILDING WORK SETS   (this is the slow part) ====
PROMPT

-- ---------- 1a. every FS_CEBD run in the lookback, tagged by era ----------
CREATE PRIVATE TEMPORARY TABLE ora$ptt_runs
ON COMMIT PRESERVE DEFINITION AS
SELECT r.prcsinstance,
       r.oprid,
       r.runcntlid,
       r.runstatus,
       CAST(r.begindttm AS DATE) b,
       CAST(NVL(r.enddttm,SYSTIMESTAMP) AS DATE) e,
       ROUND((CAST(NVL(r.enddttm,SYSTIMESTAMP) AS DATE)
             -CAST(r.begindttm AS DATE))*86400) run_sec,
       CASE
         WHEN CAST(r.begindttm AS DATE)
              <  TO_DATE(:v_upg,'YYYY-MM-DD HH24:MI:SS') THEN '1-PRE-UPGRADE'
         WHEN CAST(r.begindttm AS DATE)
              <  TO_DATE(:v_fix,'YYYY-MM-DD HH24:MI:SS') THEN '2-POST-UPG-PREFIX'
         ELSE                                                 '3-POST-FIX'
       END era
FROM   sysadm.psprcsrqst r
WHERE  r.prcsname = :v_prcsname
AND    r.begindttm IS NOT NULL
AND    r.begindttm > SYSTIMESTAMP - :v_look
AND    r.runstatus NOT IN (2,5,8);

SELECT 'runs captured = '||TO_CHAR(COUNT(*))||
       '   earliest = '||TO_CHAR(MIN(b),'YYYY-MM-DD')||
       '   latest = '||TO_CHAR(MAX(b),'YYYY-MM-DD') info
FROM   ora$ptt_runs;

-- ---------- 1b. snapshot bounds covering those runs ----------
CREATE PRIVATE TEMPORARY TABLE ora$ptt_bnd
ON COMMIT PRESERVE DEFINITION AS
SELECT MIN(sn.snap_id) snap_lo,
       MAX(sn.snap_id) snap_hi,
       MAX(sn.dbid)    dbid
FROM   dba_hist_snapshot sn
WHERE  sn.dbid = (SELECT dbid FROM v$database)
AND    sn.end_interval_time   >= (SELECT MIN(b) FROM ora$ptt_runs)
AND    sn.begin_interval_time <= (SELECT MAX(e) FROM ora$ptt_runs) + 1;

SELECT 'snap range = '||TO_CHAR(snap_lo)||' .. '||TO_CHAR(snap_hi)||
       '   dbid = '||TO_CHAR(dbid) info
FROM   ora$ptt_bnd;

-- ---------- 1c. the job's ASH, both nodes, PX children included ----------
-- PeopleSoft AE does not populate MODULE/ACTION on this system, so the
-- correlation is CLIENT_ID = OPRID, plus PX slaves via the QC columns.
CREATE PRIVATE TEMPORARY TABLE ora$ptt_ash
ON COMMIT PRESERVE DEFINITION AS
WITH qc AS (
  SELECT /*+ no_merge */ DISTINCT
         h.instance_number qc_inst, h.session_id qc_sid,
         h.session_serial# qc_ser,  r.prcsinstance
  FROM   dba_hist_active_sess_history h, ora$ptt_runs r, ora$ptt_bnd bd
  WHERE  h.snap_id BETWEEN bd.snap_lo AND bd.snap_hi
  AND    h.dbid = bd.dbid
  AND    h.sample_time BETWEEN CAST(r.b AS TIMESTAMP) AND CAST(r.e AS TIMESTAMP)
  AND    h.client_id = r.oprid)
SELECT r.prcsinstance, r.runcntlid, r.era, r.run_sec, r.b run_begin,
       h.instance_number inst, h.sample_time, h.session_id,
       h.session_state, h.event, h.wait_class,
       h.sql_id, h.sql_plan_hash_value phv, h.sql_plan_line_id plan_line,
       h.current_obj#, h.program
FROM   dba_hist_active_sess_history h, ora$ptt_runs r, ora$ptt_bnd bd
WHERE  h.snap_id BETWEEN bd.snap_lo AND bd.snap_hi
AND    h.dbid = bd.dbid
AND    h.sample_time BETWEEN CAST(r.b AS TIMESTAMP) AND CAST(r.e AS TIMESTAMP)
AND   (h.client_id = r.oprid
   OR  EXISTS (SELECT 1 FROM qc c
               WHERE c.qc_inst      = h.qc_instance_id
               AND   c.qc_sid       = h.qc_session_id
               AND   c.qc_ser       = h.qc_session_serial#
               AND   c.prcsinstance = r.prcsinstance));

SELECT 'ASH rows captured = '||TO_CHAR(COUNT(*))||
       '   = '||TO_CHAR(COUNT(*)*10)||' DB seconds'||
       '   (1 AWR ASH sample = 10 sec)' info
FROM   ora$ptt_ash;

-- ---------- 1d. catalogue every SQL_ID with text, kind and signature ----------
CREATE PRIVATE TEMPORARY TABLE ora$ptt_sql
ON COMMIT PRESERVE DEFINITION AS
WITH ids AS (
  SELECT DISTINCT sql_id FROM ora$ptt_ash WHERE sql_id IS NOT NULL),
raw AS (
  SELECT i.sql_id,
         REGEXP_REPLACE(
           NVL(DBMS_LOB.SUBSTR(t.sql_text,900,1),'(text aged out of AWR)'),
           '[[:space:]]+',' ') txt
  FROM   ids i
  LEFT   JOIN dba_hist_sqltext t
         ON t.sql_id = i.sql_id
        AND t.dbid   = (SELECT dbid FROM v$database))
SELECT r.sql_id,
       SUBSTR(r.txt,1,900) txt,
       -- signature: strip standalone numbers so literal-varying statements
       -- collapse to one comparable identity across eras
       SUBSTR(REGEXP_REPLACE(UPPER(r.txt),'(^|[^A-Za-z0-9_])[0-9]+','\1#'),1,300) sig,
       CASE
         WHEN r.txt = '(text aged out of AWR)'                 THEN 'AGED-OUT'
         WHEN UPPER(r.txt) LIKE '%SQL ANALYZE%'                THEN 'STATS-ANALYZE'
         WHEN UPPER(r.txt) LIKE '%DBMS_STATS%'                 THEN 'STATS-GATHER'
         WHEN UPPER(r.txt) LIKE '%PARALLEL_INDEX(T%'           THEN 'STATS-INDEX'
         WHEN UPPER(r.txt) LIKE 'DELETE FROM PS_COMBO_DATA_TBL%' THEN 'PURGE'
         WHEN UPPER(r.txt) LIKE 'INSERT INTO PS_COMBO_DATA_TBL%' THEN 'BUILD-INSERT'
         WHEN UPPER(r.txt) LIKE '%PS_COMBO_DATA_BUDG%'         THEN 'BUDG'
         WHEN UPPER(r.txt) LIKE '%PS_FS_CEBD_TAO%'             THEN 'TAO-WORK'
         WHEN UPPER(r.txt) LIKE '%PS_VED_CMB%'                 THEN 'COMBO-EDIT'
         WHEN UPPER(r.txt) LIKE '%PS_COMB_EXP%'                THEN 'COMBO-EDIT'
         WHEN UPPER(r.txt) LIKE 'UPDATE%'                      THEN 'APP-UPDATE'
         WHEN UPPER(r.txt) LIKE 'INSERT%'                      THEN 'APP-INSERT'
         WHEN UPPER(r.txt) LIKE 'DELETE%'                      THEN 'APP-DELETE'
         WHEN UPPER(r.txt) LIKE 'SELECT%'                      THEN 'APP-SELECT'
         ELSE 'APP-OTHER'
       END kind
FROM   raw r;

SELECT 'distinct SQL_IDs in the job = '||TO_CHAR(COUNT(*))||
       '   text aged out = '||
       TO_CHAR(SUM(CASE WHEN kind='AGED-OUT' THEN 1 ELSE 0 END)) info
FROM   ora$ptt_sql;

PROMPT
PROMPT ####################################################################
PROMPT #  2. RUN INVENTORY   every run, every run control, every era
PROMPT ####################################################################
PROMPT
SELECT r.era, r.runcntlid, r.prcsinstance, r.oprid,
       DECODE(r.runstatus,3,'ERROR',7,'PROCESSING',9,'SUCCESS',
                          10,'NOTSUCCESS',17,'SUCC_WARN',
                          TO_CHAR(r.runstatus)) stat,
       TO_CHAR(r.b,'MM-DD HH24:MI') started,
       r.run_sec,
       ROUND(r.run_sec/60,1) run_min,
       NVL(a.db_secs,0) db_secs,
       ROUND(NVL(a.db_secs,0)/GREATEST(r.run_sec,1),2) aas,
       NVL(a.sqls,0)  sqls,
       NVL(a.plans,0) plans,
       NVL(a.nodes,'-') nodes
FROM   ora$ptt_runs r
LEFT   JOIN (SELECT prcsinstance, COUNT(*)*10 db_secs,
                    COUNT(DISTINCT sql_id) sqls,
                    COUNT(DISTINCT phv) plans,
                    LISTAGG(DISTINCT TO_CHAR(inst),',')
                      WITHIN GROUP (ORDER BY TO_CHAR(inst)) nodes
             FROM   ora$ptt_ash GROUP BY prcsinstance) a
       ON a.prcsinstance = r.prcsinstance
ORDER  BY r.era, r.runcntlid, r.b;
PROMPT ---- AAS near 1.0 means the App Engine is running single threaded ----
PROMPT ---- AAS 0 means ASH correlation failed for that run ----

PROMPT
PROMPT ####################################################################
PROMPT #  3. HEADLINE   runtime per run control per era
PROMPT ####################################################################
PROMPT
SELECT r.runcntlid, r.era,
       COUNT(*) runs,
       ROUND(MIN(r.run_sec)/60,1)  min_min,
       ROUND(AVG(r.run_sec)/60,1)  avg_min,
       ROUND(MAX(r.run_sec)/60,1)  max_min,
       ROUND(AVG(NVL(a.db_secs,0)))          avg_db_secs,
       ROUND(AVG(NVL(a.stats_secs,0)))       avg_stats_secs,
       ROUND(AVG(NVL(a.stats_secs,0))*100
             /GREATEST(AVG(NVL(a.db_secs,0)),1),1) stats_pct
FROM   ora$ptt_runs r
LEFT   JOIN (SELECT h.prcsinstance,
                    COUNT(*)*10 db_secs,
                    SUM(CASE WHEN s.kind LIKE 'STATS%' THEN 10 ELSE 0 END) stats_secs
             FROM   ora$ptt_ash h
             LEFT   JOIN ora$ptt_sql s ON s.sql_id = h.sql_id
             GROUP  BY h.prcsinstance) a
       ON a.prcsinstance = r.prcsinstance
GROUP  BY r.runcntlid, r.era
ORDER  BY r.runcntlid, r.era;
PROMPT ---- this is the table for management. Never average across run controls ----

PROMPT
PROMPT ####################################################################
PROMPT #  4. DB TIME BY CATEGORY PER ERA
PROMPT ####################################################################
PROMPT
SELECT h.era, NVL(s.kind,'NO-SQL-ID') kind,
       COUNT(*)*10 db_secs,
       ROUND(COUNT(*)*100/SUM(COUNT(*)) OVER (PARTITION BY h.era),1) pct_of_era,
       COUNT(DISTINCT h.sql_id) sqls,
       COUNT(DISTINCT h.prcsinstance) runs
FROM   ora$ptt_ash h
LEFT   JOIN ora$ptt_sql s ON s.sql_id = h.sql_id
GROUP  BY h.era, NVL(s.kind,'NO-SQL-ID')
ORDER  BY h.era, 3 DESC;
PROMPT ---- statistics share was 82 pct on run 26068516. Watch it fall to single digits ----

PROMPT
PROMPT ####################################################################
PROMPT #  5. ATTRIBUTION CONFIDENCE   did other work share the OPRID
PROMPT ####################################################################
PROMPT
SELECT r.prcsinstance, r.era, r.runcntlid,
       (SELECT COUNT(DISTINCT o.prcsname)
        FROM   sysadm.psprcsrqst o
        WHERE  o.oprid = r.oprid
        AND    o.prcsname <> :v_prcsname
        AND    o.begindttm < CAST(r.e AS TIMESTAMP)
        AND    NVL(o.enddttm,SYSTIMESTAMP) > CAST(r.b AS TIMESTAMP)) overlap_prcs,
       CASE WHEN (SELECT COUNT(*)
                  FROM   sysadm.psprcsrqst o
                  WHERE  o.oprid = r.oprid
                  AND    o.prcsname <> :v_prcsname
                  AND    o.begindttm < CAST(r.e AS TIMESTAMP)
                  AND    NVL(o.enddttm,SYSTIMESTAMP) > CAST(r.b AS TIMESTAMP)) = 0
            THEN 'CLEAN' ELSE 'BLENDED' END confidence
FROM   ora$ptt_runs r
ORDER  BY r.era, r.b;
PROMPT ---- BLENDED = that run's ASH may include other work by the same operator ----

PROMPT
PROMPT ####################################################################
PROMPT #  6. EVERY SQL_ID THE JOB RAN, BY ERA
PROMPT ####################################################################
PROMPT
SELECT * FROM (
  SELECT h.era, h.sql_id, NVL(s.kind,'NO-TEXT') kind,
         COUNT(*)*10 db_secs,
         SUM(CASE WHEN h.session_state='ON CPU' THEN 10 ELSE 0 END) cpu_secs,
         COUNT(DISTINCT h.phv)          plans,
         COUNT(DISTINCT h.prcsinstance) runs,
         TO_CHAR(MIN(h.sample_time),'MM-DD HH24:MI') first_seen,
         TO_CHAR(MAX(h.sample_time),'MM-DD HH24:MI') last_seen,
         SUBSTR(MIN(s.txt),1,76) txt
  FROM   ora$ptt_ash h
  LEFT   JOIN ora$ptt_sql s ON s.sql_id = h.sql_id
  WHERE  h.sql_id IS NOT NULL
  GROUP  BY h.era, h.sql_id, NVL(s.kind,'NO-TEXT')
  ORDER  BY h.era, 4 DESC)
WHERE  ROWNUM <= 150;

PROMPT
PROMPT ####################################################################
PROMPT #  7. STATEMENT COMPARISON ACROSS ERAS   grouped by SIGNATURE
PROMPT #     This is the section that survives literal-varying SQL_IDs.
PROMPT ####################################################################
PROMPT
SELECT * FROM (
  SELECT NVL(s.kind,'NO-TEXT') kind,
         COUNT(*)*10 tot_secs,
         SUM(CASE WHEN h.era='1-PRE-UPGRADE'     THEN 10 ELSE 0 END) pre_secs,
         SUM(CASE WHEN h.era='2-POST-UPG-PREFIX' THEN 10 ELSE 0 END) upg_secs,
         SUM(CASE WHEN h.era='3-POST-FIX'        THEN 10 ELSE 0 END) fix_secs,
         COUNT(DISTINCT h.sql_id) sqlids,
         COUNT(DISTINCT h.phv)    plans,
         SUBSTR(MIN(s.sig),1,74)  sig
  FROM   ora$ptt_ash h
  JOIN   ora$ptt_sql s ON s.sql_id = h.sql_id
  GROUP  BY s.sig, NVL(s.kind,'NO-TEXT')
  ORDER  BY 2 DESC)
WHERE  ROWNUM <= 60;
PROMPT ---- sqlids > 1 for one signature = literal not bound = hard parse every run ----
PROMPT ---- upg_secs high with pre_secs low = the statement the upgrade broke ----
PROMPT ---- fix_secs low with upg_secs high = what our change repaired ----

PROMPT
PROMPT ####################################################################
PROMPT #  8. NORMALISED PER-RUN COST PER SIGNATURE
PROMPT #     seconds of DB time this statement family costs one run
PROMPT ####################################################################
PROMPT
SELECT * FROM (
  SELECT NVL(s.kind,'NO-TEXT') kind,
         ROUND(SUM(CASE WHEN h.era='1-PRE-UPGRADE' THEN 10 ELSE 0 END)
               /GREATEST(COUNT(DISTINCT CASE WHEN h.era='1-PRE-UPGRADE'
                         THEN h.prcsinstance END),1)) pre_per_run,
         ROUND(SUM(CASE WHEN h.era='2-POST-UPG-PREFIX' THEN 10 ELSE 0 END)
               /GREATEST(COUNT(DISTINCT CASE WHEN h.era='2-POST-UPG-PREFIX'
                         THEN h.prcsinstance END),1)) upg_per_run,
         ROUND(SUM(CASE WHEN h.era='3-POST-FIX' THEN 10 ELSE 0 END)
               /GREATEST(COUNT(DISTINCT CASE WHEN h.era='3-POST-FIX'
                         THEN h.prcsinstance END),1)) fix_per_run,
         SUBSTR(MIN(s.sig),1,74) sig
  FROM   ora$ptt_ash h
  JOIN   ora$ptt_sql s ON s.sql_id = h.sql_id
  GROUP  BY s.sig, NVL(s.kind,'NO-TEXT')
  ORDER  BY 4 DESC, 3 DESC)
WHERE  ROWNUM <= 40;
PROMPT ---- fix_per_run is today's real remaining cost per run. Improve the top rows ----

PROMPT
PROMPT ####################################################################
PROMPT #  9. PLAN HASH BY ERA   did any plan actually change
PROMPT ####################################################################
PROMPT
SELECT * FROM (
  SELECT h.sql_id, h.phv,
         COUNT(*)*10 tot_secs,
         SUM(CASE WHEN h.era='1-PRE-UPGRADE'     THEN 10 ELSE 0 END) pre_secs,
         SUM(CASE WHEN h.era='2-POST-UPG-PREFIX' THEN 10 ELSE 0 END) upg_secs,
         SUM(CASE WHEN h.era='3-POST-FIX'        THEN 10 ELSE 0 END) fix_secs,
         COUNT(DISTINCT h.prcsinstance) runs,
         NVL(s.kind,'NO-TEXT') kind
  FROM   ora$ptt_ash h
  LEFT   JOIN ora$ptt_sql s ON s.sql_id = h.sql_id
  WHERE  h.phv > 0
  GROUP  BY h.sql_id, h.phv, NVL(s.kind,'NO-TEXT')
  ORDER  BY 3 DESC)
WHERE  ROWNUM <= 60;

PROMPT
PROMPT ---- statements that ran more than one plan hash ----
PROMPT
SELECT h.sql_id, NVL(s.kind,'NO-TEXT') kind,
       COUNT(DISTINCT h.phv) plans, COUNT(*)*10 db_secs,
       LISTAGG(DISTINCT TO_CHAR(h.phv),',')
         WITHIN GROUP (ORDER BY TO_CHAR(h.phv)) phvs
FROM   ora$ptt_ash h
LEFT   JOIN ora$ptt_sql s ON s.sql_id = h.sql_id
WHERE  h.phv > 0
GROUP  BY h.sql_id, NVL(s.kind,'NO-TEXT')
HAVING COUNT(DISTINCT h.phv) > 1
ORDER  BY 4 DESC;

PROMPT
PROMPT ####################################################################
PROMPT #  10. AWR EXECUTION METRICS PER SQL_ID PER ERA
PROMPT #      real executions, elapsed, CPU, IO, gets per row
PROMPT ####################################################################
PROMPT
SELECT * FROM (
  SELECT CASE
           WHEN sn.end_interval_time
                <  TO_TIMESTAMP(:v_upg,'YYYY-MM-DD HH24:MI:SS') THEN '1-PRE-UPGRADE'
           WHEN sn.end_interval_time
                <  TO_TIMESTAMP(:v_fix,'YYYY-MM-DD HH24:MI:SS') THEN '2-POST-UPG-PREFIX'
           ELSE                                                      '3-POST-FIX'
         END era,
         st.sql_id, st.plan_hash_value phv,
         SUM(st.executions_delta) execs,
         ROUND(SUM(st.elapsed_time_delta)/1e6,1) elapsed_s,
         ROUND(SUM(st.elapsed_time_delta)/1e6
               /NULLIF(SUM(st.executions_delta),0),3) s_per_exec,
         ROUND(SUM(st.cpu_time_delta)/1e6,1) cpu_s,
         ROUND(SUM(st.iowait_delta)/1e6,1)   io_s,
         ROUND(SUM(st.clwait_delta)/1e6,1)   clu_s,
         SUM(st.buffer_gets_delta)  bgets,
         SUM(st.disk_reads_delta)   dreads,
         SUM(st.rows_processed_delta) rows_proc,
         ROUND(SUM(st.buffer_gets_delta)
               /NULLIF(SUM(st.rows_processed_delta),0),2) gets_row
  FROM   dba_hist_sqlstat st, dba_hist_snapshot sn, ora$ptt_bnd bd
  WHERE  st.snap_id BETWEEN bd.snap_lo AND bd.snap_hi
  AND    st.dbid = bd.dbid
  AND    sn.snap_id = st.snap_id
  AND    sn.dbid    = st.dbid
  AND    sn.instance_number = st.instance_number
  AND    st.sql_id IN (SELECT sql_id FROM ora$ptt_sql)
  GROUP  BY CASE
              WHEN sn.end_interval_time
                   <  TO_TIMESTAMP(:v_upg,'YYYY-MM-DD HH24:MI:SS') THEN '1-PRE-UPGRADE'
              WHEN sn.end_interval_time
                   <  TO_TIMESTAMP(:v_fix,'YYYY-MM-DD HH24:MI:SS') THEN '2-POST-UPG-PREFIX'
              ELSE                                                      '3-POST-FIX'
            END, st.sql_id, st.plan_hash_value
  ORDER  BY 5 DESC)
WHERE  ROWNUM <= 80;
PROMPT ---- gets_row in the millions for few rows = broken access path ----
PROMPT ---- s_per_exec is the number to quote. Same statement, before vs after ----

PROMPT
PROMPT ####################################################################
PROMPT #  11. THE DDL MODEL CALL   the cleanest before / after proof
PROMPT #      One PL/SQL wrapper, identical text, measured both sides.
PROMPT ####################################################################
PROMPT
SELECT era, sql_id, SUM(execs) execs, ROUND(SUM(elapsed_s),1) total_s,
       ROUND(SUM(elapsed_s)/NULLIF(SUM(execs),0),2) s_per_exec
FROM (
  SELECT CASE
           WHEN sn.end_interval_time
                <  TO_TIMESTAMP(:v_upg,'YYYY-MM-DD HH24:MI:SS') THEN '1-PRE-UPGRADE'
           WHEN sn.end_interval_time
                <  TO_TIMESTAMP(:v_fix,'YYYY-MM-DD HH24:MI:SS') THEN '2-POST-UPG-PREFIX'
           ELSE                                                      '3-POST-FIX'
         END era,
         st.sql_id,
         st.executions_delta execs,
         st.elapsed_time_delta/1e6 elapsed_s
  FROM   dba_hist_sqlstat st, dba_hist_snapshot sn, ora$ptt_bnd bd
  WHERE  st.snap_id BETWEEN bd.snap_lo AND bd.snap_hi
  AND    st.dbid = bd.dbid
  AND    sn.snap_id = st.snap_id
  AND    sn.dbid    = st.dbid
  AND    sn.instance_number = st.instance_number
  AND    st.sql_id IN (
           SELECT t.sql_id FROM dba_hist_sqltext t
           WHERE  t.dbid = bd.dbid
           AND    DBMS_LOB.INSTR(t.sql_text,'GATHER_TABLE_STATS') > 0
           AND    DBMS_LOB.INSTR(t.sql_text,'PS_COMBO_DATA_TBL')  > 0))
GROUP  BY era, sql_id
ORDER  BY era, 4 DESC;
PROMPT ---- expect roughly 101 sec per exec before the fix, 5.5 after ----

PROMPT
PROMPT ####################################################################
PROMPT #  12. TODAY'S RUN   minute-by-minute timeline
PROMPT ####################################################################
PROMPT
WITH seg AS (
  SELECT h.prcsinstance,
         TRUNC((CAST(h.sample_time AS DATE) - h.run_begin)*1440/5) bucket,
         h.sql_id, h.session_state, h.event
  FROM   ora$ptt_ash h
  WHERE  h.prcsinstance = :v_pi),
agg AS (
  SELECT bucket, COUNT(*)*10 db_secs, ROUND(COUNT(*)*10/300,2) aas
  FROM   seg GROUP BY bucket),
dom AS (
  SELECT bucket, sql_id, secs, rn FROM (
    SELECT bucket, sql_id, COUNT(*)*10 secs,
           ROW_NUMBER() OVER (PARTITION BY bucket ORDER BY COUNT(*) DESC) rn
    FROM   seg WHERE sql_id IS NOT NULL
    GROUP  BY bucket, sql_id)
  WHERE rn = 1),
dev AS (
  SELECT bucket, ev, rn FROM (
    SELECT bucket, DECODE(session_state,'ON CPU','CPU',event) ev,
           ROW_NUMBER() OVER (PARTITION BY bucket
                              ORDER BY COUNT(*) DESC) rn
    FROM   seg GROUP BY bucket, DECODE(session_state,'ON CPU','CPU',event))
  WHERE rn = 1)
SELECT a.bucket seg,
       a.bucket*5     from_min,
       a.bucket*5 + 5 to_min,
       a.db_secs, a.aas,
       RPAD('#',LEAST(GREATEST(ROUND(a.aas*8),1),40),'#') bar,
       d.sql_id dominant_sql,
       NVL(s.kind,'-') kind,
       e.ev dominant_event
FROM   agg a
LEFT   JOIN dom d ON d.bucket = a.bucket
LEFT   JOIN dev e ON e.bucket = a.bucket
LEFT   JOIN ora$ptt_sql s ON s.sql_id = d.sql_id
ORDER  BY a.bucket;
PROMPT ---- a long bar is a busy phase. AAS 1.0 = one session, single threaded ----

PROMPT
PROMPT ####################################################################
PROMPT #  13. TODAY'S RUN   SQL waterfall in execution order
PROMPT ####################################################################
PROMPT
WITH w AS (
  SELECT h.sql_id, h.phv,
         ROUND(MIN((CAST(h.sample_time AS DATE) - h.run_begin)*1440),1) start_min,
         ROUND(MAX((CAST(h.sample_time AS DATE) - h.run_begin)*1440),1) end_min,
         COUNT(*)*10 db_secs, MAX(h.run_sec) run_sec
  FROM   ora$ptt_ash h
  WHERE  h.prcsinstance = :v_pi AND h.sql_id IS NOT NULL
  GROUP  BY h.sql_id, h.phv)
SELECT w.sql_id, w.phv, NVL(s.kind,'-') kind,
       w.start_min, w.end_min, w.db_secs,
       ROUND(w.db_secs*100/GREATEST(w.run_sec,1),1) pct_of_run,
       LPAD(' ',GREATEST(ROUND(w.start_min*30/GREATEST(w.run_sec/60,1)),0),' ')||
       RPAD('=',GREATEST(ROUND((w.end_min-w.start_min)*30
             /GREATEST(w.run_sec/60,1)),1),'=') bar
FROM   w LEFT JOIN ora$ptt_sql s ON s.sql_id = w.sql_id
ORDER  BY w.start_min, w.db_secs DESC;

PROMPT
PROMPT ####################################################################
PROMPT #  14. WHICH PLAN LINE BURNS THE TIME   today vs the slow era
PROMPT ####################################################################
PROMPT
SELECT * FROM (
  SELECT h.era, h.sql_id, h.phv, h.plan_line line,
         p.operation, p.options, p.object_name,
         COUNT(*)*10 db_secs,
         ROUND(SUM(CASE WHEN h.session_state='ON CPU' THEN 1 ELSE 0 END)
               *100/COUNT(*),1) cpu_pct
  FROM   ora$ptt_ash h
  LEFT   JOIN (SELECT DISTINCT sql_id, plan_hash_value, id,
                      operation, options, object_name
               FROM   dba_hist_sql_plan
               WHERE  dbid = (SELECT dbid FROM v$database)) p
         ON  p.sql_id          = h.sql_id
         AND p.plan_hash_value = h.phv
         AND p.id              = h.plan_line
  WHERE  h.plan_line IS NOT NULL
  GROUP  BY h.era, h.sql_id, h.phv, h.plan_line,
            p.operation, p.options, p.object_name
  ORDER  BY 8 DESC)
WHERE  ROWNUM <= 50;
PROMPT ---- OPTIMIZER STATISTICS GATHERING as a row source = AUTO_SAMPLE_SIZE ----
PROMPT ---- LOAD TABLE CONVENTIONAL = row by row insert with full index maintenance ----

PROMPT
PROMPT ####################################################################
PROMPT #  15. HOT SEGMENTS PER ERA
PROMPT ####################################################################
PROMPT
SELECT * FROM (
  SELECT h.era, o.owner||'.'||o.object_name obj,
         SUBSTR(o.object_type,1,6) otype,
         COUNT(*)*10 db_secs,
         ROUND(COUNT(*)*100/SUM(COUNT(*)) OVER (PARTITION BY h.era),1) pct_of_era
  FROM   ora$ptt_ash h
  JOIN   dba_objects o ON o.object_id = h.current_obj#
  WHERE  h.current_obj# > 0
  GROUP  BY h.era, o.owner||'.'||o.object_name, SUBSTR(o.object_type,1,6)
  ORDER  BY h.era, 4 DESC)
WHERE  ROWNUM <= 45;

PROMPT
PROMPT ####################################################################
PROMPT #  16. WAIT PROFILE PER ERA AND PER RAC NODE
PROMPT ####################################################################
PROMPT
SELECT h.era, h.inst node, NVL(h.wait_class,'CPU') wclass,
       COUNT(*)*10 db_secs,
       ROUND(COUNT(*)*100/SUM(COUNT(*)) OVER (PARTITION BY h.era),1) pct_of_era,
       MAX(DECODE(h.session_state,'ON CPU','CPU',h.event)) sample_event
FROM   ora$ptt_ash h
GROUP  BY h.era, h.inst, NVL(h.wait_class,'CPU')
ORDER  BY h.era, 4 DESC;

PROMPT
PROMPT ---- top single event per era ----
PROMPT
SELECT * FROM (
  SELECT h.era, DECODE(h.session_state,'ON CPU','CPU',h.event) ev,
         COUNT(*)*10 db_secs,
         ROUND(COUNT(*)*100/SUM(COUNT(*)) OVER (PARTITION BY h.era),1) pct_of_era
  FROM   ora$ptt_ash h
  GROUP  BY h.era, DECODE(h.session_state,'ON CPU','CPU',h.event)
  ORDER  BY h.era, 3 DESC)
WHERE  ROWNUM <= 40;

PROMPT
PROMPT ####################################################################
PROMPT #  17. STATISTICS GATHERING DURING TODAY'S RUN
PROMPT #      DBA_OPTSTAT_OPERATIONS has no TARGET_TYPE column in 19c
PROMPT ####################################################################
PROMPT
SELECT * FROM (
  SELECT o.target, COUNT(*) gathers,
         TO_CHAR(MIN(o.start_time),'HH24:MI:SS') first_gather,
         TO_CHAR(MAX(o.end_time),'HH24:MI:SS')   last_gather,
         SUM(CASE WHEN o.status='COMPLETED' THEN 1 ELSE 0 END) completed
  FROM   dba_optstat_operations o, ora$ptt_runs r
  WHERE  r.prcsinstance = :v_pi
  AND    o.start_time >= CAST(r.b AS TIMESTAMP)
  AND    o.start_time <= CAST(r.e AS TIMESTAMP)
  AND    o.operation LIKE 'gather%'
  GROUP  BY o.target
  ORDER  BY 2 DESC)
WHERE  ROWNUM <= 30;
PROMPT ---- targets outside FS_CEBD tables = other App Engines with the same regression ----

PROMPT
PROMPT ####################################################################
PROMPT #  18. THE TWO TABLES THAT MATTER, AND THEIR INDEXES
PROMPT ####################################################################
PROMPT
SELECT t.table_name tbl, t.num_rows, t.sample_size,
       ROUND(t.sample_size/NULLIF(t.num_rows,0)*100,2) pct_sampled,
       t.last_analyzed,
       (SELECT ROUND(SUM(sg.bytes)/1024/1024)
        FROM   dba_segments sg
        WHERE  sg.owner = t.owner AND sg.segment_name = t.table_name
        AND    sg.segment_type LIKE 'TABLE%') table_mb
FROM   dba_tab_statistics t
WHERE  t.owner = 'SYSADM' AND t.object_type = 'TABLE'
AND    t.table_name IN ('PS_COMBO_DATA_TBL','PS_COMBO_DATA_BUDG')
ORDER  BY 1;

PROMPT
SELECT i.index_name, i.num_rows, i.sample_size,
       ROUND(i.sample_size/NULLIF(i.num_rows,0)*100,2) pct_sampled,
       i.clustering_factor cf,
       ROUND(i.clustering_factor/NULLIF(i.num_rows,0),3) cf_ratio,
       i.blevel, i.last_analyzed,
       (SELECT ROUND(SUM(sg.bytes)/1024/1024) FROM dba_segments sg
        WHERE  sg.owner='SYSADM' AND sg.segment_name = i.index_name
        AND    sg.segment_type='INDEX') index_mb
FROM   dba_ind_statistics i
WHERE  i.owner = 'SYSADM'
AND    i.table_name IN ('PS_COMBO_DATA_TBL','PS_COMBO_DATA_BUDG')
ORDER  BY 9 DESC NULLS LAST;
PROMPT ---- cf_ratio near 1.0 = worst case clustering. Index MB vs table MB drives ----
PROMPT ---- insert and delete cost, because every row maintains every index ----

PROMPT
PROMPT ---- how often is each index actually READ vs merely MAINTAINED ----
PROMPT
SELECT o.object_name,
       SUM(CASE WHEN ss.statistic_name='logical reads'    THEN ss.value END) lreads,
       SUM(CASE WHEN ss.statistic_name='physical reads'   THEN ss.value END) preads,
       SUM(CASE WHEN ss.statistic_name='db block changes' THEN ss.value END) blk_changes
FROM   dba_hist_seg_stat ss
JOIN   dba_hist_seg_stat_obj o
       ON o.dbid = ss.dbid AND o.obj# = ss.obj# AND o.dataobj# = ss.dataobj#
JOIN   ora$ptt_bnd bd ON ss.dbid = bd.dbid
WHERE  ss.snap_id BETWEEN bd.snap_lo AND bd.snap_hi
AND    o.owner = 'SYSADM'
AND    o.object_name IN ('PS_COMBO_DATA_TBL','PSACOMBO_DATA_TBL',
                         'PSBCOMBO_DATA_TBL','PS_COMBO_DATA_BUDG')
GROUP  BY o.object_name
ORDER  BY 4 DESC NULLS LAST;
PROMPT ---- high block changes with near zero logical reads = maintained but never used ----

PROMPT
PROMPT ---- clustering factor history, did the 1 pct sample move it ----
PROMPT
SELECT o.name index_name,
       TO_CHAR(h.savtime,'YYYY-MM-DD HH24:MI') saved,
       h.rowcnt num_rows, h.samplesize, h.clufac, h.blevel, h.leafcnt
FROM   sys.wri$_optstat_ind_history h
JOIN   sys.obj$ o ON o.obj# = h.obj#
WHERE  o.name IN ('PS_COMBO_DATA_TBL','PSACOMBO_DATA_TBL','PSBCOMBO_DATA_TBL')
AND    h.savtime > SYSTIMESTAMP - 45
ORDER  BY o.name, h.savtime;

PROMPT
PROMPT ####################################################################
PROMPT #  19. WHERE THE REMAINING TIME IS, AND THE LEVER FOR EACH
PROMPT ####################################################################
PROMPT
WITH cur AS (
  SELECT h.sql_id, NVL(s.kind,'NO-TEXT') kind, s.sig,
         COUNT(*)*10 db_secs,
         ROUND(SUM(CASE WHEN h.session_state='ON CPU' THEN 1 ELSE 0 END)
               *100/COUNT(*),1) cpu_pct,
         MAX(h.run_sec) run_sec
  FROM   ora$ptt_ash h
  LEFT   JOIN ora$ptt_sql s ON s.sql_id = h.sql_id
  WHERE  h.prcsinstance = :v_pi AND h.sql_id IS NOT NULL
  GROUP  BY h.sql_id, NVL(s.kind,'NO-TEXT'), s.sig)
SELECT * FROM (
  SELECT c.sql_id, c.kind, c.db_secs,
         ROUND(c.db_secs*100/GREATEST(SUM(c.db_secs) OVER (),1),1) pct_of_job,
         c.cpu_pct,
         CASE
           WHEN c.kind LIKE 'STATS%'
             THEN 'DBMS_STATS table pref. Already applied to COMBO_DATA_TBL'
           WHEN c.kind = 'BUILD-INSERT'
             THEN 'App Designer: direct path insert, or fewer indexes'
           WHEN c.kind = 'PURGE'
             THEN 'App Designer: ReUse Statement on, so a baseline can bind'
           WHEN c.kind = 'BUDG'
             THEN 'DB: candidate second DBMS_STATS pref on PS_COMBO_DATA_BUDG'
           WHEN c.kind = 'TAO-WORK'
             THEN 'Check temp table stats, dynamic sampling is usually right'
           WHEN c.cpu_pct > 80
             THEN 'CPU bound. Look at the plan line in section 14'
           ELSE 'IO bound. Buffer cache pressure or access path'
         END lever
  FROM   cur c
  ORDER  BY c.db_secs DESC)
WHERE  ROWNUM <= 25;

PROMPT
PROMPT ####################################################################
PROMPT #  20. VALIDATION AND DRIFT CHECK
PROMPT ####################################################################
PROMPT
SELECT 'table prefs on PS_COMBO_DATA_TBL (want 4)' info,
       TO_CHAR(COUNT(*)) val
FROM   dba_tab_stat_prefs
WHERE  owner='SYSADM' AND table_name='PS_COMBO_DATA_TBL'
UNION ALL
SELECT 'ESTIMATE_PERCENT numeric (want 1)',
       TO_CHAR(TO_NUMBER(DBMS_STATS.GET_PREFS('ESTIMATE_PERCENT',
               'SYSADM','PS_COMBO_DATA_TBL'))) FROM dual
UNION ALL
SELECT 'PREFERENCE_OVERRIDES_PARAMETER (want TRUE)',
       DBMS_STATS.GET_PREFS('PREFERENCE_OVERRIDES_PARAMETER',
               'SYSADM','PS_COMBO_DATA_TBL') FROM dual
UNION ALL
SELECT 'CASCADE (want TRUE)',
       DBMS_STATS.GET_PREFS('CASCADE','SYSADM','PS_COMBO_DATA_TBL') FROM dual
UNION ALL
SELECT 'METHOD_OPT',
       SUBSTR(DBMS_STATS.GET_PREFS('METHOD_OPT',
               'SYSADM','PS_COMBO_DATA_TBL'),1,60) FROM dual
UNION ALL
SELECT 'GLOBAL ESTIMATE_PERCENT (should be AUTO_SAMPLE_SIZE)',
       DBMS_STATS.GET_PREFS('ESTIMATE_PERCENT') FROM dual
UNION ALL
SELECT 'GLOBAL override (should be FALSE)',
       DBMS_STATS.GET_PREFS('PREFERENCE_OVERRIDES_PARAMETER') FROM dual
UNION ALL
SELECT 'other tables carrying prefs',
       TO_CHAR(COUNT(DISTINCT table_name))
FROM   dba_tab_stat_prefs
WHERE  owner='SYSADM' AND table_name <> 'PS_COMBO_DATA_TBL'
UNION ALL
SELECT 'locked stats on the two tables (want 0)',
       TO_CHAR(COUNT(*))
FROM   dba_tab_statistics
WHERE  owner='SYSADM' AND stattype_locked IS NOT NULL
AND    table_name IN ('PS_COMBO_DATA_TBL','PS_COMBO_DATA_BUDG')
UNION ALL
SELECT 'SQL patches on the instance',
       TO_CHAR(COUNT(*)) FROM dba_sql_patches
UNION ALL
SELECT 'SQL profiles',
       TO_CHAR(COUNT(*)) FROM dba_sql_profiles
UNION ALL
SELECT 'SQL plan baselines',
       TO_CHAR(COUNT(*)) FROM dba_sql_plan_baselines;

PROMPT
PROMPT ---- the four regressed SQL_IDs must be absent after the fix ----
PROMPT
SELECT h.era, h.sql_id, COUNT(*)*10 db_secs,
       TO_CHAR(MAX(h.sample_time),'MM-DD HH24:MI') last_seen
FROM   ora$ptt_ash h
WHERE  h.sql_id IN ('f4v8yvxn8pn1p','1ggxdkgha6w5b','6hh8xgvmyqrzs','bp3nhn5v4ms9t')
GROUP  BY h.era, h.sql_id
ORDER  BY 1,2;
PROMPT ---- no 3-POST-FIX rows = clean ----

PROMPT
PROMPT ---- PSDDLMODEL as delivered by 8.62, we never touched it ----
PROMPT
SELECT statement_type, platform, LENGTH(model_statement) len,
       SUBSTR(REPLACE(REPLACE(model_statement,CHR(10),' '),CHR(13),' '),1,140) txt
FROM   sysadm.psddlmodel
WHERE  statement_type = 4 AND platform = 2
ORDER  BY 1,2;
PROMPT ---- len 154 with AUTO_SAMPLE_SIZE = the 8.62 model. Our fix overrides it ----
PROMPT ---- via table preferences, so a future upgrade cannot revert the fix ----

PROMPT
PROMPT ####################################################################
PROMPT #  END OF REPORT
PROMPT ####################################################################
EXIT

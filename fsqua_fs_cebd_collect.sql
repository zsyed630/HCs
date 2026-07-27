-- =====================================================================
-- fsqua_fs_cebd_collect.sql
-- Target : FSQUA (Oracle 19c, PeopleSoft FSCM, SYSADM)
-- Purpose: Collect everything for the FS_CEBD regression AND quantify
--          the contamination introduced by the manually applied
--          PATCH_CEBD% patches / locked stats / NOPARALLEL DDL.
-- Mode   : Read-only with ONE exception: PART 5.1 calls
--          DBMS_WORKLOAD_REPOSITORY.CREATE_SNAPSHOT to flush the ASH ring
--          buffer to AWR before it wraps. No application data, no
--          statistics, no plans and no schema objects are modified.
-- Input  : NONE. No SQL_IDs, no SIDs, no dates typed by hand.
--          The script resolves the latest FS_CEBD run by itself.
-- Run as : a DBA-privileged account (needs DBA_* and GV$ views).
-- Note   : substitution char is set to ~ so that any literal ampersand
--          inside dumped PeopleSoft SQL text is NOT treated as a
--          SQL*Plus variable.
-- Note   : no WHENEVER SQLERROR EXIT -- a failure in one section does
--          not abort the spool.
-- =====================================================================

SET ECHO OFF
SET FEEDBACK ON
SET VERIFY OFF
SET HEADING ON
SET LINESIZE 320
SET PAGESIZE 5000
SET TRIMSPOOL ON
SET TRIMOUT ON
SET SQLBLANKLINES ON
SET LONG 2000000
SET LONGCHUNKSIZE 100000
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
SET DEFINE '~'

ALTER SESSION SET NLS_DATE_FORMAT = 'YYYY-MM-DD HH24:MI:SS';
ALTER SESSION SET NLS_TIMESTAMP_FORMAT = 'YYYY-MM-DD HH24:MI:SS';

SPOOL fsqua_fs_cebd_collect.log

PROMPT
PROMPT #####################################################################
PROMPT ## PART 0 - PREFLIGHT: WHAT AM I CONNECTED TO, WHAT EXISTS
PROMPT #####################################################################
PROMPT

COL banner_full FORMAT A90
SELECT banner_full FROM v$version;

COL db_name FORMAT A12
COL host_name FORMAT A30
COL instance_name FORMAT A16
SELECT i.inst_id, i.instance_name, i.host_name, i.status,
       i.startup_time, d.name db_name, d.dbid, d.open_mode, d.database_role
FROM   gv$instance i CROSS JOIN v$database d
ORDER  BY i.inst_id;

PROMPT
PROMPT -- 0.1 Parameters that change the interpretation of everything below
PROMPT --     (read-only check: we are NOT changing any of these)
COL name FORMAT A34
COL value FORMAT A46
SELECT name, value, isdefault, ismodified
FROM   v$parameter
WHERE  name IN ('control_management_pack_access','statistics_level',
                'cursor_sharing','optimizer_features_enable',
                'optimizer_adaptive_plans','optimizer_dynamic_sampling',
                'optimizer_capture_sql_plan_baselines',
                'parallel_degree_policy','parallel_max_servers',
                'parallel_force_local','_optimizer_use_auto_indexes',
                'db_file_multiblock_read_count','compatible')
ORDER  BY name;

PROMPT
PROMPT -- 0.2 AWR / stats-history retention (how much evidence still exists)
SELECT dbid, snap_interval, retention, topnsql FROM dba_hist_wr_control;
SELECT MIN(begin_interval_time) oldest_snap,
       MAX(end_interval_time)   newest_snap,
       COUNT(*)                 snap_count
FROM   dba_hist_snapshot;
SELECT DBMS_STATS.GET_STATS_HISTORY_RETENTION    AS stats_hist_days FROM dual;
SELECT DBMS_STATS.GET_STATS_HISTORY_AVAILABILITY AS stats_hist_oldest FROM dual;

PROMPT
PROMPT -- 0.3 Dictionary probe: confirm the PeopleSoft objects and their
PROMPT --     real column names in THIS PeopleTools release. Nothing below
PROMPT --     assumes a column that is not listed here.
COL table_name  FORMAT A24
COL column_name FORMAT A26
COL data_type   FORMAT A14
SELECT table_name, column_name, data_type, data_length, column_id
FROM   dba_tab_columns
WHERE  owner = 'SYSADM'
AND    table_name IN ('PSPRCSRQST','PSPRCSDEFN','PSTEMPTBLCNTL',
                      'PSAEAPPLTEMPTBL','PSAEAPPLDEFN','PSAESTMTDEFN',
                      'PSDDLMODEL','PSSTATUS','PS_BAT_TIMINGS_DTL',
                      'PS_BAT_TIMINGS_LOG','PS_MESSAGE_LOG')
ORDER  BY table_name, column_id;

PROMPT
PROMPT -- 0.4 Which of those objects actually exist here
SELECT object_name, object_type, status, created, last_ddl_time
FROM   dba_objects
WHERE  owner = 'SYSADM'
AND    object_name IN ('PSPRCSRQST','PSPRCSDEFN','PSTEMPTBLCNTL',
                       'PSAEAPPLTEMPTBL','PSAEAPPLDEFN','PSAESTMTDEFN',
                       'PSDDLMODEL','PSSTATUS','PS_BAT_TIMINGS_DTL',
                       'PS_BAT_TIMINGS_LOG','PS_MESSAGE_LOG')
ORDER  BY object_name;

PROMPT
PROMPT -- 0.5 Column lists for the views this script leans on, so that any
PROMPT --     ORA-00904 below is immediately explainable
SELECT table_name, column_name, data_type, data_length, column_id
FROM   dba_tab_columns
WHERE  owner = 'SYS'
AND    table_name IN ('DBA_SQL_PATCHES','DBA_SQL_PROFILES',
                      'DBA_SQL_PLAN_BASELINES','GV_$SQL_MONITOR',
                      'DBA_OPTSTAT_OPERATIONS')
ORDER  BY table_name, column_id;

PROMPT
PROMPT #####################################################################
PROMPT ## PART 1 - CONTAMINATION LEDGER
PROMPT ## Everything manually applied to FSQUA that FPRD does not have.
PROMPT ## Until this is quantified, the FSQUA runtime is NOT a valid
PROMPT ## reproduction of the FPRD regression.
PROMPT #####################################################################
PROMPT

PROMPT -- 1.1a Every SQL patch in the database
COL name        FORMAT A32
COL category    FORMAT A16
COL status      FORMAT A10
COL description FORMAT A40
SELECT name, category, status, created, last_modified, description
FROM   dba_sql_patches
ORDER  BY created;

PROMPT
PROMPT -- 1.1b The SQL_TEXT each patch was built from. A patch matches on the
PROMPT --      signature of the COMPLETE normalised statement. If the text
PROMPT --      below is a short fragment rather than a whole statement, the
PROMPT --      patch can never bind to anything.
COL patch_sql_text FORMAT A120
SELECT name,
       DBMS_LOB.GETLENGTH(sql_text) text_len,
       DBMS_LOB.SUBSTR(sql_text, 120, 1) patch_sql_text
FROM   dba_sql_patches
ORDER  BY created;

PROMPT
PROMPT -- 1.2 Every SQL profile
COL sql_text FORMAT A70
SELECT name, category, status, type, force_matching, created, last_modified
FROM   dba_sql_profiles
ORDER  BY created;

PROMPT
PROMPT -- 1.3 Every SQL plan baseline
COL sql_handle FORMAT A26
COL plan_name  FORMAT A34
SELECT sql_handle, plan_name, enabled, accepted, fixed, autopurge,
       origin, created, last_executed,
       DBMS_LOB.SUBSTR(sql_text, 70, 1) sql_head
FROM   dba_sql_plan_baselines
ORDER  BY created DESC
FETCH FIRST 100 ROWS ONLY;

PROMPT
PROMPT -- 1.4 THE DECISIVE TEST: are those patches actually attached to any
PROMPT --     cursor? V$SQL.SQL_PATCH is populated only when a patch really
PROMPT --     bound. A patch created from a truncated SQL_TEXT fragment will
PROMPT --     appear in 1.1 and never show up here.
COL patch_name   FORMAT A32
COL profile_name FORMAT A32
COL sql_head     FORMAT A80
SELECT s.inst_id,
       s.sql_id,
       s.child_number             child#,
       s.plan_hash_value          phv,
       s.sql_patch                patch_name,
       s.sql_profile              profile_name,
       s.sql_plan_baseline        baseline_name,
       s.executions,
       s.parse_calls,
       ROUND(s.elapsed_time / 1e6, 2) elapsed_s,
       s.force_matching_signature fms,
       DBMS_LOB.SUBSTR(s.sql_fulltext, 80, 1) sql_head
FROM   gv$sql s
WHERE  s.sql_patch IS NOT NULL
OR     s.sql_profile IS NOT NULL
OR     s.sql_plan_baseline IS NOT NULL
ORDER  BY s.elapsed_time DESC
FETCH FIRST 60 ROWS ONLY;

PROMPT
PROMPT -- 1.5 Patches that exist but are bound to ZERO cursors (= no-ops)
SELECT p.name, p.status, p.created,
       'CREATED BUT NOT BOUND TO ANY CURSOR' AS finding
FROM   dba_sql_patches p
WHERE  NOT EXISTS (SELECT 1 FROM gv$sql s WHERE s.sql_patch = p.name)
ORDER  BY p.created;

PROMPT
PROMPT -- 1.6 Locked / synthetic optimizer statistics on the FS_CEBD objects
COL owner FORMAT A10
SELECT ts.table_name,
       ts.partition_name,
       ts.object_type,
       ts.num_rows,
       ts.blocks,
       ts.avg_row_len,
       ts.sample_size,
       ts.last_analyzed,
       ts.stattype_locked,
       ts.stale_stats
FROM   dba_tab_statistics ts
WHERE  ts.owner = 'SYSADM'
AND    (   ts.table_name LIKE 'PS_FS_CEBD%'
        OR ts.table_name LIKE 'PS_COMBO_DATA%'
        OR ts.table_name LIKE 'PS%COMBO%')
ORDER  BY ts.table_name, NVL(ts.partition_name, ' ');

PROMPT
PROMPT -- 1.7 Any locked stats anywhere in SYSADM (widen the net)
SELECT table_name, partition_name, stattype_locked, num_rows, last_analyzed
FROM   dba_tab_statistics
WHERE  owner = 'SYSADM'
AND    stattype_locked IS NOT NULL
ORDER  BY table_name
FETCH FIRST 200 ROWS ONLY;

PROMPT
PROMPT -- 1.8 Reported NUM_ROWS vs physical reality (detects fabricated stats)
PROMPT --     Exact COUNT is taken only for segments under 2 GB; larger
PROMPT --     objects report segment size only so this stays cheap.
DECLARE
  v_cnt     NUMBER;
  v_bytes   NUMBER;
  v_blocks  NUMBER;
  v_limit   CONSTANT NUMBER := 2 * 1024 * 1024 * 1024;
BEGIN
  DBMS_OUTPUT.PUT_LINE(RPAD('TABLE_NAME', 26) || RPAD('STAT_NUM_ROWS', 16)
    || RPAD('REAL_ROWS', 16) || RPAD('SEG_MB', 12) || RPAD('SEG_BLOCKS', 14)
    || RPAD('LOCKED', 10) || 'VERDICT');
  DBMS_OUTPUT.PUT_LINE(RPAD('-', 120, '-'));
  FOR t IN (SELECT ts.table_name, ts.num_rows, ts.blocks, ts.stattype_locked
            FROM   dba_tab_statistics ts
            WHERE  ts.owner = 'SYSADM'
            AND    ts.object_type = 'TABLE'
            AND    (   ts.table_name LIKE 'PS_FS_CEBD%'
                    OR ts.table_name LIKE 'PS_COMBO_DATA%')
            ORDER  BY ts.table_name)
  LOOP
    v_bytes  := NULL;
    v_blocks := NULL;
    v_cnt    := NULL;
    BEGIN
      SELECT SUM(bytes), SUM(blocks)
      INTO   v_bytes, v_blocks
      FROM   dba_segments
      WHERE  owner = 'SYSADM' AND segment_name = t.table_name;
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;

    IF NVL(v_bytes, 0) <= v_limit THEN
      BEGIN
        EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM SYSADM.' || DBMS_ASSERT.SIMPLE_SQL_NAME(t.table_name)
          INTO v_cnt;
      EXCEPTION WHEN OTHERS THEN
        v_cnt := NULL;
      END;
    END IF;

    DBMS_OUTPUT.PUT_LINE(
        RPAD(t.table_name, 26)
     || RPAD(NVL(TO_CHAR(t.num_rows), 'NULL'), 16)
     || RPAD(NVL(TO_CHAR(v_cnt), 'skipped'), 16)
     || RPAD(NVL(TO_CHAR(ROUND(v_bytes / 1048576, 1)), 'n/a'), 12)
     || RPAD(NVL(TO_CHAR(v_blocks), 'n/a'), 14)
     || RPAD(NVL(t.stattype_locked, 'NO'), 10)
     || CASE
          WHEN t.stattype_locked IS NOT NULL AND t.num_rows = 1000000
            THEN 'FABRICATED AND LOCKED'
          WHEN t.stattype_locked IS NOT NULL
            THEN 'LOCKED'
          WHEN v_cnt IS NOT NULL AND t.num_rows IS NOT NULL
               AND v_cnt > 0
               AND (t.num_rows / GREATEST(v_cnt, 1) > 10
                    OR v_cnt / GREATEST(t.num_rows, 1) > 10)
            THEN 'STATS OFF BY MORE THAN 10x'
          WHEN t.num_rows IS NULL
            THEN 'NO STATS - DYNAMIC SAMPLING LIKELY'
          ELSE 'ok'
        END);
  END LOOP;
END;
/

PROMPT
PROMPT -- 1.9 Parallel degree on the master combo objects (NOPARALLEL damage)
COL degree FORMAT A12
SELECT 'TABLE' obj_class, table_name obj_name, NULL parent_table,
       degree, instances, cache, logging, partitioned, last_analyzed
FROM   dba_tables
WHERE  owner = 'SYSADM'
AND    (table_name LIKE 'PS_COMBO_DATA%' OR table_name LIKE 'PS_FS_CEBD%')
UNION ALL
SELECT 'INDEX', index_name, table_name,
       degree, instances, NULL, logging, partitioned, last_analyzed
FROM   dba_indexes
WHERE  owner = 'SYSADM'
AND    (table_name LIKE 'PS_COMBO_DATA%' OR table_name LIKE 'PS_FS_CEBD%')
ORDER  BY 1, 3, 2;

PROMPT
PROMPT -- 1.10 Stats history: what timestamps are available to restore to
SELECT owner, table_name, partition_name, stats_update_time
FROM   dba_tab_stats_history
WHERE  owner = 'SYSADM'
AND    (table_name LIKE 'PS_FS_CEBD%' OR table_name LIKE 'PS_COMBO_DATA%')
ORDER  BY stats_update_time DESC, table_name
FETCH FIRST 300 ROWS ONLY;

PROMPT
PROMPT -- 1.11 Optimizer stats operations recorded on this database
COL operation FORMAT A34
COL target    FORMAT A44
SELECT operation, target, start_time, end_time,
       ROUND(  EXTRACT(DAY    FROM (end_time - start_time)) * 86400
             + EXTRACT(HOUR   FROM (end_time - start_time)) * 3600
             + EXTRACT(MINUTE FROM (end_time - start_time)) * 60
             + EXTRACT(SECOND FROM (end_time - start_time)), 1) secs,
       status
FROM   dba_optstat_operations
WHERE  start_time > SYSTIMESTAMP - INTERVAL '3' DAY
ORDER  BY start_time DESC
FETCH FIRST 200 ROWS ONLY;

PROMPT
PROMPT #####################################################################
PROMPT ## PART 2 - THE RUN ITSELF (auto-resolved, no manual input)
PROMPT #####################################################################
PROMPT

PROMPT -- 2.0 Resolve the most recent FS_CEBD run and its session.
PROMPT --     Seeded first from DUAL so the variables always exist and
PROMPT --     SQL*Plus can never stop to prompt.

COLUMN c_pi    NEW_VALUE g_pi    NOPRINT
COLUMN c_oprid NEW_VALUE g_oprid NOPRINT
COLUMN c_beg   NEW_VALUE g_beg   NOPRINT
COLUMN c_end   NEW_VALUE g_end   NOPRINT
COLUMN c_inst  NEW_VALUE g_inst  NOPRINT
COLUMN c_sid   NEW_VALUE g_sid   NOPRINT
COLUMN c_ser   NEW_VALUE g_ser   NOPRINT

SELECT -1 AS c_pi,
       'NONE' AS c_oprid,
       TO_CHAR(SYSDATE - 1, 'YYYY-MM-DD HH24:MI:SS') AS c_beg,
       TO_CHAR(SYSDATE,     'YYYY-MM-DD HH24:MI:SS') AS c_end,
       -1 AS c_inst,
       -1 AS c_sid,
       -1 AS c_ser
FROM   dual;

SELECT PRCSINSTANCE AS c_pi,
       OPRID        AS c_oprid,
       TO_CHAR(BEGINDTTM, 'YYYY-MM-DD HH24:MI:SS') AS c_beg,
       TO_CHAR(NVL(ENDDTTM, SYSDATE), 'YYYY-MM-DD HH24:MI:SS') AS c_end
FROM   (SELECT PRCSINSTANCE, OPRID, BEGINDTTM, ENDDTTM
        FROM   SYSADM.PSPRCSRQST
        WHERE  PRCSNAME = 'FS_CEBD'
        AND    BEGINDTTM IS NOT NULL
        ORDER  BY BEGINDTTM DESC)
WHERE  ROWNUM = 1;

PROMPT
PROMPT -- 2.1 The resolved run
COL prcsname  FORMAT A12
COL oprid     FORMAT A12
COL runcntlid FORMAT A34
COL runstatus FORMAT A10
SELECT PRCSINSTANCE, PRCSNAME, OPRID, RUNCNTLID, RUNSTATUS,
       SERVERNAMERUN, BEGINDTTM, ENDDTTM,
       ROUND((NVL(ENDDTTM, SYSDATE) - BEGINDTTM) * 1440, 1) mins
FROM   SYSADM.PSPRCSRQST
WHERE  PRCSINSTANCE = ~g_pi;

PROMPT
PROMPT -- 2.2 Full FS_CEBD run history (pre and post upgrade shape)
SELECT PRCSINSTANCE, OPRID, RUNSTATUS, BEGINDTTM, ENDDTTM,
       ROUND((CAST(ENDDTTM AS DATE) - CAST(BEGINDTTM AS DATE)) * 1440, 1) mins
FROM   SYSADM.PSPRCSRQST
WHERE  PRCSNAME = 'FS_CEBD'
AND    BEGINDTTM > SYSDATE - 180
ORDER  BY BEGINDTTM;

PROMPT
PROMPT -- 2.3 Resolve the live database session for this run.
PROMPT --     Tier 1 = CLIENT_IDENTIFIER carries the OPRID (the reliable
PROMPT --     correlation on this system, since AE does not set
PROMPT --     MODULE/ACTION). Tier 2 = PSAE program name within the window.
COL client_identifier FORMAT A22
COL client_info       FORMAT A34
COL program           FORMAT A26
COL event             FORMAT A34
COL state             FORMAT A10
SELECT s.inst_id, s.sid, s.serial#, p.spid os_pid, s.process client_pid,
       s.client_identifier, s.client_info, s.module, s.action, s.program,
       s.sql_id, s.sql_child_number, s.sql_exec_id, s.sql_exec_start,
       s.status, s.state, s.event, s.seconds_in_wait,
       s.blocking_instance, s.blocking_session, s.last_call_et, s.logon_time
FROM   gv$session s
LEFT   JOIN gv$process p
       ON p.inst_id = s.inst_id AND p.addr = s.paddr
WHERE  s.username = 'SYSADM'
AND    (   UPPER(s.client_identifier) LIKE '%' || UPPER('~g_oprid') || '%'
        OR UPPER(s.client_info)       LIKE '%' || UPPER('~g_oprid') || '%'
        OR UPPER(s.module)            LIKE '%FS_CEBD%'
        OR UPPER(s.action)            LIKE '%CEBD%'
        OR (    UPPER(s.program) LIKE '%PSAE%'
            AND s.logon_time >= TO_DATE('~g_beg', 'YYYY-MM-DD HH24:MI:SS') - 10 / 1440))
ORDER  BY s.logon_time;

SELECT inst_id AS c_inst, sid AS c_sid, serial# AS c_ser
FROM   (SELECT s.inst_id, s.sid, s.serial#
        FROM   gv$session s
        WHERE  s.username = 'SYSADM'
        AND    (   UPPER(s.client_identifier) LIKE '%' || UPPER('~g_oprid') || '%'
                OR UPPER(s.client_info)       LIKE '%' || UPPER('~g_oprid') || '%'
                OR (    UPPER(s.program) LIKE '%PSAE%'
                    AND s.logon_time >= TO_DATE('~g_beg', 'YYYY-MM-DD HH24:MI:SS') - 10 / 1440))
        ORDER  BY s.last_call_et DESC)
WHERE  ROWNUM = 1;

PROMPT
PROMPT -- 2.4 Temp-table instance allocation. If the run fell back to the
PROMPT --     shared base table instead of a dedicated instance, that alone
PROMPT --     serialises the job and no SQL patch will ever fix it.
SELECT * FROM SYSADM.PSAEAPPLTEMPTBL WHERE AE_APPLID = 'FS_CEBD' ORDER BY RECNAME;

SELECT * FROM SYSADM.PSTEMPTBLCNTL
WHERE  RECNAME LIKE 'FS_CEBD%' OR RECNAME LIKE 'COMBO%'
ORDER  BY RECNAME;

PROMPT
PROMPT -- 2.5 Where the elapsed time went, in 10 minute buckets.
PROMPT --     SESSION_STATE is used to identify CPU rather than a NULL
PROMPT --     wait_class, because WAIT_CLASS can carry the previous wait
PROMPT --     while the session is on CPU.
COL bucket     FORMAT A18
COL wait_class FORMAT A16
WITH ash AS (
  SELECT h.*
  FROM   gv$active_session_history h
  WHERE  h.sample_time >= TO_TIMESTAMP('~g_beg', 'YYYY-MM-DD HH24:MI:SS')
  AND    h.sample_time <= TO_TIMESTAMP('~g_end', 'YYYY-MM-DD HH24:MI:SS') + INTERVAL '2' MINUTE
  AND    (   h.session_id = ~g_sid
          OR UPPER(h.client_id) LIKE '%' || UPPER('~g_oprid') || '%'
          OR UPPER(h.program)   LIKE '%PSAE%')
)
SELECT TO_CHAR(TRUNC(CAST(sample_time AS DATE), 'HH24')
         + FLOOR(TO_NUMBER(TO_CHAR(CAST(sample_time AS DATE), 'MI')) / 10) * 10 / 1440,
         'YYYY-MM-DD HH24:MI') bucket,
       CASE WHEN session_state = 'ON CPU' THEN 'CPU' ELSE NVL(wait_class, 'UNKNOWN') END wait_class,
       COUNT(*) db_secs,
       SUM(CASE WHEN in_hard_parse    = 'Y' THEN 1 ELSE 0 END) hard_parse_s,
       SUM(CASE WHEN in_parse         = 'Y' THEN 1 ELSE 0 END) parse_s,
       SUM(CASE WHEN in_sql_execution = 'Y' THEN 1 ELSE 0 END) exec_s,
       COUNT(DISTINCT sql_id) sql_ids,
       COUNT(DISTINCT force_matching_signature) sigs
FROM   ash
GROUP  BY TRUNC(CAST(sample_time AS DATE), 'HH24')
         + FLOOR(TO_NUMBER(TO_CHAR(CAST(sample_time AS DATE), 'MI')) / 10) * 10 / 1440,
         CASE WHEN session_state = 'ON CPU' THEN 'CPU' ELSE NVL(wait_class, 'UNKNOWN') END
ORDER  BY 1, 3 DESC;

PROMPT
PROMPT -- 2.6 Same window, rolled up: total DB time by wait class and event
COL event FORMAT A44
WITH ash AS (
  SELECT h.*
  FROM   gv$active_session_history h
  WHERE  h.sample_time >= TO_TIMESTAMP('~g_beg', 'YYYY-MM-DD HH24:MI:SS')
  AND    h.sample_time <= TO_TIMESTAMP('~g_end', 'YYYY-MM-DD HH24:MI:SS') + INTERVAL '2' MINUTE
  AND    (   h.session_id = ~g_sid
          OR UPPER(h.client_id) LIKE '%' || UPPER('~g_oprid') || '%'
          OR UPPER(h.program)   LIKE '%PSAE%')
)
SELECT CASE WHEN session_state = 'ON CPU' THEN 'CPU' ELSE NVL(wait_class, 'UNKNOWN') END wait_class,
       CASE WHEN session_state = 'ON CPU' THEN 'ON CPU' ELSE NVL(event, 'UNKNOWN') END event,
       COUNT(*) db_secs,
       ROUND(RATIO_TO_REPORT(COUNT(*)) OVER () * 100, 1) pct
FROM   ash
GROUP  BY CASE WHEN session_state = 'ON CPU' THEN 'CPU' ELSE NVL(wait_class, 'UNKNOWN') END,
         CASE WHEN session_state = 'ON CPU' THEN 'ON CPU' ELSE NVL(event, 'UNKNOWN') END
ORDER  BY 3 DESC
FETCH FIRST 30 ROWS ONLY;

PROMPT
PROMPT -- 2.7 Parse versus execute. This is the literal-SQL hypothesis test.
WITH ash AS (
  SELECT h.*
  FROM   gv$active_session_history h
  WHERE  h.sample_time >= TO_TIMESTAMP('~g_beg', 'YYYY-MM-DD HH24:MI:SS')
  AND    h.sample_time <= TO_TIMESTAMP('~g_end', 'YYYY-MM-DD HH24:MI:SS') + INTERVAL '2' MINUTE
  AND    (   h.session_id = ~g_sid
          OR UPPER(h.client_id) LIKE '%' || UPPER('~g_oprid') || '%'
          OR UPPER(h.program)   LIKE '%PSAE%')
)
SELECT COUNT(*) total_db_secs,
       SUM(CASE WHEN in_hard_parse      = 'Y' THEN 1 ELSE 0 END) hard_parse_secs,
       SUM(CASE WHEN in_parse           = 'Y' THEN 1 ELSE 0 END) parse_secs,
       SUM(CASE WHEN in_sql_execution   = 'Y' THEN 1 ELSE 0 END) exec_secs,
       SUM(CASE WHEN in_plsql_execution = 'Y' THEN 1 ELSE 0 END) plsql_secs,
       COUNT(DISTINCT sql_id) distinct_sql_ids,
       COUNT(DISTINCT force_matching_signature) distinct_signatures,
       ROUND(COUNT(DISTINCT sql_id)
             / GREATEST(COUNT(DISTINCT force_matching_signature), 1), 1) literal_churn_ratio
FROM   ash;

PROMPT
PROMPT -- 2.8 Top SQL for this run, collapsed by FORCE_MATCHING_SIGNATURE.
PROMPT --     Signature is the only stable key for literal SQL, and it is
PROMPT --     also the key a force-matching SQL profile binds on.
COL sql_head FORMAT A86
WITH ash AS (
  SELECT h.*
  FROM   gv$active_session_history h
  WHERE  h.sample_time >= TO_TIMESTAMP('~g_beg', 'YYYY-MM-DD HH24:MI:SS')
  AND    h.sample_time <= TO_TIMESTAMP('~g_end', 'YYYY-MM-DD HH24:MI:SS') + INTERVAL '2' MINUTE
  AND    (   h.session_id = ~g_sid
          OR UPPER(h.client_id) LIKE '%' || UPPER('~g_oprid') || '%'
          OR UPPER(h.program)   LIKE '%PSAE%')
), agg AS (
  SELECT force_matching_signature fms,
         COUNT(*) db_secs,
         COUNT(DISTINCT sql_id) variants,
         COUNT(DISTINCT sql_plan_hash_value) plans,
         SUM(CASE WHEN in_hard_parse = 'Y' THEN 1 ELSE 0 END) hard_parse_s,
         MAX(sql_id) KEEP (DENSE_RANK FIRST ORDER BY sample_time DESC) sample_sql_id
  FROM   ash
  WHERE  sql_id IS NOT NULL
  GROUP  BY force_matching_signature
)
SELECT a.fms, a.db_secs, a.variants, a.plans, a.hard_parse_s, a.sample_sql_id,
       (SELECT DBMS_LOB.SUBSTR(q.sql_fulltext, 86, 1)
        FROM   gv$sql q
        WHERE  q.sql_id = a.sample_sql_id AND ROWNUM = 1) sql_head
FROM   agg a
ORDER  BY a.db_secs DESC
FETCH FIRST 25 ROWS ONLY;

PROMPT
PROMPT -- 2.9 Which plan line is burning the time (points at the operation,
PROMPT --     not just the statement)
COL sql_plan_operation FORMAT A26
COL sql_plan_options   FORMAT A22
WITH ash AS (
  SELECT h.*
  FROM   gv$active_session_history h
  WHERE  h.sample_time >= TO_TIMESTAMP('~g_beg', 'YYYY-MM-DD HH24:MI:SS')
  AND    h.sample_time <= TO_TIMESTAMP('~g_end', 'YYYY-MM-DD HH24:MI:SS') + INTERVAL '2' MINUTE
  AND    (   h.session_id = ~g_sid
          OR UPPER(h.client_id) LIKE '%' || UPPER('~g_oprid') || '%'
          OR UPPER(h.program)   LIKE '%PSAE%')
)
SELECT sql_plan_operation, sql_plan_options, sql_plan_line_id,
       COUNT(*) db_secs,
       COUNT(DISTINCT force_matching_signature) sigs
FROM   ash
WHERE  sql_plan_operation IS NOT NULL
GROUP  BY sql_plan_operation, sql_plan_options, sql_plan_line_id
ORDER  BY 4 DESC
FETCH FIRST 25 ROWS ONLY;

PROMPT
PROMPT -- 2.10 Which segments the time was spent on
COL obj_owner FORMAT A12
COL obj_name  FORMAT A32
COL obj_type  FORMAT A18
WITH ash AS (
  SELECT h.*
  FROM   gv$active_session_history h
  WHERE  h.sample_time >= TO_TIMESTAMP('~g_beg', 'YYYY-MM-DD HH24:MI:SS')
  AND    h.sample_time <= TO_TIMESTAMP('~g_end', 'YYYY-MM-DD HH24:MI:SS') + INTERVAL '2' MINUTE
  AND    (   h.session_id = ~g_sid
          OR UPPER(h.client_id) LIKE '%' || UPPER('~g_oprid') || '%'
          OR UPPER(h.program)   LIKE '%PSAE%')
)
SELECT o.owner obj_owner, o.object_name obj_name, o.object_type obj_type,
       COUNT(*) db_secs,
       CASE WHEN a.session_state = 'ON CPU' THEN 'CPU' ELSE NVL(a.wait_class, 'UNKNOWN') END wait_class
FROM   ash a
JOIN   dba_objects o ON o.object_id = a.current_obj#
WHERE  a.current_obj# > 0
GROUP  BY o.owner, o.object_name, o.object_type,
         CASE WHEN a.session_state = 'ON CPU' THEN 'CPU' ELSE NVL(a.wait_class, 'UNKNOWN') END
ORDER  BY 4 DESC
FETCH FIRST 25 ROWS ONLY;

PROMPT
PROMPT -- 2.11 Real-time SQL Monitor entries owned by this session
SELECT sql_id, sql_exec_id, sql_plan_hash_value, status, sql_exec_start,
       ROUND(elapsed_time / 1e6, 1)       elapsed_s,
       ROUND(cpu_time / 1e6, 1)           cpu_s,
       ROUND(user_io_wait_time / 1e6, 1)  io_s,
       ROUND(application_wait_time / 1e6, 1) app_s,
       ROUND(concurrency_wait_time / 1e6, 1) conc_s,
       buffer_gets, disk_reads,
       px_servers_requested, px_servers_allocated
FROM   gv$sql_monitor
WHERE  (sid = ~g_sid AND inst_id = ~g_inst)
OR     sql_exec_start >= TO_DATE('~g_beg', 'YYYY-MM-DD HH24:MI:SS')
ORDER  BY elapsed_time DESC
FETCH FIRST 25 ROWS ONLY;

PROMPT
PROMPT -- 2.12 Long operations still in flight
COL opname  FORMAT A34
COL target  FORMAT A34
COL message FORMAT A70
SELECT inst_id, sid, serial#, opname, target, sofar, totalwork,
       ROUND(sofar / NULLIF(totalwork, 0) * 100, 1) pct_done,
       elapsed_seconds, time_remaining, message
FROM   gv$session_longops
WHERE  totalwork > 0 AND sofar < totalwork
ORDER  BY elapsed_seconds DESC;

PROMPT
PROMPT -- 2.13 Blockers, if anything is serialising
SELECT s.inst_id, s.sid, s.serial#, s.username, s.event, s.seconds_in_wait,
       s.blocking_instance, s.blocking_session, s.final_blocking_session,
       s.row_wait_obj#
FROM   gv$session s
WHERE  s.blocking_session IS NOT NULL
ORDER  BY s.seconds_in_wait DESC;

PROMPT
PROMPT #####################################################################
PROMPT ## PART 3 - AUTOMATIC PLAN AND SQL MONITOR CAPTURE
PROMPT ## Top statements are chosen by the script. Nothing is typed.
PROMPT #####################################################################
PROMPT

PROMPT -- 3.1 Execution plans with runtime rowsource stats for the top 5
PROMPT --     signatures. Look for E-Rows versus A-Rows divergence and for
PROMPT --     any SQL patch or profile named in the Note section.
DECLARE
  v_n PLS_INTEGER := 0;
BEGIN
  FOR s IN (
    SELECT sql_id, child_no, db_secs
    FROM (
      SELECT x.sql_id, x.child_no, x.db_secs, x.rn_in_sig,
             DENSE_RANK() OVER (ORDER BY x.sig_secs DESC) sig_rank
      FROM (
        SELECT a.sql_id,
               MIN(NVL(a.sql_child_number, 0)) child_no,
               COUNT(*) db_secs,
               SUM(COUNT(*)) OVER (PARTITION BY a.force_matching_signature) sig_secs,
               ROW_NUMBER() OVER (PARTITION BY a.force_matching_signature
                                  ORDER BY COUNT(*) DESC) rn_in_sig
        FROM   gv$active_session_history a
        WHERE  a.sample_time >= TO_TIMESTAMP('~g_beg', 'YYYY-MM-DD HH24:MI:SS')
        AND    a.sql_id IS NOT NULL
        AND    (   a.session_id = ~g_sid
                OR UPPER(a.client_id) LIKE '%' || UPPER('~g_oprid') || '%'
                OR UPPER(a.program)   LIKE '%PSAE%')
        GROUP  BY a.sql_id, a.force_matching_signature
      ) x
    )
    WHERE rn_in_sig = 1 AND sig_rank <= 5
    ORDER BY db_secs DESC)
  LOOP
    v_n := v_n + 1;
    DBMS_OUTPUT.PUT_LINE(' ');
    DBMS_OUTPUT.PUT_LINE(RPAD('=', 110, '='));
    DBMS_OUTPUT.PUT_LINE('PLAN ' || v_n || ' : sql_id ' || s.sql_id
      || '  child ' || s.child_no || '  ash_db_secs ' || s.db_secs);
    DBMS_OUTPUT.PUT_LINE(RPAD('=', 110, '='));
    BEGIN
      FOR p IN (SELECT plan_table_output pto
                FROM   TABLE(DBMS_XPLAN.DISPLAY_CURSOR(s.sql_id, s.child_no,
                             'ALLSTATS LAST +OUTLINE +PREDICATE +NOTE +ADAPTIVE')))
      LOOP
        DBMS_OUTPUT.PUT_LINE(p.pto);
      END LOOP;
    EXCEPTION WHEN OTHERS THEN
      DBMS_OUTPUT.PUT_LINE('  cursor no longer in shared pool: ' || SQLERRM);
      BEGIN
        FOR p IN (SELECT plan_table_output pto
                  FROM   TABLE(DBMS_XPLAN.DISPLAY_AWR(s.sql_id, NULL, NULL, 'ADVANCED')))
        LOOP
          DBMS_OUTPUT.PUT_LINE(p.pto);
        END LOOP;
      EXCEPTION WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('  not in AWR either: ' || SQLERRM);
      END;
    END;
  END LOOP;
  IF v_n = 0 THEN
    DBMS_OUTPUT.PUT_LINE('No ASH rows matched the resolved run. Check PART 2.3 output.');
  END IF;
END;
/

PROMPT
PROMPT -- 3.2 Full SQL text of the top statements (literals intact, so the
PROMPT --     exact predicate values used by the AE are visible)
DECLARE
  v_clob CLOB;
  v_len  PLS_INTEGER;
  v_off  PLS_INTEGER;
BEGIN
  FOR s IN (
    SELECT sql_id, db_secs FROM (
      SELECT a.sql_id, COUNT(*) db_secs,
             ROW_NUMBER() OVER (PARTITION BY a.force_matching_signature
                                ORDER BY COUNT(*) DESC) rn
      FROM   gv$active_session_history a
      WHERE  a.sample_time >= TO_TIMESTAMP('~g_beg', 'YYYY-MM-DD HH24:MI:SS')
      AND    a.sql_id IS NOT NULL
      AND    (   a.session_id = ~g_sid
              OR UPPER(a.client_id) LIKE '%' || UPPER('~g_oprid') || '%'
              OR UPPER(a.program)   LIKE '%PSAE%')
      GROUP  BY a.sql_id, a.force_matching_signature)
    WHERE rn = 1
    ORDER BY db_secs DESC
    FETCH FIRST 8 ROWS ONLY)
  LOOP
    v_clob := NULL;
    BEGIN
      SELECT sql_fulltext INTO v_clob
      FROM   gv$sql
      WHERE  sql_id = s.sql_id AND ROWNUM = 1;
    EXCEPTION WHEN OTHERS THEN
      BEGIN
        SELECT sql_text INTO v_clob
        FROM   dba_hist_sqltext
        WHERE  sql_id = s.sql_id AND ROWNUM = 1;
      EXCEPTION WHEN OTHERS THEN
        v_clob := NULL;
      END;
    END;
    DBMS_OUTPUT.PUT_LINE(' ');
    DBMS_OUTPUT.PUT_LINE(RPAD('-', 110, '-'));
    DBMS_OUTPUT.PUT_LINE('SQL_ID ' || s.sql_id || '   ash_db_secs ' || s.db_secs);
    DBMS_OUTPUT.PUT_LINE(RPAD('-', 110, '-'));
    IF v_clob IS NULL THEN
      DBMS_OUTPUT.PUT_LINE('  text not available');
    ELSE
      v_len := DBMS_LOB.GETLENGTH(v_clob);
      v_off := 1;
      WHILE v_off <= v_len LOOP
        DBMS_OUTPUT.PUT_LINE(DBMS_LOB.SUBSTR(v_clob, 900, v_off));
        v_off := v_off + 900;
      END LOOP;
    END IF;
  END LOOP;
END;
/

PROMPT
PROMPT -- 3.3 SQL Monitor text report for the single longest execution of
PROMPT --     this run. A-Rows versus E-Rows here settles the cardinality
PROMPT --     question outright.
DECLARE
  v_rep  CLOB;
  v_len  PLS_INTEGER;
  v_off  PLS_INTEGER;
  v_done PLS_INTEGER := 0;
BEGIN
  FOR m IN (SELECT sql_id, sql_exec_id, sql_exec_start, inst_id,
                   ROUND(elapsed_time / 1e6, 1) elapsed_s
            FROM   gv$sql_monitor
            WHERE  sql_exec_start >= TO_DATE('~g_beg', 'YYYY-MM-DD HH24:MI:SS') - 5 / 1440
            AND    sql_id IS NOT NULL
            ORDER  BY elapsed_time DESC
            FETCH FIRST 3 ROWS ONLY)
  LOOP
    v_done := v_done + 1;
    DBMS_OUTPUT.PUT_LINE(' ');
    DBMS_OUTPUT.PUT_LINE(RPAD('=', 110, '='));
    DBMS_OUTPUT.PUT_LINE('SQL MONITOR ' || v_done || ' : ' || m.sql_id
      || '  exec_id ' || m.sql_exec_id || '  elapsed_s ' || m.elapsed_s);
    DBMS_OUTPUT.PUT_LINE(RPAD('=', 110, '='));
    BEGIN
      v_rep := DBMS_SQL_MONITOR.REPORT_SQL_MONITOR(
                 sql_id         => m.sql_id,
                 sql_exec_id    => m.sql_exec_id,
                 sql_exec_start => m.sql_exec_start,
                 inst_id        => m.inst_id,
                 report_level   => 'ALL',
                 type           => 'TEXT');
      v_len := DBMS_LOB.GETLENGTH(v_rep);
      v_off := 1;
      WHILE v_off <= v_len LOOP
        DBMS_OUTPUT.PUT_LINE(RTRIM(DBMS_LOB.SUBSTR(v_rep, 900, v_off), CHR(10)));
        v_off := v_off + 900;
      END LOOP;
    EXCEPTION WHEN OTHERS THEN
      DBMS_OUTPUT.PUT_LINE('  report failed: ' || SQLERRM);
    END;
  END LOOP;
  IF v_done = 0 THEN
    DBMS_OUTPUT.PUT_LINE('No SQL Monitor entries in the window.');
  END IF;
END;
/

PROMPT
PROMPT #####################################################################
PROMPT ## PART 4 - AUTOMATED VERDICT
PROMPT #####################################################################
PROMPT

DECLARE
  v_total       NUMBER := 0;
  v_hard        NUMBER := 0;
  v_ids         NUMBER := 0;
  v_sigs        NUMBER := 0;
  v_locked      NUMBER := 0;
  v_fake        NUMBER := 0;
  v_noparallel  NUMBER := 0;
  v_patches     NUMBER := 0;
  v_bound       NUMBER := 0;
  v_profiles    NUMBER := 0;
  v_conc        NUMBER := 0;
  v_io          NUMBER := 0;
  v_cpu         NUMBER := 0;
  v_findings    PLS_INTEGER := 0;

  PROCEDURE say(p_tag IN VARCHAR2, p_msg IN VARCHAR2) IS
  BEGIN
    v_findings := v_findings + 1;
    DBMS_OUTPUT.PUT_LINE(RPAD(p_tag, 14) || p_msg);
  END say;
BEGIN
  SELECT COUNT(*),
         SUM(CASE WHEN in_hard_parse = 'Y' THEN 1 ELSE 0 END),
         COUNT(DISTINCT sql_id),
         COUNT(DISTINCT force_matching_signature),
         SUM(CASE WHEN session_state <> 'ON CPU' AND wait_class = 'Concurrency' THEN 1 ELSE 0 END),
         SUM(CASE WHEN session_state <> 'ON CPU' AND wait_class = 'User I/O'    THEN 1 ELSE 0 END),
         SUM(CASE WHEN session_state  = 'ON CPU' THEN 1 ELSE 0 END)
  INTO   v_total, v_hard, v_ids, v_sigs, v_conc, v_io, v_cpu
  FROM   gv$active_session_history
  WHERE  sample_time >= TO_TIMESTAMP('~g_beg', 'YYYY-MM-DD HH24:MI:SS')
  AND    (   session_id = ~g_sid
          OR UPPER(client_id) LIKE '%' || UPPER('~g_oprid') || '%'
          OR UPPER(program)   LIKE '%PSAE%');

  SELECT COUNT(*) INTO v_locked
  FROM   dba_tab_statistics
  WHERE  owner = 'SYSADM' AND stattype_locked IS NOT NULL
  AND    (table_name LIKE 'PS_FS_CEBD%' OR table_name LIKE 'PS_COMBO_DATA%');

  SELECT COUNT(*) INTO v_fake
  FROM   dba_tab_statistics
  WHERE  owner = 'SYSADM' AND num_rows = 1000000 AND blocks = 25000
  AND    (table_name LIKE 'PS_FS_CEBD%' OR table_name LIKE 'PS_COMBO_DATA%');

  SELECT COUNT(*) INTO v_noparallel
  FROM   (SELECT degree FROM dba_tables
          WHERE owner = 'SYSADM'
          AND   (table_name LIKE 'PS_COMBO_DATA%' OR table_name LIKE 'PS_FS_CEBD%')
          UNION ALL
          SELECT degree FROM dba_indexes
          WHERE owner = 'SYSADM'
          AND   (table_name LIKE 'PS_COMBO_DATA%' OR table_name LIKE 'PS_FS_CEBD%'))
  WHERE  TRIM(degree) = '1';

  SELECT COUNT(*) INTO v_patches FROM dba_sql_patches;
  SELECT COUNT(DISTINCT sql_patch) INTO v_bound FROM gv$sql WHERE sql_patch IS NOT NULL;
  SELECT COUNT(*) INTO v_profiles FROM dba_sql_profiles;

  DBMS_OUTPUT.PUT_LINE(RPAD('=', 110, '='));
  DBMS_OUTPUT.PUT_LINE('FS_CEBD AUTOMATED VERDICT   process_instance ~g_pi   oprid ~g_oprid');
  DBMS_OUTPUT.PUT_LINE('window ~g_beg  to  ~g_end');
  DBMS_OUTPUT.PUT_LINE(RPAD('=', 110, '='));
  DBMS_OUTPUT.PUT_LINE('ash db seconds captured : ' || v_total);
  DBMS_OUTPUT.PUT_LINE('  on cpu                : ' || v_cpu);
  DBMS_OUTPUT.PUT_LINE('  user i/o              : ' || v_io);
  DBMS_OUTPUT.PUT_LINE('  concurrency           : ' || v_conc);
  DBMS_OUTPUT.PUT_LINE('  hard parse            : ' || v_hard);
  DBMS_OUTPUT.PUT_LINE('distinct sql_ids        : ' || v_ids);
  DBMS_OUTPUT.PUT_LINE('distinct signatures     : ' || v_sigs);
  DBMS_OUTPUT.PUT_LINE(RPAD('-', 110, '-'));

  IF v_total = 0 THEN
    say('[NO DATA]', 'No ASH rows matched. Session correlation failed - review PART 2.3.');
  END IF;

  IF v_fake > 0 THEN
    say('[CONTAMINATED]', v_fake || ' table(s) carry num_rows=1000000 blocks=25000. '
      || 'Those are the injected synthetic statistics, not reality.');
  END IF;

  IF v_locked > 0 THEN
    say('[CONTAMINATED]', v_locked || ' table(s) have LOCKED statistics. PeopleSoft '
      || 'percent-UpdateStats cannot refresh them and may raise ORA-20005.');
  END IF;

  IF v_noparallel > 0 THEN
    say('[CONTAMINATED]', v_noparallel || ' object(s) sit at DEGREE 1. If FPRD has a '
      || 'higher degree, serial execution here is self-inflicted.');
  END IF;

  IF v_patches > 0 AND v_bound = 0 THEN
    say('[NO-OP]', v_patches || ' SQL patch(es) exist and NONE are bound to a cursor. '
      || 'They are inert - they neither help nor explain anything.');
  ELSIF v_bound > 0 THEN
    say('[CONTAMINATED]', v_bound || ' SQL patch(es) ARE bound to live cursors and are '
      || 'shaping the plans in this run.');
  END IF;

  IF v_profiles > 0 THEN
    say('[NOTE]', v_profiles || ' SQL profile(s) present - confirm FPRD has the same set.');
  END IF;

  IF v_total > 0 AND v_hard / GREATEST(v_total, 1) > 0.25 THEN
    say('[PARSE]', 'Hard parse is ' || ROUND(v_hard * 100 / v_total, 1)
      || ' percent of DB time. Literal SQL parse storm is the leading cause.');
  END IF;

  IF v_sigs > 0 AND v_ids / GREATEST(v_sigs, 1) > 20 THEN
    say('[LITERALS]', ROUND(v_ids / GREATEST(v_sigs, 1), 1)
      || ' distinct sql_ids per signature. Force-matching profiles are the only '
      || 'binding mechanism that will hold.');
  END IF;

  IF v_total > 0 AND v_io / GREATEST(v_total, 1) > 0.40 THEN
    say('[IO]', 'User I/O is ' || ROUND(v_io * 100 / v_total, 1)
      || ' percent of DB time. Check 2.9 and 2.10 for the driving operation and segment.');
  END IF;

  IF v_total > 0 AND v_conc / GREATEST(v_total, 1) > 0.20 THEN
    say('[CONCURRENCY]', 'Concurrency is ' || ROUND(v_conc * 100 / v_total, 1)
      || ' percent of DB time. Suspect cursor or library cache contention, or temp '
      || 'table instance serialisation - see 2.4.');
  END IF;

  IF v_findings = 0 THEN
    DBMS_OUTPUT.PUT_LINE('No threshold was crossed. Read PART 2.5 through 2.10 manually.');
  END IF;

  DBMS_OUTPUT.PUT_LINE(RPAD('=', 110, '='));
  DBMS_OUTPUT.PUT_LINE('While any CONTAMINATED line is present, this runtime is NOT a');
  DBMS_OUTPUT.PUT_LINE('valid reproduction of the FPRD regression. Run the reset script,');
  DBMS_OUTPUT.PUT_LINE('then re-run FS_CEBD, then re-run this collection.');
  DBMS_OUTPUT.PUT_LINE(RPAD('=', 110, '='));
END;
/

PROMPT
PROMPT #####################################################################
PROMPT ## PART 5 - RUN THIS AGAIN AFTER THE JOB COMPLETES
PROMPT #####################################################################
PROMPT

PROMPT -- 5.1 Persist the in-memory ASH before the ring buffer wraps
EXEC DBMS_WORKLOAD_REPOSITORY.CREATE_SNAPSHOT('ALL');

PROMPT -- 5.2 PeopleSoft per-step timings, if AE timings were enabled
SELECT * FROM SYSADM.PS_BAT_TIMINGS_LOG WHERE PROCESS_INSTANCE = ~g_pi;
SELECT * FROM SYSADM.PS_BAT_TIMINGS_DTL WHERE PROCESS_INSTANCE = ~g_pi;
SELECT * FROM SYSADM.PS_MESSAGE_LOG     WHERE PROCESS_INSTANCE = ~g_pi ORDER BY MESSAGE_SEQ;

PROMPT -- 5.3 Final run status
SELECT PRCSINSTANCE, RUNSTATUS, BEGINDTTM, ENDDTTM,
       ROUND((CAST(ENDDTTM AS DATE) - CAST(BEGINDTTM AS DATE)) * 1440, 1) mins
FROM   SYSADM.PSPRCSRQST WHERE PRCSINSTANCE = ~g_pi;

SPOOL OFF

SET DEFINE ON
PROMPT
PROMPT Collection complete. Output file: fsqua_fs_cebd_collect.log
PROMPT

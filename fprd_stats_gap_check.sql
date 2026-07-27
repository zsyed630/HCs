-- =====================================================================
-- fprd_stats_gap_check.sql
-- Target : FPRD (read only). Also valid in FSTRN and FSQUA.
-- Purpose: two jobs.
--   1. Find EVERY statistics-gathering SQL by pattern rather than from
--      a hand-supplied list, so nothing is missed.
--   2. Test whether the statistics cost actually accounts for the full
--      1 hour to 4 hour regression, or only part of it.
--
-- Classification note: DBMS_STATS recursive SQL is identified by the
-- dbms_stats optimizer hint, which every variant carries. Matching only
-- on the leading /* SQL Analyze */ comment misses the index_ffs
-- variants entirely.
--
-- Measurement note: ELAPSED_TIME in AWR is summed across parallel
-- execution servers, so it is DB time and not wall clock. The PX
-- columns below are printed so the two can be told apart.
-- =====================================================================

SET LINESIZE 118
SET PAGESIZE 0
SET HEADING OFF
SET FEEDBACK OFF
SET VERIFY OFF
SET TRIMSPOOL ON
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
SET DEFINE '~'

-- upgrade boundary
DEFINE cutover = 2026-06-26

SPOOL fprd_stats_gap_check.log

DECLARE
  v_db       VARCHAR2(30);
  v_cut      DATE := TO_DATE('~cutover', 'YYYY-MM-DD');
  v_line     PLS_INTEGER := 0;

  v_pre_runs  NUMBER := 0;
  v_pre_avg   NUMBER;
  v_post_runs NUMBER := 0;
  v_post_avg  NUMBER;

  v_oldest   TIMESTAMP;
  v_awr_pre  NUMBER := 0;

  v_stats_s  NUMBER := 0;
  v_app_s    NUMBER := 0;
  v_tot_s    NUMBER := 0;

  PROCEDURE p(s IN VARCHAR2) IS
  BEGIN
    v_line := v_line + 1;
    DBMS_OUTPUT.PUT_LINE(s);
  END p;

  FUNCTION clean(s IN VARCHAR2, n IN PLS_INTEGER) RETURN VARCHAR2 IS
  BEGIN
    RETURN SUBSTR(REPLACE(REPLACE(REPLACE(NVL(s, ' '), CHR(10), ' '),
                                  CHR(13), ' '), CHR(9), ' '), 1, n);
  END clean;

BEGIN
  SELECT name INTO v_db FROM v$database;
  p(RPAD('=', 116, '='));
  p('STATS GAP CHECK   db=' || v_db || '   cutover=' || TO_CHAR(v_cut, 'YYYY-MM-DD')
    || '   at=' || TO_CHAR(SYSDATE, 'MM-DD HH24:MI'));
  p(RPAD('=', 116, '='));

  ---------------------------------------------------------------- [1] runtimes
  p('[1] FS_CEBD RUNTIME, BEFORE AND AFTER THE CUTOVER');
  BEGIN
    SELECT COUNT(*), ROUND(AVG(mins), 1)
    INTO   v_pre_runs, v_pre_avg
    FROM  (SELECT (CAST(ENDDTTM AS DATE) - CAST(BEGINDTTM AS DATE)) * 1440 mins
           FROM   SYSADM.PSPRCSRQST
           WHERE  PRCSNAME = 'FS_CEBD' AND ENDDTTM IS NOT NULL
           AND    BEGINDTTM < v_cut);

    SELECT COUNT(*), ROUND(AVG(mins), 1)
    INTO   v_post_runs, v_post_avg
    FROM  (SELECT (CAST(ENDDTTM AS DATE) - CAST(BEGINDTTM AS DATE)) * 1440 mins
           FROM   SYSADM.PSPRCSRQST
           WHERE  PRCSNAME = 'FS_CEBD' AND ENDDTTM IS NOT NULL
           AND    BEGINDTTM >= v_cut);

    p('  pre-cutover : runs=' || v_pre_runs  || '  avg_mins=' || NVL(TO_CHAR(v_pre_avg), 'n/a'));
    p('  post-cutover: runs=' || v_post_runs || '  avg_mins=' || NVL(TO_CHAR(v_post_avg), 'n/a'));
    IF v_pre_avg IS NOT NULL AND v_post_avg IS NOT NULL THEN
      p('  >> REGRESSION = ' || ROUND(v_post_avg - v_pre_avg, 1) || ' minutes per run = '
        || ROUND((v_post_avg - v_pre_avg) * 60) || ' seconds of WALL CLOCK to explain');
    END IF;
  EXCEPTION WHEN OTHERS THEN
    p('  failed: ' || SUBSTR(SQLERRM, 1, 60));
  END;

  p(' ');
  p('  distribution of post-cutover runtimes');
  BEGIN
    FOR r IN (SELECT bucket, COUNT(*) n FROM (
                SELECT CASE
                         WHEN mins <  30 THEN 'under 30m'
                         WHEN mins <  75 THEN '30 to 75m'
                         WHEN mins < 150 THEN '75 to 150m'
                         WHEN mins < 240 THEN '150 to 240m'
                         ELSE 'over 240m'
                       END bucket
                FROM (SELECT (CAST(ENDDTTM AS DATE) - CAST(BEGINDTTM AS DATE)) * 1440 mins
                      FROM   SYSADM.PSPRCSRQST
                      WHERE  PRCSNAME = 'FS_CEBD' AND ENDDTTM IS NOT NULL
                      AND    BEGINDTTM >= v_cut))
              GROUP BY bucket ORDER BY 2 DESC)
    LOOP
      p('    ' || RPAD(r.bucket, 16) || r.n);
    END LOOP;
  EXCEPTION WHEN OTHERS THEN p('    failed: ' || SUBSTR(SQLERRM, 1, 60));
  END;

  ---------------------------------------------------------------- [2] awr reach
  p(' ');
  p('[2] AWR COVERAGE');
  BEGIN
    SELECT MIN(begin_interval_time) INTO v_oldest FROM dba_hist_snapshot;
    SELECT COUNT(*) INTO v_awr_pre FROM dba_hist_snapshot
     WHERE begin_interval_time < CAST(v_cut AS TIMESTAMP);
    p('  oldest snapshot   = ' || TO_CHAR(v_oldest, 'YYYY-MM-DD HH24:MI'));
    p('  pre-cutover snaps = ' || v_awr_pre
      || CASE WHEN v_awr_pre = 0 THEN '   (no before picture - section 4 is post only)' ELSE '' END);
  EXCEPTION WHEN OTHERS THEN p('  failed: ' || SUBSTR(SQLERRM, 1, 60));
  END;

  ---------------------------------------------------------------- [3] all stats sql
  p(' ');
  p('[3] EVERY STATS SQL SINCE CUTOVER, FOUND BY PATTERN NOT BY LIST');
  p('  ' || RPAD('SQL_ID', 15) || RPAD('KIND', 12) || LPAD('EXECS', 8)
    || LPAD('DB_SECS', 11) || LPAD('PER_EXEC', 10) || LPAD('PX', 6) || '  TEXT');
  p('  ' || RPAD('-', 112, '-'));
  BEGIN
    FOR r IN (SELECT * FROM (
                SELECT s.sql_id,
                       CASE
                         WHEN DBMS_LOB.SUBSTR(t.sql_text, 20, 1) LIKE '/* SQL Analyze%'
                           THEN 'TAB+COL'
                         WHEN UPPER(DBMS_LOB.SUBSTR(t.sql_text, 500, 1)) LIKE '%INDEX_FFS%'
                           THEN 'INDEX'
                         WHEN UPPER(DBMS_LOB.SUBSTR(t.sql_text, 300, 1)) LIKE '%GATHER_TABLE_STATS%'
                           THEN 'CALL'
                         ELSE 'OTHER-STATS'
                       END kind,
                       SUM(s.executions_delta) execs,
                       ROUND(SUM(s.elapsed_time_delta) / 1e6, 1) db_secs,
                       ROUND(SUM(s.elapsed_time_delta) / 1e6
                             / GREATEST(SUM(s.executions_delta), 1), 1) per_exec,
                       MAX(s.px_servers_execs_delta) px,
                       DBMS_LOB.SUBSTR(t.sql_text, 46, 1) txt
                FROM   dba_hist_sqlstat s
                JOIN   dba_hist_snapshot n
                       ON n.snap_id = s.snap_id AND n.dbid = s.dbid
                      AND n.instance_number = s.instance_number
                JOIN   dba_hist_sqltext t
                       ON t.sql_id = s.sql_id AND t.dbid = s.dbid
                WHERE  n.begin_interval_time >= CAST(v_cut AS TIMESTAMP)
                AND    UPPER(DBMS_LOB.SUBSTR(t.sql_text, 500, 1)) LIKE '%DBMS_STATS%'
                GROUP  BY s.sql_id,
                       CASE
                         WHEN DBMS_LOB.SUBSTR(t.sql_text, 20, 1) LIKE '/* SQL Analyze%'
                           THEN 'TAB+COL'
                         WHEN UPPER(DBMS_LOB.SUBSTR(t.sql_text, 500, 1)) LIKE '%INDEX_FFS%'
                           THEN 'INDEX'
                         WHEN UPPER(DBMS_LOB.SUBSTR(t.sql_text, 300, 1)) LIKE '%GATHER_TABLE_STATS%'
                           THEN 'CALL'
                         ELSE 'OTHER-STATS'
                       END,
                       DBMS_LOB.SUBSTR(t.sql_text, 46, 1)
                ORDER  BY 4 DESC)
              WHERE ROWNUM <= 20)
    LOOP
      p('  ' || RPAD(r.sql_id, 15) || RPAD(r.kind, 12) || LPAD(NVL(r.execs, 0), 8)
        || LPAD(r.db_secs, 11) || LPAD(r.per_exec, 10)
        || LPAD(NVL(r.px, 0), 6) || '  ' || clean(r.txt, 44));
    END LOOP;
  EXCEPTION WHEN OTHERS THEN p('  failed: ' || SUBSTR(SQLERRM, 1, 60));
  END;

  ---------------------------------------------------------------- [4] totals
  p(' ');
  p('[4] STATS VERSUS APPLICATION, WHOLE POST-CUTOVER WINDOW');
  BEGIN
    SELECT SUM(CASE WHEN is_stats = 1 THEN secs ELSE 0 END),
           SUM(CASE WHEN is_stats = 0 THEN secs ELSE 0 END),
           SUM(secs)
    INTO   v_stats_s, v_app_s, v_tot_s
    FROM (
      SELECT CASE WHEN UPPER(DBMS_LOB.SUBSTR(t.sql_text, 500, 1)) LIKE '%DBMS_STATS%'
                  THEN 1 ELSE 0 END is_stats,
             ROUND(SUM(s.elapsed_time_delta) / 1e6, 1) secs
      FROM   dba_hist_sqlstat s
      JOIN   dba_hist_snapshot n
             ON n.snap_id = s.snap_id AND n.dbid = s.dbid
            AND n.instance_number = s.instance_number
      LEFT   JOIN dba_hist_sqltext t ON t.sql_id = s.sql_id AND t.dbid = s.dbid
      WHERE  n.begin_interval_time >= CAST(v_cut AS TIMESTAMP)
      AND    s.parsing_schema_name = 'SYSADM'
      GROUP  BY CASE WHEN UPPER(DBMS_LOB.SUBSTR(t.sql_text, 500, 1)) LIKE '%DBMS_STATS%'
                     THEN 1 ELSE 0 END);

    p('  stats db_secs       = ' || NVL(v_stats_s, 0));
    p('  application db_secs = ' || NVL(v_app_s, 0));
    p('  total SYSADM        = ' || NVL(v_tot_s, 0));
  EXCEPTION WHEN OTHERS THEN p('  failed: ' || SUBSTR(SQLERRM, 1, 60));
  END;

  ---------------------------------------------------------------- [5] the test
  p(' ');
  p('[5] DOES THE ARITHMETIC CLOSE');
  IF v_post_runs > 0 AND v_pre_avg IS NOT NULL AND v_post_avg IS NOT NULL THEN
    p('  regression to explain   = ' || ROUND((v_post_avg - v_pre_avg) * 60)
      || ' wall-clock seconds per run');
    p('  stats db_secs per run   = ' || ROUND(NVL(v_stats_s, 0) / v_post_runs)
      || '   (' || NVL(v_stats_s, 0) || ' over ' || v_post_runs || ' runs)');
    p(' ');
    p('  Caution: the second number is DB time summed across parallel');
    p('  execution servers. Divide by the PX column in section 3 for the');
    p('  serial-equivalent wall clock before comparing the two.');
    p(' ');
    IF NVL(v_stats_s, 0) / GREATEST(v_post_runs, 1)
       >= (v_post_avg - v_pre_avg) * 60 * 0.6 THEN
      p('  >> Statistics gathering is large enough to account for most or all');
      p('     of the regression. Fixing the DDL model should recover it.');
    ELSE
      p('  >> Statistics gathering does NOT account for the whole regression.');
      p('     Fix it anyway, then look at section 3 of the digest for the');
      p('     application SQL that makes up the remainder. Do not assume one');
      p('     root cause covers the whole gap.');
    END IF;
  ELSE
    p('  cannot compute - missing pre-cutover runs or post-cutover runs');
    IF v_pre_runs = 0 THEN
      p('  no pre-cutover FS_CEBD runs in PSPRCSRQST here. Use FSTRN for the');
      p('  before picture, or widen the retention on PSPRCSRQST.');
    END IF;
  END IF;

  ---------------------------------------------------------------- [6] non-stats
  p(' ');
  p('[6] TOP NON-STATS SQL SINCE CUTOVER - the remainder');
  p('  ' || RPAD('SQL_ID', 15) || LPAD('EXECS', 9) || LPAD('DB_SECS', 11)
    || LPAD('PLANS', 7) || '  TEXT');
  BEGIN
    FOR r IN (SELECT * FROM (
                SELECT s.sql_id,
                       SUM(s.executions_delta) execs,
                       ROUND(SUM(s.elapsed_time_delta) / 1e6, 1) db_secs,
                       COUNT(DISTINCT s.plan_hash_value) plans,
                       DBMS_LOB.SUBSTR(t.sql_text, 60, 1) txt
                FROM   dba_hist_sqlstat s
                JOIN   dba_hist_snapshot n
                       ON n.snap_id = s.snap_id AND n.dbid = s.dbid
                      AND n.instance_number = s.instance_number
                LEFT   JOIN dba_hist_sqltext t ON t.sql_id = s.sql_id AND t.dbid = s.dbid
                WHERE  n.begin_interval_time >= CAST(v_cut AS TIMESTAMP)
                AND    s.parsing_schema_name = 'SYSADM'
                AND    NVL(UPPER(DBMS_LOB.SUBSTR(t.sql_text, 500, 1)), ' ') NOT LIKE '%DBMS_STATS%'
                GROUP  BY s.sql_id, DBMS_LOB.SUBSTR(t.sql_text, 60, 1)
                ORDER  BY 3 DESC)
              WHERE ROWNUM <= 12)
    LOOP
      p('  ' || RPAD(r.sql_id, 15) || LPAD(NVL(r.execs, 0), 9)
        || LPAD(r.db_secs, 11) || LPAD(r.plans, 7) || '  ' || clean(r.txt, 56));
    END LOOP;
  EXCEPTION WHEN OTHERS THEN p('  failed: ' || SUBSTR(SQLERRM, 1, 60));
  END;

  p(RPAD('=', 116, '='));
  p('END   db=' || v_db || '   lines=' || (v_line + 1));
END;
/

SPOOL OFF

SET DEFINE ON
SET HEADING ON
SET FEEDBACK ON
SET PAGESIZE 5000

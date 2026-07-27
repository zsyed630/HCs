-- =====================================================================
-- fscebd_per_run_attribution_fast.sql
-- Target : FPRD (read only).
--
-- Replaces fscebd_per_run_attribution.sql, which was unusable: it ran
-- three ASH queries per run in a PL/SQL loop, 108 in total, and none of
-- them carried a SNAP_ID predicate. DBA_HIST_ACTIVE_SESS_HISTORY is
-- partitioned on (DBID, SNAP_ID), so filtering on SAMPLE_TIME alone
-- prunes nothing and every call scanned a full year of history.
--
-- This version:
--   * derives the SNAP_ID range once and filters on it, so the
--     partitions actually prune
--   * resolves the set of DBMS_STATS sql_ids once instead of doing a
--     CLOB LIKE per ASH row per run
--   * produces every run in ONE pass rather than looping
--
-- Same output shape as before so it stays photographable.
-- =====================================================================

SET LINESIZE 118
SET PAGESIZE 0
SET HEADING OFF
SET FEEDBACK OFF
SET VERIFY OFF
SET TRIMSPOOL ON
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
SET DEFINE '~'

DEFINE cutover = 2026-06-26
DEFINE prerows = 15

SPOOL fscebd_per_run_attribution_fast.log

DECLARE
  v_db      VARCHAR2(30);
  v_cut     DATE := TO_DATE('~cutover', 'YYYY-MM-DD');
  v_pre     PLS_INTEGER := ~prerows;
  v_line    PLS_INTEGER := 0;

  v_lo      NUMBER;
  v_hi      NUMBER;
  v_wbeg    DATE;
  v_wend    DATE;
  v_t0      TIMESTAMP;

  v_fast_n NUMBER := 0; v_fast_st NUMBER := 0; v_fast_ap NUMBER := 0; v_fast_x NUMBER := 0;
  v_slow_n NUMBER := 0; v_slow_st NUMBER := 0; v_slow_ap NUMBER := 0; v_slow_x NUMBER := 0;

  PROCEDURE p(s IN VARCHAR2) IS
  BEGIN
    v_line := v_line + 1;
    DBMS_OUTPUT.PUT_LINE(s);
  END p;

  FUNCTION clean(s IN VARCHAR2, n IN PLS_INTEGER) RETURN VARCHAR2 IS
  BEGIN
    RETURN SUBSTR(REPLACE(REPLACE(NVL(s, ' '), CHR(10), ' '), CHR(13), ' '), 1, n);
  END clean;

BEGIN
  v_t0 := SYSTIMESTAMP;
  SELECT name INTO v_db FROM v$database;
  p(RPAD('=', 116, '='));
  p('FS_CEBD PER-RUN ATTRIBUTION   db=' || v_db
    || '   cutover=' || TO_CHAR(v_cut, 'YYYY-MM-DD')
    || '   at=' || TO_CHAR(SYSDATE, 'MM-DD HH24:MI'));
  p(RPAD('=', 116, '='));

  ---------------------------------------------------------------- [1] shape
  p('[1] RUNTIME SHAPE BOTH SIDES OF THE CUTOVER   (PSPRCSRQST only, fast)');
  p('  ' || RPAD('BUCKET', 16) || LPAD('PRE', 8) || LPAD('POST', 8));
  BEGIN
    FOR r IN (SELECT ord_seq, bucket,
                     SUM(CASE WHEN era = 'PRE'  THEN 1 ELSE 0 END) n_pre,
                     SUM(CASE WHEN era = 'POST' THEN 1 ELSE 0 END) n_post
              FROM (
                SELECT CASE WHEN BEGINDTTM < v_cut THEN 'PRE' ELSE 'POST' END era,
                       CASE
                         WHEN mins <  15 THEN 'under 15m'
                         WHEN mins <  30 THEN '15 to 30m'
                         WHEN mins <  75 THEN '30 to 75m'
                         WHEN mins < 150 THEN '75 to 150m'
                         WHEN mins < 240 THEN '150 to 240m'
                         ELSE 'over 240m'
                       END bucket,
                       CASE
                         WHEN mins <  15 THEN 1 WHEN mins <  30 THEN 2
                         WHEN mins <  75 THEN 3 WHEN mins < 150 THEN 4
                         WHEN mins < 240 THEN 5 ELSE 6 END ord_seq
                FROM (SELECT BEGINDTTM,
                             (CAST(ENDDTTM AS DATE) - CAST(BEGINDTTM AS DATE)) * 1440 mins
                      FROM   SYSADM.PSPRCSRQST
                      WHERE  PRCSNAME = 'FS_CEBD' AND ENDDTTM IS NOT NULL))
              GROUP BY ord_seq, bucket
              ORDER BY ord_seq)
    LOOP
      p('  ' || RPAD(r.bucket, 16) || LPAD(r.n_pre, 8) || LPAD(r.n_post, 8));
    END LOOP;
  EXCEPTION WHEN OTHERS THEN p('  failed: ' || SUBSTR(SQLERRM, 1, 60));
  END;

  ---------------------------------------------------------------- [2] window
  p(' ');
  p('[2] ANALYSIS WINDOW AND SNAPSHOT RANGE');
  BEGIN
    SELECT MIN(beg), MAX(fin) INTO v_wbeg, v_wend
    FROM (
      SELECT BEGINDTTM beg, ENDDTTM fin
      FROM   SYSADM.PSPRCSRQST
      WHERE  PRCSNAME = 'FS_CEBD' AND ENDDTTM IS NOT NULL AND BEGINDTTM >= v_cut
      UNION ALL
      SELECT beg, fin FROM (
        SELECT BEGINDTTM beg, ENDDTTM fin
        FROM   SYSADM.PSPRCSRQST
        WHERE  PRCSNAME = 'FS_CEBD' AND ENDDTTM IS NOT NULL AND BEGINDTTM < v_cut
        ORDER  BY BEGINDTTM DESC)
      WHERE ROWNUM <= v_pre);

    SELECT MIN(snap_id), MAX(snap_id) INTO v_lo, v_hi
    FROM   dba_hist_snapshot
    WHERE  end_interval_time   >= CAST(v_wbeg AS TIMESTAMP)
    AND    begin_interval_time <= CAST(v_wend AS TIMESTAMP);

    p('  window   = ' || TO_CHAR(v_wbeg, 'YYYY-MM-DD HH24:MI')
      || '  to  ' || TO_CHAR(v_wend, 'YYYY-MM-DD HH24:MI'));
    p('  snap_ids = ' || NVL(TO_CHAR(v_lo), 'none') || ' to ' || NVL(TO_CHAR(v_hi), 'none')
      || '   (partition pruning key - this is what the old script was missing)');
  EXCEPTION WHEN OTHERS THEN
    p('  failed: ' || SUBSTR(SQLERRM, 1, 60));
    v_lo := NULL;
  END;

  IF v_lo IS NULL THEN
    p('  cannot derive a snapshot range - stopping rather than full scanning AWR');
    RETURN;
  END IF;

  ---------------------------------------------------------------- [3] runs
  p(' ');
  p('[3] EVERY RUN, ATTRIBUTED   (one pass)');
  p('  ' || RPAD('ERA', 5) || RPAD('PI', 11) || RPAD('STARTED', 13) || LPAD('MINS', 7)
    || LPAD('DB_S', 9) || LPAD('STATS_S', 9) || LPAD('APP_S', 9) || LPAD('XSTAT_S', 9));
  p('  ' || RPAD('-', 112, '-'));
  BEGIN
    FOR r IN (
      WITH runs AS (
        SELECT /*+ MATERIALIZE */ pi, oprid, beg, fin,
               ROUND((CAST(fin AS DATE) - CAST(beg AS DATE)) * 1440, 1) mins,
               CASE WHEN beg < v_cut THEN 'PRE' ELSE 'POST' END era
        FROM (
          SELECT PRCSINSTANCE pi, OPRID oprid, BEGINDTTM beg, ENDDTTM fin
          FROM   SYSADM.PSPRCSRQST
          WHERE  PRCSNAME = 'FS_CEBD' AND ENDDTTM IS NOT NULL AND BEGINDTTM >= v_cut
          UNION ALL
          SELECT pi, oprid, beg, fin FROM (
            SELECT PRCSINSTANCE pi, OPRID oprid, BEGINDTTM beg, ENDDTTM fin
            FROM   SYSADM.PSPRCSRQST
            WHERE  PRCSNAME = 'FS_CEBD' AND ENDDTTM IS NOT NULL AND BEGINDTTM < v_cut
            ORDER  BY BEGINDTTM DESC)
          WHERE ROWNUM <= v_pre)
      ),
      statids AS (
        SELECT /*+ MATERIALIZE */ DISTINCT t.sql_id
        FROM   dba_hist_sqltext t
        WHERE  UPPER(DBMS_LOB.SUBSTR(t.sql_text, 500, 1)) LIKE '%DBMS_STATS%'
      ),
      ash AS (
        SELECT /*+ MATERIALIZE */
               h.sample_time, h.client_id, h.program,
               CASE WHEN s.sql_id IS NULL THEN 0 ELSE 1 END is_stats
        FROM   dba_hist_active_sess_history h
        LEFT   JOIN statids s ON s.sql_id = h.sql_id
        WHERE  h.snap_id BETWEEN v_lo AND v_hi
      )
      SELECT r.era, r.pi, r.beg, r.mins,
             NVL(SUM(CASE WHEN mine = 1 THEN 10 END), 0) db_s,
             NVL(SUM(CASE WHEN mine = 1 AND is_stats = 1 THEN 10 END), 0) stats_s,
             NVL(SUM(CASE WHEN mine = 1 AND is_stats = 0 THEN 10 END), 0) app_s,
             NVL(SUM(CASE WHEN mine = 0 AND is_stats = 1 THEN 10 END), 0) xstat_s
      FROM (
        SELECT r2.era, r2.pi, r2.beg, r2.mins,
               a.is_stats,
               CASE WHEN UPPER(a.client_id) LIKE '%' || UPPER(r2.oprid) || '%'
                      OR UPPER(a.program)   LIKE '%PSAE%'
                    THEN 1 ELSE 0 END mine
        FROM   runs r2
        LEFT   JOIN ash a
               ON  a.sample_time >= CAST(r2.beg AS TIMESTAMP)
               AND a.sample_time <= CAST(r2.fin AS TIMESTAMP)
      ) r
      GROUP  BY r.era, r.pi, r.beg, r.mins
      ORDER  BY r.beg)
    LOOP
      p('  ' || RPAD(r.era, 5) || RPAD(r.pi, 11)
        || RPAD(TO_CHAR(r.beg, 'MM-DD HH24:MI'), 13)
        || LPAD(r.mins, 7) || LPAD(r.db_s, 9) || LPAD(r.stats_s, 9)
        || LPAD(r.app_s, 9) || LPAD(r.xstat_s, 9));

      IF r.era = 'POST' THEN
        IF r.mins >= 75 THEN
          v_slow_n := v_slow_n + 1; v_slow_st := v_slow_st + r.stats_s;
          v_slow_ap := v_slow_ap + r.app_s; v_slow_x := v_slow_x + r.xstat_s;
        ELSE
          v_fast_n := v_fast_n + 1; v_fast_st := v_fast_st + r.stats_s;
          v_fast_ap := v_fast_ap + r.app_s; v_fast_x := v_fast_x + r.xstat_s;
        END IF;
      END IF;
    END LOOP;
  EXCEPTION WHEN OTHERS THEN
    p('  failed: ' || SUBSTR(SQLERRM, 1, 90));
  END;

  ---------------------------------------------------------------- [4] verdict
  p(' ');
  p('[4] FAST VERSUS SLOW, POST-CUTOVER ONLY  (slow = 75 minutes or more)');
  IF v_slow_n = 0 OR v_fast_n = 0 THEN
    p('  not enough of one class to compare  (fast=' || v_fast_n
      || ' slow=' || v_slow_n || ')');
  ELSE
    DECLARE
      f_st NUMBER := v_fast_st / v_fast_n;
      s_st NUMBER := v_slow_st / v_slow_n;
      f_ap NUMBER := v_fast_ap / v_fast_n;
      s_ap NUMBER := v_slow_ap / v_slow_n;
      f_x  NUMBER := v_fast_x  / v_fast_n;
      s_x  NUMBER := v_slow_x  / v_slow_n;
    BEGIN
      p('  fast runs = ' || v_fast_n || '   avg stats_s=' || ROUND(f_st)
        || '   avg app_s=' || ROUND(f_ap) || '   avg xstat_s=' || ROUND(f_x));
      p('  slow runs = ' || v_slow_n || '   avg stats_s=' || ROUND(s_st)
        || '   avg app_s=' || ROUND(s_ap) || '   avg xstat_s=' || ROUND(s_x));
      p(' ');
      p('  stats  ratio slow/fast = ' || ROUND(s_st / GREATEST(f_st, 1), 1) || 'x');
      p('  app    ratio slow/fast = ' || ROUND(s_ap / GREATEST(f_ap, 1), 1) || 'x');
      p('  xstats ratio slow/fast = ' || ROUND(s_x  / GREATEST(f_x, 1), 1) || 'x');
      p(' ');
      IF s_st / GREATEST(f_st, 1) >= 2 AND s_st > s_ap THEN
        p('  >> Slow runs are slow because of THEIR OWN statistics gathering.');
        p('     The DDL model fix targets exactly this.');
      ELSIF s_x / GREATEST(f_x, 1) >= 2 THEN
        p('  >> Slow runs coincide with heavy statistics work by OTHER sessions,');
        p('     i.e. the nightly autotask. Scheduling collision, not PSDDLMODEL.');
      ELSIF s_ap / GREATEST(f_ap, 1) >= 2 THEN
        p('  >> Slow runs are slow in APPLICATION sql, not statistics.');
        p('     Look at data volume or a plan change on the combo build.');
      ELSE
        p('  >> No single factor separates them. Compare START times in section 3;');
        p('     if the slow runs cluster in one window, the cause is concurrency.');
      END IF;
    END;
  END IF;

  ---------------------------------------------------------------- [5] autotask
  p(' ');
  p('[5] AUTOTASK AND MAINTENANCE WINDOWS');
  BEGIN
    FOR r IN (SELECT client_name, status FROM dba_autotask_client)
    LOOP
      p('  ' || RPAD(clean(r.client_name, 44), 46) || r.status);
    END LOOP;
  EXCEPTION WHEN OTHERS THEN p('  failed: ' || SUBSTR(SQLERRM, 1, 60));
  END;
  BEGIN
    FOR r IN (SELECT window_name, enabled, duration, repeat_interval
              FROM   dba_scheduler_windows ORDER BY window_name)
    LOOP
      p('  ' || RPAD(r.window_name, 20) || RPAD(NVL(r.enabled, '?'), 6)
        || RPAD(SUBSTR(TO_CHAR(r.duration), 1, 16), 18)
        || clean(r.repeat_interval, 48));
    END LOOP;
  EXCEPTION WHEN OTHERS THEN p('  failed: ' || SUBSTR(SQLERRM, 1, 60));
  END;

  p(RPAD('=', 116, '='));
  p('END   db=' || v_db || '   lines=' || (v_line + 2)
    || '   script_seconds=' || ROUND(EXTRACT(SECOND FROM (SYSTIMESTAMP - v_t0))
       + EXTRACT(MINUTE FROM (SYSTIMESTAMP - v_t0)) * 60
       + EXTRACT(HOUR FROM (SYSTIMESTAMP - v_t0)) * 3600, 1));
END;
/

SPOOL OFF

SET DEFINE ON
SET HEADING ON
SET FEEDBACK ON
SET PAGESIZE 5000

-- =====================================================================
-- fscebd_per_run_attribution.sql
-- Target : FPRD (read only).
--
-- Replaces fprd_stats_gap_check.sql sections 3 to 6, which were scoped
-- to the whole database and therefore counted the nightly
-- gather_database_stats_job_proc autotask as if it belonged to FS_CEBD.
-- Everything below is scoped to individual FS_CEBD runs.
--
-- Question it answers: the post-cutover runtimes are bimodal - 13 runs
-- normal, 5 runs long. What is different about the long ones? A uniform
-- DDL model change cannot cause a bimodal distribution, so either
-- something gates it or the cause is elsewhere.
--
-- Per-run columns:
--   DB_S     total ash db seconds for that run's own sessions
--   STATS_S  of which was DBMS_STATS recursive sql
--   APP_S    of which was application sql
--   XSTAT_S  stats activity by OTHER sessions during the same window,
--            i.e. the autotask running concurrently
-- =====================================================================

SET LINESIZE 118
SET PAGESIZE 0
SET HEADING OFF
SET FEEDBACK OFF
SET VERIFY OFF
SET TRIMSPOOL ON
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
SET DEFINE '~'

DEFINE cutover  = 2026-06-26
DEFINE prerows  = 15

SPOOL fscebd_per_run_attribution.log

DECLARE
  v_db     VARCHAR2(30);
  v_cut    DATE := TO_DATE('~cutover', 'YYYY-MM-DD');
  v_line   PLS_INTEGER := 0;

  v_tot    NUMBER;
  v_stats  NUMBER;
  v_app    NUMBER;
  v_xstat  NUMBER;
  v_ev     VARCHAR2(64);

  v_fast_n NUMBER := 0;  v_fast_st NUMBER := 0;  v_fast_ap NUMBER := 0;  v_fast_x NUMBER := 0;
  v_slow_n NUMBER := 0;  v_slow_st NUMBER := 0;  v_slow_ap NUMBER := 0;  v_slow_x NUMBER := 0;

  PROCEDURE p(s IN VARCHAR2) IS
  BEGIN
    v_line := v_line + 1;
    DBMS_OUTPUT.PUT_LINE(s);
  END p;

  FUNCTION clean(s IN VARCHAR2, n IN PLS_INTEGER) RETURN VARCHAR2 IS
  BEGIN
    RETURN SUBSTR(REPLACE(REPLACE(NVL(s, ' '), CHR(10), ' '), CHR(13), ' '), 1, n);
  END clean;

  -- one run, four numbers
  PROCEDURE measure(p_beg IN DATE, p_end IN DATE, p_oprid IN VARCHAR2) IS
  BEGIN
    v_tot := 0; v_stats := 0; v_app := 0; v_xstat := 0; v_ev := NULL;

    SELECT NVL(SUM(secs), 0),
           NVL(SUM(CASE WHEN is_stats = 1 THEN secs ELSE 0 END), 0),
           NVL(SUM(CASE WHEN is_stats = 0 THEN secs ELSE 0 END), 0)
    INTO   v_tot, v_stats, v_app
    FROM (
      SELECT CASE WHEN UPPER(DBMS_LOB.SUBSTR(t.sql_text, 500, 1)) LIKE '%DBMS_STATS%'
                  THEN 1 ELSE 0 END is_stats,
             COUNT(*) * 10 secs
      FROM   dba_hist_active_sess_history h
      LEFT   JOIN dba_hist_sqltext t ON t.sql_id = h.sql_id AND t.dbid = h.dbid
      WHERE  h.sample_time >= CAST(p_beg AS TIMESTAMP)
      AND    h.sample_time <= CAST(p_end AS TIMESTAMP)
      AND    (UPPER(h.client_id) LIKE '%' || UPPER(p_oprid) || '%'
              OR UPPER(h.program) LIKE '%PSAE%')
      GROUP  BY CASE WHEN UPPER(DBMS_LOB.SUBSTR(t.sql_text, 500, 1)) LIKE '%DBMS_STATS%'
                     THEN 1 ELSE 0 END);

    -- concurrent stats work by everything that is NOT this job
    SELECT NVL(COUNT(*) * 10, 0)
    INTO   v_xstat
    FROM   dba_hist_active_sess_history h
    JOIN   dba_hist_sqltext t ON t.sql_id = h.sql_id AND t.dbid = h.dbid
    WHERE  h.sample_time >= CAST(p_beg AS TIMESTAMP)
    AND    h.sample_time <= CAST(p_end AS TIMESTAMP)
    AND    UPPER(DBMS_LOB.SUBSTR(t.sql_text, 500, 1)) LIKE '%DBMS_STATS%'
    AND    NOT (UPPER(h.client_id) LIKE '%' || UPPER(p_oprid) || '%'
                OR UPPER(h.program) LIKE '%PSAE%');

    BEGIN
      SELECT ev INTO v_ev FROM (
        SELECT CASE WHEN session_state = 'ON CPU' THEN 'ON CPU'
                    ELSE NVL(event, 'unknown') END ev, COUNT(*) n
        FROM   dba_hist_active_sess_history
        WHERE  sample_time >= CAST(p_beg AS TIMESTAMP)
        AND    sample_time <= CAST(p_end AS TIMESTAMP)
        AND    (UPPER(client_id) LIKE '%' || UPPER(p_oprid) || '%'
                OR UPPER(program) LIKE '%PSAE%')
        GROUP  BY CASE WHEN session_state = 'ON CPU' THEN 'ON CPU'
                       ELSE NVL(event, 'unknown') END
        ORDER  BY 2 DESC)
      WHERE ROWNUM = 1;
    EXCEPTION WHEN OTHERS THEN v_ev := NULL;
    END;
  EXCEPTION WHEN OTHERS THEN
    v_tot := -1; v_stats := -1; v_app := -1; v_xstat := -1;
  END measure;

BEGIN
  SELECT name INTO v_db FROM v$database;
  p(RPAD('=', 116, '='));
  p('FS_CEBD PER-RUN ATTRIBUTION   db=' || v_db
    || '   cutover=' || TO_CHAR(v_cut, 'YYYY-MM-DD')
    || '   at=' || TO_CHAR(SYSDATE, 'MM-DD HH24:MI'));
  p(RPAD('=', 116, '='));

  ---------------------------------------------------------------- [1] shape
  p('[1] RUNTIME SHAPE BOTH SIDES OF THE CUTOVER');
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
  p('  If PRE is also spread across buckets, the job was ALWAYS bimodal and');
  p('  the cutover changed the mix, not the mechanism.');

  ---------------------------------------------------------------- [2] post runs
  p(' ');
  p('[2] EVERY POST-CUTOVER RUN, ATTRIBUTED');
  p('  ' || RPAD('PI', 11) || RPAD('STARTED', 13) || LPAD('MINS', 7)
    || LPAD('DB_S', 9) || LPAD('STATS_S', 9) || LPAD('APP_S', 9)
    || LPAD('XSTAT_S', 9) || '  TOP EVENT');
  p('  ' || RPAD('-', 112, '-'));
  BEGIN
    FOR r IN (SELECT PRCSINSTANCE, OPRID, BEGINDTTM, ENDDTTM,
                     ROUND((CAST(ENDDTTM AS DATE) - CAST(BEGINDTTM AS DATE)) * 1440, 1) mins
              FROM   SYSADM.PSPRCSRQST
              WHERE  PRCSNAME = 'FS_CEBD' AND ENDDTTM IS NOT NULL
              AND    BEGINDTTM >= v_cut
              ORDER  BY BEGINDTTM)
    LOOP
      measure(r.BEGINDTTM, r.ENDDTTM, r.OPRID);
      p('  ' || RPAD(r.PRCSINSTANCE, 11)
        || RPAD(TO_CHAR(r.BEGINDTTM, 'MM-DD HH24:MI'), 13)
        || LPAD(r.mins, 7) || LPAD(v_tot, 9) || LPAD(v_stats, 9)
        || LPAD(v_app, 9) || LPAD(v_xstat, 9) || '  ' || clean(v_ev, 30));

      IF r.mins >= 75 THEN
        v_slow_n := v_slow_n + 1; v_slow_st := v_slow_st + GREATEST(v_stats, 0);
        v_slow_ap := v_slow_ap + GREATEST(v_app, 0);
        v_slow_x  := v_slow_x  + GREATEST(v_xstat, 0);
      ELSE
        v_fast_n := v_fast_n + 1; v_fast_st := v_fast_st + GREATEST(v_stats, 0);
        v_fast_ap := v_fast_ap + GREATEST(v_app, 0);
        v_fast_x  := v_fast_x  + GREATEST(v_xstat, 0);
      END IF;
    END LOOP;
  EXCEPTION WHEN OTHERS THEN p('  failed: ' || SUBSTR(SQLERRM, 1, 60));
  END;

  ---------------------------------------------------------------- [3] pre runs
  p(' ');
  p('[3] LAST ~prerows PRE-CUTOVER RUNS, SAME TREATMENT');
  p('  ' || RPAD('PI', 11) || RPAD('STARTED', 13) || LPAD('MINS', 7)
    || LPAD('DB_S', 9) || LPAD('STATS_S', 9) || LPAD('APP_S', 9)
    || LPAD('XSTAT_S', 9) || '  TOP EVENT');
  p('  ' || RPAD('-', 112, '-'));
  BEGIN
    FOR r IN (SELECT * FROM (
                SELECT PRCSINSTANCE, OPRID, BEGINDTTM, ENDDTTM,
                       ROUND((CAST(ENDDTTM AS DATE) - CAST(BEGINDTTM AS DATE)) * 1440, 1) mins
                FROM   SYSADM.PSPRCSRQST
                WHERE  PRCSNAME = 'FS_CEBD' AND ENDDTTM IS NOT NULL
                AND    BEGINDTTM < v_cut
                ORDER  BY BEGINDTTM DESC)
              WHERE ROWNUM <= ~prerows)
    LOOP
      measure(r.BEGINDTTM, r.ENDDTTM, r.OPRID);
      p('  ' || RPAD(r.PRCSINSTANCE, 11)
        || RPAD(TO_CHAR(r.BEGINDTTM, 'MM-DD HH24:MI'), 13)
        || LPAD(r.mins, 7) || LPAD(v_tot, 9) || LPAD(v_stats, 9)
        || LPAD(v_app, 9) || LPAD(v_xstat, 9) || '  ' || clean(v_ev, 30));
    END LOOP;
  EXCEPTION WHEN OTHERS THEN p('  failed: ' || SUBSTR(SQLERRM, 1, 60));
  END;

  ---------------------------------------------------------------- [4] verdict
  p(' ');
  p('[4] FAST VERSUS SLOW, POST-CUTOVER ONLY  (slow = 75 minutes or more)');
  p('  fast runs = ' || v_fast_n
    || '   avg stats_s=' || ROUND(v_fast_st / GREATEST(v_fast_n, 1))
    || '   avg app_s=' || ROUND(v_fast_ap / GREATEST(v_fast_n, 1))
    || '   avg xstat_s=' || ROUND(v_fast_x / GREATEST(v_fast_n, 1)));
  p('  slow runs = ' || v_slow_n
    || '   avg stats_s=' || ROUND(v_slow_st / GREATEST(v_slow_n, 1))
    || '   avg app_s=' || ROUND(v_slow_ap / GREATEST(v_slow_n, 1))
    || '   avg xstat_s=' || ROUND(v_slow_x / GREATEST(v_slow_n, 1)));
  p(' ');
  IF v_slow_n = 0 OR v_fast_n = 0 THEN
    p('  not enough of one class to compare');
  ELSE
    DECLARE
      f_st NUMBER := v_fast_st / GREATEST(v_fast_n, 1);
      s_st NUMBER := v_slow_st / GREATEST(v_slow_n, 1);
      f_ap NUMBER := v_fast_ap / GREATEST(v_fast_n, 1);
      s_ap NUMBER := v_slow_ap / GREATEST(v_slow_n, 1);
      f_x  NUMBER := v_fast_x  / GREATEST(v_fast_n, 1);
      s_x  NUMBER := v_slow_x  / GREATEST(v_slow_n, 1);
    BEGIN
      p('  stats  ratio slow/fast = ' || ROUND(s_st / GREATEST(f_st, 1), 1) || 'x');
      p('  app    ratio slow/fast = ' || ROUND(s_ap / GREATEST(f_ap, 1), 1) || 'x');
      p('  xstats ratio slow/fast = ' || ROUND(s_x  / GREATEST(f_x, 1), 1) || 'x');
      p(' ');
      IF s_st / GREATEST(f_st, 1) >= 2 AND s_st > s_ap THEN
        p('  >> The slow runs are slow because of THEIR OWN statistics gathering.');
        p('     The DDL model fix targets exactly this.');
      ELSIF s_x / GREATEST(f_x, 1) >= 2 THEN
        p('  >> The slow runs coincide with heavy statistics work by OTHER');
        p('     sessions - the nightly autotask. This is a scheduling collision,');
        p('     not a PSDDLMODEL problem. Fixing the DDL model will not help much.');
      ELSIF s_ap / GREATEST(f_ap, 1) >= 2 THEN
        p('  >> The slow runs are slow in APPLICATION sql, not statistics.');
        p('     Look at data volume or plan change on the combo build itself.');
      ELSE
        p('  >> No single factor separates fast from slow. Compare the START');
        p('     times in section 2 - if the slow runs cluster in one window,');
        p('     the cause is concurrency, not anything inside FS_CEBD.');
      END IF;
    END;
  END IF;

  ---------------------------------------------------------------- [5] autotask
  p(' ');
  p('[5] AUTOTASK FOOTPRINT - context for XSTAT_S');
  BEGIN
    FOR r IN (SELECT client_name, status, window_group
              FROM   dba_autotask_client)
    LOOP
      p('  ' || RPAD(clean(r.client_name, 40), 42) || RPAD(r.status, 10)
        || clean(r.window_group, 20));
    END LOOP;
  EXCEPTION WHEN OTHERS THEN p('  failed: ' || SUBSTR(SQLERRM, 1, 60));
  END;
  BEGIN
    FOR r IN (SELECT window_name, repeat_interval, duration, enabled
              FROM   dba_scheduler_windows ORDER BY window_name)
    LOOP
      p('  ' || RPAD(r.window_name, 22) || RPAD(NVL(r.enabled, '?'), 6)
        || ' dur=' || RPAD(SUBSTR(TO_CHAR(r.duration), 1, 18), 20)
        || clean(r.repeat_interval, 46));
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

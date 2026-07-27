-- =====================================================================
--  fscebd_pulse.sql
--
--  Live monitoring while the FS_CEBD test run is in flight.
--  Read only. No input. Auto-resolves the running job.
--  Safe to run every few minutes for the whole run.
--
--  SECTION B IS THE ONE THAT MATTERS. It tells you within the first few
--  minutes whether the ESTIMATE_PERCENT preference actually took effect,
--  long before the runtime does.
--
--  Why that works: with ESTIMATE_PERCENT = AUTO_SAMPLE_SIZE, DBMS_STATS
--  routes through the SQL Tuning framework for approximate NDV, and the
--  recursive SQL carries a leading  /* SQL Analyze(n) */  comment. With
--  a fixed sample percent it does not take that path at all - it issues
--  a SAMPLE-clause query instead. So the presence or absence of that
--  comment is a binary read on whether the fix is live.
--
--  Second binary read: the four SQL_IDs from the slow FPRD runs. SQL_ID
--  is a hash of the statement text. Change estimate_percent and the text
--  changes, so the hash changes. If you still see these exact IDs, the
--  preference is not being honoured:
--     f4v8yvxn8pn1p  1ggxdkgha6w5b  6hh8xgvmyqrzs  bp3nhn5v4ms9t
--
--  Baseline for FDC_COMBO_BUILD_MASTER_RUNCNTL:
--     pre-upgrade 72.7 min   post-upgrade 202.3 min   target 73 min
-- =====================================================================

SET DEFINE OFF
SET LINESIZE 130
SET PAGESIZE 0
SET HEADING OFF
SET FEEDBACK OFF
SET VERIFY OFF
SET TRIMSPOOL ON
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED

DECLARE
  c_baseline_slow CONSTANT NUMBER := 202.3;   -- post-upgrade FPRD avg
  c_baseline_good CONSTANT NUMBER :=  72.7;   -- pre-upgrade FPRD avg

  v_db      VARCHAR2(30);
  v_line    PLS_INTEGER := 0;

  v_pi      NUMBER;
  v_rc      VARCHAR2(64);
  v_oprid   VARCHAR2(64);
  v_beg     DATE;
  v_fin     DATE;
  v_status  VARCHAR2(30);
  v_mins    NUMBER;
  v_live    BOOLEAN := FALSE;

  v_analyze NUMBER := 0;
  v_sample  NUMBER := 0;
  v_oldids  NUMBER := 0;

  v_tot     NUMBER := 0;
  v_stats   NUMBER := 0;
  v_app     NUMBER := 0;

  PROCEDURE p(s IN VARCHAR2) IS
  BEGIN
    v_line := v_line + 1;
    DBMS_OUTPUT.PUT_LINE(s);
  END p;

  PROCEDURE hdr(s IN VARCHAR2) IS
  BEGIN
    p(' ');
    p(RPAD('=', 128, '='));
    p(s);
    p(RPAD('=', 128, '='));
  END hdr;

  FUNCTION clean(s IN VARCHAR2, n IN PLS_INTEGER) RETURN VARCHAR2 IS
  BEGIN
    RETURN SUBSTR(REPLACE(REPLACE(REPLACE(NVL(s, ' '), CHR(10), ' '),
                                  CHR(13), ' '), CHR(9), ' '), 1, n);
  END clean;

  FUNCTION pct(a IN NUMBER, b IN NUMBER) RETURN VARCHAR2 IS
  BEGIN
    IF NVL(b, 0) = 0 THEN RETURN '0%'; END IF;
    RETURN TO_CHAR(ROUND(a * 100 / b)) || '%';
  END pct;

BEGIN
  SELECT UPPER(name) INTO v_db FROM v$database;

  p(RPAD('=', 128, '='));
  p('FS_CEBD PULSE    db=' || v_db || '    at='
    || TO_CHAR(SYSDATE, 'YYYY-MM-DD HH24:MI:SS'));
  p(RPAD('=', 128, '='));

  -- ==================================================================
  hdr('A - RUN STATUS');
  -- ==================================================================
  BEGIN
    SELECT PRCSINSTANCE, RUNCNTLID, OPRID, RUNSTATUS, BEGINDTTM, ENDDTTM
    INTO   v_pi, v_rc, v_oprid, v_status, v_beg, v_fin
    FROM  (SELECT PRCSINSTANCE, RUNCNTLID, OPRID, RUNSTATUS, BEGINDTTM, ENDDTTM
           FROM   SYSADM.PSPRCSRQST
           WHERE  PRCSNAME = 'FS_CEBD' AND BEGINDTTM IS NOT NULL
           ORDER  BY BEGINDTTM DESC)
    WHERE ROWNUM = 1;

    v_live := (v_fin IS NULL);
    v_mins := ROUND((NVL(v_fin, SYSDATE) - v_beg) * 1440, 1);

    p('  process instance : ' || v_pi);
    p('  run control      : ' || NVL(v_rc, '(null)'));
    p('  oprid            : ' || v_oprid || '     status=' || v_status);
    p('  started          : ' || TO_CHAR(v_beg, 'YYYY-MM-DD HH24:MI:SS')
      || CASE WHEN v_live THEN '   STILL RUNNING'
              ELSE '   finished ' || TO_CHAR(v_fin, 'HH24:MI:SS') END);
    p('  elapsed          : ' || v_mins || ' minutes');
    p(' ');
    p('  baseline post-upgrade : ' || c_baseline_slow || ' min   ('
      || pct(v_mins, c_baseline_slow) || ' of the slow run so far)');
    p('  baseline pre-upgrade  : ' || c_baseline_good || ' min   ('
      || pct(v_mins, c_baseline_good) || ' of the target)');
    IF v_live AND v_mins > c_baseline_good * 1.25 THEN
      p('  >> past the target already. Read section B and D carefully.');
    END IF;
  EXCEPTION WHEN OTHERS THEN
    p('  no FS_CEBD run found: ' || SUBSTR(SQLERRM, 1, 60));
    v_beg := SYSDATE - 1/24;
    v_oprid := 'NONE';
  END;

  p(' ');
  p('  Database sessions for this job:');
  p('  ' || RPAD('INST', 6) || RPAD('SID', 8) || RPAD('SERIAL', 9)
    || RPAD('SQL_ID', 15) || RPAD('STATE', 9) || RPAD('EVENT', 34) || 'SECS');
  BEGIN
    FOR r IN (SELECT s.inst_id i, s.sid sd, s.serial# sr, s.sql_id sq,
                     s.state st, s.event ev, s.seconds_in_wait sw
              FROM   gv$session s
              WHERE  s.username = 'SYSADM'
              AND    (UPPER(s.client_identifier) LIKE '%' || UPPER(v_oprid) || '%'
                      OR UPPER(s.program) LIKE '%PSAE%')
              ORDER  BY s.logon_time)
    LOOP
      p('  ' || RPAD(r.i, 6) || RPAD(r.sd, 8) || RPAD(r.sr, 9)
        || RPAD(NVL(r.sq, '-'), 15) || RPAD(NVL(r.st, '-'), 9)
        || RPAD(clean(r.ev, 32), 34) || NVL(r.sw, 0));
    END LOOP;
  EXCEPTION WHEN OTHERS THEN
    p('  session lookup failed: ' || SUBSTR(SQLERRM, 1, 60));
  END;

  -- ==================================================================
  hdr('B - DID THE FIX TAKE EFFECT   (read this first)');
  -- ==================================================================
  BEGIN
    SELECT
      COUNT(CASE WHEN DBMS_LOB.SUBSTR(sql_fulltext, 20, 1) LIKE '/* SQL Analyze%'
                 THEN 1 END),
      COUNT(CASE WHEN UPPER(DBMS_LOB.SUBSTR(sql_fulltext, 900, 1)) LIKE '%SAMPLE (%'
                   OR UPPER(DBMS_LOB.SUBSTR(sql_fulltext, 900, 1)) LIKE '%SAMPLE(%'
                 THEN 1 END),
      COUNT(CASE WHEN sql_id IN ('f4v8yvxn8pn1p','1ggxdkgha6w5b',
                                 '6hh8xgvmyqrzs','bp3nhn5v4ms9t')
                 THEN 1 END)
    INTO v_analyze, v_sample, v_oldids
    FROM gv$sql
    WHERE UPPER(DBMS_LOB.SUBSTR(sql_fulltext, 500, 1)) LIKE '%DBMS_STATS%'
    AND   last_active_time > SYSDATE - 60/1440;
  EXCEPTION WHEN OTHERS THEN
    p('  scan failed: ' || SUBSTR(SQLERRM, 1, 60));
  END;

  p('  In the last 60 minutes of shared pool activity:');
  p('    cursors with the SQL Analyze marker : ' || v_analyze
    || '   <- AUTO_SAMPLE_SIZE path, should be 0');
  p('    cursors using a SAMPLE clause       : ' || v_sample
    || '   <- fixed sample path, expect > 0');
  p('    the four old slow SQL_IDs           : ' || v_oldids
    || '   <- should be 0');
  p(' ');
  IF v_analyze = 0 AND v_oldids = 0 THEN
    p('  >> LOOKS RIGHT. The AUTO_SAMPLE_SIZE code path is not being used.');
  ELSIF v_analyze > 0 OR v_oldids > 0 THEN
    p('  >> WARNING. The old path is still running. The preference is not');
    p('     being honoured. Check PREFERENCE_OVERRIDES_PARAMETER is TRUE');
    p('     and that the gather is against PS_COMBO_DATA_TBL and not some');
    p('     other table that has no preference set.');
  END IF;

  p(' ');
  p('  Every DBMS_STATS cursor active in the last 30 minutes:');
  p('  ' || RPAD('SQL_ID', 15) || RPAD('EXECS', 8) || RPAD('ELAPSED_S', 12)
    || RPAD('PX', 5) || 'TEXT');
  BEGIN
    FOR r IN (SELECT sql_id sq, SUM(executions) ex,
                     ROUND(SUM(elapsed_time)/1e6, 1) el,
                     MAX(px_servers_executions) px,
                     MIN(DBMS_LOB.SUBSTR(sql_fulltext, 78, 1)) tx
              FROM   gv$sql
              WHERE  UPPER(DBMS_LOB.SUBSTR(sql_fulltext, 500, 1)) LIKE '%DBMS_STATS%'
              AND    last_active_time > SYSDATE - 30/1440
              GROUP  BY sql_id
              ORDER  BY 3 DESC
              FETCH FIRST 12 ROWS ONLY)
    LOOP
      p('  ' || RPAD(r.sq, 15) || RPAD(NVL(r.ex, 0), 8) || RPAD(r.el, 12)
        || RPAD(NVL(r.px, 0), 5) || clean(r.tx, 76));
    END LOOP;
  EXCEPTION WHEN OTHERS THEN
    p('  failed: ' || SUBSTR(SQLERRM, 1, 60));
  END;

  -- ==================================================================
  hdr('C - WHAT IT IS DOING RIGHT NOW   (last 15 minutes)');
  -- ==================================================================
  p('  ' || RPAD('WAIT CLASS', 16) || RPAD('EVENT', 44) || LPAD('DB_SECS', 10)
    || LPAD('PCT', 7));
  BEGIN
    FOR r IN (SELECT CASE WHEN session_state = 'ON CPU' THEN 'CPU'
                          ELSE NVL(wait_class, 'unknown') END wc,
                     CASE WHEN session_state = 'ON CPU' THEN 'ON CPU'
                          ELSE NVL(event, 'unknown') END ev,
                     COUNT(*) secs,
                     ROUND(RATIO_TO_REPORT(COUNT(*)) OVER () * 100, 1) pc
              FROM   gv$active_session_history
              WHERE  sample_time > SYSTIMESTAMP - INTERVAL '15' MINUTE
              AND    (UPPER(client_id) LIKE '%' || UPPER(v_oprid) || '%'
                      OR UPPER(program) LIKE '%PSAE%')
              GROUP  BY CASE WHEN session_state = 'ON CPU' THEN 'CPU'
                             ELSE NVL(wait_class, 'unknown') END,
                        CASE WHEN session_state = 'ON CPU' THEN 'ON CPU'
                             ELSE NVL(event, 'unknown') END
              ORDER  BY 3 DESC
              FETCH FIRST 12 ROWS ONLY)
    LOOP
      p('  ' || RPAD(r.wc, 16) || RPAD(clean(r.ev, 42), 44)
        || LPAD(r.secs, 10) || LPAD(r.pc, 7));
    END LOOP;
  EXCEPTION WHEN OTHERS THEN
    p('  failed: ' || SUBSTR(SQLERRM, 1, 60));
  END;

  -- ==================================================================
  hdr('D - TOP SQL SINCE THE RUN STARTED, AND THE STATS SHARE');
  -- ==================================================================
  BEGIN
    SELECT NVL(SUM(secs), 0),
           NVL(SUM(CASE WHEN is_stats = 1 THEN secs ELSE 0 END), 0),
           NVL(SUM(CASE WHEN is_stats = 0 THEN secs ELSE 0 END), 0)
    INTO   v_tot, v_stats, v_app
    FROM (
      SELECT CASE WHEN UPPER(DBMS_LOB.SUBSTR(q.sql_fulltext, 500, 1))
                       LIKE '%DBMS_STATS%' THEN 1 ELSE 0 END is_stats,
             COUNT(*) secs
      FROM   gv$active_session_history h
      LEFT   JOIN gv$sql q ON q.sql_id = h.sql_id AND q.inst_id = h.inst_id
                          AND q.child_number = 0
      WHERE  h.sample_time >= CAST(v_beg AS TIMESTAMP)
      AND    (UPPER(h.client_id) LIKE '%' || UPPER(v_oprid) || '%'
              OR UPPER(h.program) LIKE '%PSAE%')
      GROUP  BY CASE WHEN UPPER(DBMS_LOB.SUBSTR(q.sql_fulltext, 500, 1))
                          LIKE '%DBMS_STATS%' THEN 1 ELSE 0 END);
  EXCEPTION WHEN OTHERS THEN
    p('  split failed: ' || SUBSTR(SQLERRM, 1, 60));
  END;

  p('  total db seconds  : ' || v_tot);
  p('  statistics        : ' || v_stats || '   (' || pct(v_stats, v_tot) || ')');
  p('  application sql   : ' || v_app   || '   (' || pct(v_app, v_tot) || ')');
  p(' ');
  p('  It was 82 percent statistics on the slow FPRD run 26068516.');
  IF v_tot > 300 AND v_stats / GREATEST(v_tot, 1) < 0.20 THEN
    p('  >> statistics share is well down. That is the fix working.');
  ELSIF v_tot > 300 AND v_stats / GREATEST(v_tot, 1) > 0.50 THEN
    p('  >> statistics still dominant. Cross-check section B.');
  END IF;

  p(' ');
  p('  ' || RPAD('SQL_ID', 15) || RPAD('KIND', 8) || LPAD('DB_SECS', 9)
    || LPAD('PLANS', 7) || '  TEXT');
  BEGIN
    FOR r IN (SELECT h.sql_id sq,
                     CASE WHEN UPPER(DBMS_LOB.SUBSTR(q.sql_fulltext, 500, 1))
                               LIKE '%DBMS_STATS%' THEN 'STATS' ELSE 'app' END kd,
                     COUNT(*) secs,
                     COUNT(DISTINCT h.sql_plan_hash_value) pl,
                     MIN(DBMS_LOB.SUBSTR(q.sql_fulltext, 62, 1)) tx
              FROM   gv$active_session_history h
              LEFT   JOIN gv$sql q ON q.sql_id = h.sql_id AND q.inst_id = h.inst_id
                                  AND q.child_number = 0
              WHERE  h.sample_time >= CAST(v_beg AS TIMESTAMP)
              AND    h.sql_id IS NOT NULL
              AND    (UPPER(h.client_id) LIKE '%' || UPPER(v_oprid) || '%'
                      OR UPPER(h.program) LIKE '%PSAE%')
              GROUP  BY h.sql_id,
                     CASE WHEN UPPER(DBMS_LOB.SUBSTR(q.sql_fulltext, 500, 1))
                               LIKE '%DBMS_STATS%' THEN 'STATS' ELSE 'app' END
              ORDER  BY 3 DESC
              FETCH FIRST 15 ROWS ONLY)
    LOOP
      p('  ' || RPAD(r.sq, 15) || RPAD(r.kd, 8) || LPAD(r.secs, 9)
        || LPAD(r.pl, 7) || '  ' || clean(r.tx, 60));
    END LOOP;
  EXCEPTION WHEN OTHERS THEN
    p('  failed: ' || SUBSTR(SQLERRM, 1, 60));
  END;

  -- ==================================================================
  hdr('E - STATISTICS GATHERING ACTIVITY DURING THIS RUN');
  -- ==================================================================
  p('  Tables gathered since the job started:');
  p('  ' || RPAD('TABLE', 30) || LPAD('GATHERS', 9) || '  FIRST      LAST');
  BEGIN
    FOR r IN (SELECT table_name tn, COUNT(*) g,
                     MIN(stats_update_time) f, MAX(stats_update_time) l
              FROM   dba_tab_stats_history
              WHERE  owner = 'SYSADM'
              AND    stats_update_time >= CAST(v_beg AS TIMESTAMP)
              GROUP  BY table_name
              ORDER  BY 2 DESC
              FETCH FIRST 15 ROWS ONLY)
    LOOP
      p('  ' || RPAD(r.tn, 30) || LPAD(r.g, 9) || '  '
        || TO_CHAR(r.f, 'HH24:MI:SS') || '   ' || TO_CHAR(r.l, 'HH24:MI:SS'));
    END LOOP;
  EXCEPTION WHEN OTHERS THEN
    p('  failed: ' || SUBSTR(SQLERRM, 1, 60));
  END;

  p(' ');
  p('  Current statistics on the two tables that matter:');
  p('  ' || RPAD('TABLE', 26) || LPAD('NUM_ROWS', 14) || LPAD('SAMPLE_SIZE', 14)
    || '  LAST_ANALYZED');
  BEGIN
    FOR r IN (SELECT table_name tn, num_rows nr, sample_size ss, last_analyzed la
              FROM   dba_tab_statistics
              WHERE  owner = 'SYSADM' AND object_type = 'TABLE'
              AND    table_name IN ('PS_COMBO_DATA_TBL', 'PS_COMBO_DATA_BUDG')
              ORDER  BY table_name)
    LOOP
      p('  ' || RPAD(r.tn, 26) || LPAD(NVL(TO_CHAR(r.nr), 'null'), 14)
        || LPAD(NVL(TO_CHAR(r.ss), 'null'), 14) || '  '
        || NVL(TO_CHAR(r.la, 'YYYY-MM-DD HH24:MI:SS'), 'never'));
    END LOOP;
    p(' ');
    p('  SAMPLE_SIZE much smaller than NUM_ROWS means the 1 percent sample');
    p('  is being used. Roughly equal means it is still full scanning.');
  EXCEPTION WHEN OTHERS THEN
    p('  failed: ' || SUBSTR(SQLERRM, 1, 60));
  END;

  -- ==================================================================
  hdr('F - LONG OPERATIONS, TEMP, BLOCKING');
  -- ==================================================================
  BEGIN
    FOR r IN (SELECT inst_id i, sid sd, opname op, target tg, sofar sf,
                     totalwork tw, elapsed_seconds es, time_remaining tr
              FROM   gv$session_longops
              WHERE  totalwork > 0 AND sofar < totalwork
              ORDER  BY elapsed_seconds DESC
              FETCH FIRST 8 ROWS ONLY)
    LOOP
      p('  longop inst=' || r.i || ' sid=' || r.sd || '  ' || clean(r.op, 30)
        || '  ' || clean(r.tg, 30) || '  '
        || ROUND(r.sf / NULLIF(r.tw, 0) * 100, 1) || '%  elapsed=' || r.es
        || 's  remaining=' || NVL(TO_CHAR(r.tr), '?') || 's');
    END LOOP;
  EXCEPTION WHEN OTHERS THEN NULL;
  END;

  BEGIN
    FOR r IN (SELECT s.inst_id i, s.sid sd, s.event ev, s.seconds_in_wait sw,
                     s.blocking_instance bi, s.blocking_session bs
              FROM   gv$session s
              WHERE  s.blocking_session IS NOT NULL
              ORDER  BY s.seconds_in_wait DESC
              FETCH FIRST 8 ROWS ONLY)
    LOOP
      p('  BLOCKED inst=' || r.i || ' sid=' || r.sd || '  ' || clean(r.ev, 34)
        || '  ' || r.sw || 's  blocker=' || r.bi || ':' || r.bs);
    END LOOP;
  EXCEPTION WHEN OTHERS THEN NULL;
  END;

  BEGIN
    FOR r IN (SELECT inst_id i, ROUND(MAX(temp_space_allocated)/1073741824, 2) tg,
                     ROUND(MAX(pga_allocated)/1073741824, 2) pg
              FROM   gv$active_session_history
              WHERE  sample_time > SYSTIMESTAMP - INTERVAL '15' MINUTE
              AND    (UPPER(client_id) LIKE '%' || UPPER(v_oprid) || '%'
                      OR UPPER(program) LIKE '%PSAE%')
              GROUP  BY inst_id)
    LOOP
      p('  inst ' || r.i || '  peak temp=' || NVL(TO_CHAR(r.tg), '0')
        || ' GB   peak pga=' || NVL(TO_CHAR(r.pg), '0') || ' GB');
    END LOOP;
  EXCEPTION WHEN OTHERS THEN NULL;
  END;

  p(RPAD('=', 128, '='));
  p('END PULSE   elapsed=' || NVL(TO_CHAR(v_mins), '?') || ' min   target='
    || c_baseline_good || ' min   lines=' || (v_line + 1));
END;
/

SET HEADING ON
SET FEEDBACK ON
SET PAGESIZE 5000

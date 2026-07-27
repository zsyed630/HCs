-- =====================================================================
-- fs_cebd_digest.sql
-- Emits a compact fixed-width digest, roughly 50 lines at LINESIZE 100,
-- sized to be photographed and still legible.
-- Read-only. No input. Resolves the latest FS_CEBD run by itself.
-- Run in FSQUA, FSTRN and FPRD. Section 6 is the cross-environment diff.
-- =====================================================================

SET LINESIZE 100
SET PAGESIZE 0
SET HEADING OFF
SET FEEDBACK OFF
SET VERIFY OFF
SET TRIMSPOOL ON
SET TRIMOUT ON
SET SQLBLANKLINES ON
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
SET DEFINE '~'

SPOOL fs_cebd_digest.log

DECLARE
  v_line    PLS_INTEGER := 0;
  v_db      VARCHAR2(30);
  v_inst    PLS_INTEGER;
  v_tools   VARCHAR2(30) := 'n/a';

  v_pi      NUMBER;
  v_oprid   VARCHAR2(64);
  v_stat    VARCHAR2(30);
  v_beg     DATE;
  v_end     DATE;
  v_mins    NUMBER;

  v_tot     NUMBER := 0;
  v_cpu     NUMBER := 0;
  v_io      NUMBER := 0;
  v_conc    NUMBER := 0;
  v_appl    NUMBER := 0;
  v_clus    NUMBER := 0;
  v_hp      NUMBER := 0;
  v_ps      NUMBER := 0;
  v_ex      NUMBER := 0;
  v_ids     NUMBER := 0;
  v_sigs    NUMBER := 0;

  v_pat     NUMBER := 0;
  v_bound   NUMBER := 0;
  v_prof    NUMBER := 0;
  v_base    NUMBER := 0;
  v_lock    NUMBER := 0;
  v_fake    NUMBER := 0;
  v_deg1    NUMBER := 0;
  v_nostat  NUMBER := 0;

  v_keyexpr VARCHAR2(4000);
  v_longcol VARCHAR2(128);
  v_key     VARCHAR2(400);
  v_txt     VARCHAR2(32760);
  v_n       PLS_INTEGER;

  PROCEDURE p(s IN VARCHAR2) IS
  BEGIN
    v_line := v_line + 1;
    DBMS_OUTPUT.PUT_LINE(s);
  END p;

  FUNCTION pct(a IN NUMBER, b IN NUMBER) RETURN VARCHAR2 IS
  BEGIN
    IF NVL(b, 0) = 0 THEN RETURN '0%'; END IF;
    RETURN TO_CHAR(ROUND(a * 100 / b)) || '%';
  END pct;

  FUNCTION clean(s IN VARCHAR2, n IN PLS_INTEGER) RETURN VARCHAR2 IS
  BEGIN
    RETURN SUBSTR(REPLACE(REPLACE(REPLACE(NVL(s, ' '), CHR(10), ' '),
                                  CHR(13), ' '), CHR(9), ' '), 1, n);
  END clean;

BEGIN
  ------------------------------------------------------------------ header
  SELECT d.name, i.instance_number INTO v_db, v_inst
  FROM   v$database d CROSS JOIN v$instance i;

  BEGIN
    EXECUTE IMMEDIATE 'SELECT TOOLSREL FROM SYSADM.PSSTATUS WHERE ROWNUM=1' INTO v_tools;
  EXCEPTION WHEN OTHERS THEN v_tools := 'n/a';
  END;

  p(RPAD('=', 100, '='));
  p('FS_CEBD DIGEST   db=' || v_db || '  inst=' || v_inst
    || '  tools=' || v_tools || '  at=' || TO_CHAR(SYSDATE, 'MM-DD HH24:MI:SS'));
  p(RPAD('=', 100, '='));

  ------------------------------------------------------------------ [1] run
  BEGIN
    SELECT PRCSINSTANCE, OPRID, RUNSTATUS, BEGINDTTM, ENDDTTM
    INTO   v_pi, v_oprid, v_stat, v_beg, v_end
    FROM  (SELECT PRCSINSTANCE, OPRID, RUNSTATUS, BEGINDTTM, ENDDTTM
           FROM   SYSADM.PSPRCSRQST
           WHERE  PRCSNAME = 'FS_CEBD' AND BEGINDTTM IS NOT NULL
           ORDER  BY BEGINDTTM DESC)
    WHERE ROWNUM = 1;
    v_mins := ROUND((NVL(v_end, SYSDATE) - v_beg) * 1440, 1);
  EXCEPTION WHEN OTHERS THEN
    v_pi := NULL; v_oprid := 'NONE'; v_beg := SYSDATE - 1; v_mins := 0;
  END;

  p('[1] RUN');
  p('  pi=' || NVL(TO_CHAR(v_pi), 'none') || '  oprid=' || v_oprid
    || '  status=' || NVL(v_stat, '?') || '  mins=' || NVL(TO_CHAR(v_mins), '?'));
  p('  beg=' || TO_CHAR(v_beg, 'MM-DD HH24:MI:SS')
    || '  end=' || NVL(TO_CHAR(v_end, 'MM-DD HH24:MI:SS'), 'RUNNING'));

  ------------------------------------------------------------------ [2] ash
  BEGIN
    SELECT COUNT(*),
           SUM(CASE WHEN session_state = 'ON CPU' THEN 1 ELSE 0 END),
           SUM(CASE WHEN session_state <> 'ON CPU' AND wait_class = 'User I/O'     THEN 1 ELSE 0 END),
           SUM(CASE WHEN session_state <> 'ON CPU' AND wait_class = 'Concurrency'  THEN 1 ELSE 0 END),
           SUM(CASE WHEN session_state <> 'ON CPU' AND wait_class = 'Application'  THEN 1 ELSE 0 END),
           SUM(CASE WHEN session_state <> 'ON CPU' AND wait_class = 'Cluster'      THEN 1 ELSE 0 END),
           SUM(CASE WHEN in_hard_parse    = 'Y' THEN 1 ELSE 0 END),
           SUM(CASE WHEN in_parse         = 'Y' THEN 1 ELSE 0 END),
           SUM(CASE WHEN in_sql_execution = 'Y' THEN 1 ELSE 0 END),
           COUNT(DISTINCT sql_id),
           COUNT(DISTINCT force_matching_signature)
    INTO   v_tot, v_cpu, v_io, v_conc, v_appl, v_clus, v_hp, v_ps, v_ex, v_ids, v_sigs
    FROM   gv$active_session_history
    WHERE  sample_time >= CAST(v_beg AS TIMESTAMP)
    AND    sample_time <= CAST(NVL(v_end, SYSDATE) AS TIMESTAMP) + INTERVAL '2' MINUTE
    AND    (UPPER(client_id) LIKE '%' || UPPER(v_oprid) || '%'
            OR UPPER(program) LIKE '%PSAE%');
  EXCEPTION WHEN OTHERS THEN v_tot := 0;
  END;

  p('[2] ASH db-seconds');
  p('  total=' || v_tot
    || '  cpu=' || v_cpu || '(' || pct(v_cpu, v_tot) || ')'
    || '  io=' || v_io || '(' || pct(v_io, v_tot) || ')'
    || '  conc=' || v_conc || '(' || pct(v_conc, v_tot) || ')');
  p('  appl=' || v_appl || '  clus=' || v_clus
    || '  hardparse=' || v_hp || '(' || pct(v_hp, v_tot) || ')'
    || '  parse=' || v_ps || '  exec=' || v_ex);
  p('  sql_ids=' || v_ids || '  signatures=' || v_sigs
    || '  literal_churn=' || ROUND(v_ids / GREATEST(NVL(v_sigs, 1), 1), 1) || 'x');

  ------------------------------------------------------------------ [3] sigs
  p('[3] TOP SIGNATURES     secs  vars plans  sql');
  v_n := 0;
  BEGIN
    FOR r IN (SELECT * FROM (
                SELECT a.force_matching_signature fms,
                       COUNT(*) secs,
                       COUNT(DISTINCT a.sql_id) vars,
                       COUNT(DISTINCT a.sql_plan_hash_value) plans,
                       MAX(a.sql_id) KEEP (DENSE_RANK FIRST ORDER BY a.sample_time DESC) sid
                FROM   gv$active_session_history a
                WHERE  a.sample_time >= CAST(v_beg AS TIMESTAMP)
                AND    a.sql_id IS NOT NULL
                AND    (UPPER(a.client_id) LIKE '%' || UPPER(v_oprid) || '%'
                        OR UPPER(a.program) LIKE '%PSAE%')
                GROUP  BY a.force_matching_signature
                ORDER  BY 2 DESC)
              WHERE ROWNUM <= 6)
    LOOP
      v_n := v_n + 1;
      v_txt := NULL;
      BEGIN
        SELECT DBMS_LOB.SUBSTR(q.sql_fulltext, 60, 1) INTO v_txt
        FROM   gv$sql q WHERE q.sql_id = r.sid AND ROWNUM = 1;
      EXCEPTION WHEN OTHERS THEN
        BEGIN
          SELECT DBMS_LOB.SUBSTR(t.sql_text, 60, 1) INTO v_txt
          FROM   dba_hist_sqltext t WHERE t.sql_id = r.sid AND ROWNUM = 1;
        EXCEPTION WHEN OTHERS THEN v_txt := NULL;
        END;
      END;
      p('  ' || RPAD(v_n, 3) || LPAD(r.secs, 8) || LPAD(r.vars, 6)
        || LPAD(r.plans, 6) || '  ' || RPAD(r.sid, 14) || clean(v_txt, 46));
    END LOOP;
  EXCEPTION WHEN OTHERS THEN
    p('  section failed: ' || SUBSTR(SQLERRM, 1, 70));
  END;
  IF v_n = 0 THEN p('  no ash rows matched'); END IF;

  ------------------------------------------------------------------ [4] events
  p('[4] TOP EVENTS');
  BEGIN
    FOR r IN (SELECT * FROM (
                SELECT CASE WHEN session_state = 'ON CPU' THEN 'ON CPU'
                            ELSE NVL(event, 'unknown') END ev,
                       COUNT(*) secs
                FROM   gv$active_session_history
                WHERE  sample_time >= CAST(v_beg AS TIMESTAMP)
                AND    (UPPER(client_id) LIKE '%' || UPPER(v_oprid) || '%'
                        OR UPPER(program) LIKE '%PSAE%')
                GROUP  BY CASE WHEN session_state = 'ON CPU' THEN 'ON CPU'
                               ELSE NVL(event, 'unknown') END
                ORDER  BY 2 DESC)
              WHERE ROWNUM <= 6)
    LOOP
      p('  ' || RPAD(clean(r.ev, 46), 48) || LPAD(r.secs, 8)
        || '  ' || pct(r.secs, v_tot));
    END LOOP;
  EXCEPTION WHEN OTHERS THEN
    p('  section failed: ' || SUBSTR(SQLERRM, 1, 70));
  END;

  ------------------------------------------------------------------ [5] contam
  BEGIN SELECT COUNT(*) INTO v_pat  FROM dba_sql_patches;        EXCEPTION WHEN OTHERS THEN v_pat := -1; END;
  BEGIN SELECT COUNT(DISTINCT sql_patch) INTO v_bound FROM gv$sql WHERE sql_patch IS NOT NULL; EXCEPTION WHEN OTHERS THEN v_bound := -1; END;
  BEGIN SELECT COUNT(*) INTO v_prof FROM dba_sql_profiles;       EXCEPTION WHEN OTHERS THEN v_prof := -1; END;
  BEGIN SELECT COUNT(*) INTO v_base FROM dba_sql_plan_baselines; EXCEPTION WHEN OTHERS THEN v_base := -1; END;

  SELECT COUNT(CASE WHEN stattype_locked IS NOT NULL THEN 1 END),
         COUNT(CASE WHEN num_rows = 1000000 AND blocks = 25000 THEN 1 END),
         COUNT(CASE WHEN num_rows IS NULL THEN 1 END)
  INTO   v_lock, v_fake, v_nostat
  FROM   dba_tab_statistics
  WHERE  owner = 'SYSADM' AND object_type = 'TABLE'
  AND    (table_name LIKE 'PS_FS_CEBD%' OR table_name LIKE 'PS_COMBO_DATA%');

  SELECT COUNT(*) INTO v_deg1 FROM (
    SELECT degree FROM dba_tables
     WHERE owner = 'SYSADM'
       AND (table_name LIKE 'PS_COMBO_DATA%' OR table_name LIKE 'PS_FS_CEBD%')
    UNION ALL
    SELECT degree FROM dba_indexes
     WHERE owner = 'SYSADM'
       AND (table_name LIKE 'PS_COMBO_DATA%' OR table_name LIKE 'PS_FS_CEBD%'))
  WHERE TRIM(degree) = '1';

  p('[5] CONTAMINATION');
  p('  sql_patches=' || v_pat || '  bound_to_cursor=' || v_bound
    || '  profiles=' || v_prof || '  baselines=' || v_base);
  p('  locked_stats=' || v_lock || '  fake_1m_stats=' || v_fake
    || '  no_stats=' || v_nostat || '  degree1_objects=' || v_deg1);

  ------------------------------------------------------------------ [6] ddl
  p('[6] DDL MODELS - source of percent-UpdateStats');
  BEGIN
    SELECT LISTAGG('TO_CHAR(' || column_name || ')', ' ||''/''|| ')
             WITHIN GROUP (ORDER BY column_id)
    INTO   v_keyexpr
    FROM   dba_tab_columns
    WHERE  owner = 'SYSADM' AND table_name = 'PSDDLMODEL'
    AND    data_type NOT IN ('LONG', 'LONG RAW', 'CLOB', 'BLOB');

    SELECT MIN(column_name) INTO v_longcol
    FROM   dba_tab_columns
    WHERE  owner = 'SYSADM' AND table_name = 'PSDDLMODEL'
    AND    data_type IN ('LONG', 'CLOB');

    IF v_longcol IS NULL THEN
      p('  no LONG column found on PSDDLMODEL - dump it manually');
    ELSE
      FOR r IN (SELECT ROWID rid FROM SYSADM.PSDDLMODEL) LOOP
        BEGIN
          EXECUTE IMMEDIATE
            'SELECT ' || v_keyexpr || ', ' || v_longcol
            || ' FROM SYSADM.PSDDLMODEL WHERE ROWID = :1'
            INTO v_key, v_txt USING r.rid;

          IF UPPER(v_txt) LIKE '%STATS%' OR UPPER(v_txt) LIKE '%ANALYZE%' THEN
            p('  key=' || clean(v_key, 40) || '  len=' || LENGTH(v_txt));
            p('    ' || clean(v_txt, 94));
            IF LENGTH(v_txt) > 94 THEN
              p('    ' || clean(SUBSTR(v_txt, 95), 94));
            END IF;
            IF LENGTH(v_txt) > 188 THEN
              p('    ' || clean(SUBSTR(v_txt, 189), 94));
            END IF;
          END IF;
        EXCEPTION WHEN OTHERS THEN
          p('  row read failed: ' || SUBSTR(SQLERRM, 1, 60));
        END;
      END LOOP;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    p('  section failed: ' || SUBSTR(SQLERRM, 1, 70));
  END;

  ------------------------------------------------------------------ [7] verdict
  p('[7] VERDICT');
  IF v_tot = 0 THEN
    p('  NO ASH - session correlation failed, oprid=' || v_oprid);
  END IF;
  IF v_fake > 0 OR v_lock > 0 OR v_deg1 > 0 OR NVL(v_bound, 0) > 0 THEN
    p('  CONTAMINATED - this runtime is not a valid reproduction');
  END IF;
  IF v_pat > 0 AND NVL(v_bound, 0) = 0 THEN
    p('  ' || v_pat || ' patches exist, none bound to a cursor - inert');
  END IF;
  IF v_tot > 0 AND v_hp / GREATEST(v_tot, 1) > 0.25 THEN
    p('  PARSE STORM - hard parse ' || pct(v_hp, v_tot) || ' of db time');
  END IF;
  IF v_tot > 0 AND v_io / GREATEST(v_tot, 1) > 0.40 THEN
    p('  IO BOUND - user io ' || pct(v_io, v_tot) || ' of db time');
  END IF;
  IF v_tot > 0 AND v_conc / GREATEST(v_tot, 1) > 0.20 THEN
    p('  CONCURRENCY - ' || pct(v_conc, v_tot) || ' of db time');
  END IF;
  IF v_sigs > 0 AND v_ids / GREATEST(v_sigs, 1) > 20 THEN
    p('  LITERALS - ' || ROUND(v_ids / GREATEST(v_sigs, 1), 1)
      || ' sql_ids per signature, only force-match profiles will bind');
  END IF;

  p(RPAD('=', 100, '='));
  p('END OF DIGEST   db=' || v_db || '   lines=' || (v_line + 1));
END;
/

SPOOL OFF

SET DEFINE ON
SET HEADING ON
SET FEEDBACK ON
SET PAGESIZE 5000

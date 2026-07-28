-- =====================================================================
--  fprd_validate.sql
--
--  Thorough post-change validation of FPRD after the four DBMS_STATS
--  table preferences were applied to SYSADM.PS_COMBO_DATA_TBL.
--
--  Read only. No input. Safe to run any time.
--
--  Two jobs:
--    1. confirm the change is in place and complete
--    2. confirm NOTHING ELSE moved, by comparing against the values
--       captured from FPRD before the change on 2026-07-27
--
--  The second job matters because the script that applied the change was
--  built for the QA clone and had its database guard switched off. It
--  reported taking no other action. This verifies that independently
--  rather than trusting the log.
--
--  Baseline captured from FPRD 2026-07-27 16:19 (pre-change):
--    sql patches                  1     (PATCH_INC2680517)
--    sql profiles                46
--    sql plan baselines           4
--    locked statistics            0
--    PS_COMBO_DATA_TBL     17,524,884 rows   801,418 blocks
--    PS_COMBO_DATA_BUDG    22,969,537 rows   419,070 blocks
--    TABLE PS_COMBO_DATA_TBL      degree 4
--    TABLE PS_COMBO_DATA_BDP      degree 1
--    TABLE PS_COMBO_DATA_BUDG     degree 1
--    TABLE PS_COMBO_DATA_S        degree 1
--    TABLE PS_FS_CEBD_TAO..TAO9   degree 1
--    INDEX PSACOMBO_DATA_TBL      DEFAULT
--    INDEX PSACOMBO_DATA_BUDG     DEFAULT
--    INDEX PSBCOMBO_DATA_TBL      1
--    INDEX PS_COMBO_DATA_BDP      DEFAULT
--    INDEX PS_COMBO_DATA_BUDG     DEFAULT
--    INDEX PS_COMBO_DATA_S        DEFAULT
--    INDEX PS_COMBO_DATA_TBL      DEFAULT
-- =====================================================================

SET DEFINE OFF
SET LINESIZE 128
SET PAGESIZE 0
SET HEADING OFF
SET FEEDBACK OFF
SET VERIFY OFF
SET TRIMSPOOL ON
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED

SPOOL fprd_validate.log

DECLARE
  c_tab CONSTANT VARCHAR2(30) := 'PS_COMBO_DATA_TBL';

  v_db    VARCHAR2(30);
  v_line  PLS_INTEGER := 0;
  v_bad   PLS_INTEGER := 0;
  v_warn  PLS_INTEGER := 0;
  v_n     NUMBER;
  v_s     VARCHAR2(200);

  PROCEDURE p(s IN VARCHAR2) IS
  BEGIN
    v_line := v_line + 1;
    DBMS_OUTPUT.PUT_LINE(s);
  END p;

  PROCEDURE hdr(s IN VARCHAR2) IS
  BEGIN
    p(' ');
    p(RPAD('=', 126, '='));
    p(s);
    p(RPAD('=', 126, '='));
  END hdr;

  PROCEDURE ok(label IN VARCHAR2, val IN VARCHAR2, good IN BOOLEAN) IS
  BEGIN
    IF NOT good THEN v_bad := v_bad + 1; END IF;
    p('  ' || RPAD(label, 50) || RPAD(SUBSTR(val, 1, 36), 38)
      || CASE WHEN good THEN 'OK' ELSE '** CHECK **' END);
  END ok;

  PROCEDURE note(label IN VARCHAR2, val IN VARCHAR2, expected IN VARCHAR2) IS
  BEGIN
    IF NVL(val, 'x') <> NVL(expected, 'x') THEN v_warn := v_warn + 1; END IF;
    p('  ' || RPAD(label, 50) || RPAD(SUBSTR(val, 1, 20), 22)
      || RPAD(SUBSTR(expected, 1, 20), 22)
      || CASE WHEN NVL(val,'x') = NVL(expected,'x') THEN 'same'
              ELSE '** DRIFT **' END);
  END note;

  FUNCTION clean(s IN VARCHAR2, n IN PLS_INTEGER) RETURN VARCHAR2 IS
  BEGIN
    RETURN SUBSTR(REPLACE(REPLACE(NVL(s,' '), CHR(10), ' '), CHR(13), ' '), 1, n);
  END clean;

BEGIN
  SELECT UPPER(name) INTO v_db FROM v$database;
  p(RPAD('=', 126, '='));
  p('FPRD POST-CHANGE VALIDATION   db=' || v_db
    || '   at=' || TO_CHAR(SYSDATE, 'YYYY-MM-DD HH24:MI:SS')
    || '   user=' || USER);
  p(RPAD('=', 126, '='));

  IF v_db NOT LIKE 'FPRD%' THEN
    p('  NOTE: this is ' || v_db || ', not FPRD. The baseline comparisons');
    p('  below are FPRD values and will not be meaningful here.');
  END IF;

  -- ==================================================================
  hdr('1 - THE CHANGE: FOUR PREFERENCES ON ' || c_tab);
  -- ==================================================================
  p('  ' || RPAD('CHECK', 50) || RPAD('VALUE', 38) || 'STATUS');
  p('  ' || RPAD('-', 122, '-'));
  DECLARE
    v_ep VARCHAR2(200); v_epn NUMBER;
  BEGIN
    v_ep := DBMS_STATS.GET_PREFS('ESTIMATE_PERCENT', 'SYSADM', c_tab);
    BEGIN v_epn := TO_NUMBER(v_ep); EXCEPTION WHEN OTHERS THEN v_epn := NULL; END;
    ok('ESTIMATE_PERCENT  (numeric compare)', v_ep, v_epn = 1);
  EXCEPTION WHEN OTHERS THEN ok('ESTIMATE_PERCENT','unreadable',FALSE);
  END;
  BEGIN
    v_s := DBMS_STATS.GET_PREFS('METHOD_OPT', 'SYSADM', c_tab);
    ok('METHOD_OPT', v_s, v_s = 'FOR ALL INDEXED COLUMNS SIZE 1');
  EXCEPTION WHEN OTHERS THEN ok('METHOD_OPT','unreadable',FALSE);
  END;
  BEGIN
    v_s := DBMS_STATS.GET_PREFS('CASCADE', 'SYSADM', c_tab);
    ok('CASCADE  (must be TRUE, site default is FALSE)', v_s, UPPER(v_s) = 'TRUE');
  EXCEPTION WHEN OTHERS THEN ok('CASCADE','unreadable',FALSE);
  END;
  BEGIN
    v_s := DBMS_STATS.GET_PREFS('PREFERENCE_OVERRIDES_PARAMETER', 'SYSADM', c_tab);
    ok('PREFERENCE_OVERRIDES_PARAMETER', v_s, UPPER(v_s) = 'TRUE');
  EXCEPTION WHEN OTHERS THEN ok('PREFERENCE_OVERRIDES_PARAMETER','unreadable',FALSE);
  END;
  BEGIN
    v_s := DBMS_STATS.GET_PREFS('DEGREE', 'SYSADM', c_tab);
    p('  ' || RPAD('DEGREE preference (informational)', 50)
      || RPAD(NVL(v_s,'NULL'), 38)
      || CASE WHEN v_s IS NULL THEN 'uses table attribute' ELSE 'overrides table' END);
  EXCEPTION WHEN OTHERS THEN NULL;
  END;
  BEGIN
    v_s := DBMS_STATS.GET_PREFS('NO_INVALIDATE', 'SYSADM', c_tab);
    p('  ' || RPAD('NO_INVALIDATE (informational)', 50) || clean(v_s, 38));
  EXCEPTION WHEN OTHERS THEN NULL;
  END;

  -- ==================================================================
  hdr('2 - EVERY TABLE-LEVEL PREFERENCE IN SYSADM');
  -- ==================================================================
  p('  Only PS_COMBO_DATA_TBL should appear. Anything else was set by');
  p('  someone else, or by a script that reached further than intended.');
  p(' ');
  p('  ' || RPAD('TABLE', 30) || RPAD('PREFERENCE', 36) || 'VALUE');
  v_n := 0;
  BEGIN
    FOR r IN (SELECT table_name tn, preference_name pn, preference_value pv
              FROM   dba_tab_stat_prefs
              WHERE  owner = 'SYSADM'
              ORDER  BY table_name, preference_name)
    LOOP
      v_n := v_n + 1;
      p('  ' || RPAD(r.tn, 30) || RPAD(r.pn, 36) || clean(r.pv, 40));
    END LOOP;
    IF v_n = 0 THEN p('  none found'); END IF;
    p(' ');
    IF v_n = 4 THEN
      p('  4 rows, all on ' || c_tab || '. Exactly as intended.');
    ELSE
      v_warn := v_warn + 1;
      p('  ' || v_n || ' rows. Expected 4. Review the list above.');
    END IF;
  EXCEPTION WHEN OTHERS THEN
    p('  dba_tab_stat_prefs unreadable: ' || SUBSTR(SQLERRM,1,60));
  END;

  -- ==================================================================
  hdr('3 - GLOBAL DBMS_STATS PREFERENCES  (must be unchanged)');
  -- ==================================================================
  p('  The change was table-scoped. None of these should have moved.');
  p(' ');
  BEGIN
    p('  ESTIMATE_PERCENT               = ' || DBMS_STATS.GET_PREFS('ESTIMATE_PERCENT'));
    p('  METHOD_OPT                     = ' || DBMS_STATS.GET_PREFS('METHOD_OPT'));
    p('  CASCADE                        = ' || DBMS_STATS.GET_PREFS('CASCADE'));
    p('  DEGREE                         = ' || DBMS_STATS.GET_PREFS('DEGREE'));
    p('  NO_INVALIDATE                  = ' || DBMS_STATS.GET_PREFS('NO_INVALIDATE'));
    p('  PREFERENCE_OVERRIDES_PARAMETER = '
      || DBMS_STATS.GET_PREFS('PREFERENCE_OVERRIDES_PARAMETER'));
    p('  STALE_PERCENT                  = ' || DBMS_STATS.GET_PREFS('STALE_PERCENT'));
    p('  INCREMENTAL                    = ' || DBMS_STATS.GET_PREFS('INCREMENTAL'));
    p(' ');
    p('  Expected: METHOD_OPT FOR ALL COLUMNS SIZE 1, CASCADE FALSE,');
    p('  PREFERENCE_OVERRIDES_PARAMETER FALSE. Those are the site values');
    p('  observed before the change.');
  EXCEPTION WHEN OTHERS THEN
    p('  failed: ' || SUBSTR(SQLERRM,1,60));
  END;

  -- ==================================================================
  hdr('4 - PARALLELISM: EVERY OBJECT IN THE FS_CEBD PATH');
  -- ==================================================================
  p('  ' || RPAD('OBJECT', 50) || RPAD('NOW', 22) || RPAD('BEFORE', 22) || 'RESULT');
  p('  ' || RPAD('-', 122, '-'));

  DECLARE
    TYPE t_nm IS TABLE OF VARCHAR2(40) INDEX BY VARCHAR2(40);
    l_exp t_nm;
    v_d   VARCHAR2(40);
  BEGIN
    l_exp('TABLE PS_COMBO_DATA_TBL')  := '4';
    l_exp('TABLE PS_COMBO_DATA_BDP')  := '1';
    l_exp('TABLE PS_COMBO_DATA_BUDG') := '1';
    l_exp('TABLE PS_COMBO_DATA_S')    := '1';
    l_exp('INDEX PSACOMBO_DATA_TBL')  := 'DEFAULT';
    l_exp('INDEX PSACOMBO_DATA_BUDG') := 'DEFAULT';
    l_exp('INDEX PSBCOMBO_DATA_TBL')  := '1';
    l_exp('INDEX PS_COMBO_DATA_BDP')  := 'DEFAULT';
    l_exp('INDEX PS_COMBO_DATA_BUDG') := 'DEFAULT';
    l_exp('INDEX PS_COMBO_DATA_S')    := 'DEFAULT';
    l_exp('INDEX PS_COMBO_DATA_TBL')  := 'DEFAULT';

    FOR r IN (SELECT 'TABLE' k, table_name o, TRIM(degree) d FROM dba_tables
              WHERE owner='SYSADM'
                AND (table_name LIKE 'PS_COMBO_DATA%' OR table_name LIKE 'PS_FS_CEBD%')
              UNION ALL
              SELECT 'INDEX', index_name, TRIM(degree) FROM dba_indexes
              WHERE owner='SYSADM'
                AND (table_name LIKE 'PS_COMBO_DATA%' OR table_name LIKE 'PS_FS_CEBD%')
              ORDER BY 1, 2)
    LOOP
      v_s := r.k || ' ' || r.o;
      IF l_exp.EXISTS(v_s) THEN
        note(v_s, r.d, l_exp(v_s));
      ELSIF r.o LIKE 'PS_FS_CEBD_TAO%' AND r.k = 'TABLE' THEN
        note(v_s, r.d, '1');
      ELSE
        p('  ' || RPAD(v_s, 50) || RPAD(r.d, 22) || RPAD('not baselined', 22)
          || 'review');
      END IF;
    END LOOP;
  EXCEPTION WHEN OTHERS THEN
    p('  failed: ' || SUBSTR(SQLERRM,1,60));
  END;

  p(' ');
  p('  Parallelism matters here because the DEGREE preference is NULL, so');
  p('  DBMS_STATS inherits the object DEGREE. PS_COMBO_DATA_TBL at 4 is');
  p('  what makes the cascaded index gather run in parallel.');

  -- ==================================================================
  hdr('5 - STATISTICS STATE  (nothing should have been touched yet)');
  -- ==================================================================
  p('  ' || RPAD('TABLE', 26) || LPAD('NUM_ROWS', 13) || LPAD('BLOCKS', 10)
    || LPAD('SAMPLE', 13) || LPAD('PCT', 7) || '  ' || RPAD('LOCKED', 8)
    || RPAD('STALE', 7) || 'LAST_ANALYZED');
  BEGIN
    FOR r IN (SELECT table_name tn, num_rows nr, blocks bl, sample_size ss,
                     stattype_locked lk, stale_stats st, last_analyzed la
              FROM   dba_tab_statistics
              WHERE  owner='SYSADM' AND object_type='TABLE'
              AND    (table_name LIKE 'PS_COMBO_DATA%' OR table_name LIKE 'PS_FS_CEBD%')
              ORDER  BY table_name)
    LOOP
      p('  ' || RPAD(r.tn, 26) || LPAD(NVL(TO_CHAR(r.nr),'null'), 13)
        || LPAD(NVL(TO_CHAR(r.bl),'null'), 10)
        || LPAD(NVL(TO_CHAR(r.ss),'null'), 13)
        || LPAD(NVL(TO_CHAR(ROUND(r.ss/NULLIF(r.nr,0)*100,1)),'-'), 7) || '  '
        || RPAD(NVL(r.lk,'no'), 8) || RPAD(NVL(r.st,'-'), 7)
        || NVL(TO_CHAR(r.la,'YYYY-MM-DD HH24:MI'),'never'));
    END LOOP;
  EXCEPTION WHEN OTHERS THEN p('  failed: ' || SUBSTR(SQLERRM,1,60));
  END;

  p(' ');
  BEGIN
    SELECT num_rows INTO v_n FROM dba_tab_statistics
     WHERE owner='SYSADM' AND table_name='PS_COMBO_DATA_TBL' AND object_type='TABLE';
    note('PS_COMBO_DATA_TBL num_rows', TO_CHAR(v_n), '17524884');
  EXCEPTION WHEN OTHERS THEN NULL;
  END;
  BEGIN
    SELECT num_rows INTO v_n FROM dba_tab_statistics
     WHERE owner='SYSADM' AND table_name='PS_COMBO_DATA_BUDG' AND object_type='TABLE';
    note('PS_COMBO_DATA_BUDG num_rows', TO_CHAR(v_n), '22969537');
  EXCEPTION WHEN OTHERS THEN NULL;
  END;
  SELECT COUNT(*) INTO v_n FROM dba_tab_statistics
   WHERE owner='SYSADM' AND stattype_locked IS NOT NULL;
  note('locked statistics anywhere in SYSADM', TO_CHAR(v_n), '0');

  -- ==================================================================
  hdr('6 - INDEX HEALTH');
  -- ==================================================================
  p('  ' || RPAD('INDEX', 30) || RPAD('TABLE', 26) || RPAD('STATUS', 12)
    || RPAD('DEGREE', 10) || 'LAST_ANALYZED');
  BEGIN
    FOR r IN (SELECT index_name ix, table_name tb, status st,
                     TRIM(degree) dg, last_analyzed la
              FROM   dba_indexes
              WHERE  owner='SYSADM'
              AND    (table_name LIKE 'PS_COMBO_DATA%' OR table_name LIKE 'PS_FS_CEBD%')
              ORDER  BY table_name, index_name)
    LOOP
      IF r.st <> 'VALID' THEN v_bad := v_bad + 1; END IF;
      p('  ' || RPAD(r.ix, 30) || RPAD(r.tb, 26) || RPAD(r.st, 12)
        || RPAD(r.dg, 10) || NVL(TO_CHAR(r.la,'YYYY-MM-DD HH24:MI'),'never')
        || CASE WHEN r.st <> 'VALID' THEN '   ** NOT VALID **' ELSE '' END);
    END LOOP;
  EXCEPTION WHEN OTHERS THEN p('  failed: ' || SUBSTR(SQLERRM,1,60));
  END;

  -- ==================================================================
  hdr('7 - DID ANY DDL RUN AGAINST THESE OBJECTS');
  -- ==================================================================
  p('  Setting a table preference writes to the statistics dictionary, not');
  p('  the object definition, so LAST_DDL_TIME should NOT be today. If it');
  p('  is, an ALTER ran.');
  p(' ');
  p('  ' || RPAD('OBJECT', 30) || RPAD('TYPE', 8) || RPAD('CREATED', 20)
    || RPAD('LAST_DDL_TIME', 20) || 'TODAY');
  BEGIN
    FOR r IN (SELECT object_name o, object_type t, created c, last_ddl_time l
              FROM   dba_objects
              WHERE  owner='SYSADM'
              AND    object_type IN ('TABLE','INDEX')
              AND    (object_name LIKE 'PS_COMBO_DATA%' OR object_name LIKE 'PS_FS_CEBD%'
                      OR object_name LIKE 'PSACOMBO%' OR object_name LIKE 'PSBCOMBO%')
              ORDER  BY last_ddl_time DESC FETCH FIRST 20 ROWS ONLY)
    LOOP
      p('  ' || RPAD(r.o, 30) || RPAD(r.t, 8)
        || RPAD(TO_CHAR(r.c,'YYYY-MM-DD HH24:MI'), 20)
        || RPAD(TO_CHAR(r.l,'YYYY-MM-DD HH24:MI'), 20)
        || CASE WHEN TRUNC(r.l) = TRUNC(SYSDATE) THEN '** YES **' ELSE 'no' END);
    END LOOP;
  EXCEPTION WHEN OTHERS THEN p('  failed: ' || SUBSTR(SQLERRM,1,60));
  END;

  -- ==================================================================
  hdr('8 - PATCHES, PROFILES, BASELINES');
  -- ==================================================================
  SELECT COUNT(*) INTO v_n FROM dba_sql_patches;
  note('sql patches', TO_CHAR(v_n), '1');
  SELECT COUNT(*) INTO v_n FROM dba_sql_patches WHERE name LIKE 'PATCH_CEBD%';
  ok('PATCH_CEBD patches (must be none)', TO_CHAR(v_n), v_n = 0);
  SELECT COUNT(*) INTO v_n FROM dba_sql_profiles;
  note('sql profiles', TO_CHAR(v_n), '46');
  SELECT COUNT(*) INTO v_n FROM dba_sql_plan_baselines;
  note('sql plan baselines', TO_CHAR(v_n), '4');
  SELECT COUNT(DISTINCT sql_patch) INTO v_n FROM gv$sql WHERE sql_patch IS NOT NULL;
  ok('patches bound to a cursor', TO_CHAR(v_n), v_n = 0);

  p(' ');
  p('  Patches present:');
  FOR r IN (SELECT name nm, status st, created cr FROM dba_sql_patches ORDER BY created)
  LOOP
    p('    ' || RPAD(r.nm, 32) || RPAD(r.st, 10)
      || TO_CHAR(r.cr, 'YYYY-MM-DD HH24:MI:SS'));
  END LOOP;

  -- ==================================================================
  hdr('9 - PSDDLMODEL  (we never touched it - confirm)');
  -- ==================================================================
  DECLARE
    v_key VARCHAR2(400); v_txt VARCHAR2(32760);
    v_keyexpr VARCHAR2(4000); v_longcol VARCHAR2(128);
  BEGIN
    SELECT LISTAGG('TO_CHAR(' || column_name || ')', ' ||''/''|| ')
             WITHIN GROUP (ORDER BY column_id)
    INTO   v_keyexpr FROM dba_tab_columns
    WHERE  owner='SYSADM' AND table_name='PSDDLMODEL'
    AND    data_type NOT IN ('LONG','LONG RAW','CLOB','BLOB');
    SELECT MIN(column_name) INTO v_longcol FROM dba_tab_columns
    WHERE  owner='SYSADM' AND table_name='PSDDLMODEL'
    AND    data_type IN ('LONG','CLOB');

    FOR r IN (SELECT ROWID rid FROM SYSADM.PSDDLMODEL) LOOP
      BEGIN
        EXECUTE IMMEDIATE 'SELECT ' || v_keyexpr || ', ' || v_longcol
          || ' FROM SYSADM.PSDDLMODEL WHERE ROWID = :1'
          INTO v_key, v_txt USING r.rid;
        IF UPPER(v_txt) LIKE '%STATS%' OR UPPER(v_txt) LIKE '%ANALYZE%' THEN
          p('  key=' || RPAD(clean(v_key,20),22) || ' len=' || NVL(LENGTH(v_txt),0));
          p('      ' || clean(v_txt, 116));
          IF LENGTH(v_txt) > 116 THEN
            p('      ' || clean(SUBSTR(v_txt,117), 116));
          END IF;
        END IF;
      EXCEPTION WHEN OTHERS THEN NULL;
      END;
    END LOOP;
    p(' ');
    p('  Expected: still the delivered 8.62 model with AUTO_SAMPLE_SIZE and');
    p('  no method_opt. The preferences override it at runtime; the model');
    p('  itself is deliberately left alone so a PeopleTools upgrade cannot');
    p('  conflict with the fix.');
  EXCEPTION WHEN OTHERS THEN
    p('  failed: ' || SUBSTR(SQLERRM,1,60));
  END;

  -- ==================================================================
  hdr('10 - HAS ANY GATHER RUN SINCE THE CHANGE');
  -- ==================================================================
  p('  Nothing takes effect until the next percent-UpdateStats. If no rows');
  p('  appear here, the change is staged but unproven in this database.');
  p(' ');
  p('  ' || RPAD('TABLE', 30) || LPAD('GATHERS', 9) || '  FIRST                LAST');
  v_n := 0;
  BEGIN
    FOR r IN (SELECT table_name tn, COUNT(*) g,
                     MIN(stats_update_time) f, MAX(stats_update_time) l
              FROM   dba_tab_stats_history
              WHERE  owner='SYSADM'
              AND    (table_name LIKE 'PS_COMBO_DATA%' OR table_name LIKE 'PS_FS_CEBD%')
              AND    stats_update_time > SYSTIMESTAMP - INTERVAL '2' DAY
              GROUP  BY table_name ORDER BY 2 DESC)
    LOOP
      v_n := v_n + 1;
      p('  ' || RPAD(r.tn,30) || LPAD(r.g,9) || '  '
        || TO_CHAR(r.f,'MM-DD HH24:MI:SS') || '     '
        || TO_CHAR(r.l,'MM-DD HH24:MI:SS'));
    END LOOP;
    IF v_n = 0 THEN
      p('  none in the last 2 days. Change is staged, not yet exercised.');
    END IF;
  EXCEPTION WHEN OTHERS THEN p('  failed: ' || SUBSTR(SQLERRM,1,60));
  END;

  p(' ');
  p('  Most recent FS_CEBD runs:');
  BEGIN
    FOR r IN (SELECT * FROM (
                SELECT PRCSINSTANCE pi, RUNCNTLID rc, BEGINDTTM bg,
                       ROUND((CAST(ENDDTTM AS DATE)-CAST(BEGINDTTM AS DATE))*1440,1) mn,
                       RUNSTATUS rs
                FROM   SYSADM.PSPRCSRQST
                WHERE  PRCSNAME='FS_CEBD' AND BEGINDTTM IS NOT NULL
                ORDER  BY BEGINDTTM DESC)
              WHERE ROWNUM <= 8)
    LOOP
      p('    ' || RPAD(r.pi,11) || RPAD(NVL(r.rc,'(null)'),34)
        || RPAD(TO_CHAR(r.bg,'MM-DD HH24:MI'),14)
        || LPAD(NVL(TO_CHAR(r.mn),'running'),9) || '  status=' || r.rs);
    END LOOP;
  EXCEPTION WHEN OTHERS THEN p('    failed: ' || SUBSTR(SQLERRM,1,60));
  END;

  -- ==================================================================
  hdr('VERDICT');
  -- ==================================================================
  p('  hard failures : ' || v_bad);
  p('  drift vs pre-change baseline : ' || v_warn);
  p(' ');
  IF v_bad = 0 AND v_warn = 0 THEN
    p('  *** CLEAN ***  The four preferences are in place and nothing else');
    p('  moved. FPRD is ready for the next master build.');
  ELSIF v_bad = 0 THEN
    p('  Preferences are correct. ' || v_warn || ' value(s) differ from the');
    p('  pre-change baseline. Some drift is normal - statistics and profile');
    p('  counts change on their own. Read the DRIFT lines and confirm each');
    p('  one has an innocent explanation before signing off.');
  ELSE
    p('  *** ' || v_bad || ' HARD FAILURE(S) ***  Read the CHECK lines above.');
  END IF;

  p(' ');
  p('  Undo, if ever needed. Override switch FIRST:');
  p('    BEGIN');
  p('      DBMS_STATS.DELETE_TABLE_PREFS(''SYSADM'',''' || c_tab
    || ''',''PREFERENCE_OVERRIDES_PARAMETER'');');
  p('      DBMS_STATS.DELETE_TABLE_PREFS(''SYSADM'',''' || c_tab
    || ''',''ESTIMATE_PERCENT'');');
  p('      DBMS_STATS.DELETE_TABLE_PREFS(''SYSADM'',''' || c_tab
    || ''',''METHOD_OPT'');');
  p('      DBMS_STATS.DELETE_TABLE_PREFS(''SYSADM'',''' || c_tab
    || ''',''CASCADE'');');
  p('    END;');
  p('    /');

  p(RPAD('=', 126, '='));
  p('END   db=' || v_db || '   failures=' || v_bad || '   drift=' || v_warn
    || '   lines=' || (v_line + 1));
END;
/

SPOOL OFF

SET HEADING ON
SET FEEDBACK ON
SET PAGESIZE 5000

EXIT

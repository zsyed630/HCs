-- =====================================================================
--  fsqua_GO.sql        VERSION 2  -  no substitution variables at all
--
--  FSQUA ONLY. Rollback, degree alignment, the fix, verification, and a
--  GO or NO-GO verdict, in one run.
--
--  V2 CHANGE: this script uses SET DEFINE OFF and holds its settings as
--  PL/SQL constants instead of SQL*Plus DEFINE variables. Nothing in it
--  can ever trigger an "Enter Substitution Variable" prompt, whatever
--  characters appear in the output text.
--
--  TO SWITCH FROM DRY RUN TO APPLY, change ONE line below:
--      c_mode  CONSTANT VARCHAR2(20) := 'DRY_RUN';
--   to
--      c_mode  CONSTANT VARCHAR2(20) := 'EXECUTE';
--
-- ---------------------------------------------------------------------
--  WHAT IT DOES
--    1. drops the seven PATCH_CEBD patches added during triage
--    2. unlocks and restores the thirteen fabricated TAO statistics
--    3. aligns parallel degree with FPRD (two objects, values taken
--       from the FPRD report of 2026-07-27)
--    4. applies four DBMS_STATS preferences on PS_COMBO_DATA_TBL that
--       undo the PeopleTools 8.62 %UpdateStats regression
--
--  ROOT CAUSE
--    The 8.62 upgrade reseeded PSDDLMODEL. The %UpdateStats DDL model
--    went from estimate_percent=>1 with method_opt FOR ALL INDEXED
--    COLUMNS SIZE 1, to ESTIMATE_PERCENT=>AUTO_SAMPLE_SIZE with no
--    method_opt. Statistics cost now scales with table size, so only the
--    run controls that fully populate PS_COMBO_DATA_TBL regressed.
--
--  TARGETS, all measured in FPRD
--    RUN CONTROL                       PRE-UPGRADE   NOW       TARGET
--    FDC_COMBO_BUILD_MASTER_RUNCNTL    72.7 min      202.3     73 min
--    coa                               13.4 min       80.8     13 min
--
--  Run as a DBA account.
-- =====================================================================

SET DEFINE OFF
SET LINESIZE 118
SET PAGESIZE 0
SET HEADING OFF
SET FEEDBACK OFF
SET VERIFY OFF
SET TRIMSPOOL ON
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED

SPOOL fsqua_GO.log

DECLARE
  -- ==================================================================
  -- SETTINGS - edit c_mode to apply. Everything else is already correct
  -- for this environment.
  -- ==================================================================
  c_mode     CONSTANT VARCHAR2(20) := 'DRY_RUN';            -- or EXECUTE
  c_dbguard  CONSTANT VARCHAR2(30) := 'FSQUA';
  c_fixtable CONSTANT VARCHAR2(30) := 'PS_COMBO_DATA_TBL';
  c_tbl_deg  CONSTANT VARCHAR2(10) := '4';                  -- FPRD value
  c_idx_name CONSTANT VARCHAR2(30) := 'PSACOMBO_DATA_TBL';  -- FPRD DEFAULT
  -- ==================================================================

  v_db     VARCHAR2(30);
  v_go     BOOLEAN := TRUE;
  v_run    BOOLEAN := FALSE;
  v_line   PLS_INTEGER := 0;

  v_asof   TIMESTAMP WITH TIME ZONE;
  v_oldest TIMESTAMP WITH TIME ZONE;

  v_patch_cebd NUMBER := 0;
  v_patch_all  NUMBER := 0;
  v_bound      NUMBER := 0;
  v_locked     NUMBER := 0;
  v_fake       NUMBER := 0;
  v_tabdeg     VARCHAR2(20);
  v_idxdeg     VARCHAR2(20);

  v_dropped NUMBER := 0;
  v_unlock  NUMBER := 0;
  v_restore NUMBER := 0;
  v_deleted NUMBER := 0;
  v_failed  NUMBER := 0;

  PROCEDURE p(s IN VARCHAR2) IS
  BEGIN
    v_line := v_line + 1;
    DBMS_OUTPUT.PUT_LINE(s);
  END p;

  PROCEDURE hdr(s IN VARCHAR2) IS
  BEGIN
    p(' ');
    p(RPAD('=', 116, '='));
    p(s);
    p(RPAD('=', 116, '='));
  END hdr;

  PROCEDURE chk(label IN VARCHAR2, val IN VARCHAR2, ok IN BOOLEAN) IS
  BEGIN
    IF NOT ok THEN v_go := FALSE; END IF;
    p('  ' || RPAD(label, 48) || RPAD(SUBSTR(val, 1, 34), 36)
      || CASE WHEN ok THEN 'PASS' ELSE '** FAIL **' END);
  END chk;

BEGIN
  SELECT UPPER(name) INTO v_db FROM v$database;
  v_run := (UPPER(c_mode) = 'EXECUTE' AND v_db LIKE c_dbguard || '%');

  p(RPAD('=', 116, '='));
  p('FSQUA GO SCRIPT v2    db=' || v_db || '   mode=' || c_mode
    || '   at=' || TO_CHAR(SYSDATE, 'YYYY-MM-DD HH24:MI:SS'));
  p(RPAD('=', 116, '='));

  IF v_db NOT LIKE c_dbguard || '%' THEN
    p(' ');
    p('REFUSING TO RUN. Database is ' || v_db || ', not ' || c_dbguard || '.');
    p('This script drops SQL patches, rewrites statistics and alters');
    p('parallel degree. It runs in the QA clone only.');
    RETURN;
  END IF;

  IF NOT v_run THEN
    p('  DRY RUN. Nothing will be changed.');
    p('  To apply, edit the DECLARE section:  c_mode := EXECUTE');
  END IF;

  -- ==================================================================
  hdr('STEP 1 - ROLLBACK: PATCHES AND FABRICATED STATISTICS');
  -- ==================================================================

  -- capture the restore point BEFORE dropping, since the patch creation
  -- time is what dates the tampering session
  BEGIN
    SELECT CAST(MIN(created) AS TIMESTAMP) - INTERVAL '1' MINUTE
    INTO   v_asof FROM dba_sql_patches WHERE name LIKE 'PATCH_CEBD%';
  EXCEPTION WHEN OTHERS THEN v_asof := NULL;
  END;
  BEGIN
    v_oldest := DBMS_STATS.GET_STATS_HISTORY_AVAILABILITY;
  EXCEPTION WHEN OTHERS THEN v_oldest := NULL;
  END;

  p('  stats history back to : '
    || NVL(TO_CHAR(v_oldest, 'YYYY-MM-DD HH24:MI:SS'), 'unknown'));
  p('  restore target        : '
    || NVL(TO_CHAR(v_asof, 'YYYY-MM-DD HH24:MI:SS'), 'could not derive'));
  p(' ');

  FOR r IN (SELECT name nm FROM dba_sql_patches
            WHERE name LIKE 'PATCH_CEBD%' ORDER BY created)
  LOOP
    IF v_run THEN
      BEGIN
        DBMS_SQLDIAG.DROP_SQL_PATCH(name => r.nm, ignore => TRUE);
        v_dropped := v_dropped + 1;
        p('  DROPPED  ' || r.nm);
      EXCEPTION WHEN OTHERS THEN
        v_failed := v_failed + 1;
        p('  FAILED   ' || r.nm || ' : ' || SUBSTR(SQLERRM, 1, 50));
      END;
    ELSE
      p('  would drop  ' || r.nm);
    END IF;
  END LOOP;

  p(' ');
  FOR t IN (SELECT DISTINCT table_name tn, stattype_locked lk, num_rows nr
            FROM   dba_tab_statistics
            WHERE  owner = 'SYSADM' AND object_type = 'TABLE'
            AND    (table_name LIKE 'PS_FS_CEBD%' OR table_name LIKE 'PS_COMBO_DATA%')
            AND    (stattype_locked IS NOT NULL OR num_rows = 1000000)
            ORDER  BY table_name)
  LOOP
    IF NOT v_run THEN
      p('  would unlock and restore  ' || RPAD(t.tn, 26)
        || ' locked=' || NVL(t.lk, 'no') || ' rows=' || NVL(TO_CHAR(t.nr), 'null'));
    ELSE
      IF t.lk IS NOT NULL THEN
        BEGIN
          DBMS_STATS.UNLOCK_TABLE_STATS('SYSADM', t.tn);
          v_unlock := v_unlock + 1;
        EXCEPTION WHEN OTHERS THEN
          v_failed := v_failed + 1;
          p('  UNLOCK FAILED ' || t.tn || ' : ' || SUBSTR(SQLERRM, 1, 50));
        END;
      END IF;
      IF v_asof IS NOT NULL THEN
        BEGIN
          DBMS_STATS.RESTORE_TABLE_STATS(ownname => 'SYSADM', tabname => t.tn,
                                         as_of_timestamp => v_asof,
                                         force => TRUE, no_invalidate => FALSE);
          v_restore := v_restore + 1;
          p('  UNLOCKED + RESTORED  ' || t.tn);
        EXCEPTION WHEN OTHERS THEN
          BEGIN
            DBMS_STATS.DELETE_TABLE_STATS(ownname => 'SYSADM', tabname => t.tn,
                                          cascade_indexes => TRUE, force => TRUE,
                                          no_invalidate => FALSE);
            v_deleted := v_deleted + 1;
            p('  UNLOCKED + DELETED   ' || RPAD(t.tn, 26)
              || ' (restore unavailable; UpdateStats will regather)');
          EXCEPTION WHEN OTHERS THEN
            v_failed := v_failed + 1;
            p('  FAILED   ' || t.tn || ' : ' || SUBSTR(SQLERRM, 1, 50));
          END;
        END;
      END IF;
    END IF;
  END LOOP;

  IF v_run THEN
    p(' ');
    p('  dropped=' || v_dropped || '  unlocked=' || v_unlock
      || '  restored=' || v_restore || '  deleted=' || v_deleted
      || '  failed=' || v_failed);
  END IF;

  -- ==================================================================
  hdr('STEP 2 - DEGREE ALIGNMENT WITH FPRD');
  -- ==================================================================
  p('  FPRD reports TABLE ' || c_fixtable || ' at DEGREE ' || c_tbl_deg
    || ' and INDEX ' || c_idx_name || ' at DEFAULT.');
  p('  FSQUA has both at 1, from the NOPARALLEL statements run during');
  p('  triage. Every other object already matches, so only these two');
  p('  need changing.');
  p(' ');

  BEGIN
    SELECT TRIM(degree) INTO v_tabdeg FROM dba_tables
    WHERE owner = 'SYSADM' AND table_name = c_fixtable;
    p('  before: TABLE ' || RPAD(c_fixtable, 26) || ' degree=' || v_tabdeg);
  EXCEPTION WHEN OTHERS THEN
    p('  could not read table degree: ' || SUBSTR(SQLERRM, 1, 50));
  END;
  BEGIN
    SELECT TRIM(degree) INTO v_idxdeg FROM dba_indexes
    WHERE owner = 'SYSADM' AND index_name = c_idx_name;
    p('  before: INDEX ' || RPAD(c_idx_name, 26) || ' degree=' || v_idxdeg);
  EXCEPTION WHEN OTHERS THEN
    p('  could not read index degree: ' || SUBSTR(SQLERRM, 1, 50));
  END;

  p(' ');
  IF v_run THEN
    BEGIN
      EXECUTE IMMEDIATE 'ALTER TABLE SYSADM.' || c_fixtable
                        || ' PARALLEL (DEGREE ' || c_tbl_deg || ')';
      p('  APPLIED  ALTER TABLE SYSADM.' || c_fixtable
        || ' PARALLEL (DEGREE ' || c_tbl_deg || ');');
    EXCEPTION WHEN OTHERS THEN
      v_failed := v_failed + 1;
      p('  FAILED   alter table : ' || SUBSTR(SQLERRM, 1, 60));
    END;
    BEGIN
      EXECUTE IMMEDIATE 'ALTER INDEX SYSADM.' || c_idx_name || ' PARALLEL';
      p('  APPLIED  ALTER INDEX SYSADM.' || c_idx_name || ' PARALLEL;');
    EXCEPTION WHEN OTHERS THEN
      v_failed := v_failed + 1;
      p('  FAILED   alter index : ' || SUBSTR(SQLERRM, 1, 60));
    END;
  ELSE
    p('  would run: ALTER TABLE SYSADM.' || c_fixtable
      || ' PARALLEL (DEGREE ' || c_tbl_deg || ');');
    p('  would run: ALTER INDEX SYSADM.' || c_idx_name || ' PARALLEL;');
  END IF;

  -- ==================================================================
  hdr('STEP 3 - THE FIX: FOUR TABLE PREFERENCES');
  -- ==================================================================
  p('  CASCADE is in this list for a non-obvious reason. The site');
  p('  preference for CASCADE is FALSE. That is harmless today, because');
  p('  the DDL model passes CASCADE=>TRUE explicitly and an explicit');
  p('  parameter beats a preference. Turning on');
  p('  PREFERENCE_OVERRIDES_PARAMETER reverses that, the FALSE');
  p('  preference wins, and index statistics silently stop being');
  p('  gathered on this table. Setting it TRUE explicitly prevents that.');
  p(' ');
  p('  The override switch is set LAST, so the other three values are');
  p('  already in place the moment it starts taking effect.');
  p(' ');

  IF v_run THEN
    BEGIN
      DBMS_STATS.SET_TABLE_PREFS('SYSADM', c_fixtable, 'ESTIMATE_PERCENT', '1');
      p('  SET  ESTIMATE_PERCENT = 1');
    EXCEPTION WHEN OTHERS THEN
      v_failed := v_failed + 1;
      p('  FAILED ESTIMATE_PERCENT : ' || SUBSTR(SQLERRM, 1, 60));
    END;
    BEGIN
      DBMS_STATS.SET_TABLE_PREFS('SYSADM', c_fixtable, 'METHOD_OPT',
                                 'FOR ALL INDEXED COLUMNS SIZE 1');
      p('  SET  METHOD_OPT = FOR ALL INDEXED COLUMNS SIZE 1');
    EXCEPTION WHEN OTHERS THEN
      v_failed := v_failed + 1;
      p('  FAILED METHOD_OPT : ' || SUBSTR(SQLERRM, 1, 60));
    END;
    BEGIN
      DBMS_STATS.SET_TABLE_PREFS('SYSADM', c_fixtable, 'CASCADE', 'TRUE');
      p('  SET  CASCADE = TRUE');
    EXCEPTION WHEN OTHERS THEN
      v_failed := v_failed + 1;
      p('  FAILED CASCADE : ' || SUBSTR(SQLERRM, 1, 60));
    END;
    BEGIN
      DBMS_STATS.SET_TABLE_PREFS('SYSADM', c_fixtable,
                                 'PREFERENCE_OVERRIDES_PARAMETER', 'TRUE');
      p('  SET  PREFERENCE_OVERRIDES_PARAMETER = TRUE   (last, on purpose)');
    EXCEPTION WHEN OTHERS THEN
      v_failed := v_failed + 1;
      p('  FAILED PREFERENCE_OVERRIDES_PARAMETER : ' || SUBSTR(SQLERRM, 1, 60));
    END;
  ELSE
    p('  would set ESTIMATE_PERCENT               = 1');
    p('  would set METHOD_OPT                     = FOR ALL INDEXED COLUMNS SIZE 1');
    p('  would set CASCADE                        = TRUE');
    p('  would set PREFERENCE_OVERRIDES_PARAMETER = TRUE');
  END IF;

  -- ==================================================================
  hdr('STEP 4 - VERIFICATION');
  -- ==================================================================
  p('  ' || RPAD('CHECK', 48) || RPAD('VALUE', 36) || 'STATUS');
  p('  ' || RPAD('-', 112, '-'));

  SELECT COUNT(*) INTO v_patch_cebd FROM dba_sql_patches WHERE name LIKE 'PATCH_CEBD%';
  SELECT COUNT(*) INTO v_patch_all  FROM dba_sql_patches;
  SELECT COUNT(DISTINCT sql_patch) INTO v_bound FROM gv$sql WHERE sql_patch IS NOT NULL;
  SELECT COUNT(CASE WHEN stattype_locked IS NOT NULL THEN 1 END),
         COUNT(CASE WHEN num_rows = 1000000 AND blocks = 25000 THEN 1 END)
  INTO   v_locked, v_fake
  FROM   dba_tab_statistics
  WHERE  owner = 'SYSADM' AND object_type = 'TABLE'
  AND    (table_name LIKE 'PS_FS_CEBD%' OR table_name LIKE 'PS_COMBO_DATA%');

  chk('PATCH_CEBD patches remaining',   TO_CHAR(v_patch_cebd), v_patch_cebd = 0);
  chk('total patches  (FPRD has 1)',    TO_CHAR(v_patch_all),  v_patch_all = 1);
  chk('patches bound to a cursor',      TO_CHAR(v_bound),      v_bound = 0);
  chk('tables with LOCKED statistics',  TO_CHAR(v_locked),     v_locked = 0);
  chk('tables with FAKE 1M statistics', TO_CHAR(v_fake),       v_fake = 0);

  BEGIN
    SELECT TRIM(degree) INTO v_tabdeg FROM dba_tables
    WHERE owner = 'SYSADM' AND table_name = c_fixtable;
    chk('degree  TABLE ' || c_fixtable, v_tabdeg, v_tabdeg = c_tbl_deg);
  EXCEPTION WHEN OTHERS THEN
    chk('degree  TABLE ' || c_fixtable, 'unreadable', FALSE);
  END;
  BEGIN
    SELECT TRIM(degree) INTO v_idxdeg FROM dba_indexes
    WHERE owner = 'SYSADM' AND index_name = c_idx_name;
    chk('degree  INDEX ' || c_idx_name, v_idxdeg, UPPER(v_idxdeg) = 'DEFAULT');
  EXCEPTION WHEN OTHERS THEN
    chk('degree  INDEX ' || c_idx_name, 'unreadable', FALSE);
  END;

  BEGIN
    chk('pref ESTIMATE_PERCENT',
        DBMS_STATS.GET_PREFS('ESTIMATE_PERCENT', 'SYSADM', c_fixtable),
        DBMS_STATS.GET_PREFS('ESTIMATE_PERCENT', 'SYSADM', c_fixtable) = '1');
    chk('pref METHOD_OPT',
        DBMS_STATS.GET_PREFS('METHOD_OPT', 'SYSADM', c_fixtable),
        DBMS_STATS.GET_PREFS('METHOD_OPT', 'SYSADM', c_fixtable)
          = 'FOR ALL INDEXED COLUMNS SIZE 1');
    chk('pref CASCADE',
        DBMS_STATS.GET_PREFS('CASCADE', 'SYSADM', c_fixtable),
        UPPER(DBMS_STATS.GET_PREFS('CASCADE', 'SYSADM', c_fixtable)) = 'TRUE');
    chk('pref PREFERENCE_OVERRIDES_PARAMETER',
        DBMS_STATS.GET_PREFS('PREFERENCE_OVERRIDES_PARAMETER', 'SYSADM', c_fixtable),
        UPPER(DBMS_STATS.GET_PREFS('PREFERENCE_OVERRIDES_PARAMETER',
                                   'SYSADM', c_fixtable)) = 'TRUE');
  EXCEPTION WHEN OTHERS THEN
    chk('preference readback', SUBSTR(SQLERRM, 1, 30), FALSE);
  END;

  IF v_failed > 0 THEN
    v_go := FALSE;
    p(' ');
    p('  ' || v_failed || ' operation(s) reported a failure above.');
  END IF;

  -- ==================================================================
  hdr('STEP 5 - VERDICT');
  -- ==================================================================

  IF NOT v_run THEN
    p('  DRY RUN COMPLETE. Nothing was changed.');
    p('  The FAILs above are expected - the work has not been done yet.');
    p(' ');
    p('  To apply, edit one line in the DECLARE section at the top:');
    p('      c_mode  CONSTANT VARCHAR2(20) := ''EXECUTE'';');
  ELSIF v_go THEN
    p('  *** GO ***  FSQUA is prod-like and the fix is in place.');
    p(' ');
    p('  Tell the user to run FS_CEBD. Two run controls regressed, so');
    p('  either one is a valid test. The master build is the bigger');
    p('  signal; coa turns around faster.');
    p(' ');
    p('    RUN CONTROL                       WAS      NOW      TARGET');
    p('    ------------------------------    ------   ------   ------');
    p('    FDC_COMBO_BUILD_MASTER_RUNCNTL    72.7 m   202.3 m  73 m');
    p('    coa                               13.4 m    80.8 m  13 m');
    p(' ');
    p('  WAS is the pre-upgrade FPRD average for that same run control.');
    p('  NOW is the post-upgrade FPRD average. TARGET is a return to WAS.');
    p(' ');
    p('  Ask them to enable AE timings so PS_BAT_TIMINGS_DTL gives');
    p('  per-step numbers. Note the process instance when it starts.');
    p(' ');
    p('  Afterwards check two things:');
    p('    1. wall clock against the target above');
    p('    2. statistics share of DB time. It was 82 percent of run');
    p('       26068516. It should now be in single digits.');
    p(' ');
    p('  If runtime drops but another query regresses, ESTIMATE_PERCENT');
    p('  is the dial. Try 5 or 10 before abandoning the approach.');
  ELSE
    p('  *** NO-GO ***  Do not run the test yet.');
    p(' ');
    p('  One or more checks in step 4 failed. Fix those first, or the');
    p('  test result will not mean anything. Send the failing lines on.');
  END IF;

  p(' ');
  p('  Undo the fix at any time. Drop the override switch FIRST:');
  p('    BEGIN');
  p('      DBMS_STATS.DELETE_TABLE_PREFS(''SYSADM'', ''' || c_fixtable
    || ''', ''PREFERENCE_OVERRIDES_PARAMETER'');');
  p('      DBMS_STATS.DELETE_TABLE_PREFS(''SYSADM'', ''' || c_fixtable
    || ''', ''ESTIMATE_PERCENT'');');
  p('      DBMS_STATS.DELETE_TABLE_PREFS(''SYSADM'', ''' || c_fixtable
    || ''', ''METHOD_OPT'');');
  p('      DBMS_STATS.DELETE_TABLE_PREFS(''SYSADM'', ''' || c_fixtable
    || ''', ''CASCADE'');');
  p('    END;');
  p('    /');

  p(RPAD('=', 116, '='));
  p('END   db=' || v_db || '   mode=' || c_mode || '   failures=' || v_failed
    || '   verdict=' || CASE WHEN NOT v_run THEN 'DRY RUN'
                             WHEN v_go THEN 'GO' ELSE 'NO-GO' END);
END;
/

SPOOL OFF

SET HEADING ON
SET FEEDBACK ON
SET PAGESIZE 5000

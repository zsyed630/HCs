-- =====================================================================
--  fsqua_GO.sql
--  FSQUA ONLY. Everything needed to make the QA clone prod-like and
--  apply the fix, in one run, ending with a GO or NO-GO verdict.
--
--  Do all four of these:
--    1. rollback the seven PATCH_CEBD patches added during triage
--    2. unlock and restore the thirteen fabricated TAO statistics
--    3. align parallel degree with FPRD (two objects, values confirmed
--       from the FPRD report on 2026-07-27)
--    4. apply the four DBMS_STATS preferences that undo the 8.62
--       %UpdateStats regression on PS_COMBO_DATA_TBL
--
--  Then hand the job to the user. Targets, measured in FPRD:
--
--    RUN CONTROL                       PRE-UPGRADE   NOW      TARGET
--    FDC_COMBO_BUILD_MASTER_RUNCNTL    72.7 min      202.3    ~73 min
--    coa                               13.4 min       80.8    ~13 min
--
--  Both regressed. Both are driven by the same four statistics
--  statements against PS_COMBO_DATA_TBL and its two indexes.
--
--  Run as a DBA account. mode defaults to DRY_RUN.
-- =====================================================================

SET LINESIZE 118
SET PAGESIZE 0
SET HEADING OFF
SET FEEDBACK OFF
SET VERIFY OFF
SET TRIMSPOOL ON
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
SET DEFINE '~'

-- ---------------------------------------------------------------------
DEFINE mode      = DRY_RUN
DEFINE dbguard   = FSQUA
DEFINE fixtable  = PS_COMBO_DATA_TBL
-- degree values confirmed from the FPRD report, 2026-07-27
DEFINE tbl_deg   = 4
DEFINE idx_name  = PSACOMBO_DATA_TBL
-- ---------------------------------------------------------------------

SPOOL fsqua_GO.log

DECLARE
  v_mode   VARCHAR2(20) := UPPER('~mode');
  v_guard  VARCHAR2(30) := UPPER('~dbguard');
  v_tab    VARCHAR2(30) := UPPER('~fixtable');
  v_idx    VARCHAR2(30) := UPPER('~idx_name');
  v_deg    VARCHAR2(10) := '~tbl_deg';
  v_db     VARCHAR2(30);
  v_go     BOOLEAN := TRUE;
  v_line   PLS_INTEGER := 0;
  v_run    BOOLEAN := FALSE;

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

  -- a check that also drives the final verdict
  PROCEDURE chk(label IN VARCHAR2, val IN VARCHAR2, ok IN BOOLEAN) IS
  BEGIN
    IF NOT ok THEN v_go := FALSE; END IF;
    p('  ' || RPAD(label, 48) || RPAD(SUBSTR(val, 1, 34), 36)
      || CASE WHEN ok THEN 'PASS' ELSE '** FAIL **' END);
  END chk;

BEGIN
  SELECT UPPER(name) INTO v_db FROM v$database;
  v_run := (v_mode = 'EXECUTE' AND v_db LIKE v_guard || '%');

  p(RPAD('=', 116, '='));
  p('FSQUA GO SCRIPT    db=' || v_db || '   mode=' || v_mode
    || '   at=' || TO_CHAR(SYSDATE, 'YYYY-MM-DD HH24:MI:SS'));
  p(RPAD('=', 116, '='));

  IF v_db NOT LIKE v_guard || '%' THEN
    p(' ');
    p('REFUSING TO RUN. Database is ' || v_db || ', not ' || v_guard || '.');
    p('This script drops SQL patches, rewrites statistics and alters');
    p('parallel degree. It runs in the QA clone only.');
    RETURN;
  END IF;

  IF NOT v_run THEN
    p('  DRY RUN. Nothing will be changed. Set mode=EXECUTE to apply.');
  END IF;

  -- ==================================================================
  hdr('STEP 1 - ROLLBACK: PATCHES AND FABRICATED STATISTICS');
  -- ==================================================================

  -- capture the restore point BEFORE dropping the patches, since the
  -- patch creation time is what dates the tampering session
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
              || ' (restore unavailable; percent-UpdateStats will regather)');
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
  p('  FPRD reports TABLE ' || v_tab || ' at DEGREE ' || v_deg
    || ' and INDEX ' || v_idx || ' at DEFAULT.');
  p('  FSQUA has both at 1, from the NOPARALLEL statements run during');
  p('  triage. Every other object already matches, so only these two');
  p('  need changing.');
  p(' ');

  BEGIN
    SELECT TRIM(degree) INTO v_tabdeg FROM dba_tables
    WHERE owner = 'SYSADM' AND table_name = v_tab;
    p('  before: TABLE ' || RPAD(v_tab, 26) || ' degree=' || v_tabdeg);
  EXCEPTION WHEN OTHERS THEN
    p('  could not read table degree: ' || SUBSTR(SQLERRM, 1, 50));
  END;
  BEGIN
    SELECT TRIM(degree) INTO v_idxdeg FROM dba_indexes
    WHERE owner = 'SYSADM' AND index_name = v_idx;
    p('  before: INDEX ' || RPAD(v_idx, 26) || ' degree=' || v_idxdeg);
  EXCEPTION WHEN OTHERS THEN
    p('  could not read index degree: ' || SUBSTR(SQLERRM, 1, 50));
  END;

  p(' ');
  IF v_run THEN
    BEGIN
      EXECUTE IMMEDIATE 'ALTER TABLE SYSADM.' || v_tab
                        || ' PARALLEL (DEGREE ' || v_deg || ')';
      p('  APPLIED  ALTER TABLE SYSADM.' || v_tab
        || ' PARALLEL (DEGREE ' || v_deg || ');');
    EXCEPTION WHEN OTHERS THEN
      v_failed := v_failed + 1;
      p('  FAILED   alter table : ' || SUBSTR(SQLERRM, 1, 60));
    END;
    BEGIN
      EXECUTE IMMEDIATE 'ALTER INDEX SYSADM.' || v_idx || ' PARALLEL';
      p('  APPLIED  ALTER INDEX SYSADM.' || v_idx || ' PARALLEL;');
    EXCEPTION WHEN OTHERS THEN
      v_failed := v_failed + 1;
      p('  FAILED   alter index : ' || SUBSTR(SQLERRM, 1, 60));
    END;
  ELSE
    p('  would run: ALTER TABLE SYSADM.' || v_tab
      || ' PARALLEL (DEGREE ' || v_deg || ');');
    p('  would run: ALTER INDEX SYSADM.' || v_idx || ' PARALLEL;');
  END IF;

  -- ==================================================================
  hdr('STEP 3 - THE FIX: FOUR TABLE PREFERENCES');
  -- ==================================================================
  p('  CASCADE is in this list for a non-obvious reason. The site');
  p('  preference for CASCADE is FALSE. That is harmless today because');
  p('  the DDL model passes CASCADE=>TRUE explicitly and an explicit');
  p('  parameter beats a preference. Turning on');
  p('  PREFERENCE_OVERRIDES_PARAMETER reverses that, the FALSE');
  p('  preference wins, and index statistics silently stop being');
  p('  gathered. Setting it TRUE explicitly prevents that.');
  p(' ');
  p('  The override switch is set LAST, so the other three values are');
  p('  already in place the moment it starts taking effect.');
  p(' ');

  IF v_run THEN
    BEGIN
      DBMS_STATS.SET_TABLE_PREFS('SYSADM', v_tab, 'ESTIMATE_PERCENT', '1');
      p('  SET  ESTIMATE_PERCENT = 1');
    EXCEPTION WHEN OTHERS THEN
      v_failed := v_failed + 1;
      p('  FAILED ESTIMATE_PERCENT : ' || SUBSTR(SQLERRM, 1, 60));
    END;
    BEGIN
      DBMS_STATS.SET_TABLE_PREFS('SYSADM', v_tab, 'METHOD_OPT',
                                 'FOR ALL INDEXED COLUMNS SIZE 1');
      p('  SET  METHOD_OPT = FOR ALL INDEXED COLUMNS SIZE 1');
    EXCEPTION WHEN OTHERS THEN
      v_failed := v_failed + 1;
      p('  FAILED METHOD_OPT : ' || SUBSTR(SQLERRM, 1, 60));
    END;
    BEGIN
      DBMS_STATS.SET_TABLE_PREFS('SYSADM', v_tab, 'CASCADE', 'TRUE');
      p('  SET  CASCADE = TRUE');
    EXCEPTION WHEN OTHERS THEN
      v_failed := v_failed + 1;
      p('  FAILED CASCADE : ' || SUBSTR(SQLERRM, 1, 60));
    END;
    BEGIN
      DBMS_STATS.SET_TABLE_PREFS('SYSADM', v_tab,
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

  chk('PATCH_CEBD patches remaining',        TO_CHAR(v_patch_cebd), v_patch_cebd = 0);
  chk('total patches  (FPRD has 1)',         TO_CHAR(v_patch_all),  v_patch_all = 1);
  chk('patches bound to a cursor',           TO_CHAR(v_bound),      v_bound = 0);
  chk('tables with LOCKED statistics',       TO_CHAR(v_locked),     v_locked = 0);
  chk('tables with FAKE 1M statistics',      TO_CHAR(v_fake),       v_fake = 0);

  BEGIN
    SELECT TRIM(degree) INTO v_tabdeg FROM dba_tables
    WHERE owner = 'SYSADM' AND table_name = v_tab;
    chk('degree  TABLE ' || v_tab, v_tabdeg, v_tabdeg = v_deg);
  EXCEPTION WHEN OTHERS THEN
    chk('degree  TABLE ' || v_tab, 'unreadable', FALSE);
  END;
  BEGIN
    SELECT TRIM(degree) INTO v_idxdeg FROM dba_indexes
    WHERE owner = 'SYSADM' AND index_name = v_idx;
    chk('degree  INDEX ' || v_idx, v_idxdeg, UPPER(v_idxdeg) = 'DEFAULT');
  EXCEPTION WHEN OTHERS THEN
    chk('degree  INDEX ' || v_idx, 'unreadable', FALSE);
  END;

  BEGIN
    chk('pref ESTIMATE_PERCENT',
        DBMS_STATS.GET_PREFS('ESTIMATE_PERCENT', 'SYSADM', v_tab),
        DBMS_STATS.GET_PREFS('ESTIMATE_PERCENT', 'SYSADM', v_tab) = '1');
    chk('pref METHOD_OPT',
        DBMS_STATS.GET_PREFS('METHOD_OPT', 'SYSADM', v_tab),
        DBMS_STATS.GET_PREFS('METHOD_OPT', 'SYSADM', v_tab)
          = 'FOR ALL INDEXED COLUMNS SIZE 1');
    chk('pref CASCADE',
        DBMS_STATS.GET_PREFS('CASCADE', 'SYSADM', v_tab),
        UPPER(DBMS_STATS.GET_PREFS('CASCADE', 'SYSADM', v_tab)) = 'TRUE');
    chk('pref PREFERENCE_OVERRIDES_PARAMETER',
        DBMS_STATS.GET_PREFS('PREFERENCE_OVERRIDES_PARAMETER', 'SYSADM', v_tab),
        UPPER(DBMS_STATS.GET_PREFS('PREFERENCE_OVERRIDES_PARAMETER',
                                   'SYSADM', v_tab)) = 'TRUE');
  EXCEPTION WHEN OTHERS THEN
    chk('preference readback', SUBSTR(SQLERRM, 1, 30), FALSE);
    v_go := FALSE;
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
    p('  To apply: set  DEFINE mode = EXECUTE  at the top and run again.');
  ELSIF v_go THEN
    p('  *** GO ***  FSQUA is prod-like and the fix is in place.');
    p(' ');
    p('  Tell the user to run FS_CEBD. Two run controls regressed, so');
    p('  either one is a valid test. The master build is the bigger');
    p('  signal; coa is quicker to turn around.');
    p(' ');
    p('    RUN CONTROL                       WAS      NOW      TARGET');
    p('    ------------------------------    ------   ------   ------');
    p('    FDC_COMBO_BUILD_MASTER_RUNCNTL    72.7 m   202.3 m  ~73 m');
    p('    coa                               13.4 m    80.8 m  ~13 m');
    p(' ');
    p('  WAS is the pre-upgrade FPRD average for that same run control.');
    p('  NOW is the post-upgrade FPRD average. TARGET is a return to WAS.');
    p(' ');
    p('  Ask them to enable AE timings so PS_BAT_TIMINGS_DTL gives');
    p('  per-step numbers. Note the process instance when it starts.');
    p(' ');
    p('  After it finishes, check two things:');
    p('    1. wall clock against the target above');
    p('    2. statistics share of DB time - it was 82 percent of run');
    p('       26068516; it should now be in single digits');
    p(' ');
    p('  If runtime drops but some other query regresses, ESTIMATE_PERCENT');
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
  p('      DBMS_STATS.DELETE_TABLE_PREFS(''SYSADM'', ''' || v_tab
    || ''', ''PREFERENCE_OVERRIDES_PARAMETER'');');
  p('      DBMS_STATS.DELETE_TABLE_PREFS(''SYSADM'', ''' || v_tab
    || ''', ''ESTIMATE_PERCENT'');');
  p('      DBMS_STATS.DELETE_TABLE_PREFS(''SYSADM'', ''' || v_tab
    || ''', ''METHOD_OPT'');');
  p('      DBMS_STATS.DELETE_TABLE_PREFS(''SYSADM'', ''' || v_tab
    || ''', ''CASCADE'');');
  p('    END;');
  p('    /');

  p(RPAD('=', 116, '='));
  p('END   db=' || v_db || '   mode=' || v_mode || '   failures=' || v_failed
    || '   verdict=' || CASE WHEN NOT v_run THEN 'DRY RUN'
                             WHEN v_go THEN 'GO' ELSE 'NO-GO' END);
END;
/

SPOOL OFF

SET DEFINE ON
SET HEADING ON
SET FEEDBACK ON
SET PAGESIZE 5000

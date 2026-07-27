-- =====================================================================
--  FS_CEBD  --  PeopleTools 8.62 %UpdateStats regression
--  Single script: evidence, rollback, fix, verification.
--
--  Oracle 19c RAC / PeopleSoft FSCM / schema SYSADM
--
-- ---------------------------------------------------------------------
--  ROOT CAUSE
-- ---------------------------------------------------------------------
--  The PeopleTools upgrade on 2026-06-26 reseeded PSDDLMODEL, the
--  metadata row that the %UpdateStats meta-SQL expands into at runtime.
--
--    8.59 (before) : DBMS_STATS.GATHER_TABLE_STATS(... ,
--                      estimate_percent => 1,
--                      method_opt       => FOR ALL INDEXED COLUMNS SIZE 1,
--                      cascade          => TRUE)
--
--    8.62 (after)  : DBMS_STATS.GATHER_TABLE_STATS(... ,
--                      ESTIMATE_PERCENT => DBMS_STATS.AUTO_SAMPLE_SIZE,
--                      NO_INVALIDATE    => FALSE,
--                      CASCADE          => TRUE)
--                    -- method_opt absent, so it falls back to the
--                    -- default FOR ALL COLUMNS SIZE AUTO
--
--  Effect: statistics gathering changed from a 1 percent sample with no
--  histograms, to a full scan with histograms on every column. The cost
--  now scales with table size.
--
--  Which is why only ONE run control regressed. Only
--  FDC_COMBO_BUILD_MASTER_RUNCNTL fully populates PS_COMBO_DATA_TBL
--  (17.5M rows). The other run controls touch a fraction of the data, so
--  full-scanning that fraction is still cheap.
--
--    FDC_COMBO_BUILD_MASTER_RUNCNTL   83 min  ->  202 min
--    FDC_Budget_Build, FDC_COA_JRNLLOAD, PAYONLYALL, coa   unchanged
--
--  Measured on run 26068516 (211.8 min): statistics gathering was
--  17,930 of 21,960 DB seconds, 82 percent. The final 69 minutes of the
--  run is one statistics statement and nothing else. Three objects,
--  PS_COMBO_DATA_TBL and its two indexes, account for 81 percent of all
--  segment time.
--
-- ---------------------------------------------------------------------
--  THE FIX
-- ---------------------------------------------------------------------
--  Three DBMS_STATS table preferences on PS_COMBO_DATA_TBL.
--
--  Parameters passed explicitly in a GATHER_TABLE_STATS call normally
--  beat table preferences. PREFERENCE_OVERRIDES_PARAMETER (12.2+)
--  reverses that, which lets a preference override the values the DDL
--  model hardcodes. So PSDDLMODEL is never touched:
--    - no App Designer project, no migration
--    - blast radius is one table
--    - a future PeopleTools upgrade cannot revert it
--    - reversible with three DELETE_TABLE_PREFS calls
--
--  ESTIMATE_PERCENT is the lever that matters. It also governs the
--  cascaded index statistics, so it reaches all four hot statements
--  (f4v8yvxn8pn1p, 1ggxdkgha6w5b, 6hh8xgvmyqrzs, bp3nhn5v4ms9t).
--
-- ---------------------------------------------------------------------
--  ON THE PRE-EXISTING SQL PATCH IN FPRD -- WE ARE LEAVING IT ALONE
-- ---------------------------------------------------------------------
--  FPRD holds one SQL patch that predates this incident. FSQUA inherited
--  it in the 2026-07-26 clone, then seven more named PATCH_CEBD% were
--  added manually during triage. This script drops ONLY the seven.
--
--  The inherited patch is deliberately not dropped, because:
--    1. It is bound to zero cursors. It is inert and is not a factor.
--    2. Its provenance is unknown. It may be an Oracle Support bug
--       workaround. Dropping an unidentified patch on a hunch is how the
--       next incident gets created.
--    3. Scope. This change is the statistics fix. Bundling an unrelated
--       patch removal muddies the blast radius and the rollback.
--    4. It exists in BOTH databases, so it is a controlled variable and
--       cancels out of the comparison. Dropping it in FSQUA only would
--       stop FSQUA matching prod, which defeats the purpose of the test.
--  Section 4 identifies it so it can be triaged as separate work.
--
-- ---------------------------------------------------------------------
--  HOW TO RUN
-- ---------------------------------------------------------------------
--  The script detects which database it is in and behaves accordingly.
--
--    mode = REPORT    read only. Safe anywhere, including production.
--                     Run this first, in FPRD and in FSQUA.
--    mode = DRY_RUN   read only. Also prints every action it would take.
--    mode = EXECUTE   makes changes. See the gates below.
--
--  Gates:
--    - ROLLBACK (dropping patches, restoring statistics) runs in FSQUA
--      only. It is hard blocked in every other database.
--    - THE FIX runs in FSQUA freely. To apply it in FPRD you must ALSO
--      set allow_prod = YES. Two deliberate edits, not one.
--
--  Suggested sequence:
--    1. FPRD  mode=REPORT     capture the baseline and the evidence
--    2. FSQUA mode=REPORT     confirm the contamination
--    3. FSQUA mode=EXECUTE    rollback + fix
--    4. FSQUA                 run FS_CEBD with
--                             FDC_COMBO_BUILD_MASTER_RUNCNTL
--                             expect roughly 200 min -> 85-90 min
--    5. FPRD  mode=EXECUTE, allow_prod=YES     after sign-off
-- =====================================================================

SET LINESIZE 120
SET PAGESIZE 0
SET HEADING OFF
SET FEEDBACK OFF
SET VERIFY OFF
SET TRIMSPOOL ON
SET SQLBLANKLINES ON
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
SET DEFINE '~'

-- ---------------------------------------------------------------------
DEFINE mode       = REPORT
DEFINE allow_prod = NO
DEFINE qa_db      = FSQUA
DEFINE prod_db    = FPRD
DEFINE fixtable   = PS_COMBO_DATA_TBL
DEFINE cutover    = 2026-06-26
-- ---------------------------------------------------------------------

SPOOL fs_cebd_reset_and_fix.log

DECLARE
  v_mode      VARCHAR2(20) := UPPER('~mode');
  v_allowprod VARCHAR2(10) := UPPER('~allow_prod');
  v_qa        VARCHAR2(30) := UPPER('~qa_db');
  v_prod      VARCHAR2(30) := UPPER('~prod_db');
  v_tab       VARCHAR2(30) := UPPER('~fixtable');
  v_cut       DATE         := TO_DATE('~cutover', 'YYYY-MM-DD');

  v_db        VARCHAR2(30);
  v_role      VARCHAR2(10);          -- QA | PROD | OTHER
  v_line      PLS_INTEGER := 0;
  v_may_roll  BOOLEAN := FALSE;
  v_may_fix   BOOLEAN := FALSE;

  v_asof      TIMESTAMP WITH TIME ZONE;
  v_oldest    TIMESTAMP WITH TIME ZONE;

  v_patch_all  NUMBER := 0;
  v_patch_cebd NUMBER := 0;
  v_bound      NUMBER := 0;
  v_prof       NUMBER := 0;
  v_base       NUMBER := 0;
  v_locked     NUMBER := 0;
  v_fake       NUMBER := 0;

  v_dropped NUMBER := 0;
  v_unlock  NUMBER := 0;
  v_restore NUMBER := 0;
  v_deleted NUMBER := 0;
  v_failed  NUMBER := 0;

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

  PROCEDURE hdr(s IN VARCHAR2) IS
  BEGIN
    p(' ');
    p(RPAD('=', 118, '='));
    p(s);
    p(RPAD('=', 118, '='));
  END hdr;

  FUNCTION yn(b IN BOOLEAN) RETURN VARCHAR2 IS
  BEGIN
    IF b THEN RETURN 'PASS'; ELSE RETURN '** FAIL **'; END IF;
  END yn;

  FUNCTION clean(s IN VARCHAR2, n IN PLS_INTEGER) RETURN VARCHAR2 IS
  BEGIN
    RETURN SUBSTR(REPLACE(REPLACE(REPLACE(NVL(s, ' '), CHR(10), ' '),
                                  CHR(13), ' '), CHR(9), ' '), 1, n);
  END clean;

  PROCEDURE wrapout(prefix IN VARCHAR2, s IN VARCHAR2, w IN PLS_INTEGER) IS
    v_o PLS_INTEGER := 1;
  BEGIN
    WHILE v_o <= NVL(LENGTH(s), 0) LOOP
      p(prefix || clean(SUBSTR(s, v_o, w), w));
      v_o := v_o + w;
    END LOOP;
  END wrapout;

BEGIN
  SELECT UPPER(name) INTO v_db FROM v$database;

  IF    v_db LIKE v_qa   || '%' THEN v_role := 'QA';
  ELSIF v_db LIKE v_prod || '%' THEN v_role := 'PROD';
  ELSE                               v_role := 'OTHER';
  END IF;

  v_may_roll := (v_mode = 'EXECUTE' AND v_role = 'QA');
  v_may_fix  := (v_mode = 'EXECUTE'
                 AND (v_role = 'QA'
                      OR (v_role = 'PROD' AND v_allowprod = 'YES')));

  -- ==================================================================
  p(RPAD('=', 118, '='));
  p('FS_CEBD RESET AND FIX    db=' || v_db || '  role=' || v_role
    || '  mode=' || v_mode || '  allow_prod=' || v_allowprod);
  p('                         at=' || TO_CHAR(SYSDATE, 'YYYY-MM-DD HH24:MI:SS'));
  p(RPAD('=', 118, '='));

  IF v_role = 'OTHER' THEN
    p(' ');
    p('This database is neither ' || v_qa || ' nor ' || v_prod || '.');
    p('Running in REPORT mode only. No changes will be attempted.');
    v_may_roll := FALSE;
    v_may_fix  := FALSE;
  END IF;

  p(' ');
  p('  rollback (drop patches, restore stats) : '
    || CASE WHEN v_may_roll THEN 'WILL RUN'
            WHEN v_role <> 'QA' THEN 'blocked - not ' || v_qa
            ELSE 'not in EXECUTE mode' END);
  p('  fix (table preferences)                : '
    || CASE WHEN v_may_fix THEN 'WILL RUN'
            WHEN v_role = 'PROD' AND v_allowprod <> 'YES'
              THEN 'blocked - set allow_prod=YES to apply in production'
            ELSE 'not in EXECUTE mode' END);

  FOR r IN (SELECT i.instance_number inst, i.instance_name nm, i.host_name hst,
                   d.open_mode om, d.database_role dr
            FROM   gv$instance i CROSS JOIN v$database d
            ORDER  BY i.instance_number)
  LOOP
    p('  instance ' || r.inst || '  ' || RPAD(r.nm, 12) || RPAD(r.hst, 26)
      || r.om || '  ' || r.dr);
  END LOOP;

  BEGIN
    FOR r IN (SELECT TOOLSREL tr, OWNERID oi FROM SYSADM.PSSTATUS WHERE ROWNUM = 1) LOOP
      p('  PeopleTools release ' || r.tr || '   ownerid ' || r.oi);
    END LOOP;
  EXCEPTION WHEN OTHERS THEN
    p('  PSSTATUS unreadable: ' || SUBSTR(SQLERRM, 1, 50));
  END;

  -- ==================================================================
  hdr('SECTION 1 - BASELINE: FS_CEBD RUNTIME BY RUN CONTROL');
  -- ==================================================================
  p('  The regression is confined to one run control. Averaging across all');
  p('  of them hides it. Compare like with like.');
  p(' ');
  p('  ' || RPAD('RUN CONTROL', 34) || RPAD('ERA', 6) || LPAD('RUNS', 6)
    || LPAD('AVG_MIN', 10) || LPAD('MIN', 9) || LPAD('MAX', 9));
  p('  ' || RPAD('-', 114, '-'));
  BEGIN
    FOR r IN (SELECT RUNCNTLID rc,
                     CASE WHEN BEGINDTTM < v_cut THEN 'PRE' ELSE 'POST' END era,
                     COUNT(*) runs,
                     ROUND(AVG((CAST(ENDDTTM AS DATE) - CAST(BEGINDTTM AS DATE)) * 1440), 1) avg_min,
                     ROUND(MIN((CAST(ENDDTTM AS DATE) - CAST(BEGINDTTM AS DATE)) * 1440), 1) min_min,
                     ROUND(MAX((CAST(ENDDTTM AS DATE) - CAST(BEGINDTTM AS DATE)) * 1440), 1) max_min
              FROM   SYSADM.PSPRCSRQST
              WHERE  PRCSNAME = 'FS_CEBD' AND ENDDTTM IS NOT NULL
              AND    BEGINDTTM > v_cut - 60
              GROUP  BY RUNCNTLID,
                     CASE WHEN BEGINDTTM < v_cut THEN 'PRE' ELSE 'POST' END
              ORDER  BY RUNCNTLID, 2 DESC)
    LOOP
      p('  ' || RPAD(NVL(r.rc, '(null)'), 34) || RPAD(r.era, 6) || LPAD(r.runs, 6)
        || LPAD(r.avg_min, 10) || LPAD(r.min_min, 9) || LPAD(r.max_min, 9));
    END LOOP;
  EXCEPTION WHEN OTHERS THEN
    p('  failed: ' || SUBSTR(SQLERRM, 1, 70));
  END;

  p(' ');
  p('  Most recent runs:');
  p('  ' || RPAD('PRCS_INST', 12) || RPAD('RUN CONTROL', 34)
    || RPAD('STARTED', 18) || LPAD('MINUTES', 9));
  BEGIN
    FOR r IN (SELECT * FROM (
                SELECT PRCSINSTANCE pi, RUNCNTLID rc, BEGINDTTM beg,
                       ROUND((CAST(ENDDTTM AS DATE) - CAST(BEGINDTTM AS DATE)) * 1440, 1) mins
                FROM   SYSADM.PSPRCSRQST
                WHERE  PRCSNAME = 'FS_CEBD' AND ENDDTTM IS NOT NULL
                ORDER  BY BEGINDTTM DESC)
              WHERE ROWNUM <= 25)
    LOOP
      p('  ' || RPAD(r.pi, 12) || RPAD(NVL(r.rc, '(null)'), 34)
        || RPAD(TO_CHAR(r.beg, 'MM-DD HH24:MI:SS'), 18) || LPAD(r.mins, 9));
    END LOOP;
  EXCEPTION WHEN OTHERS THEN
    p('  failed: ' || SUBSTR(SQLERRM, 1, 70));
  END;

  -- ==================================================================
  hdr('SECTION 2 - ROOT CAUSE EVIDENCE: THE DDL MODEL');
  -- ==================================================================
  p('  Every row of PSDDLMODEL whose text mentions statistics. In FSTRN');
  p('  (pre-upgrade clone, tools 8.59) the Oracle row reads');
  p('  estimate_percent=>1 with method_opt FOR ALL INDEXED COLUMNS SIZE 1.');
  p('  Here it should read AUTO_SAMPLE_SIZE with no method_opt.');
  p(' ');
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
      p('  no LONG column found on PSDDLMODEL');
    ELSE
      v_n := 0;
      FOR r IN (SELECT ROWID rid FROM SYSADM.PSDDLMODEL) LOOP
        BEGIN
          EXECUTE IMMEDIATE
            'SELECT ' || v_keyexpr || ', ' || v_longcol
            || ' FROM SYSADM.PSDDLMODEL WHERE ROWID = :1'
            INTO v_key, v_txt USING r.rid;
          IF UPPER(v_txt) LIKE '%STATS%' OR UPPER(v_txt) LIKE '%ANALYZE%' THEN
            v_n := v_n + 1;
            p('  key=' || RPAD(clean(v_key, 24), 26) || ' len=' || NVL(LENGTH(v_txt), 0));
            wrapout('      ', v_txt, 104);
          END IF;
        EXCEPTION WHEN OTHERS THEN
          p('  row unreadable: ' || SUBSTR(SQLERRM, 1, 60));
        END;
      END LOOP;
      p('  statistics-related model rows: ' || v_n);
    END IF;
  EXCEPTION WHEN OTHERS THEN
    p('  failed: ' || SUBSTR(SQLERRM, 1, 70));
  END;

  -- ==================================================================
  hdr('SECTION 3 - CURRENT STATE');
  -- ==================================================================

  SELECT COUNT(*) INTO v_patch_all  FROM dba_sql_patches;
  SELECT COUNT(*) INTO v_patch_cebd FROM dba_sql_patches WHERE name LIKE 'PATCH_CEBD%';
  SELECT COUNT(DISTINCT sql_patch) INTO v_bound FROM gv$sql WHERE sql_patch IS NOT NULL;
  SELECT COUNT(*) INTO v_prof FROM dba_sql_profiles;
  SELECT COUNT(*) INTO v_base FROM dba_sql_plan_baselines;

  SELECT COUNT(CASE WHEN stattype_locked IS NOT NULL THEN 1 END),
         COUNT(CASE WHEN num_rows = 1000000 AND blocks = 25000 THEN 1 END)
  INTO   v_locked, v_fake
  FROM   dba_tab_statistics
  WHERE  owner = 'SYSADM' AND object_type = 'TABLE'
  AND    (table_name LIKE 'PS_FS_CEBD%' OR table_name LIKE 'PS_COMBO_DATA%');

  p('  sql patches total          : ' || v_patch_all);
  p('  of those named PATCH_CEBD  : ' || v_patch_cebd
    || '   <- manually added during triage, to be removed');
  p('  patches bound to a cursor  : ' || v_bound
    || '   <- 0 means no patch has ever shaped a plan');
  p('  sql profiles               : ' || v_prof);
  p('  sql plan baselines         : ' || v_base);
  p('  tables with LOCKED stats   : ' || v_locked);
  p('  tables with FAKE 1M stats  : ' || v_fake);

  p(' ');
  p('  Statistics on the FS_CEBD objects:');
  p('  ' || RPAD('TABLE', 28) || LPAD('NUM_ROWS', 14) || LPAD('BLOCKS', 10)
    || '  ' || RPAD('LOCKED', 9) || 'LAST_ANALYZED');
  FOR r IN (SELECT table_name tn, num_rows nr, blocks bl,
                   stattype_locked lk, last_analyzed la
            FROM   dba_tab_statistics
            WHERE  owner = 'SYSADM' AND object_type = 'TABLE'
            AND    (table_name LIKE 'PS_FS_CEBD%' OR table_name LIKE 'PS_COMBO_DATA%')
            ORDER  BY table_name)
  LOOP
    p('  ' || RPAD(r.tn, 28) || LPAD(NVL(TO_CHAR(r.nr), 'null'), 14)
      || LPAD(NVL(TO_CHAR(r.bl), 'null'), 10) || '  '
      || RPAD(NVL(r.lk, 'no'), 9)
      || NVL(TO_CHAR(r.la, 'YYYY-MM-DD HH24:MI'), 'never'));
  END LOOP;

  p(' ');
  p('  Parallel degree on the FS_CEBD objects. Compare FPRD against FSQUA;');
  p('  a mismatch will distort the application-SQL half of the retest.');
  p('  ' || RPAD('KIND', 7) || RPAD('OBJECT', 34) || 'DEGREE');
  FOR r IN (SELECT 'TABLE' kind, table_name obj, degree deg FROM dba_tables
            WHERE owner = 'SYSADM'
              AND (table_name LIKE 'PS_COMBO_DATA%' OR table_name LIKE 'PS_FS_CEBD%')
            UNION ALL
            SELECT 'INDEX', index_name, degree FROM dba_indexes
            WHERE owner = 'SYSADM'
              AND (table_name LIKE 'PS_COMBO_DATA%' OR table_name LIKE 'PS_FS_CEBD%')
            ORDER BY 1, 2)
  LOOP
    p('  ' || RPAD(r.kind, 7) || RPAD(r.obj, 34) || TRIM(r.deg));
  END LOOP;

  IF v_role = 'PROD' THEN
    p(' ');
    p('  Generated DDL to align FSQUA degree with this database.');
    p('  Review, then run the statements in FSQUA only:');
    FOR t IN (SELECT table_name tn, TRIM(degree) deg FROM dba_tables
              WHERE owner = 'SYSADM'
                AND (table_name LIKE 'PS_COMBO_DATA%' OR table_name LIKE 'PS_FS_CEBD%')
              ORDER BY table_name)
    LOOP
      IF UPPER(t.deg) = 'DEFAULT' THEN
        p('    ALTER TABLE SYSADM.' || t.tn || ' PARALLEL;');
      ELSIF t.deg = '1' THEN
        p('    ALTER TABLE SYSADM.' || t.tn || ' NOPARALLEL;');
      ELSE
        p('    ALTER TABLE SYSADM.' || t.tn || ' PARALLEL (DEGREE ' || t.deg || ');');
      END IF;
    END LOOP;
    FOR i IN (SELECT index_name inm, TRIM(degree) deg FROM dba_indexes
              WHERE owner = 'SYSADM'
                AND (table_name LIKE 'PS_COMBO_DATA%' OR table_name LIKE 'PS_FS_CEBD%')
              ORDER BY index_name)
    LOOP
      IF UPPER(i.deg) = 'DEFAULT' THEN
        p('    ALTER INDEX SYSADM.' || i.inm || ' PARALLEL;');
      ELSIF i.deg = '1' THEN
        p('    ALTER INDEX SYSADM.' || i.inm || ' NOPARALLEL;');
      ELSE
        p('    ALTER INDEX SYSADM.' || i.inm || ' PARALLEL (DEGREE ' || i.deg || ');');
      END IF;
    END LOOP;
  END IF;

  p(' ');
  p('  Current preferences on ' || v_tab || ':');
  BEGIN
    p('    ESTIMATE_PERCENT               = '
      || DBMS_STATS.GET_PREFS('ESTIMATE_PERCENT', 'SYSADM', v_tab));
    p('    METHOD_OPT                     = '
      || DBMS_STATS.GET_PREFS('METHOD_OPT', 'SYSADM', v_tab));
    p('    DEGREE                         = '
      || DBMS_STATS.GET_PREFS('DEGREE', 'SYSADM', v_tab));
    p('    CASCADE                        = '
      || DBMS_STATS.GET_PREFS('CASCADE', 'SYSADM', v_tab));
    p('    PREFERENCE_OVERRIDES_PARAMETER = '
      || DBMS_STATS.GET_PREFS('PREFERENCE_OVERRIDES_PARAMETER', 'SYSADM', v_tab));
  EXCEPTION WHEN OTHERS THEN
    p('    unreadable: ' || SUBSTR(SQLERRM, 1, 60));
  END;

  -- ==================================================================
  hdr('SECTION 4 - SQL PATCH INVENTORY');
  -- ==================================================================
  p('  PATCH_CEBD% rows were added manually during triage and will be');
  p('  dropped by section 5. Anything else predates this incident, is');
  p('  present in both databases, and is deliberately LEFT ALONE. Identify');
  p('  it and triage it as separate work.');
  p(' ');
  FOR r IN (SELECT name nm, status st, created cr, description ds
            FROM   dba_sql_patches ORDER BY created)
  LOOP
    p('  ' || RPAD(r.nm, 32) || RPAD(r.st, 10)
      || TO_CHAR(r.cr, 'YYYY-MM-DD HH24:MI:SS')
      || CASE WHEN r.nm LIKE 'PATCH_CEBD%' THEN '   <- will be dropped'
              ELSE '   <- PRE-EXISTING, left in place' END);
    IF r.ds IS NOT NULL THEN
      p('      description: ' || clean(r.ds, 96));
    END IF;
  END LOOP;
  IF v_patch_all = 0 THEN p('  none'); END IF;

  p(' ');
  p('  SQL_TEXT of each patch. A patch matches on the signature of the');
  p('  COMPLETE normalised statement, so a short fragment can never bind:');
  FOR r IN (SELECT name nm, DBMS_LOB.GETLENGTH(sql_text) ln,
                   DBMS_LOB.SUBSTR(sql_text, 200, 1) tx
            FROM   dba_sql_patches ORDER BY created)
  LOOP
    p('  ' || RPAD(r.nm, 32) || ' text_len=' || NVL(TO_CHAR(r.ln), '0'));
    wrapout('      ', r.tx, 104);
  END LOOP;

  -- ==================================================================
  hdr('SECTION 5 - ROLLBACK   (' || v_qa || ' only)');
  -- ==================================================================

  IF v_role <> 'QA' THEN
    p('  Skipped. This database is ' || v_db || ', not ' || v_qa || '.');
    p('  Nothing is rolled back outside the QA clone.');
  ELSE
    -- Capture the restore point BEFORE dropping, because the patch
    -- creation time is what dates the tampering session.
    BEGIN
      SELECT CAST(MIN(created) AS TIMESTAMP) - INTERVAL '1' MINUTE
      INTO   v_asof
      FROM   dba_sql_patches
      WHERE  name LIKE 'PATCH_CEBD%';
    EXCEPTION WHEN OTHERS THEN
      v_asof := NULL;
    END;

    BEGIN
      v_oldest := DBMS_STATS.GET_STATS_HISTORY_AVAILABILITY;
    EXCEPTION WHEN OTHERS THEN
      v_oldest := NULL;
    END;

    p('  stats history reaches back to : '
      || NVL(TO_CHAR(v_oldest, 'YYYY-MM-DD HH24:MI:SS'), 'unknown'));
    p('  restore target timestamp      : '
      || NVL(TO_CHAR(v_asof, 'YYYY-MM-DD HH24:MI:SS'), 'could not derive'));
    IF v_asof IS NOT NULL AND v_oldest IS NOT NULL AND v_asof < v_oldest THEN
      p('  NOTE: target predates retained history. Restore will fail and the');
      p('        fabricated statistics will be DELETED instead, which lets the');
      p('        AE percent-UpdateStats step regather them naturally. Empty');
      p('        statistics are safer than fabricated 1,000,000 row values.');
    END IF;

    p(' ');
    p('  5a. Drop PATCH_CEBD% patches');
    FOR r IN (SELECT name nm FROM dba_sql_patches
              WHERE name LIKE 'PATCH_CEBD%' ORDER BY created)
    LOOP
      IF v_may_roll THEN
        BEGIN
          DBMS_SQLDIAG.DROP_SQL_PATCH(name => r.nm, ignore => TRUE);
          v_dropped := v_dropped + 1;
          p('      DROPPED  ' || r.nm);
        EXCEPTION WHEN OTHERS THEN
          v_failed := v_failed + 1;
          p('      FAILED   ' || r.nm || ' : ' || SUBSTR(SQLERRM, 1, 50));
        END;
      ELSE
        p('      would drop  ' || r.nm);
      END IF;
    END LOOP;
    IF v_patch_cebd = 0 THEN p('      none present'); END IF;

    p(' ');
    p('  5b. Unlock and restore fabricated statistics');
    FOR t IN (SELECT DISTINCT table_name tn, stattype_locked lk, num_rows nr
              FROM   dba_tab_statistics
              WHERE  owner = 'SYSADM' AND object_type = 'TABLE'
              AND    (table_name LIKE 'PS_FS_CEBD%' OR table_name LIKE 'PS_COMBO_DATA%')
              AND    (stattype_locked IS NOT NULL OR num_rows = 1000000)
              ORDER  BY table_name)
    LOOP
      IF NOT v_may_roll THEN
        p('      would unlock and restore  ' || RPAD(t.tn, 28)
          || ' locked=' || NVL(t.lk, 'no')
          || ' num_rows=' || NVL(TO_CHAR(t.nr), 'null'));
      ELSE
        IF t.lk IS NOT NULL THEN
          BEGIN
            DBMS_STATS.UNLOCK_TABLE_STATS('SYSADM', t.tn);
            v_unlock := v_unlock + 1;
            p('      UNLOCKED ' || t.tn);
          EXCEPTION WHEN OTHERS THEN
            v_failed := v_failed + 1;
            p('      UNLOCK FAILED ' || t.tn || ' : ' || SUBSTR(SQLERRM, 1, 50));
          END;
        END IF;

        IF v_asof IS NOT NULL THEN
          BEGIN
            DBMS_STATS.RESTORE_TABLE_STATS(
              ownname         => 'SYSADM',
              tabname         => t.tn,
              as_of_timestamp => v_asof,
              force           => TRUE,
              no_invalidate   => FALSE);
            v_restore := v_restore + 1;
            p('      RESTORED ' || t.tn);
          EXCEPTION WHEN OTHERS THEN
            BEGIN
              DBMS_STATS.DELETE_TABLE_STATS(
                ownname         => 'SYSADM',
                tabname         => t.tn,
                cascade_indexes => TRUE,
                force           => TRUE,
                no_invalidate   => FALSE);
              v_deleted := v_deleted + 1;
              p('      DELETED  ' || RPAD(t.tn, 28)
                || ' (restore unavailable; percent-UpdateStats will regather)');
            EXCEPTION WHEN OTHERS THEN
              v_failed := v_failed + 1;
              p('      FAILED   ' || t.tn || ' : ' || SUBSTR(SQLERRM, 1, 50));
            END;
          END;
        END IF;
      END IF;
    END LOOP;

    IF v_may_roll THEN
      p(' ');
      p('      dropped=' || v_dropped || '  unlocked=' || v_unlock
        || '  restored=' || v_restore || '  deleted=' || v_deleted
        || '  failed=' || v_failed);
    END IF;

    p(' ');
    p('  5c. Parallel degree is NOT changed here, on purpose. The original');
    p('      value cannot be guessed. Run this script in ' || v_prod
      || ' with mode=REPORT');
    p('      to generate the exact ALTER statements, then run them here.');
  END IF;

  -- ==================================================================
  hdr('SECTION 6 - THE FIX');
  -- ==================================================================
  p('  Target: SYSADM.' || v_tab);
  p(' ');
  p('    DBMS_STATS.SET_TABLE_PREFS(''SYSADM'', ''' || v_tab
    || ''', ''PREFERENCE_OVERRIDES_PARAMETER'', ''TRUE'');');
  p('    DBMS_STATS.SET_TABLE_PREFS(''SYSADM'', ''' || v_tab
    || ''', ''ESTIMATE_PERCENT'', ''1'');');
  p('    DBMS_STATS.SET_TABLE_PREFS(''SYSADM'', ''' || v_tab
    || ''', ''METHOD_OPT'', ''FOR ALL INDEXED COLUMNS SIZE 1'');');
  p(' ');

  IF v_may_fix THEN
    BEGIN
      DBMS_STATS.SET_TABLE_PREFS('SYSADM', v_tab,
                                 'PREFERENCE_OVERRIDES_PARAMETER', 'TRUE');
      p('    SET  PREFERENCE_OVERRIDES_PARAMETER = TRUE');
    EXCEPTION WHEN OTHERS THEN
      v_failed := v_failed + 1;
      p('    FAILED PREFERENCE_OVERRIDES_PARAMETER : ' || SUBSTR(SQLERRM, 1, 60));
    END;
    BEGIN
      DBMS_STATS.SET_TABLE_PREFS('SYSADM', v_tab, 'ESTIMATE_PERCENT', '1');
      p('    SET  ESTIMATE_PERCENT = 1');
    EXCEPTION WHEN OTHERS THEN
      v_failed := v_failed + 1;
      p('    FAILED ESTIMATE_PERCENT : ' || SUBSTR(SQLERRM, 1, 60));
    END;
    BEGIN
      DBMS_STATS.SET_TABLE_PREFS('SYSADM', v_tab, 'METHOD_OPT',
                                 'FOR ALL INDEXED COLUMNS SIZE 1');
      p('    SET  METHOD_OPT = FOR ALL INDEXED COLUMNS SIZE 1');
    EXCEPTION WHEN OTHERS THEN
      v_failed := v_failed + 1;
      p('    FAILED METHOD_OPT : ' || SUBSTR(SQLERRM, 1, 60));
    END;
  ELSIF v_role = 'PROD' AND v_allowprod <> 'YES' THEN
    p('    NOT APPLIED. This is production and allow_prod is ' || v_allowprod || '.');
    p('    Set both mode=EXECUTE and allow_prod=YES to apply here.');
  ELSE
    p('    NOT APPLIED. mode is ' || v_mode || '.');
  END IF;

  -- ==================================================================
  hdr('SECTION 7 - VERIFICATION');
  -- ==================================================================

  SELECT COUNT(*) INTO v_patch_cebd FROM dba_sql_patches WHERE name LIKE 'PATCH_CEBD%';
  SELECT COUNT(*) INTO v_patch_all  FROM dba_sql_patches;
  SELECT COUNT(DISTINCT sql_patch) INTO v_bound FROM gv$sql WHERE sql_patch IS NOT NULL;

  SELECT COUNT(CASE WHEN stattype_locked IS NOT NULL THEN 1 END),
         COUNT(CASE WHEN num_rows = 1000000 AND blocks = 25000 THEN 1 END)
  INTO   v_locked, v_fake
  FROM   dba_tab_statistics
  WHERE  owner = 'SYSADM' AND object_type = 'TABLE'
  AND    (table_name LIKE 'PS_FS_CEBD%' OR table_name LIKE 'PS_COMBO_DATA%');

  p('  ' || RPAD('CHECK', 50) || RPAD('VALUE', 34) || 'STATUS');
  p('  ' || RPAD('-', 114, '-'));
  p('  ' || RPAD('PATCH_CEBD patches remaining', 50)
    || RPAD(TO_CHAR(v_patch_cebd), 34) || yn(v_patch_cebd = 0));
  p('  ' || RPAD('patches bound to a cursor', 50)
    || RPAD(TO_CHAR(v_bound), 34) || yn(v_bound = 0));
  p('  ' || RPAD('tables with LOCKED statistics', 50)
    || RPAD(TO_CHAR(v_locked), 34) || yn(v_locked = 0));
  p('  ' || RPAD('tables with FAKE 1M statistics', 50)
    || RPAD(TO_CHAR(v_fake), 34) || yn(v_fake = 0));
  p('  ' || RPAD('total patches (pre-existing ones stay)', 50)
    || RPAD(TO_CHAR(v_patch_all), 34) || 'compare across databases');

  BEGIN
    p('  ' || RPAD('pref ESTIMATE_PERCENT', 50)
      || RPAD(SUBSTR(DBMS_STATS.GET_PREFS('ESTIMATE_PERCENT', 'SYSADM', v_tab), 1, 33), 34)
      || yn(DBMS_STATS.GET_PREFS('ESTIMATE_PERCENT', 'SYSADM', v_tab) = '1'));
    p('  ' || RPAD('pref METHOD_OPT', 50)
      || RPAD(SUBSTR(DBMS_STATS.GET_PREFS('METHOD_OPT', 'SYSADM', v_tab), 1, 33), 34)
      || yn(DBMS_STATS.GET_PREFS('METHOD_OPT', 'SYSADM', v_tab)
            = 'FOR ALL INDEXED COLUMNS SIZE 1'));
    p('  ' || RPAD('pref PREFERENCE_OVERRIDES_PARAMETER', 50)
      || RPAD(SUBSTR(DBMS_STATS.GET_PREFS('PREFERENCE_OVERRIDES_PARAMETER',
                                          'SYSADM', v_tab), 1, 33), 34)
      || yn(UPPER(DBMS_STATS.GET_PREFS('PREFERENCE_OVERRIDES_PARAMETER',
                                       'SYSADM', v_tab)) = 'TRUE'));
  EXCEPTION WHEN OTHERS THEN
    p('  preference readback failed: ' || SUBSTR(SQLERRM, 1, 60));
  END;

  p(' ');
  p('  Locked statistics anywhere in SYSADM (should be none):');
  v_n := 0;
  FOR r IN (SELECT table_name tn, stattype_locked lk FROM dba_tab_statistics
            WHERE owner = 'SYSADM' AND stattype_locked IS NOT NULL
            ORDER BY table_name FETCH FIRST 40 ROWS ONLY)
  LOOP
    v_n := v_n + 1;
    p('    ' || RPAD(r.tn, 34) || r.lk);
  END LOOP;
  IF v_n = 0 THEN p('    none'); END IF;

  -- ==================================================================
  hdr('SECTION 8 - UNDO AND NEXT STEPS');
  -- ==================================================================
  p('  Undo the fix, leaving the rollback in place:');
  p(' ');
  p('    BEGIN');
  p('      DBMS_STATS.DELETE_TABLE_PREFS(''SYSADM'', ''' || v_tab
    || ''', ''ESTIMATE_PERCENT'');');
  p('      DBMS_STATS.DELETE_TABLE_PREFS(''SYSADM'', ''' || v_tab
    || ''', ''METHOD_OPT'');');
  p('      DBMS_STATS.DELETE_TABLE_PREFS(''SYSADM'', ''' || v_tab
    || ''', ''PREFERENCE_OVERRIDES_PARAMETER'');');
  p('    END;');
  p('    /');
  p(' ');
  p('  That is the entire rollback. No PeopleSoft metadata was altered, so');
  p('  there is no project to back out and no migration to reverse.');
  p(' ');

  IF v_mode <> 'EXECUTE' THEN
    p('  Nothing was changed. mode is ' || v_mode || '.');
    p('  Sequence:');
    p('    1. ' || v_prod || '  mode=REPORT    baseline and evidence');
    p('    2. ' || v_qa   || ' mode=REPORT    confirm contamination');
    p('    3. ' || v_qa   || ' mode=EXECUTE   rollback and fix');
    p('    4. ' || v_qa   || ' run FS_CEBD with FDC_COMBO_BUILD_MASTER_RUNCNTL');
    p('    5. ' || v_prod || '  mode=EXECUTE allow_prod=YES   after sign-off');
  ELSE
    p('  Applied in ' || v_db || '. Next:');
    p('    1. Confirm every line in section 7 reads PASS.');
    p('    2. Align parallel degree if section 3 shows a mismatch.');
    p('    3. Run FS_CEBD with FDC_COMBO_BUILD_MASTER_RUNCNTL.');
    p('    4. Expect roughly 200 minutes to fall to 85-90.');
    p('    5. Confirm the statistics share of DB time falls from about');
    p('       82 percent to single digits.');
  END IF;

  p(RPAD('=', 118, '='));
  p('END   db=' || v_db || '  role=' || v_role || '  mode=' || v_mode
    || '  failures=' || v_failed || '  lines=' || (v_line + 1));
END;
/

SPOOL OFF

SET DEFINE ON
SET HEADING ON
SET FEEDBACK ON
SET PAGESIZE 5000

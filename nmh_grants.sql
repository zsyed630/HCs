-- =====================================================================
-- nmh_grants.sql
--
--   NMH_ALL_SYSADM  -> SELECT/INSERT/UPDATE/DELETE on every SYSADM
--                      table and view
--   NMH_SQL_TUNING  -> full SQL Tuning Advisor privilege set
--
-- RUN AS: SYS (as sysdba) or a DBA holding GRANT ANY OBJECT PRIVILEGE.
--         Required because section 4 grants on SYS-owned views.
--
-- Idempotent + restartable. Re-running processes only what is missing.
--
-- RUNTIME: ~20k objects, one DDL each. Budget 5-20 min. GRANT auto-commits,
--          so watch progress live from a SECOND session with the query in
--          section 8a -- no logging table needed.
--
-- WARNING: mass GRANT invalidates dependent cursors in the library cache.
--          Fine on FSDEV. On FPRD/HRPRD use a change window.
--
-- Single role instead of two? Set c_tune_role := 'NMH_ALL_SYSADM' in sec 5.
-- =====================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED
SET TIMING ON
SET LINESIZE 200
SET PAGESIZE 200

PROMPT ==== 0. CONFIRM TARGET DATABASE ====
SELECT SYS_CONTEXT('USERENV','DB_NAME')        AS db_name,
       SYS_CONTEXT('USERENV','DB_UNIQUE_NAME') AS db_unique,
       SYS_CONTEXT('USERENV','SESSION_USER')   AS session_user,
       SYS_CONTEXT('USERENV','CON_NAME')       AS container
  FROM dual;


PROMPT ==== 1. PRE-FLIGHT: scope and what already exists ====
SELECT (SELECT COUNT(*) FROM dba_tables
         WHERE owner='SYSADM' AND nested='NO' AND secondary='N'
           AND dropped='NO' AND (iot_type IS NULL OR iot_type='IOT'))  AS tables_in_scope,
       (SELECT COUNT(*) FROM dba_views WHERE owner='SYSADM')           AS views_in_scope,
       (SELECT COUNT(*) FROM dba_tab_privs
         WHERE grantee='NMH_ALL_SYSADM' AND owner='SYSADM')            AS privs_today
  FROM dual;
-- privs_today near 0 confirms the old script's DDL-inside-PL/SQL bug
-- granted nothing. Expect roughly (tables+views)*4 rows when done.


PROMPT ==== 2. CREATE ROLES ====
DECLARE
  PROCEDURE mk_role(p_role IN VARCHAR2) IS
    v_cnt PLS_INTEGER;
  BEGIN
    SELECT COUNT(*) INTO v_cnt FROM dba_roles WHERE role = p_role;
    IF v_cnt = 0 THEN
      EXECUTE IMMEDIATE 'CREATE ROLE ' || p_role;
      DBMS_OUTPUT.PUT_LINE('Created role ' || p_role);
    ELSE
      DBMS_OUTPUT.PUT_LINE('Role already exists: ' || p_role);
    END IF;
  END;
BEGIN
  mk_role('NMH_ALL_SYSADM');
  mk_role('NMH_SQL_TUNING');
END;
/

-- A password-protected role will NOT enable as a default role at logon.
SELECT role, password_required, authentication_type
  FROM dba_roles
 WHERE role IN ('NMH_ALL_SYSADM','NMH_SQL_TUNING');


PROMPT ==== 3. SYSADM TABLES + VIEWS -> NMH_ALL_SYSADM ====
PROMPT ==== One EXECUTE IMMEDIATE per object. This is what was broken. ====
DECLARE
  c_role  CONSTANT VARCHAR2(128) := 'NMH_ALL_SYSADM';
  c_owner CONSTANT VARCHAR2(128) := 'SYSADM';
  v_try   PLS_INTEGER := 0;
  v_full  PLS_INTEGER := 0;
  v_sel   PLS_INTEGER := 0;
  v_fail  PLS_INTEGER := 0;
BEGIN
  FOR r IN (
    WITH targets AS (
        SELECT table_name AS obj, 'TABLE' AS typ
          FROM dba_tables
         WHERE owner     = c_owner
           AND nested    = 'NO'   -- nested-table storage segments
           AND secondary = 'N'    -- domain-index secondary tables
           AND dropped   = 'NO'   -- recycle bin BIN$...
           AND (iot_type IS NULL OR iot_type = 'IOT')  -- no IOT overflow/mapping
        UNION ALL
        SELECT view_name, 'VIEW'
          FROM dba_views
         WHERE owner = c_owner
    ),
    already AS (
        SELECT table_name AS obj
          FROM dba_tab_privs
         WHERE grantee = c_role
           AND owner   = c_owner
           AND privilege IN ('SELECT','INSERT','UPDATE','DELETE')
         GROUP BY table_name
        HAVING COUNT(DISTINCT privilege) = 4
    )
    SELECT t.obj, t.typ
      FROM targets t
     WHERE NOT EXISTS (SELECT 1 FROM already a WHERE a.obj = t.obj)
     ORDER BY t.typ, t.obj
  )
  LOOP
    v_try := v_try + 1;
    BEGIN
      -- DDL MUST go through EXECUTE IMMEDIATE. Never inline inside PL/SQL.
      EXECUTE IMMEDIATE 'GRANT SELECT, INSERT, UPDATE, DELETE ON "'
                        || c_owner || '"."' || r.obj || '" TO ' || c_role;
      v_full := v_full + 1;
    EXCEPTION
      WHEN OTHERS THEN
        -- Typical on views: ORA-01720, no grant option on a base object
        -- owned by another schema. Degrade to SELECT rather than lose it.
        DECLARE
          v_err VARCHAR2(500) := SQLERRM;
        BEGIN
          EXECUTE IMMEDIATE 'GRANT SELECT ON "'
                            || c_owner || '"."' || r.obj || '" TO ' || c_role;
          v_sel := v_sel + 1;
          DBMS_OUTPUT.PUT_LINE('SELECT-ONLY ' || r.typ || ' ' || r.obj
                               || ' :: ' || v_err);
        EXCEPTION
          WHEN OTHERS THEN
            v_fail := v_fail + 1;
            DBMS_OUTPUT.PUT_LINE('HARD-FAIL   ' || r.typ || ' ' || r.obj
                                 || ' :: ' || SQLERRM);
        END;
    END;
  END LOOP;

  DBMS_OUTPUT.PUT_LINE('---------------------------------------------');
  DBMS_OUTPUT.PUT_LINE('SYSADM objects  attempted=' || v_try
                       || '  full_dml=' || v_full
                       || '  select_only=' || v_sel
                       || '  hard_fail=' || v_fail);
END;
/


PROMPT ==== 4. SQL TUNING ADVISOR PRIVS -> NMH_SQL_TUNING ====
DECLARE
  c_tune_role CONSTANT VARCHAR2(128) := 'NMH_SQL_TUNING';
  --                                    ^ set to 'NMH_ALL_SYSADM' for one role

  TYPE t_list IS TABLE OF VARCHAR2(200);

  v_sys_privs t_list := t_list(
    'ADVISOR',
    'CREATE JOB',
    'SELECT ANY DICTIONARY',
    'ADMINISTER SQL TUNING SET',
    'ADMINISTER ANY SQL TUNING SET'
  );

  -- Role-to-role grants are legal in Oracle and chain to the user.
  v_roles t_list := t_list(
    'SELECT_CATALOG_ROLE',
    'OEM_ADVISOR'
  );

  -- SYS-owned. Requires SYSDBA or GRANT ANY OBJECT PRIVILEGE.
  v_objs t_list := t_list(
    'SYS.GV_$SQL',
    'SYS.GV_$SQLAREA',
    'SYS.GV_$SQL_BIND_CAPTURE',
    'SYS.GV_$SESSION',
    'SYS.GV_$ACTIVE_SESSION_HISTORY',
    'SYS.DBA_HIST_BASELINE',
    'SYS.DBA_HIST_SQLTEXT',
    'SYS.DBA_HIST_SQLSTAT',
    'SYS.DBA_HIST_SQLBIND',
    'SYS.DBA_HIST_OPTIMIZER_ENV',
    'SYS.DBA_HIST_SNAPSHOT',
    'SYS.DBA_HIST_ACTIVE_SESS_HISTORY'
  );

  v_ok   PLS_INTEGER := 0;
  v_fail PLS_INTEGER := 0;

  PROCEDURE try(p_sql VARCHAR2) IS
  BEGIN
    EXECUTE IMMEDIATE p_sql;
    v_ok := v_ok + 1;
  EXCEPTION WHEN OTHERS THEN
    v_fail := v_fail + 1;
    DBMS_OUTPUT.PUT_LINE('FAIL :: ' || p_sql || ' :: ' || SQLERRM);
  END;
BEGIN
  FOR i IN 1 .. v_sys_privs.COUNT LOOP
    try('GRANT ' || v_sys_privs(i) || ' TO ' || c_tune_role);
  END LOOP;

  FOR i IN 1 .. v_roles.COUNT LOOP
    try('GRANT ' || v_roles(i) || ' TO ' || c_tune_role);
  END LOOP;

  FOR i IN 1 .. v_objs.COUNT LOOP
    try('GRANT SELECT ON ' || v_objs(i) || ' TO ' || c_tune_role);
  END LOOP;

  try('GRANT EXECUTE ON SYS.DBMS_SQLTUNE TO ' || c_tune_role);

  DBMS_OUTPUT.PUT_LINE('---------------------------------------------');
  DBMS_OUTPUT.PUT_LINE('Tuning grants  ok=' || v_ok || '  fail=' || v_fail);
END;
/


PROMPT ==== 5. GRANT BOTH ROLES TO USERS ====
DECLARE
  TYPE t_list IS TABLE OF VARCHAR2(128);
  v_users t_list := t_list(
    'NM324374','SVANZALE','NM209935','KGUNDELL',
    'AAGRAWA1','MBOONE','BEVANS','NM183530'
  );
  v_roles t_list := t_list('NMH_ALL_SYSADM','NMH_SQL_TUNING');
  v_exists PLS_INTEGER;
BEGIN
  FOR i IN 1 .. v_users.COUNT LOOP
    SELECT COUNT(*) INTO v_exists FROM dba_users WHERE username = v_users(i);

    IF v_exists = 0 THEN
      DBMS_OUTPUT.PUT_LINE('MISSING USER (not in dba_users): ' || v_users(i));
    ELSE
      FOR j IN 1 .. v_roles.COUNT LOOP
        BEGIN
          EXECUTE IMMEDIATE 'GRANT ' || v_roles(j)
                            || ' TO "' || v_users(i) || '"';
        EXCEPTION WHEN OTHERS THEN
          DBMS_OUTPUT.PUT_LINE('ROLE GRANT FAILED ' || v_roles(j)
                               || ' -> ' || v_users(i) || ' :: ' || SQLERRM);
        END;
      END LOOP;
    END IF;
  END LOOP;
END;
/


PROMPT ==== 6. DEFAULT ROLE -- non-default means not enabled at logon ====
SELECT grantee, granted_role, default_role, admin_option
  FROM dba_role_privs
 WHERE granted_role IN ('NMH_ALL_SYSADM','NMH_SQL_TUNING')
 ORDER BY grantee, granted_role;

-- Generates the fix for anyone showing DEFAULT_ROLE = NO. Review first:
-- DEFAULT ROLE ALL enables every role that user holds.
SELECT DISTINCT 'ALTER USER "' || grantee || '" DEFAULT ROLE ALL;' AS fix_stmt
  FROM dba_role_privs
 WHERE granted_role IN ('NMH_ALL_SYSADM','NMH_SQL_TUNING')
   AND default_role = 'NO';


PROMPT ==== 7. VALIDATION ====

-- 7a. Progress / coverage. Run this from a SECOND session during the run
--     to watch it move -- GRANT auto-commits so it updates live.
SELECT COUNT(DISTINCT table_name) AS done,
       (SELECT COUNT(*) FROM dba_tables
         WHERE owner='SYSADM' AND nested='NO' AND secondary='N'
           AND dropped='NO' AND (iot_type IS NULL OR iot_type='IOT'))
     + (SELECT COUNT(*) FROM dba_views WHERE owner='SYSADM') AS total
  FROM dba_tab_privs
 WHERE grantee='NMH_ALL_SYSADM' AND owner='SYSADM';

-- 7b. Objects holding fewer than all 4 privs -> these still ORA-01031 on DML
SELECT table_name
  FROM dba_tab_privs
 WHERE grantee='NMH_ALL_SYSADM' AND owner='SYSADM'
 GROUP BY table_name
HAVING COUNT(DISTINCT CASE WHEN privilege IN ('SELECT','INSERT','UPDATE','DELETE')
                           THEN privilege END) < 4
 ORDER BY 1;

-- 7c. Objects that got nothing at all
SELECT obj FROM (
  SELECT table_name AS obj FROM dba_tables
   WHERE owner='SYSADM' AND nested='NO' AND secondary='N'
     AND dropped='NO' AND (iot_type IS NULL OR iot_type='IOT')
  UNION ALL
  SELECT view_name FROM dba_views WHERE owner='SYSADM'
  MINUS
  SELECT DISTINCT table_name FROM dba_tab_privs
   WHERE grantee='NMH_ALL_SYSADM' AND owner='SYSADM'
) ORDER BY 1;

-- 7d. The object that was failing
SELECT grantee, owner, table_name, privilege, grantor
  FROM dba_tab_privs
 WHERE table_name = 'PS_FS_MAP_REQUEST'
 ORDER BY grantee, privilege;

-- 7e. NAME RESOLUTION. Your UPDATE had no schema prefix. If a synonym
--     resolves elsewhere, granting on SYSADM does nothing for it.
SELECT owner, synonym_name, table_owner, table_name
  FROM dba_synonyms WHERE synonym_name = 'PS_FS_MAP_REQUEST';

SELECT owner, object_name, object_type, status
  FROM dba_objects WHERE object_name = 'PS_FS_MAP_REQUEST';

-- 7f. Confirm the tuning role carries what you expect
SELECT privilege    FROM dba_sys_privs  WHERE grantee='NMH_SQL_TUNING' ORDER BY 1;
SELECT granted_role FROM dba_role_privs WHERE grantee='NMH_SQL_TUNING' ORDER BY 1;
SELECT owner, table_name, privilege
  FROM dba_tab_privs WHERE grantee='NMH_SQL_TUNING' ORDER BY 1,2,3;


PROMPT ==== 8. TEST AS THE END USER IN A BRAND-NEW SESSION ====
-- Role grants apply only to sessions created AFTER the grant.
-- SQL Developer holds connections open -- disconnect and reconnect first.
--
--   SELECT role FROM session_roles
--    WHERE role IN ('NMH_ALL_SYSADM','NMH_SQL_TUNING');
--
--   UPDATE SYSADM.PS_FS_MAP_REQUEST SET file_path_name = file_path_name
--    WHERE 1 = 0;
--   ROLLBACK;
--
--   SELECT COUNT(*) FROM sys.dba_hist_sqltext WHERE ROWNUM = 1;
--
-- If session_roles shows the role but the UPDATE still fails, the name is
-- resolving elsewhere (7e) or a VPD policy is in play:
--   SELECT object_owner, object_name, policy_name, enable
--     FROM dba_policies WHERE object_name = 'PS_FS_MAP_REQUEST';


-- =====================================================================
-- KNOWN LIMITS -- verify on this instance rather than assuming
--
-- 1. Privileges held through a ROLE are invisible inside definer's-rights
--    PL/SQL. If these users call DBMS_SQLTUNE from a stored procedure the
--    role grants will not apply. Grant directly, or use AUTHID CURRENT_USER.
--
-- 2. OEM_ADVISOR only exists if the OEM catalog scripts were run. ORA-01919
--    in section 4 means the role is absent here -- expected, not a bug.
--
-- 3. SELECT_CATALOG_ROLE likely already covers most DBA_HIST_* and GV_$*
--    objects. The explicit grants are harmless belt-and-braces. Confirm:
--      SELECT table_name FROM dba_tab_privs
--       WHERE grantee='SELECT_CATALOG_ROLE'
--         AND table_name IN ('DBA_HIST_SQLTEXT','GV_$SQL','DBA_HIST_SNAPSHOT');
--
-- 4. Scope is SYSADM tables and views only. Sequences, packages, procedures
--    and types in SYSADM are NOT granted. Add them if the app needs them.
-- =====================================================================

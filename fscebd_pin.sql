-- =====================================================================
-- fscebd_pin.sql   Sets the binds every other script depends on.
-- Edit the four values below if any of them change.
-- Called with @fscebd_pin.sql from the live and rca scripts.
-- =====================================================================
SET DEFINE OFF
SET FEEDBACK OFF

VARIABLE v_pi        NUMBER
VARIABLE v_prcsname  VARCHAR2(12)
VARIABLE v_look      NUMBER
VARIABLE v_upg       VARCHAR2(19)
VARIABLE v_fix       VARCHAR2(19)

BEGIN
  -- process name to analyse
  :v_prcsname := 'FS_CEBD';

  -- how many days of history to pull. AWR retention on FPRD is 365d.
  -- PSPRCSRQST purge policy is the real limit, so this may find fewer runs.
  :v_look := 120;

  -- PeopleTools 8.59 -> 8.62 upgrade
  :v_upg := '2026-06-26 00:00:00';

  -- DBMS_STATS table preferences applied to SYSADM.PS_COMBO_DATA_TBL
  :v_fix := '2026-07-28 12:00:00';

  -- target run. 0 = auto-resolve to the most recent FS_CEBD run.
  :v_pi := 0;

  IF :v_pi = 0 THEN
    BEGIN
      SELECT prcsinstance INTO :v_pi FROM (
        SELECT prcsinstance
        FROM   sysadm.psprcsrqst
        WHERE  prcsname = :v_prcsname
        AND    begindttm IS NOT NULL
        ORDER  BY begindttm DESC)
      WHERE ROWNUM = 1;
    EXCEPTION WHEN NO_DATA_FOUND THEN :v_pi := -1;
    END;
  END IF;
END;
/
SET FEEDBACK OFF

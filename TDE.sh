#!/bin/bash

# Script is to encrypt and decrypt exadata and nonexadata systems

SCRIPT_DIR=/oracle/stagenfs/scripts/shell
TDE_DIR=$SCRIPT_DIR/tde
LOG_DIR=/oracle/stagenfs/scripts/logs/tde
DATETIME=`date +%Y%m%d`
DATE_DETAILED=`date +%Y_%m_%d_%M_%H`
PWD_KEYADMIN=`cat $TDE_DIR/.key_keyadmin`
PWD_KEYSTORE=`cat $TDE_DIR/.key_wallet`
OPTION=$1
DB_UNIQUE_NAME=$2
TDE_DB_PRE_DIR=$LOG_DIR/$DB_UNIQUE_NAME/PRE_ENCRYPTION
TDE_DB_DF_DIR=$LOG_DIR/$DB_UNIQUE_NAME/DATAFILE_ENCRYPTION
TDE_DB_DF_UNENCRYPT_DIR=$LOG_DIR/$DB_UNIQUE_NAME/DATAFILE_ENCRYPTION/UNENCRYPT
TDE_DB_DF_ENCRYPT_DIR=$LOG_DIR/$DB_UNIQUE_NAME/DATAFILE_ENCRYPTION/ENCRYPT
TDE_DB_POST_DIR=$LOG_DIR/$DB_UNIQUE_NAME/POST_ENCRYPTION
TDE_DB_STATUS_DIR=$LOG_DIR/$DB_UNIQUE_NAME
TDE_FAILED_EXEC_DIR=$LOG_DIR/$DB_UNIQUE_NAME/FAILED_EXECS
GREEN="\033[1;32;40m"
RED="\033[1;31;40m"
NORM="\033[0m"
ENDCOLOR="\e[0m"






if [ -z $OPTION ] || [ -z $DB_UNIQUE_NAME ]
then
  echo -e "${RED}Usage : TDE_ENCRYPT_UNENCRYPT.sh OPTION(ENCRYPT OR UNENCRYPT) DB_UNIQUE_NAME${ENDCOLOR}" 
  exit 1
elif [[ $OPTION != 'ENCRYPT' ]] && [[ $OPTION != 'UNENCRYPT' ]]
then
  echo -e "${RED}WRONG OPTION, Usage : TDE_ENCRYPT_UNENCRYPT.sh OPTION(ENCRYPT OR UNENCRYPT) DB_UNIQUE_NAME${ENDCOLOR}"
  exit 1
fi

function CREATE_LOG_DIRS_FUNC () {

# Create the log directories if they dont exist
if [[ ! -d "${TDE_DB_STATUS_DIR}" ]] || [[ ! -d "${TDE_DB_PRE_DIR}" ]] || [[ ! -d "${TDE_DB_DF_DIR}" ]] || [[ ! -d "${TDE_DB_POST_DIR}" ]] || [[ ! -d "${TDE_FAILED_EXEC_DIR}" ]] || [[ ! -d "${TDE_DB_DF_UNENCRYPT_DIR}" ]] || [[ ! -d "${TDE_DB_DF_ENCRYPT_DIR}" ]]
then
  mkdir -p $TDE_DB_STATUS_DIR
  chmod -R 770 $TDE_DB_STATUS_DIR
  mkdir -p $TDE_DB_PRE_DIR
  chmod -R 770 $TDE_DB_PRE_DIR
  mkdir -p $TDE_DB_DF_DIR
  chmod -R 770 $TDE_DB_DF_DIR
  mkdir -p $TDE_DB_POST_DIR
  chmod -R 770 $TDE_DB_POST_DIR
  mkdir -p $TDE_FAILED_EXEC_DIR
  chmod -R 770 $TDE_FAILED_EXEC_DIR  
  mkdir -p $TDE_DB_DF_UNENCRYPT_DIR
  chmod -R 770 $TDE_DB_DF_UNENCRYPT_DIR
  mkdir -p $TDE_DB_DF_ENCRYPT_DIR
  chmod -R 770 $TDE_DB_DF_ENCRYPT_DIR
fi

# Delete old main status log file
if [[ -f $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log ]]
then
  rm $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
fi
}




# CHECK IF THIS IS EXADATA OR NONEXADATA

ASM_RUNNING=`ps -ef|grep pmon|grep ASM|wc -l`

if [ $ASM_RUNNING -gt 0 ]
then
  export HOST_TYPE=EXADATA

  # Setting ASM HOME and then checking if DB_UNIQUE_NAME Exists

  PID_OF_ASM=`ps -ef|grep pmon|grep ASM |awk '{print $2}'`
  GRID_HOME=`ls -l /proc/${PID_OF_ASM}/exe|sed 's/\/bin\/oracle$//'|awk '{print $NF}'`
  CLUSTER_NAME=`$GRID_HOME/bin/cemutlo -n`
  
  if [ $CLUSTER_NAME == 'qa04c' ] || [ $CLUSTER_NAME == 'pr04c' ]
  then
    DATA_DG="+DATA02H"
    RECO_DG="+RECO02"
  elif [ $CLUSTER_NAME == 'cluster-qa02' ]
  then
    DATA_DG="+DATA01"
    RECO_DG="+RECO"
  else
    DATA_DG="+DATA01H"
    RECO_DG="+RECO01"
  fi

  
  
  # Check IF DB Exists, but also check if its running in either MOUNT or OPEN MODE

  DB_EXISTS=`$GRID_HOME/bin/srvctl config database -d $DB_UNIQUE_NAME |grep 'could not be found'|wc -l`

  if [ $DB_EXISTS -gt 0 ]
  then
    mkdir -p $TDE_FAILED_EXEC_DIR
    chmod -R 777 $TDE_FAILED_EXEC_DIR
	  mkdir -p $TDE_DB_STATUS_DIR
    chmod -R 777 $TDE_DB_STATUS_DIR
    echo -e "${RED}WRONG DB_UNIQUE_NAME USED $DB_UNIQUE_NAME DOESNT EXIST${ENDCOLOR}" | tee $TDE_FAILED_EXEC_DIR/FAILED_EXEC_${DATETIME}.log
	  echo -e "${RED}WRONG DB_UNIQUE_NAME USED $DB_UNIQUE_NAME DOESNT EXIST${ENDCOLOR}" >> $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
    exit 1
  elif [[ $DB_EXISTS == 0 ]]
  then
    echo "$DB_UNIQUE_NAME EXISTS ON THE CLUSTER, CHECKING IF ITS RUNNING"
	  CREATE_LOG_DIRS_FUNC
    DB_HOME=`$GRID_HOME/bin/srvctl config database -v |grep $DB_UNIQUE_NAME | awk '{print $2}'`
    export ORACLE_HOME=$DB_HOME
    ROLE_OF_DB=`${ORACLE_HOME}/bin/srvctl config database -d $DB_UNIQUE_NAME |grep role| awk '{print $3}'`
    echo $ROLE_OF_DB
    if [[ $ROLE_OF_DB == 'PRIMARY' ]]
    then
      DB_INST_CLOSED=`$ORACLE_HOME/bin/srvctl status database -d $DB_UNIQUE_NAME -v | grep 'not running\|Closed\|Dismounted'| wc -l`
      if [ $DB_INST_CLOSED -gt 0 ]
      then
        echo -e "${RED}$DB_UNIQUE_NAME HAS ONE OR ALL INSTANCES ARE IN STOPPED,NOMOUNT,MOUNT STATUS. PLEASE START ALL INSTANCES${ENDCOLOR}" | tee $TDE_FAILED_EXEC_DIR/FAILED_EXEC_${DATETIME}.log
		    echo -e "${RED}$DB_UNIQUE_NAME HAS ONE OR ALL INSTANCES ARE IN STOPPED,NOMOUNT,MOUNT STATUS. PLEASE START ALL INSTANCES${ENDCOLOR}" >> $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
        exit 1
      fi
    elif [[ $ROLE_OF_DB == 'PHYSICAL_STANDBY' ]]
    then
      DB_INST_CLOSED=`$ORACLE_HOME/bin/srvctl status database -d $DB_UNIQUE_NAME -v | grep 'not running\|Open\|Dismounted'| wc -l`
      if [ $DB_INST_CLOSED -gt 0 ]
      then
        echo -e "${RED}PHYSICAL STANDBY $DB_UNIQUE_NAME HAS ONE OR ALL INSTANCES IN STOPPED,NOMOUNT,OPEN STATUS. PLEASE START ALL INSTANCES IN MOUNT STATUS${ENDCOLOR}" | tee $TDE_FAILED_EXEC_DIR/FAILED_EXEC_${DATETIME}.log
		    echo -e "${RED}PHYSICAL STANDBY $DB_UNIQUE_NAME HAS ONE OR ALL INSTANCES IN STOPPED,NOMOUNT,OPEN STATUS. PLEASE START ALL INSTANCES IN MOUNT STATUS${ENDCOLOR}" >> $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
        exit 1
      fi
    else
      echo -e "${RED}$DB_UNIQUE_NAME IS NOT PRIMARY OR PHYSICAL_STANDBY${ENDCOLOR}" | tee $TDE_FAILED_EXEC_DIR/FAILED_EXEC_${DATETIME}.log
      echo -e "${RED}$DB_UNIQUE_NAME IS NOT PRIMARY OR PHYSICAL_STANDBY${ENDCOLOR}" >> $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log 
      exit 1
    fi
	
	# CHECK IF THE SCRIPT IS RUNNING ON FIRST INSTANCE NODE OF THE DATABASE, AND IF NOT, THEN RESTART IT ON THE FIRST NODE OF THE DB
	
    SCRIPT_HOSTNAME=`hostname -s`
	  FIRST_INST_HOST_NAME=`${ORACLE_HOME}/bin/srvctl config database -d ${DB_UNIQUE_NAME} | grep 'Configured nodes'| awk '{print $3}'| awk -F ',' '{print $1}'`
	
	  echo "SCRIPT RUNNING ON $SCRIPT_HOSTNAME" | tee -a $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
	  echo "FIRST NODE OF ${DB_UNIQUE_NAME} IS ON $FIRST_INST_HOST_NAME" | tee -a $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
	
	
	  if [[ "$SCRIPT_HOSTNAME" != "$FIRST_INST_HOST_NAME" ]]
	  then
	    ssh $FIRST_INST_HOST_NAME "nohup /oracle/stagenfs/scripts/shell/tde/tde.sh $OPTION $DB_UNIQUE_NAME > /dev/null 2>&1 &"
	    exit 0
	  fi
	 
	
  fi
else
  export HOST_TYPE=NONEXADATA
fi



### GET VERSION OF DB

function VERSION_OF_DB () {
  
  $ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF > /dev/null
  set head off
  set pages 1
  spool $TDE_DB_PRE_DIR/VERSION_OF_DB.log
  select 'VERSION='||value from v\$parameter where name = 'compatible';
  spool off
  exit
  
EOF
  
  if grep -q "19." $TDE_DB_PRE_DIR/VERSION_OF_DB.log
  then
    DB_VERSION=19
  else
    DB_VERSION=12
  fi

}
  
  
  




#### CREATE SYSKM

function CREATE_SYSKM_DBUSER () {

  # CHECK IF KEYADMIN EXISTS FIRST

  $ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF > /dev/null
  spool $TDE_DB_PRE_DIR/CHECK_USER_KEYADMIN_EXISTS.log
  select 'USERNAME='||count(*) from dba_users where username = 'KEYADMIN';
  exit

EOF

  if grep -q 'USERNAME=1' "$TDE_DB_PRE_DIR/CHECK_USER_KEYADMIN_EXISTS.log"
  then
	  echo -e "${GREEN} CREATE_SYSKM_DBUSER = SUCCESS, SKIPPED AS ALREADY CREATED, MOVING ON TO NEXT STEP ${ENDCOLOR}" | tee -a $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
  else
    $ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF > /dev/null
    spool $TDE_DB_PRE_DIR/CREATE_USER_KEYADMIN.log
    create user keyadmin identified by "${PWD_KEYADMIN}";
    grant syskm to keyadmin;
    select 'USERNAME='||count(*) from dba_users where username = 'KEYADMIN';
    exit
EOF


  # CHECK IF IT EXISTS AFTER CREATING NOW

    if grep -q 'USERNAME=1' "$TDE_DB_PRE_DIR/CREATE_USER_KEYADMIN.log"
    then
      echo -e "${GREEN} CREATE_SYSKM_DBUSER = SUCCESS,CREATED, MOVING ON TO NEXT STEP ${ENDCOLOR}" | tee -a $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
    else
      echo -e "${RED} CREATE_SYSKM_DBUSER = ERROR, NOT CREATED, PLEASE CHECK ERRORS IN $TDE_DB_PRE_DIR/CREATE_USER_KEYADMIN.log ${ENDCOLOR}" | tee $TDE_FAILED_EXEC_DIR/FAILED_EXEC_${DATETIME}.log
	    echo -e "${RED} CREATE_SYSKM_DBUSER = ERROR, NOT CREATED, PLEASE CHECK ERRORS IN $TDE_DB_PRE_DIR/CREATE_USER_KEYADMIN.log ${ENDCOLOR}" >> $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
	    exit 1
    fi
  fi
  
  
  #
  

}



function CREATE_WALLET_DIR () {

  # Create Directory in ASM for Exadata and for Nonexadata create in ORACLE_BASE
  
  if [[ $HOST_TYPE == 'EXADATA' ]] 
  then
    PID_OF_ASM=`ps -ef|grep pmon|grep ASM |awk '{print $2}'`
    ORACLE_HOME=`ls -l /proc/${PID_OF_ASM}/exe|sed 's/\/bin\/oracle$//'|awk '{print $NF}'`
	  ORACLE_SID=`ps -ef|grep pmon|grep ASM|awk '{print $8}'|awk -F '_' '{print $3}'`
	  $ORACLE_HOME/bin/asmcmd mkdir ${DATA_DG}/${DB_UNIQUE_NAME}/WALLET > /dev/null 2>&1
	  $ORACLE_HOME/bin/asmcmd mkdir ${DATA_DG}/${DB_UNIQUE_NAME}/WALLET/tde > /dev/null 2>&1
	  IS_WALLET_DIR_CREATED=`${GRID_HOME}/bin/asmcmd ls ${DATA_DG}/${DB_UNIQUE_NAME}/WALLET |grep 'tde'|wc -l`
	  if [[ $IS_WALLET_DIR_CREATED -gt 0 ]] 
	  then
	    echo -e "${GREEN} CREATE_WALLET_DIR = SUCCESS,CREATED, MOVING ON TO NEXT STEP ${ENDCOLOR}" | tee -a $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
	  else
	    echo -e "${RED} CREATE_WALLET_DIR = ERROR, NOT CREATED ${ENDCOLOR}" | tee $TDE_FAILED_EXEC_DIR/FAILED_EXEC_${DATETIME}.log
	    echo -e "${RED} CREATE_WALLET_DIR = ERROR, NOT CREATED ${ENDCOLOR}" >> $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
	    exit 1
	  fi
  elif [[ $HOST_TYPE == 'NONEXADATA' ]]
  then  
    echo $HOST_TYPE
	  mkdir -p $ORACLE_BASE/TDE_WALLET/${DB_UNIQUE_NAME}/tde
    if [[ -d "${ORACLE_BASE}/TDE_WALLET/${DB_UNIQUE_NAME}/tde" ]] 
	  then
	    echo -e "${GREEN} CREATE_WALLET_DIR = SUCCESS, CREATED, MOVING ON TO NEXT STEP ${ENDCOLOR}" | tee -a $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
	  else
	    echo -e "${RED} CREATE_WALLET_DIR = ERROR, NOT CREATED ${ENDCOLOR}" | tee $TDE_FAILED_EXEC_DIR/FAILED_EXEC_${DATETIME}.log
	    echo -e "${RED} CREATE_WALLET_DIR = ERROR, NOT CREATED ${ENDCOLOR}" >> $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
	    exit 1
	  fi
  fi
  

}



function CREATE_TNS_CONFIG_FILES_PRE_19 () {

  # Only do this for pre 19c DB systems, determine if Exadata and 12c, or nonexadata and 12c for this DB
  
  
  if [[ $HOST_TYPE == 'EXADATA' ]] && [[ $DB_VERSION -eq 12 ]]
  then
    /usr/local/bin/dcli -g /opt/oracle.SupportTools/onecommand/dbs_group -l oracle "if [ ! -d "/u01/app/oracle/TNSADMIN/${DB_UNIQUE_NAME}" ] ; then mkdir -p /u01/app/oracle/TNSADMIN/${DB_UNIQUE_NAME} ; fi"
    IS_TNSADMIN_DIR_CREATED=`/usr/local/bin/dcli -g /opt/oracle.SupportTools/onecommand/dbs_group -l oracle "if [ ! -d "/u01/app/oracle/TNSADMIN/${DB_UNIQUE_NAME}" ] ; then echo "TNSADMIN DIR NOT CREATED" ; fi" |grep 'TNSADMIN DIR NOT CREATED' |wc -l`
	  if [[ $IS_TNSADMIN_DIR_CREATED -eq 0 ]]
	  then
	    PID_OF_ASM=`ps -ef|grep pmon|grep ASM |awk '{print $2}'`
      GRID_HOME=`ls -l /proc/${PID_OF_ASM}/exe|sed 's/\/bin\/oracle$//'|awk '{print $NF}'`
	    cp ${GRID_HOME}/network/admin/sqlnet.ora $TDE_DB_PRE_DIR/staged_sqlnet.ora
	    if [[ -f "${TDE_DB_PRE_DIR}/staged_sqlnet.ora" ]] 
	    then
	      echo "ENCRYPTION_WALLET_LOCATION = (SOURCE = (METHOD = FILE)(METHOD_DATA = (DIRECTORY = ${DATA_DG}/${DB_UNIQUE_NAME}/WALLET/tde)))" >> ${TDE_DB_PRE_DIR}/staged_sqlnet.ora
		    WALLET_LOC="ENCRYPTION_WALLET_LOCATION = (SOURCE = (METHOD = FILE)(METHOD_DATA = (DIRECTORY = ${DATA_DG}/${DB_UNIQUE_NAME}/WALLET/tde)))"
		    SQLNET_STAGED_CONTAINS_WALLETLOC=`cat ${TDE_DB_PRE_DIR}/staged_sqlnet.ora| grep -i "$WALLET_LOC" | wc -l`
		    if [[ $SQLNET_STAGED_CONTAINS_WALLETLOC -ge 1 ]]
		    then
		      /usr/local/bin/dcli -g /opt/oracle.SupportTools/onecommand/dbs_group -l oracle "if [ ! -f "/u01/app/oracle/TNSADMIN/${DB_UNIQUE_NAME}/sqlnet.ora" ] ; then cp -Rp "${TDE_DB_PRE_DIR}/staged_sqlnet.ora"  /u01/app/oracle/TNSADMIN/${DB_UNIQUE_NAME}/sqlnet.ora ; fi"
		      IS_SQLNET_FILE_IN_TNSADMIN=`/usr/local/bin/dcli -g /opt/oracle.SupportTools/onecommand/dbs_group -l oracle "if [ ! -f "/u01/app/oracle/TNSADMIN/${DB_UNIQUE_NAME}/sqlnet.ora" ] ; then echo "SQLNET.ORA FILE NOT COPIED TO TNSADMIN" ; fi" |grep 'SQLNET.ORA FILE NOT COPIED' |wc -l`
		        if [[ $IS_SQLNET_FILE_IN_TNSADMIN -eq 0 ]]
		        then
		          if [[ $CLUSTER_NAME == *"-"* ]]
		          then
		            CLU_PREFIX=`cemutlo -n|awk -F '-' '{print $2}'`
		          else 
		            CLU_PREFIX=${CLUSTER_NAME}
		          fi
		          /usr/local/bin/dcli -g /opt/oracle.SupportTools/onecommand/dbs_group -l oracle "if [ ! -f "/u01/app/oracle/TNSADMIN/${DB_UNIQUE_NAME}/tnsnames.ora" ] ; then ln -s /oracle/stagenfs/tnsnames/${CLU_PREFIX}/tnsnames.ora /u01/app/oracle/TNSADMIN/${DB_UNIQUE_NAME}/tnsnames.ora ; fi"
		          IS_TNSNAMES_FILE_IN_TNSADMIN=`/usr/local/bin/dcli -g /opt/oracle.SupportTools/onecommand/dbs_group -l oracle "if [ ! -f "/u01/app/oracle/TNSADMIN/${DB_UNIQUE_NAME}/tnsnames.ora" ] ; then echo "TNSNAMES.ORA FILE NOT LINKED TO TNSADMIN" ; fi" |grep 'TNSNAMES.ORA FILE NOT LINKED' |wc -l`
              if [[ $IS_TNSNAMES_FILE_IN_TNSADMIN -eq 0 ]] 
			        then
			          echo -e "${GREEN} CREATE_TNS_CONFIG_FILES_PRE_19 = SUCCESS, CREATED, MOVING ON TO NEXT STEP ${ENDCOLOR}" | tee -a $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
			        else
	              echo -e "${RED} CREATE_TNS_CONFIG_FILES_PRE_19 = ERROR, LINKING OF TNSNAMES.ORA TO TNSADMIN DIR FAILED ${ENDCOLOR}" | tee $TDE_FAILED_EXEC_DIR/FAILED_EXEC_${DATETIME}.log
	              echo -e "${RED} CREATE_TNS_CONFIG_FILES_PRE_19 = ERROR, LINKING OF TNSNAMES.ORA TO TNSADMIN DIR FAILED ${ENDCOLOR}" >> $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
		            exit 1		    			
			        fi
		        else
	            echo -e "${RED} CREATE_TNS_CONFIG_FILES_PRE_19 = ERROR, COPYING OF SQLNET.ORA FROM STAGE DIR TO TNSADMIN DIR FAILED ${ENDCOLOR}" | tee $TDE_FAILED_EXEC_DIR/FAILED_EXEC_${DATETIME}.log
	            echo -e "${RED} CREATE_TNS_CONFIG_FILES_PRE_19 = ERROR, COPYING OF SQLNET.ORA FROM STAGE DIR TO TNSADMIN DIR FAILED ${ENDCOLOR}" >> $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
		          exit 1		    
		        fi
		      else
		        echo -e "${RED} CREATE_TNS_CONFIG_FILES_PRE_19 = ERROR, STAGED SQLNET.ORA DOES NOT CONTAIN WALLETLOC ${ENDCOLOR}" | tee $TDE_FAILED_EXEC_DIR/FAILED_EXEC_${DATETIME}.log
	          echo -e "${RED} CREATE_TNS_CONFIG_FILES_PRE_19 = ERROR, STAGED SQLNET.ORA DOES NOT CONTAIN WALLETLOC ${ENDCOLOR}" >> $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
		        exit 1
          fi 
	      else
	        echo -e "${RED} CREATE_TNS_CONFIG_FILES_PRE_19 = ERROR, COPYING OF SQLNET.ORA FROM GRID_HOME TO STAGE DIR FAILED ${ENDCOLOR}" | tee $TDE_FAILED_EXEC_DIR/FAILED_EXEC_${DATETIME}.log
	        echo -e "${RED} CREATE_TNS_CONFIG_FILES_PRE_19 = ERROR, COPYING OF SQLNET.ORA FROM GRID_HOME TO STAGE DIR FAILED ${ENDCOLOR}" >> $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
		      exit 1
	      fi
	    else
	      echo -e "${RED} CREATE_TNS_CONFIG_FILES_PRE_19 = ERROR, TNSADMIN_DIR NOT CREATED ON ALL NODES ${ENDCOLOR}" | tee $TDE_FAILED_EXEC_DIR/FAILED_EXEC_${DATETIME}.log
	      echo -e "${RED} CREATE_TNS_CONFIG_FILES_PRE_19 = ERROR, TNSADMIN_DIR NOT CREATED ON ALL NODES ${ENDCOLOR}" >> $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
	      exit 1
	    fi
    elif [[ $HOST_TYPE == 'NONEXADATA' ]] && [[ $DB_VERSION -eq 12 ]]
    then
      echo "ENCRYPTION_WALLET_LOCATION = (SOURCE = (METHOD = FILE)(METHOD_DATA = (DIRECTORY = ${ORACLE_BASE}/TDE_WALLET/${DB_UNIQUE_NAME}/tde)))" >> $ORACLE_HOME/network/admin/sqlnet.ora
      SQLNETORA_CONTAINS_WALLETLOC=`grep -i "ENCRYPTION_WALLET_LOCATION = (SOURCE = (METHOD = FILE)(METHOD_DATA = (DIRECTORY = ${ORACLE_BASE}/TDE_WALLET/${DB_UNIQUE_NAME}/tde)))" |wc -l`
	    if [[ ${SQLNETORA_CONTAINS_WALLETLOC} -ge 1 ]]
      then
        echo -e "${GREEN} CREATE_TNS_CONFIG_FILES_PRE_19 = SUCCESS, CREATED, MOVING ON TO NEXT STEP ${ENDCOLOR}" | tee -a $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log	
	    else
	      echo -e "${RED} CREATE_TNS_CONFIG_FILES_PRE_19 = ERROR, SQLNET.ORA DOES NOT CONTAIN WALLETLOC ${ENDCOLOR}" | tee $TDE_FAILED_EXEC_DIR/FAILED_EXEC_${DATETIME}.log
	      echo -e "${RED} CREATE_TNS_CONFIG_FILES_PRE_19 = ERROR, SQLNET.ORA DOES NOT CONTAIN WALLETLOC ${ENDCOLOR}" >> $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
	      exit 1
	    fi
    else
      echo -e "${GREEN} CREATE_TNS_CONFIG_FILES_PRE_19 = SUCCESS, SKIPPED, AS THIS IS 19C ${ENDCOLOR}" | tee -a $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log	
    fi

}


function DB_RESTART () {
  
  if [[ $HOST_TYPE == 'EXADATA' ]] && [[ $DB_VERSION -eq 12 ]]
  then
    ${ORACLE_HOME}/bin/srvctl stop database -d ${DB_UNIQUE_NAME} 
    IS_DB_RUNNING=`${ORACLE_HOME}/bin/srvctl status database -d ${DB_UNIQUE_NAME} -v |grep 'is running'|wc -l`
    if [[ $IS_DB_RUNNING -gt 0 ]]
    then
      echo -e "${RED} SETUP_CLUSTER_PARAMETERS_PRE_19 = ERROR, DB RESTART FAILED AFTER STOP ${ENDCOLOR}" | tee $TDE_FAILED_EXEC_DIR/FAILED_EXEC_${DATETIME}.log
      echo -e "${RED} SETUP_CLUSTER_PARAMETERS_PRE_19 = ERROR, DB RESTART FAILED AFTER STOP ${ENDCOLOR}" >>  $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
      exit 1
    else
      ${ORACLE_HOME}/bin/srvctl start database -d ${DB_UNIQUE_NAME} 
      IS_DB_RUNNING_AFTER_START=`${ORACLE_HOME}/bin/srvctl status database -d ${DB_UNIQUE_NAME} -v |grep 'not running\|Closed\|Dismounted'| wc -l`
      if [[ $IS_DB_RUNNING_AFTER_START -gt 0 ]]
      then
        echo -e "${RED} SETUP_CLUSTER_PARAMETERS_PRE_19 = ERROR, DB RESTART FAILED AFTER START ${ENDCOLOR}" | tee $TDE_FAILED_EXEC_DIR/FAILED_EXEC_${DATETIME}.log
        echo -e "${RED} SETUP_CLUSTER_PARAMETERS_PRE_19 = ERROR, DB RESTART FAILED AFTER START ${ENDCOLOR}" >>  $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log   
      fi
    fi

  elif [[ $HOST_TYPE == 'EXADATA' ]] && [[ $DB_VERSION -eq 19 ]]
  then
    ${ORACLE_HOME}/bin/srvctl stop database -d ${DB_UNIQUE_NAME} 
    IS_DB_RUNNING=`${ORACLE_HOME}/bin/srvctl status database -d ${DB_UNIQUE_NAME} -v |grep 'is running'|wc -l`
    if [[ $IS_DB_RUNNING -gt 0 ]]
    then
      echo -e "${RED} SETUP_DB_WALLET_PARAMS_19 = ERROR, DB RESTART FAILED AFTER STOP ${ENDCOLOR}" | tee $TDE_FAILED_EXEC_DIR/FAILED_EXEC_${DATETIME}.log
      echo -e "${RED} SETUP_DB_WALLET_PARAMS_19 = ERROR, DB RESTART FAILED AFTER STOP ${ENDCOLOR}" >>  $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
      exit 1
    else
      ${ORACLE_HOME}/bin/srvctl start database -d ${DB_UNIQUE_NAME} 
      IS_DB_RUNNING_AFTER_START=`${ORACLE_HOME}/bin/srvctl status database -d ${DB_UNIQUE_NAME} -v |grep 'not running\|Closed\|Dismounted'| wc -l`
      if [[ $IS_DB_RUNNING_AFTER_START -gt 0 ]]
      then
        echo -e "${RED} SETUP_DB_WALLET_PARAMS_19 = ERROR, DB RESTART FAILED AFTER START ${ENDCOLOR}" | tee $TDE_FAILED_EXEC_DIR/FAILED_EXEC_${DATETIME}.log
        echo -e "${RED} SETUP_DB_WALLET_PARAMS_19 = ERROR, DB RESTART FAILED AFTER START ${ENDCOLOR}" >>  $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log   
      fi
    fi

  elif [[ $HOST_TYPE == 'NONEXADATA' ]]
  then
    ${ORACLE_HOME}/bin/sqlplus -s / as sysdba <<EOF > /dev/null
    shutdown immediate;
    exit
EOF
    IS_DB_RUNNING=`ps -ef|grep pmon|grep ${DB_UNIQUE_NAME} | wc -l`
    if [[ $IS_DB_RUNNING -gt 0 ]]
    then
      echo -e "${RED} DB_RESTART = ERROR, DB RESTART FAILED ${ENDCOLOR}" | tee $TDE_FAILED_EXEC_DIR/FAILED_EXEC_${DATETIME}.log
      echo -e "${RED} DB_RESTART = ERROR, DB RESTART FAILED ${ENDCOLOR}" >>  $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
      exit 1
    else
      ${ORACLE_HOME}/bin/sqlplus -s / as sysdba <<EOF > /dev/null
      startup;
      spool ${TDE_DB_STATUS_DIR}/DB_RESTARTED_NONEXADATA_${DATE_DETAILED}.log
      select 'INSTANCE_STATUS='||status from v\$instance;
      spool off
      exit
EOF
      IS_DB_RUNNING_AFTER_START=`cat ${TDE_DB_STATUS_DIR}/DB_RESTARTED_NONEXADATA_DATE_DETAILED.log|grep 'INSTANCE_STATUS=OPEN' | wc -l `
      if [[ $IS_DB_RUNNING_AFTER_START -eq 0 ]]
      then
        echo -e "${RED} DB_RESTART = ERROR, DB RESTART FAILED ${ENDCOLOR}" | tee $TDE_FAILED_EXEC_DIR/FAILED_EXEC_${DATETIME}.log
        echo -e "${RED} DB_RESTART = ERROR, DB RESTART FAILED ${ENDCOLOR}" >>  $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
        exit 1
      else
        echo -e "${GREEN} DB_RESTART = SUCCESS, DB RESTARTED, MOVING ON TO NEXT STEP ${ENDCOLOR}" | tee -a $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
      fi
    fi
  fi

}



function SETUP_CLUSTER_PARAMETERS_PRE_19 () {

  if [[ $HOST_TYPE == 'EXADATA' ]] && [[ $DB_VERSION -eq 12 ]]
  then
    ${ORACLE_HOME}/bin/srvctl setenv database -d ${DB_UNIQUE_NAME} -T "ORACLE_BASE=${ORACLE_BASE}"
	  ${ORACLE_HOME}/bin/srvctl setenv database -d ${DB_UNIQUE_NAME} -T "ORACLE_UNQNAME=${DB_UNIQUE_NAME}"
	  ${ORACLE_HOME}/bin/srvctl setenv database -d ${DB_UNIQUE_NAME} -T "TNS_ADMIN=${ORACLE_BASE}/TNSADMIN/${DB_UNIQUE_NAME}"
    
    #CALL FUNCTION DB_RESTART
    DB_RESTART
    . /oracle/stagenfs/scripts/shell/setoraenv.ksh ${DB_UNIQUE_NAME} > /dev/null
	
	  CHECK_ORACLE_BASE_SET=`${ORACLE_HOME}/bin/srvctl getenv database -d ${DB_UNIQUE_NAME} | grep "ORACLE_BASE=${ORACLE_BASE}" | wc -l`
	  CHECK_ORACLE_UNQNAME_SET=`${ORACLE_HOME}/bin/srvctl getenv database -d ${DB_UNIQUE_NAME} | grep "ORACLE_UNQNAME=${DB_UNIQUE_NAME}" | wc -l`
	  CHECK_ORACLE_TNSADMIN_SET=`${ORACLE_HOME}/bin/srvctl getenv database -d ${DB_UNIQUE_NAME} | grep "TNS_ADMIN=${ORACLE_BASE}/TNSADMIN/${DB_UNIQUE_NAME}" | wc -l`
	
    if [[ ${CHECK_ORACLE_BASE_SET} -eq 1 ]] && [[ ${CHECK_ORACLE_UNQNAME_SET} -eq 1 ]] && [[ ${CHECK_ORACLE_TNSADMIN_SET} -eq 1 ]]
	  then
	    echo -e "${GREEN} SETUP_CLUSTER_PARAMETERS_PRE_19 = SUCCESS, SETUP CLUSTER CONFIGS, MOVING ON TO NEXT STEP ${ENDCOLOR}" | tee -a $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
	  else
	    echo -e "${RED} SETUP_CLUSTER_PARAMETERS_PRE_19 = ERROR, SETUP CLUSTER CONFIGS FAILED TO SETUP CLUSTER PARAMS ${ENDCOLOR}" | tee $TDE_FAILED_EXEC_DIR/FAILED_EXEC_${DATETIME}.log
	    echo -e "${RED} SETUP_CLUSTER_PARAMETERS_PRE_19 = ERROR, SETUP CLUSTER CONFIGS FAILED TO SETUP CLUSTER PARAMS ${ENDCOLOR}" >> $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
	    exit 1
	  fi
  else
    echo -e "${GREEN} SETUP_CLUSTER_PARAMETERS_PRE_19 = SUCCESS, SKIPPING AS THIS IS EITHER NONEXADATA OR NOT PRE 19c, MOVING ON TO NEXT STEP ${ENDCOLOR}" | tee -a $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
  fi

}


function SETUP_DB_WALLET_PARAMS_19 () {

  if [[ $HOST_TYPE == 'EXADATA' ]] && [[ $DB_VERSION -eq 19 ]]
  then
    $ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF > /dev/null
    set echo on
    set feedback on
    spool ${TDE_DB_PRE_DIR}/SET_WALLET_ROOT_DB_PARAMS.log
    alter system set wallet_root = '${DATA_DG}/${DB_UNIQUE_NAME}/WALLET' scope=spfile sid = '*';
    spool off
    exit
EOF
    #CALL FUNCTION DB_RESTART
    DB_RESTART
    
    $ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF > /dev/null
    set echo on
    set feedback on
    spool ${TDE_DB_PRE_DIR}/SET_TDE_CONFIG_DB_PARAMS.log
    alter system set tde_configuration = 'KEYSTORE_CONFIGURATION=FILE' scope=both sid = '*';
    spool off
    exit
EOF

    $ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF > /dev/null
    spool ${TDE_DB_PRE_DIR}/CHECK_WALLET_DB_PARAMS.log
    select 'WALLET_ROOT='||value from v\$parameter where name = 'wallet_root';    
    select 'TDE_CONFIGURATION='||value from v\$parameter where name = 'tde_configuration';
    spool off
    exit
EOF
    WALLET_ROOT_PARAM_CHECK=`cat ${TDE_DB_PRE_DIR}/CHECK_WALLET_DB_PARAMS.log | grep "WALLET_ROOT=${DATA_DG}/${DB_UNIQUE_NAME}/WALLET" | wc -l`
    TDE_CONFIG_PARAM_CHECK=`cat ${TDE_DB_PRE_DIR}/CHECK_WALLET_DB_PARAMS.log | grep 'TDE_CONFIGURATION=KEYSTORE_CONFIGURATION=FILE' | wc -l`

    if [[ ${WALLET_ROOT_PARAM_CHECK} -eq 0 ]] || [[ ${TDE_CONFIG_PARAM_CHECK} -eq 0 ]]
    then
      echo -e "${RED} SETUP_DB_WALLET_PARAMS_19 = ERROR, SETUP/CHECK DB WALLET PARAMS 19C FAILED ${ENDCOLOR}" | tee $TDE_FAILED_EXEC_DIR/FAILED_EXEC_${DATETIME}.log
	    echo -e "${RED} SETUP_DB_WALLET_PARAMS_19 = ERROR, SETUP/CHECK DB WALLET PARAMS 19C FAILED ${ENDCOLOR}" >> $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
	    exit 1
    else
      echo -e "${GREEN} SETUP_DB_WALLET_PARAMS_19 = SUCCESS, SETUP DB WALLET PARAMS 19C, MOVING ON TO NEXT STEP ${ENDCOLOR}" | tee -a $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log  
    fi

  elif [[ $HOST_TYPE == 'NONEXADATA' ]] && [[ $DB_VERSION -eq 19 ]]
  then
    $ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF > /dev/null
    set echo on
    set feedback on
    spool ${TDE_DB_PRE_DIR}/SET_WALLET_ROOT_DB_PARAMS.log
    alter system set wallet_root = '${DATA_DG}/${DB_UNIQUE_NAME}/WALLET' scope=spfile sid = '*';
    spool off
    exit
EOF
    #CALL FUNCTION DB_RESTART
    DB_RESTART
    
    $ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF > /dev/null
    set echo on
    set feedback on
    spool ${TDE_DB_PRE_DIR}/SET_TDE_CONFIG_DB_PARAMS.log
    alter system set tde_configuration = 'KEYSTORE_CONFIGURATION=FILE' scope=both sid = '*';
    spool off
    exit
EOF

    $ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF > /dev/null
    spool ${TDE_DB_PRE_DIR}/CHECK_WALLET_DB_PARAMS.log
    select 'WALLET_ROOT='||value from v\$parameter where name = 'wallet_root';    
    select 'TDE_CONFIGURATION='||value from v\$parameter where name = 'tde_configuration';
    spool off
    exit
EOF
    WALLET_ROOT_PARAM_CHECK=`cat ${TDE_DB_PRE_DIR}/CHECK_WALLET_DB_PARAMS.log | grep "WALLET_ROOT=${ORACLE_BASE}/TDE_WALLET/${DB_UNIQUE_NAME}" | wc -l`
    TDE_CONFIG_PARAM_CHECK=`cat ${TDE_DB_PRE_DIR}/CHECK_WALLET_DB_PARAMS.log | grep 'TDE_CONFIGURATION=KEYSTORE_CONFIGURATION=FILE' | wc -l`

    if [[ ${WALLET_ROOT_PARAM_CHECK} -eq 0 ]] || [[ ${TDE_CONFIG_PARAM_CHECK} -eq 0 ]]
    then
      echo -e "${RED} SETUP_DB_WALLET_PARAMS_19 = ERROR, SETUP/CHECK DB WALLET PARAMS 19C FAILED ${ENDCOLOR}" | tee $TDE_FAILED_EXEC_DIR/FAILED_EXEC_${DATETIME}.log
	    echo -e "${RED} SETUP_DB_WALLET_PARAMS_19 = ERROR, SETUP/CHECK DB WALLET PARAMS 19C FAILED ${ENDCOLOR}" >> $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
	    exit 1
    else
      echo -e "${GREEN} SETUP_DB_WALLET_PARAMS_19 = SUCCESS, SETUP DB WALLET PARAMS 19C, MOVING ON TO NEXT STEP ${ENDCOLOR}" | tee -a $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log  
    fi  
  fi        




}





function CREATE_KEYSTORE_AND_KEY () {

  EXADATA_WALLET=${DATA_DG}/${DB_UNIQUE_NAME}/WALLET/tde
  NONEXADATA_WALLET=${ORACLE_BASE}/TDE_WALLET/${DB_UNIQUE_NAME}/tde
  
  if [[ $HOST_TYPE == 'EXADATA' ]] && [[ $DB_VERSION -eq 19 ]] && [[ $OPTION == 'ENCRYPT' ]]
  then
    $ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF > /dev/null
    set echo on
    set feedback on
    spool ${TDE_DB_PRE_DIR}/CREATE_KEYSTORE.log
    administer key management create keystore identified by ${PWD_KEYSTORE};
    administer key management set keystore open identified by ${PWD_KEYSTORE};
    spool off
    exit
EOF
    $ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF > /dev/null
    spool ${TDE_DB_PRE_DIR}/CHECK_KEYSTORE_CREATED.log
    select 'STATUS='||status from v\$encryption_wallet; 
    spool off
    exit
EOF

    CREATE_KEYSTORE_ERRORS=`cat ${TDE_DB_PRE_DIR}/CREATE_KEYSTORE.log | grep 'ORA-' | wc -l`
    IS_KEYSTORE_CREATED=`cat ${TDE_DB_PRE_DIR}/CHECK_KEYSTORE_CREATED.log | grep 'STATUS=OPEN_NO_MASTER_KEY\|STATUS=OPEN' | wc -l`
    ANY_KEYSTORE_ORA_ERRORS=`cat ${TDE_DB_PRE_DIR}/CHECK_KEYSTORE_CREATED.log | grep 'ORA-' | wc -l`

    if [[ ${IS_KEYSTORE_CREATED} -ne 1 ]] || [[ ${ANY_KEYSTORE_ORA_ERRORS} -ne 0 ]] #|| [[ ${CREATE_KEYSTORE_ERRORS} -ne 0 ]]
    then
      echo -e "${RED} CREATE_KEYSTORE_AND_KEY = ERROR, KEYSTORE CREATION,OPEN FAILED ${ENDCOLOR}" | tee $TDE_FAILED_EXEC_DIR/FAILED_EXEC_${DATETIME}.log
	    echo -e "${RED} CREATE_KEYSTORE_AND_KEY = ERROR, KEYSTORE CREATION,OPEN FAILED ${ENDCOLOR}" >> $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
	    exit 1  
    else 
      $ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF > /dev/null
      set echo on
      set feedback on
      spool ${TDE_DB_PRE_DIR}/CREATE_ENCRYPTION_KEY.log
      administer key management set key force keystore identified by ${PWD_KEYSTORE} with backup;
      spool off
      exit
EOF
      
      $ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF > /dev/null
      spool ${TDE_DB_PRE_DIR}/CHECK_ENCRYPT_KEY_CREATED.log
      select 'STATUS='||status from v\$encryption_wallet; 
      spool off
      exit
EOF
      
      CREATE_ENCRYPTION_KEY_ERRORS=`cat ${TDE_DB_PRE_DIR}/CREATE_ENCRYPTION_KEY.log | grep 'ORA-' | wc -l`
      IS_ENCRYPT_KEY_CREATED=`cat ${TDE_DB_PRE_DIR}/CHECK_ENCRYPT_KEY_CREATED.log | grep 'STATUS=OPEN' | wc -l`
      ANY_ORA_ERRORS=`cat ${TDE_DB_PRE_DIR}/CHECK_ENCRYPT_KEY_CREATED.log | grep 'ORA-' | wc -l`

      if [[ ${IS_ENCRYPT_KEY_CREATED} -ne 1 ]] || [[ ${ANY_ORA_ERRORS} -ne 0 ]] || [[ ${CREATE_ENCRYPTION_KEY_ERRORS} -ne 0 ]]
      then
        echo -e "${RED} CREATE_KEYSTORE_AND_KEY = ERROR, ENCRYPT KEY CREATION FAILED ${ENDCOLOR}" | tee $TDE_FAILED_EXEC_DIR/FAILED_EXEC_${DATETIME}.log
	      echo -e "${RED} CREATE_KEYSTORE_AND_KEY = ERROR, ENCRYPT KEY CREATION FAILED ${ENDCOLOR}" >> $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
	      exit 1  
      else
        $ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF > /dev/null
        set echo on
        set feedback on
        spool ${TDE_DB_PRE_DIR}/CREATE_AUTOLOGIN_KEYSTORE.log
        administer key management create auto_login keystore from keystore identified by ${PWD_KEYSTORE};
        spool off
        exit
EOF

        $ORACLE_HOME/bin/srvctl stop database -d ${DB_UNIQUE_NAME}
        $ORACLE_HOME/bin/srvctl start database -d ${DB_UNIQUE_NAME}
      
        $ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF > /dev/null
        spool ${TDE_DB_PRE_DIR}/CHECK_AUTOLOGIN_KEYSTORE_CREATED.log
        select 'WALLET_TYPE='||WALLET_TYPE from v\$encryption_wallet; 
        spool off
        exit
EOF
 
        CREATE_AUTOLOGIN_KEYSTORE_ERRORS=`cat ${TDE_DB_PRE_DIR}/CREATE_AUTOLOGIN_KEYSTORE.log | grep 'ORA-' | wc -l`
        IS_AUTOLOGIN_KEYSTORE_CREATED=`cat ${TDE_DB_PRE_DIR}/CHECK_AUTOLOGIN_KEYSTORE_CREATED.log | grep 'WALLET_TYPE=AUTOLOGIN' | wc -l`
        ANY_AUTOLOGIN_KEYSTORE_ERRORS=`cat ${TDE_DB_PRE_DIR}/CHECK_AUTOLOGIN_KEYSTORE_CREATED.log | grep 'ORA-' | wc -l`

        if [[ ${IS_AUTOLOGIN_KEYSTORE_CREATED} -ne 1 ]] || [[ ${ANY_AUTOLOGIN_KEYSTORE_ERRORS} -ne 0 ]] ##|| [[ ${CREATE_AUTOLOGIN_KEYSTORE_ERRORS} -ne 0 ]]
        then
          echo -e "${RED} CREATE_KEYSTORE_AND_KEY = ERROR, AUTOLOGIN KEYSTORE CREATION FAILED ${ENDCOLOR}" | tee $TDE_FAILED_EXEC_DIR/FAILED_EXEC_${DATETIME}.log
	        echo -e "${RED} CREATE_KEYSTORE_AND_KEY = ERROR, AUTOLOGIN KEYSTORE CREATION FAILED ${ENDCOLOR}" >> $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
	        exit 1  
        else
          echo -e "${GREEN} CREATE_KEYSTORE_AND_KEY = SUCCESS, KEYSTORE, ENCRYPT KEY, AUTOLOGIN CONFIRUED, MOVING ON TO NEXT STEP ${ENDCOLOR}" | tee -a $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
        fi
      fi
    fi
  


  elif [[ $HOST_TYPE == 'EXADATA' ]] && [[ $DB_VERSION -eq 12 ]]
  then
    $ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF > /dev/null
    set echo on
    set feedback on
    spool ${TDE_DB_PRE_DIR}/CREATE_KEYSTORE.log
    administer key management create keystore '${EXADATA_WALLET}' identified by ${PWD_KEYSTORE};
    administer key management set keystore open identified by ${PWD_KEYSTORE};
    spool off
    exit
EOF
    $ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF > /dev/null
    spool ${TDE_DB_PRE_DIR}/CHECK_KEYSTORE_CREATED.log
    select 'STATUS='||status from v\$encryption_wallet; 
    spool off
    exit
EOF

    CREATE_KEYSTORE_ERRORS=`cat ${TDE_DB_PRE_DIR}/CREATE_KEYSTORE.log | grep 'ORA-' | wc -l`
    IS_KEYSTORE_CREATED=`cat ${TDE_DB_PRE_DIR}/CHECK_KEYSTORE_CREATED.log | grep 'STATUS=OPEN_NO_MASTER_KEY\|STATUS=OPEN' | wc -l`
    #ANY_KEYSTORE_ORA_ERRORS=`cat ${TDE_DB_PRE_DIR}/CHECK_KEYSTORE_CREATED.log | grep 'ORA-' | wc -l`

    if [[ ${IS_KEYSTORE_CREATED} -ne 1 ]] #|| [[ ${ANY_KEYSTORE_ORA_ERRORS} -ne 0 ]] ##|| [[ ${CREATE_KEYSTORE_ERRORS} -ne 0 ]]
    then
      echo -e "${RED} CREATE_KEYSTORE_AND_KEY = ERROR, KEYSTORE CREATION,OPEN FAILED ${ENDCOLOR}" | tee $TDE_FAILED_EXEC_DIR/FAILED_EXEC_${DATETIME}.log
	    echo -e "${RED} CREATE_KEYSTORE_AND_KEY = ERROR, KEYSTORE CREATION,OPEN FAILED ${ENDCOLOR}" >> $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
	    exit 1  
    else 
      $ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF > /dev/null
      set echo on
      set feedback on
      spool ${TDE_DB_PRE_DIR}/CREATE_ENCRYPTION_KEY.log
      administer key management set encryption key identified by ${PWD_KEYSTORE} with backup;
      spool off
      exit
EOF
      
      $ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF > /dev/null
      spool ${TDE_DB_PRE_DIR}/CHECK_ENCRYPT_KEY_CREATED.log
      select 'STATUS='||status from v\$encryption_wallet; 
      spool off
      exit
EOF

      CREATE_ENCRYPTION_KEY_ERRORS=`cat ${TDE_DB_PRE_DIR}/CREATE_ENCRYPTION_KEY.log | grep 'ORA-' | wc -l`
      IS_ENCRYPT_KEY_CREATED=`cat ${TDE_DB_PRE_DIR}/CHECK_ENCRYPT_KEY_CREATED.log | grep 'STATUS=OPEN' | wc -l`
      ANY_ORA_ERRORS=`cat ${TDE_DB_PRE_DIR}/CHECK_ENCRYPT_KEY_CREATED.log | grep 'ORA-' | wc -l`

      if [[ ${IS_ENCRYPT_KEY_CREATED} -ne 1 ]] || [[ ${ANY_ORA_ERRORS} -ne 0 ]] ##|| [[ ${CREATE_ENCRYPTION_KEY_ERRORS} -ne 0 ]]
      then
        echo -e "${RED} CREATE_KEYSTORE_AND_KEY = ERROR, ENCRYPT KEY CREATION FAILED ${ENDCOLOR}" | tee $TDE_FAILED_EXEC_DIR/FAILED_EXEC_${DATETIME}.log
	      echo -e "${RED} CREATE_KEYSTORE_AND_KEY = ERROR, ENCRYPT KEY CREATION FAILED ${ENDCOLOR}" >> $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
	      exit 1  
      else
        $ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF > /dev/null
        set echo on
        set feedback on
        spool ${TDE_DB_PRE_DIR}/CREATE_AUTOLOGIN_KEYSTORE.log
        administer key management create auto_login keystore from keystore '${EXADATA_WALLET}' identified by ${PWD_KEYSTORE};
        spool off
        exit
EOF

        $ORACLE_HOME/bin/srvctl stop database -d ${DB_UNIQUE_NAME}
        $ORACLE_HOME/bin/srvctl start database -d ${DB_UNIQUE_NAME}
      
        $ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF > /dev/null
        spool ${TDE_DB_PRE_DIR}/CHECK_AUTOLOGIN_KEYSTORE_CREATED.log
        select 'WALLET_TYPE='||WALLET_TYPE from v\$encryption_wallet; 
        spool off
        exit
EOF

        CREATE_AUTOLOGIN_KEYSTORE_ERRORS=`cat ${TDE_DB_PRE_DIR}/CREATE_AUTOLOGIN_KEYSTORE.log | grep 'ORA-' | wc -l`
        IS_AUTOLOGIN_KEYSTORE_CREATED=`cat ${TDE_DB_PRE_DIR}/CHECK_AUTOLOGIN_KEYSTORE_CREATED.log | grep 'WALLET_TYPE=AUTOLOGIN' | wc -l`
        ANY_AUTOLOGIN_KEYSTORE_ERRORS=`cat ${TDE_DB_PRE_DIR}/CHECK_AUTOLOGIN_KEYSTORE_CREATED.log | grep 'ORA-' | wc -l`

        if [[ ${IS_AUTOLOGIN_KEYSTORE_CREATED} -ne 1 ]]   # || [[ ${ANY_AUTOLOGIN_KEYSTORE_ERRORS} -ne 0 ]] ##|| [[ ${CREATE_AUTOLOGIN_KEYSTORE_ERRORS} -ne 0 ]]
        then
          echo -e "${RED} CREATE_KEYSTORE_AND_KEY = ERROR, AUTOLOGIN KEYSTORE CREATION FAILED ${ENDCOLOR}" | tee $TDE_FAILED_EXEC_DIR/FAILED_EXEC_${DATETIME}.log
	        echo -e "${RED} CREATE_KEYSTORE_AND_KEY = ERROR, AUTOLOGIN KEYSTORE CREATION FAILED ${ENDCOLOR}" >> $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
	        exit 1  
        else
          echo -e "${GREEN} CREATE_KEYSTORE_AND_KEY = SUCCESS, KEYSTORE, ENCRYPT KEY, AUTOLOGIN CONFIRUED, MOVING ON TO NEXT STEP ${ENDCOLOR}" | tee -a $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
        fi
      fi
    fi





  elif [[ $HOST_TYPE == 'NONEXADATA' ]] && [[ $DB_VERSION -eq 19 ]]
  then
    $ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF > /dev/null
    set echo on
    set feedback on
    spool ${TDE_DB_PRE_DIR}/CREATE_KEYSTORE.log
    administer key management create keystore identified by ${PWD_KEYSTORE};
    administer key management set keystore open identified by ${PWD_KEYSTORE};
    spool off
    exit
EOF
    $ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF > /dev/null
    spool ${TDE_DB_PRE_DIR}/CHECK_KEYSTORE_CREATED.log
    select 'STATUS='||status from v\$encryption_wallet; 
    spool off
    exit
EOF

    CREATE_KEYSTORE_ERRORS=`cat ${TDE_DB_PRE_DIR}/CREATE_KEYSTORE.log | grep 'ORA-' | wc -l`
    IS_KEYSTORE_CREATED=`cat ${TDE_DB_PRE_DIR}/CHECK_KEYSTORE_CREATED.log | grep 'STATUS=OPEN_NO_MASTER_KEY' | wc -l`
    ANY_KEYSTORE_ORA_ERRORS=`cat ${TDE_DB_PRE_DIR}/CHECK_KEYSTORE_CREATED.log | grep 'ORA-' | wc -l`

    if [[ ${IS_KEYSTORE_CREATED} -ne 1 ]] || [[ ${ANY_KEYSTORE_ORA_ERRORS} -ne 0 ]] || [[ ${CREATE_KEYSTORE_ERRORS} -ne 0 ]]
    then
      echo -e "${RED} CREATE_KEYSTORE_AND_KEY = ERROR, KEYSTORE CREATION,OPEN FAILED ${ENDCOLOR}" | tee $TDE_FAILED_EXEC_DIR/FAILED_EXEC_${DATETIME}.log
	    echo -e "${RED} CREATE_KEYSTORE_AND_KEY = ERROR, KEYSTORE CREATION,OPEN FAILED ${ENDCOLOR}" >> $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
	    exit 1  
    else 
      $ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF > /dev/null
      set echo on
      set feedback on
      spool ${TDE_DB_PRE_DIR}/CREATE_ENCRYPTION_KEY.log
      administer key management set encryption key identified by ${PWD_KEYSTORE} with backup;
      spool off
      exit
EOF
      
      $ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF > /dev/null
      spool ${TDE_DB_PRE_DIR}/CHECK_ENCRYPT_KEY_CREATED.log
      select 'STATUS='||status from v\$encryption_wallet; 
      spool off
      exit
EOF

      CREATE_ENCRYPTION_KEY_ERRORS=`cat ${TDE_DB_PRE_DIR}/CREATE_ENCRYPTION_KEY.log | grep 'ORA-' | wc -l`
      IS_ENCRYPT_KEY_CREATED=`cat ${TDE_DB_PRE_DIR}/CHECK_ENCRYPT_KEY_CREATED.log | grep 'STATUS=OPEN' | wc -l`
      ANY_ORA_ERRORS=`cat ${TDE_DB_PRE_DIR}/CHECK_ENCRYPT_KEY_CREATED.log | grep 'ORA-' | wc -l`

      if [[ ${IS_ENCRYPT_KEY_CREATED} -ne 1 ]] || [[ ${ANY_ORA_ERRORS} -ne 0 ]] || [[ ${CREATE_ENCRYPTION_KEY_ERRORS} -ne 0 ]]
      then
        echo -e "${RED} CREATE_KEYSTORE_AND_KEY = ERROR, ENCRYPT KEY CREATION FAILED ${ENDCOLOR}" | tee $TDE_FAILED_EXEC_DIR/FAILED_EXEC_${DATETIME}.log
	      echo -e "${RED} CREATE_KEYSTORE_AND_KEY = ERROR, ENCRYPT KEY CREATION FAILED ${ENDCOLOR}" >> $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
	      exit 1  
      else
        $ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF > /dev/null
        set echo on
        set feedback on
        spool ${TDE_DB_PRE_DIR}/CREATE_AUTOLOGIN_KEYSTORE.log
        administer key management create auto_login keystore from keystore identified by ${PWD_KEYSTORE};
        spool off
        exit
EOF

        $ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF > /dev/null
        shutdown immediate;
        startup;
        exit;
EOF
        $ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF > /dev/null
        spool ${TDE_DB_PRE_DIR}/CHECK_AUTOLOGIN_KEYSTORE_CREATED.log
        select 'WALLET_TYPE='||WALLET_TYPE from v\$encryption_wallet; 
        spool off
        exit
EOF

        CREATE_AUTOLOGIN_KEYSTORE_ERRORS=`cat ${TDE_DB_PRE_DIR}/CREATE_AUTOLOGIN_KEYSTORE.log | grep 'ORA-' | wc -l`
        IS_AUTOLOGIN_KEYSTORE_CREATED=`cat ${TDE_DB_PRE_DIR}/CHECK_AUTOLOGIN_KEYSTORE_CREATED.log | grep 'WALLET_TYPE=AUTOLOGIN' | wc -l`
        ANY_AUTOLOGIN_KEYSTORE_ERRORS=`cat ${TDE_DB_PRE_DIR}/CHECK_AUTOLOGIN_KEYSTORE_CREATED.log | grep 'ORA-' | wc -l`

        if [[ ${IS_AUTOLOGIN_KEYSTORE_CREATED} -ne 1 ]] || [[ ${ANY_AUTOLOGIN_KEYSTORE_ERRORS} -ne 0 ]] || [[ ${CREATE_AUTOLOGIN_KEYSTORE_ERRORS} -ne 0 ]]
        then
          echo -e "${RED} CREATE_KEYSTORE_AND_KEY = ERROR, AUTOLOGIN KEYSTORE CREATION FAILED ${ENDCOLOR}" | tee $TDE_FAILED_EXEC_DIR/FAILED_EXEC_${DATETIME}.log
	        echo -e "${RED} CREATE_KEYSTORE_AND_KEY = ERROR, AUTOLOGIN KEYSTORE CREATION FAILED ${ENDCOLOR}" >> $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
	        exit 1  
        else
          echo -e "${GREEN} CREATE_KEYSTORE_AND_KEY = SUCCESS, KEYSTORE, ENCRYPT KEY, AUTOLOGIN CONFIRUED, MOVING ON TO NEXT STEP ${ENDCOLOR}" | tee -a $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
        fi
      fi
    fi
  
  
  elif [[ $HOST_TYPE == 'NONEXADATA' ]] && [[ $DB_VERSION -eq 12 ]]
  then
    $ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF > /dev/null
    set echo on
    set feedback on
    spool ${TDE_DB_PRE_DIR}/CREATE_KEYSTORE.log
    administer key management create keystore '${NONEXADATA_WALLET}' identified by ${PWD_KEYSTORE};
    administer key management set keystore open identified by ${PWD_KEYSTORE};
    spool off
    exit
EOF
    $ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF > /dev/null
    spool ${TDE_DB_PRE_DIR}/CHECK_KEYSTORE_CREATED.log
    select 'STATUS='||status from v\$encryption_wallet; 
    spool off
    exit
EOF
    CREATE_KEYSTORE_ERRORS=`cat ${TDE_DB_PRE_DIR}/CREATE_KEYSTORE.log | grep 'ORA-' | wc -l`
    IS_KEYSTORE_CREATED=`cat ${TDE_DB_PRE_DIR}/CHECK_KEYSTORE_CREATED.log | grep 'STATUS=OPEN_NO_MASTER_KEY' | wc -l`
    ANY_KEYSTORE_ORA_ERRORS=`cat ${TDE_DB_PRE_DIR}/CHECK_KEYSTORE_CREATED.log | grep 'ORA-' | wc -l`

    if [[ ${IS_KEYSTORE_CREATED} -ne 1 ]] || [[ ${ANY_KEYSTORE_ORA_ERRORS} -ne 0 ]] || [[ ${CREATE_KEYSTORE_ERRORS} -ne 0 ]]
    then
      echo -e "${RED} CREATE_KEYSTORE_AND_KEY = ERROR, KEYSTORE CREATION,OPEN FAILED ${ENDCOLOR}" | tee $TDE_FAILED_EXEC_DIR/FAILED_EXEC_${DATETIME}.log
	    echo -e "${RED} CREATE_KEYSTORE_AND_KEY = ERROR, KEYSTORE CREATION,OPEN FAILED ${ENDCOLOR}" >> $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
	    exit 1  
    else 
      $ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF > /dev/null
      set echo on
      set feedback on
      spool ${TDE_DB_PRE_DIR}/CREATE_ENCRYPTION_KEY.log
      administer key management set encryption key identified by ${PWD_KEYSTORE} with backup;
      spool off
      exit
EOF
      
      $ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF > /dev/null
      spool ${TDE_DB_PRE_DIR}/CHECK_ENCRYPT_KEY_CREATED.log
      select 'STATUS='||status from v\$encryption_wallet; 
      spool off
      exit
EOF
      CREATE_ENCRYPTION_KEY_ERRORS=`cat ${TDE_DB_PRE_DIR}/CREATE_ENCRYPTION_KEY.log | grep 'ORA-' | wc -l`
      IS_ENCRYPT_KEY_CREATED=`cat ${TDE_DB_PRE_DIR}/CHECK_ENCRYPT_KEY_CREATED.log | grep 'STATUS=OPEN' | wc -l`
      ANY_ORA_ERRORS=`cat ${TDE_DB_PRE_DIR}/CHECK_ENCRYPT_KEY_CREATED.log | grep 'ORA-' | wc -l`

      if [[ ${IS_ENCRYPT_KEY_CREATED} -ne 1 ]] || [[ ${ANY_ORA_ERRORS} -ne 0 ]] || [[ ${CREATE_ENCRYPTION_KEY_ERRORS} -ne 0 ]]
      then
        echo -e "${RED} CREATE_KEYSTORE_AND_KEY = ERROR, ENCRYPT KEY CREATION FAILED ${ENDCOLOR}" | tee $TDE_FAILED_EXEC_DIR/FAILED_EXEC_${DATETIME}.log
	      echo -e "${RED} CREATE_KEYSTORE_AND_KEY = ERROR, ENCRYPT KEY CREATION FAILED ${ENDCOLOR}" >> $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
	      exit 1  
      else
        $ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF > /dev/null
        set echo on
        set feedback on
        spool ${TDE_DB_PRE_DIR}/CREATE_AUTOLOGIN_KEYSTORE.log
        administer key management create auto_login keystore from keystore '${NONEXADATA_WALLET}' identified by ${PWD_KEYSTORE};
        spool off
        exit;
EOF

        $ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF > /dev/null
        shutdown immediate;
        startup;
        exit;
EOF
        $ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF > /dev/null
        spool ${TDE_DB_PRE_DIR}/CHECK_AUTOLOGIN_KEYSTORE_CREATED.log
        select 'WALLET_TYPE='||WALLET_TYPE from v\$encryption_wallet; 
        spool off
        exit;
EOF
        CREATE_AUTOLOGIN_KEYSTORE_ERRORS=`cat ${TDE_DB_PRE_DIR}/CREATE_AUTOLOGIN_KEYSTORE.log | grep 'ORA-' | wc -l`
        IS_AUTOLOGIN_KEYSTORE_CREATED=`cat ${TDE_DB_PRE_DIR}/CHECK_AUTOLOGIN_KEYSTORE_CREATED.log | grep 'WALLET_TYPE=AUTOLOGIN' | wc -l`
        ANY_AUTOLOGIN_KEYSTORE_ERRORS=`cat ${TDE_DB_PRE_DIR}/CHECK_AUTOLOGIN_KEYSTORE_CREATED.log | grep 'ORA-' | wc -l`

        if [[ ${IS_AUTOLOGIN_KEYSTORE_CREATED} -ne 1 ]] || [[ ${ANY_AUTOLOGIN_KEYSTORE_ERRORS} -ne 0 ]] || [[ ${CREATE_AUTOLOGIN_KEYSTORE_ERRORS} -ne 0 ]]
        then
          echo -e "${RED} CREATE_KEYSTORE_AND_KEY = ERROR, AUTOLOGIN KEYSTORE CREATION FAILED ${ENDCOLOR}" | tee $TDE_FAILED_EXEC_DIR/FAILED_EXEC_${DATETIME}.log
	        echo -e "${RED} CREATE_KEYSTORE_AND_KEY = ERROR, AUTOLOGIN KEYSTORE CREATION FAILED ${ENDCOLOR}" >> $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
	        exit 1  
        else
          echo -e "${GREEN} CREATE_KEYSTORE_AND_KEY = SUCCESS, KEYSTORE, ENCRYPT KEY, AUTOLOGIN CONFIGURED, MOVING ON TO NEXT STEP ${ENDCOLOR}" | tee -a $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
        fi
      fi
    fi
  fi


}



function OFFLINE_TABLESPACES () {
  
  if [[ $HOST_TYPE == 'EXADATA' ]] && [[ $DB_VERSION -eq 19 ]] 
  then
    $ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF > /dev/null
    set serverout on
    set echo off
    set feedback off
    spool ${TDE_DB_PRE_DIR}/OFFLINE_TABLESPACES_BEFORE.log
    BEGIN
       FOR v_unq_tbsp in (select name from v\$tablespace where name not in ('SYSTEM','SYSAUX') and  name not like '%UNDO%' and name not like '%TEMP%' order by name)
       LOOP
          BEGIN
              EXECUTE IMMEDIATE 'alter tablespace '||v_unq_tbsp.name||' offline';
          EXCEPTION
            WHEN OTHERS THEN
              IF SQLCODE = -01539 THEN
                NULL; -- suppresses ORA-01539 exception
              ELSE
                RAISE;
              END IF;    
          END;
       END LOOP;
       FOR v_unq_tbsp in (select b.name name,a.status status from v\$datafile a, v\$tablespace b where a.ts# = b.ts# and b.name not in ('SYSTEM','SYSAUX') and b.name not like '%UNDO%' and b.name not like '%TEMP%' group by b.name,a.status)
       LOOP
          dbms_output.Put_line(v_unq_tbsp.name||' is '||v_unq_tbsp.status);
       END LOOP;    
    END;
    /

EOF

    IS_ANY_TBSP_ONLINE=`cat ${TDE_DB_PRE_DIR}/OFFLINE_TABLESPACES_BEFORE.log| grep 'ONLINE'| wc -l `

    if [[ ${IS_ANY_TBSP_ONLINE} -gt 0 ]] 
    then
      echo -e "${RED} OFFLINE_TABLESPACES = ERROR, DATA TABLESPACES WERE NOT OFFLINED BEFORE ${OPTION} ${ENDCOLOR}" | tee $TDE_FAILED_EXEC_DIR/FAILED_EXEC_${DATETIME}.log
	    echo -e "${RED} OFFLINE_TABLESPACES = ERROR, DATA TABLESPACES WERE NOT OFFLINED BEFORE ${OPTION}" >> $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
	    exit 1  
    else
      echo -e "${GREEN} OFFLINE_TABLESPACES = SUCCESS, DATA TABLESPACES ARE NOW OFFLINE BEFORE ${OPTION}, MOVING ON TO NEXT STEP ${ENDCOLOR}" | tee -a $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
    fi        

  elif [[ $HOST_TYPE == 'EXADATA' ]] && [[ $DB_VERSION -eq 12 ]] 
  then
    $ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF > /dev/null
    set serverout on
    set echo off
    set feedback off
    spool ${TDE_DB_PRE_DIR}/OFFLINE_TABLESPACES_BEFORE.log
    BEGIN
       FOR v_unq_tbsp in (select name from v\$tablespace where name not in ('SYSTEM','SYSAUX') and  name not like '%UNDO%' and name not like '%TEMP%' order by name)
       LOOP
          BEGIN
              EXECUTE IMMEDIATE 'alter tablespace '||v_unq_tbsp.name||' offline';
          EXCEPTION
            WHEN OTHERS THEN
              IF SQLCODE = -01539 THEN
                NULL; -- suppresses ORA-01539 exception
              ELSE
                RAISE;
              END IF;    
          END;
       END LOOP;
       FOR v_unq_tbsp in (select b.name name,a.status status from v\$datafile a, v\$tablespace b where a.ts# = b.ts# and b.name not in ('SYSTEM','SYSAUX') and b.name not like '%UNDO%' and b.name not like '%TEMP%' group by b.name,a.status)
       LOOP
          dbms_output.Put_line(v_unq_tbsp.name||' is '||v_unq_tbsp.status);
       END LOOP;    
    END;
    /

EOF

    IS_ANY_TBSP_ONLINE=`cat ${TDE_DB_PRE_DIR}/OFFLINE_TABLESPACES_BEFORE.log| grep 'ONLINE'| wc -l `

    if [[ ${IS_ANY_TBSP_ONLINE} -gt 0 ]] 
    then
      echo -e "${RED} OFFLINE_TABLESPACES = ERROR, DATA TABLESPACES WERE NOT OFFLINED BEFORE ${OPTION} ${ENDCOLOR}" | tee $TDE_FAILED_EXEC_DIR/FAILED_EXEC_${DATETIME}.log
	    echo -e "${RED} OFFLINE_TABLESPACES = ERROR, DATA TABLESPACES WERE NOT OFFLINED BEFORE ${OPTION}" >> $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
	    exit 1  
    else
      echo -e "${GREEN} OFFLINE_TABLESPACES = SUCCESS, DATA TABLESPACES ARE NOW OFFLINE BEFORE ${OPTION}, MOVING ON TO NEXT STEP ${ENDCOLOR}" | tee -a $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
    fi        

  elif [[ $HOST_TYPE == 'NONEXADATA' ]] && [[ $DB_VERSION -eq 19 ]] 
  then
    $ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF > /dev/null
    set serverout on
    set echo off
    set feedback off
    spool ${TDE_DB_PRE_DIR}/OFFLINE_TABLESPACES_BEFORE.log
    BEGIN
       FOR v_unq_tbsp in (select name from v\$tablespace where name not in ('SYSTEM','SYSAUX') and  name not like '%UNDO%' and name not like '%TEMP%' order by name)
       LOOP
          BEGIN
              EXECUTE IMMEDIATE 'alter tablespace '||v_unq_tbsp.name||' offline';
          EXCEPTION
            WHEN OTHERS THEN
              IF SQLCODE = -01539 THEN
                NULL; -- suppresses ORA-01539 exception
              ELSE
                RAISE;
              END IF;    
          END;
       END LOOP;
       FOR v_unq_tbsp in (select b.name name,a.status status from v\$datafile a, v\$tablespace b where a.ts# = b.ts# and b.name not in ('SYSTEM','SYSAUX') and b.name not like '%UNDO%' and b.name not like '%TEMP%' group by b.name,a.status)
       LOOP
          dbms_output.Put_line(v_unq_tbsp.name||' is '||v_unq_tbsp.status);
       END LOOP;    
    END;
    /

EOF

    IS_ANY_TBSP_ONLINE=`cat ${TDE_DB_PRE_DIR}/OFFLINE_TABLESPACES_BEFORE.log| grep 'ONLINE'| wc -l `

    if [[ ${IS_ANY_TBSP_ONLINE} -gt 0 ]] 
    then
      echo -e "${RED} OFFLINE_TABLESPACES = ERROR, DATA TABLESPACES WERE NOT OFFLINED BEFORE ${OPTION} ${ENDCOLOR}" | tee $TDE_FAILED_EXEC_DIR/FAILED_EXEC_${DATETIME}.log
	    echo -e "${RED} OFFLINE_TABLESPACES = ERROR, DATA TABLESPACES WERE NOT OFFLINED BEFORE ${OPTION}" >> $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
	    exit 1  
    else
      echo -e "${GREEN} OFFLINE_TABLESPACES = SUCCESS, DATA TABLESPACES ARE NOW OFFLINE BEFORE ${OPTION}, MOVING ON TO NEXT STEP ${ENDCOLOR}" | tee -a $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
    fi        

  elif [[ $HOST_TYPE == 'NONEXADATA' ]] && [[ $DB_VERSION -eq 12 ]] 
  then
    $ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF > /dev/null
    set serverout on
    set echo off
    set feedback off
    spool ${TDE_DB_PRE_DIR}/OFFLINE_TABLESPACES_BEFORE.log
    BEGIN
       FOR v_unq_tbsp in (select name from v\$tablespace where name not in ('SYSTEM','SYSAUX') and  name not like '%UNDO%' and name not like '%TEMP%' order by name)
       LOOP
          BEGIN
              EXECUTE IMMEDIATE 'alter tablespace '||v_unq_tbsp.name||' offline';
          EXCEPTION
            WHEN OTHERS THEN
              IF SQLCODE = -01539 THEN
                NULL; -- suppresses ORA-01539 exception
              ELSE
                RAISE;
              END IF;    
          END;
       END LOOP;
       FOR v_unq_tbsp in (select b.name name,a.status status from v\$datafile a, v\$tablespace b where a.ts# = b.ts# and b.name not in ('SYSTEM','SYSAUX') and b.name not like '%UNDO%' and b.name not like '%TEMP%' group by b.name,a.status)
       LOOP
          dbms_output.Put_line(v_unq_tbsp.name||' is '||v_unq_tbsp.status);
       END LOOP;    
    END;
    /

EOF

    IS_ANY_TBSP_ONLINE=`cat ${TDE_DB_PRE_DIR}/OFFLINE_TABLESPACES_BEFORE.log| grep 'ONLINE'| wc -l `

    if [[ ${IS_ANY_TBSP_ONLINE} -gt 0 ]] 
    then
      echo -e "${RED} OFFLINE_TABLESPACES = ERROR, DATA TABLESPACES WERE NOT OFFLINED BEFORE ${OPTION} ${ENDCOLOR}" | tee $TDE_FAILED_EXEC_DIR/FAILED_EXEC_${DATETIME}.log
	    echo -e "${RED} OFFLINE_TABLESPACES = ERROR, DATA TABLESPACES WERE NOT OFFLINED BEFORE ${OPTION}" >> $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
	    exit 1  
    else
      echo -e "${GREEN} OFFLINE_TABLESPACES = SUCCESS, DATA TABLESPACES ARE NOW OFFLINE BEFORE ${OPTION}, MOVING ON TO NEXT STEP ${ENDCOLOR}" | tee -a $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
    fi
  fi                



}



function ENCRYPT_DATAFILES () {

  if [[ $HOST_TYPE == 'EXADATA' ]] && [[ $DB_VERSION -eq 19 ]] && [[ $OPTION == 'ENCRYPT' ]]
  then

    

    $ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF > /dev/null
    set lines 200
    set pages 0
    set feedback off
    spool ${TDE_DB_DF_DIR}/${DB_UNIQUE_NAME}_DATAFILE_ENCRYPT_MAINLIST.log
    select 'alter database datafile '||chr(39)||df.name||chr(39)||' encrypt;' COMMAND from v\$tablespace ts, v\$datafile df where ts.ts#=df.ts# and ts.name not in ('SYSTEM','SYSAUX') and ts.name not like '%UNDO%' and ts.name not like '%TEMP%'   order by df.name;
    spool off
    exit
EOF
    


    DB_INSTANCE_COUNT=`${ORACLE_HOME}/bin/srvctl status database -d ${DB_UNIQUE_NAME} |awk '{print $2}'| wc -l`
    DATAFILE_COUNT=`cat ${TDE_DB_DF_DIR}/${DB_UNIQUE_NAME}_DATAFILE_ENCRYPT_MAINLIST.log | wc -l`
    SPLIT_LINES_COUNT=`echo $(((${DATAFILE_COUNT} + ${DB_INSTANCE_COUNT} - 1)/${DB_INSTANCE_COUNT}))`
    
    split  --lines=${SPLIT_LINES_COUNT} --suffix-length=1 --numeric-suffixes=1 --additional-suffix=.sql ${TDE_DB_DF_DIR}/${DB_UNIQUE_NAME}_DATAFILE_ENCRYPT_MAINLIST.log ${TDE_DB_DF_ENCRYPT_DIR}/splitted_${DB_NAME}

    LAST_COMMAND_EXIT_STATUS=$?

    if [[ $LAST_COMMAND_EXIT_STATUS -ne 0 ]]
    then 
      echo -e "${RED} ENCRYPT_DATAFILES = ERROR, MAINLIST SPLIT FOR FILES FAILED ${ENDCOLOR}" | tee $TDE_FAILED_EXEC_DIR/FAILED_EXEC_${DATETIME}.log
	    echo -e "${RED} ENCRYPT_DATAFILES = ERROR, MAINLIST SPLIT FOR FILES FAILED ${ENDCOLOR}" >> $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
	    exit 1
    else  
      for INSTANCE_NUMBER in `${ORACLE_HOME}/bin/srvctl status database -d ${DB_UNIQUE_NAME} |awk '{print $2}'|awk '{print NR,$0}'|awk '{print $1}'`
      do  
        COUNTER=0
        DB_INSTANCE_NAME=`${ORACLE_HOME}/bin/srvctl status database -d ${DB_UNIQUE_NAME} |awk '{print $2}'|awk '{print NR,$0}'|awk '{print $2}'|awk -v INSTANCE_NUMBER=${INSTANCE_NUMBER} 'FNR == INSTANCE_NUMBER {print}'`
        while read line 
        do 
          COUNTER=`echo $((${COUNTER}+1))` 
          echo ". /oracle/stagenfs/scripts/shell/setoraenv.ksh ${DB_UNIQUE_NAME} > /dev/null" > ${TDE_DB_DF_ENCRYPT_DIR}/${DB_INSTANCE_NAME}_ENCRYPT_CMD_${COUNTER}.sh
          echo "sleep 30" >> ${TDE_DB_DF_ENCRYPT_DIR}/${DB_INSTANCE_NAME}_ENCRYPT_CMD_${COUNTER}.sh
          echo "$ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF > /dev/null" >> ${TDE_DB_DF_ENCRYPT_DIR}/${DB_INSTANCE_NAME}_ENCRYPT_CMD_${COUNTER}.sh
          echo "set echo on" >> ${TDE_DB_DF_ENCRYPT_DIR}/${DB_INSTANCE_NAME}_ENCRYPT_CMD_${COUNTER}.sh
          echo "set feedback on" >> ${TDE_DB_DF_ENCRYPT_DIR}/${DB_INSTANCE_NAME}_ENCRYPT_CMD_${COUNTER}.sh
          echo "set time on" >> ${TDE_DB_DF_ENCRYPT_DIR}/${DB_INSTANCE_NAME}_ENCRYPT_CMD_${COUNTER}.sh
          echo "set timi on" >> ${TDE_DB_DF_ENCRYPT_DIR}/${DB_INSTANCE_NAME}_ENCRYPT_CMD_${COUNTER}.sh
          echo "spool ${TDE_DB_DF_ENCRYPT_DIR}/${DB_INSTANCE_NAME}_ENCRYPT_CMD_${COUNTER}_ISRUNNING.log" >> ${TDE_DB_DF_ENCRYPT_DIR}/${DB_INSTANCE_NAME}_ENCRYPT_CMD_${COUNTER}.sh
          echo "${line}" >> ${TDE_DB_DF_ENCRYPT_DIR}/${DB_INSTANCE_NAME}_ENCRYPT_CMD_${COUNTER}.sh
          echo "spool off" >> ${TDE_DB_DF_ENCRYPT_DIR}/${DB_INSTANCE_NAME}_ENCRYPT_CMD_${COUNTER}.sh
          echo "exit" >> ${TDE_DB_DF_ENCRYPT_DIR}/${DB_INSTANCE_NAME}_ENCRYPT_CMD_${COUNTER}.sh
          echo "EOF" >> ${TDE_DB_DF_ENCRYPT_DIR}/${DB_INSTANCE_NAME}_ENCRYPT_CMD_${COUNTER}.sh
          echo "if [[ -f ${TDE_DB_DF_ENCRYPT_DIR}/${DB_INSTANCE_NAME}_ENCRYPT_CMD_${COUNTER}_ISRUNNING.log ]]" >> ${TDE_DB_DF_ENCRYPT_DIR}/${DB_INSTANCE_NAME}_ENCRYPT_CMD_${COUNTER}.sh
          echo "then" >> ${TDE_DB_DF_ENCRYPT_DIR}/${DB_INSTANCE_NAME}_ENCRYPT_CMD_${COUNTER}.sh
          echo "  if grep -q "ORA-" ${TDE_DB_DF_ENCRYPT_DIR}/${DB_INSTANCE_NAME}_ENCRYPT_CMD_${COUNTER}_ISRUNNING.log" >> ${TDE_DB_DF_ENCRYPT_DIR}/${DB_INSTANCE_NAME}_ENCRYPT_CMD_${COUNTER}.sh
          echo "  then" >> ${TDE_DB_DF_ENCRYPT_DIR}/${DB_INSTANCE_NAME}_ENCRYPT_CMD_${COUNTER}.sh
          echo "    mv ${TDE_DB_DF_ENCRYPT_DIR}/${DB_INSTANCE_NAME}_ENCRYPT_CMD_${COUNTER}_ISRUNNING.log ${TDE_DB_DF_ENCRYPT_DIR}/${DB_INSTANCE_NAME}_ENCRYPT_CMD_${COUNTER}_FAILED.log" >> ${TDE_DB_DF_ENCRYPT_DIR}/${DB_INSTANCE_NAME}_ENCRYPT_CMD_${COUNTER}.sh
          echo "  else" >> ${TDE_DB_DF_ENCRYPT_DIR}/${DB_INSTANCE_NAME}_ENCRYPT_CMD_${COUNTER}.sh
          echo "    mv ${TDE_DB_DF_ENCRYPT_DIR}/${DB_INSTANCE_NAME}_ENCRYPT_CMD_${COUNTER}_ISRUNNING.log ${TDE_DB_DF_ENCRYPT_DIR}/${DB_INSTANCE_NAME}_ENCRYPT_CMD_${COUNTER}_COMPLETED.log" >> ${TDE_DB_DF_ENCRYPT_DIR}/${DB_INSTANCE_NAME}_ENCRYPT_CMD_${COUNTER}.sh
          echo "  fi" >> ${TDE_DB_DF_ENCRYPT_DIR}/${DB_INSTANCE_NAME}_ENCRYPT_CMD_${COUNTER}.sh
          echo "fi" >> ${TDE_DB_DF_ENCRYPT_DIR}/${DB_INSTANCE_NAME}_ENCRYPT_CMD_${COUNTER}.sh
          chmod a+x ${TDE_DB_DF_ENCRYPT_DIR}/${DB_INSTANCE_NAME}_ENCRYPT_CMD_${COUNTER}.sh
        done < ${TDE_DB_DF_ENCRYPT_DIR}/splitted_${DB_NAME}${INSTANCE_NUMBER}.sql; 
      done
      
      LAST_COMMAND_EXIT_STATUS=$?

      if [[ $LAST_COMMAND_EXIT_STATUS -ne 0 ]]
      then 
        echo -e "${RED} ENCRYPT_DATAFILES = ERROR, FAILED AT CREATING DB INSTANCE ENCRYPT COMMANDS ${ENDCOLOR}" | tee $TDE_FAILED_EXEC_DIR/FAILED_EXEC_${DATETIME}.log
	      echo -e "${RED} ENCRYPT_DATAFILES = ERROR, FAILED AT CREATING DB INSTANCE ENCRYPT COMMANDS ${ENDCOLOR}" >> $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
	      exit 1
      else  
        for INSTANCE_NUMBER in `${ORACLE_HOME}/bin/srvctl status database -d ${DB_UNIQUE_NAME} |awk '{print $2}'|awk '{print NR,$0}'|awk '{print $1}'`
        do
          DB_INSTANCE_NAME=`${ORACLE_HOME}/bin/srvctl status database -d ${DB_UNIQUE_NAME} |awk '{print $2}'|awk '{print NR,$0}'|awk '{print $2}'|awk -v INSTANCE_NUMBER=${INSTANCE_NUMBER} 'FNR == INSTANCE_NUMBER {print}'`
          DB_HOST_NAME=`${ORACLE_HOME}/bin/srvctl status database -d ${DB_UNIQUE_NAME} |awk '{print $NF}'|awk '{print NR,$0}'|awk '{print $2}'|awk -v INSTANCE_NUMBER=${INSTANCE_NUMBER} 'FNR == INSTANCE_NUMBER {print}'`
          for ENCRYPT_SCRIPT in `ls ${TDE_DB_DF_ENCRYPT_DIR}/${DB_INSTANCE_NAME}_ENCRYPT_CMD_*.sh`
          do
            chmod a+x ${ENCRYPT_SCRIPT}
            ssh $DB_HOST_NAME "nohup ${ENCRYPT_SCRIPT} > /dev/null 2>&1 &"
          done
        done
        
        for INSTANCE_NUMBER in `${ORACLE_HOME}/bin/srvctl status database -d ${DB_UNIQUE_NAME} |awk '{print $2}'|awk '{print NR,$0}'|awk '{print $1}'`
        do
          DB_INSTANCE_NAME=`${ORACLE_HOME}/bin/srvctl status database -d ${DB_UNIQUE_NAME} |awk '{print $2}'|awk '{print NR,$0}'|awk '{print $2}'|awk -v INSTANCE_NUMBER=${INSTANCE_NUMBER} 'FNR == INSTANCE_NUMBER {print}'`
          DB_HOST_NAME=`${ORACLE_HOME}/bin/srvctl status database -d ${DB_UNIQUE_NAME} |awk '{print $NF}'|awk '{print NR,$0}'|awk '{print $2}'|awk -v INSTANCE_NUMBER=${INSTANCE_NUMBER} 'FNR == INSTANCE_NUMBER {print}'`
          RUNNING_SCRIPTS_COUNT=`ssh $DB_HOST_NAME "ps -ef|grep ${DB_INSTANCE_NAME}_ENCRYPT_CMD |grep -v grep |wc -l"`
          ENCRYPTED_DATAFILES_COMPLETED_COUNT=`ls -ltrh ${TDE_DB_DF_ENCRYPT_DIR}/${DB_NAME}*_ENCRYPT_CMD*COMPLETED.log 2>/dev/null |wc -l`
          ENCRYPTED_DATAFILES_FAILED_COUNT=`ls -ltrh ${TDE_DB_DF_ENCRYPT_DIR}/${DB_NAME}*_ENCRYPT_CMD*FAILED.log 2>/dev/null |wc -l`
          ENCRYPTED_DATAFILES_ISRUNNING_COUNT=`ls -ltrh ${TDE_DB_DF_ENCRYPT_DIR}/${DB_NAME}*_ENCRYPT_CMD*ISRUNNING.log 2>/dev/null |wc -l`

          
          if [[ ${ENCRYPTED_DATAFILES_COMPLETED_COUNT} -eq ${DATAFILE_COUNT} ]] && [[ ${ENCRYPTED_DATAFILES_FAILED_COUNT} -eq 0 ]] && [[ ${ENCRYPTED_DATAFILES_ISRUNNING_COUNT} -eq 0 ]]
          then
            if grep -q "ENCRYPT_DATAFILES" $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
            then
              sed -i '$d' $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
              ENCRYPTED_DATAFILES_COMPLETED_COUNT=`ls -ltrh ${TDE_DB_DF_ENCRYPT_DIR}/${DB_NAME}*_ENCRYPT_CMD*COMPLETED.log 2>/dev/null |wc -l`
              ENCRYPTED_DATAFILES_FAILED_COUNT=`ls -ltrh ${TDE_DB_DF_ENCRYPT_DIR}/${DB_NAME}*_ENCRYPT_CMD*FAILED.log 2>/dev/null |wc -l`
              ENCRYPTED_DATAFILES_ISRUNNING_COUNT=`ls -ltrh ${TDE_DB_DF_ENCRYPT_DIR}/${DB_NAME}*_ENCRYPT_CMD*ISRUNNING.log 2>/dev/null |wc -l`
              echo -e "${GREEN} ENCRYPT_DATAFILES = SUCCESS, ${ENCRYPTED_DATAFILES_COMPLETED_COUNT} OUT OF ${DATAFILE_COUNT} DATAFILES, ${ENCRYPTED_DATAFILES_FAILED_COUNT} DATAFILES FAILED ${ENDCOLOR}" | tee -a $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
            else
              ENCRYPTED_DATAFILES_COMPLETED_COUNT=`ls -ltrh ${TDE_DB_DF_ENCRYPT_DIR}/${DB_NAME}*_ENCRYPT_CMD*COMPLETED.log 2>/dev/null |wc -l`
              ENCRYPTED_DATAFILES_FAILED_COUNT=`ls -ltrh ${TDE_DB_DF_ENCRYPT_DIR}/${DB_NAME}*_ENCRYPT_CMD*FAILED.log 2>/dev/null |wc -l`
              ENCRYPTED_DATAFILES_ISRUNNING_COUNT=`ls -ltrh ${TDE_DB_DF_ENCRYPT_DIR}/${DB_NAME}*_ENCRYPT_CMD*ISRUNNING.log 2>/dev/null |wc -l`
              echo -e "${GREEN} ENCRYPT_DATAFILES = SUCCESS, ${ENCRYPTED_DATAFILES_COMPLETED_COUNT} OUT OF ${DATAFILE_COUNT} DATAFILES, ${ENCRYPTED_DATAFILES_FAILED_COUNT} DATAFILES FAILED ${ENDCOLOR}" | tee -a $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
            fi
          elif [[ ${ENCRYPTED_DATAFILES_COMPLETED_COUNT} -ne ${DATAFILE_COUNT} ]] && [[ ${ENCRYPTED_DATAFILES_FAILED_COUNT} -gt 0 ]] && [[ ${ENCRYPTED_DATAFILES_ISRUNNING_COUNT} -eq 0 ]]
          then
            if grep -q "ENCRYPT_DATAFILES" $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
            then
              sed -i '$d' $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
              ENCRYPTED_DATAFILES_COMPLETED_COUNT=`ls -ltrh ${TDE_DB_DF_ENCRYPT_DIR}/${DB_NAME}*_ENCRYPT_CMD*COMPLETED.log 2>/dev/null |wc -l`
              ENCRYPTED_DATAFILES_FAILED_COUNT=`ls -ltrh ${TDE_DB_DF_ENCRYPT_DIR}/${DB_NAME}*_ENCRYPT_CMD*FAILED.log 2>/dev/null |wc -l`
              ENCRYPTED_DATAFILES_ISRUNNING_COUNT=`ls -ltrh ${TDE_DB_DF_ENCRYPT_DIR}/${DB_NAME}*_ENCRYPT_CMD*ISRUNNING.log 2>/dev/null |wc -l`
              echo -e "${RED} ENCRYPT_DATAFILES = FAILED, ${ENCRYPTED_DATAFILES_COMPLETED_COUNT} OUT OF ${DATAFILE_COUNT} DATAFILES, ${ENCRYPTED_DATAFILES_FAILED_COUNT} DATAFILES FAILED ${ENDCOLOR}" | tee -a $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
              exit 1
            else
              ENCRYPTED_DATAFILES_COMPLETED_COUNT=`ls -ltrh ${TDE_DB_DF_ENCRYPT_DIR}/${DB_NAME}*_ENCRYPT_CMD*COMPLETED.log 2>/dev/null |wc -l`
              ENCRYPTED_DATAFILES_FAILED_COUNT=`ls -ltrh ${TDE_DB_DF_ENCRYPT_DIR}/${DB_NAME}*_ENCRYPT_CMD*FAILED.log 2>/dev/null |wc -l`
              ENCRYPTED_DATAFILES_ISRUNNING_COUNT=`ls -ltrh ${TDE_DB_DF_ENCRYPT_DIR}/${DB_NAME}*_ENCRYPT_CMD*ISRUNNING.log 2>/dev/null |wc -l`
              echo -e "${RED} ENCRYPT_DATAFILES = FAILED, ${ENCRYPTED_DATAFILES_COMPLETED_COUNT} OUT OF ${DATAFILE_COUNT} DATAFILES, ${ENCRYPTED_DATAFILES_FAILED_COUNT} DATAFILES FAILED ${ENDCOLOR}" | tee -a $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
              exit 1
            fi            
          else
            if grep -q "ENCRYPT_DATAFILES" $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
            then
              sed -i '$d' $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
              ENCRYPTED_DATAFILES_COMPLETED_COUNT=`ls -ltrh ${TDE_DB_DF_ENCRYPT_DIR}/${DB_NAME}*_ENCRYPT_CMD*COMPLETED.log 2>/dev/null |wc -l`
              ENCRYPTED_DATAFILES_FAILED_COUNT=`ls -ltrh ${TDE_DB_DF_ENCRYPT_DIR}/${DB_NAME}*_ENCRYPT_CMD*FAILED.log 2>/dev/null |wc -l`
              ENCRYPTED_DATAFILES_ISRUNNING_COUNT=`ls -ltrh ${TDE_DB_DF_ENCRYPT_DIR}/${DB_NAME}*_ENCRYPT_CMD*ISRUNNING.log 2>/dev/null |wc -l`
              echo -e "${GREEN} ENCRYPT_DATAFILES = RUNNING, ${ENCRYPTED_DATAFILES_COMPLETED_COUNT} OUT OF ${DATAFILE_COUNT} DATAFILES, ${ENCRYPTED_DATAFILES_FAILED_COUNT} DATAFILES FAILED ${ENDCOLOR}" | tee -a $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log 
            else
              ENCRYPTED_DATAFILES_COMPLETED_COUNT=`ls -ltrh ${TDE_DB_DF_ENCRYPT_DIR}/${DB_NAME}*_ENCRYPT_CMD*COMPLETED.log 2>/dev/null |wc -l`
              ENCRYPTED_DATAFILES_FAILED_COUNT=`ls -ltrh ${TDE_DB_DF_ENCRYPT_DIR}/${DB_NAME}*_ENCRYPT_CMD*FAILED.log 2>/dev/null |wc -l`
              ENCRYPTED_DATAFILES_ISRUNNING_COUNT=`ls -ltrh ${TDE_DB_DF_ENCRYPT_DIR}/${DB_NAME}*_ENCRYPT_CMD*ISRUNNING.log 2>/dev/null |wc -l`
              echo -e "${GREEN} ENCRYPT_DATAFILES = RUNNING, ${ENCRYPTED_DATAFILES_COMPLETED_COUNT} OUT OF ${DATAFILE_COUNT} DATAFILES, ${ENCRYPTED_DATAFILES_FAILED_COUNT} DATAFILES FAILED ${ENDCOLOR}" | tee -a $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
            fi
          fi

          while [ ${RUNNING_SCRIPTS_COUNT} -gt 0 ] || [ ${ENCRYPTED_DATAFILES_ISRUNNING_COUNT} -gt 0 ]
          do
            sed -i '$d' $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log 
            ENCRYPTED_DATAFILES_COMPLETED_COUNT=`ls -ltrh ${TDE_DB_DF_ENCRYPT_DIR}/${DB_NAME}*_ENCRYPT_CMD*COMPLETED.log 2>/dev/null |wc -l`
            ENCRYPTED_DATAFILES_FAILED_COUNT=`ls -ltrh ${TDE_DB_DF_ENCRYPT_DIR}/${DB_NAME}*_ENCRYPT_CMD*FAILED.log 2>/dev/null |wc -l`
            ENCRYPTED_DATAFILES_ISRUNNING_COUNT=`ls -ltrh ${TDE_DB_DF_ENCRYPT_DIR}/${DB_NAME}*_ENCRYPT_CMD*ISRUNNING.log 2>/dev/null |wc -l`
            echo -e "${GREEN} ENCRYPT_DATAFILES = RUNNING, ${ENCRYPTED_DATAFILES_COMPLETED_COUNT} OUT OF ${DATAFILE_COUNT} DATAFILES, ${ENCRYPTED_DATAFILES_FAILED_COUNT} DATAFILES FAILED ${ENDCOLOR}" | tee -a $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
            sleep 10
            RUNNING_SCRIPTS_COUNT=`ssh $DB_HOST_NAME "ps -ef|grep ${DB_INSTANCE_NAME}_ENCRYPT_CMD |grep -v grep |wc -l"`
            ENCRYPTED_DATAFILES_ISRUNNING_COUNT=`ls -ltrh ${TDE_DB_DF_ENCRYPT_DIR}/${DB_NAME}*_ENCRYPT_CMD*ISRUNNING.log 2>/dev/null |wc -l`
          done  
        done
        
        sleep 20
        sed -i '$d' $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
        ENCRYPTED_DATAFILES_COMPLETED_COUNT=`ls -ltrh ${TDE_DB_DF_ENCRYPT_DIR}/${DB_NAME}*_ENCRYPT_CMD*COMPLETED.log 2>/dev/null |wc -l`
        ENCRYPTED_DATAFILES_FAILED_COUNT=`ls -ltrh ${TDE_DB_DF_ENCRYPT_DIR}/${DB_NAME}*_ENCRYPT_CMD*FAILED.log 2>/dev/null |wc -l`
        ENCRYPTED_DATAFILES_ISRUNNING_COUNT=`ls -ltrh ${TDE_DB_DF_ENCRYPT_DIR}/${DB_NAME}*_ENCRYPT_CMD*ISRUNNING.log 2>/dev/null |wc -l`
        echo -e "${GREEN} ENCRYPT_DATAFILES = SUCCESS, ${ENCRYPTED_DATAFILES_COMPLETED_COUNT} OUT OF ${DATAFILE_COUNT} DATAFILES, ${ENCRYPTED_DATAFILES_FAILED_COUNT} DATAFILES FAILED ${ENDCOLOR}" | tee -a $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
      fi
    fi
  

  elif [[ $HOST_TYPE == 'EXADATA' ]] && [[ $DB_VERSION -lt 19 ]] && [[ $OPTION == 'ENCRYPT' ]]
  then
    $ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF > /dev/null
    set lines 200
    set pages 0
    set feedback off
    spool ${TDE_DB_DF_DIR}/${DB_UNIQUE_NAME}_DATAFILE_ENCRYPT_MAINLIST.log
    select 'alter database datafile '||chr(39)||df.name||chr(39)||' encrypt;' COMMAND from v\$tablespace ts, v\$datafile df where ts.ts#=df.ts# and ts.name not in ('SYSTEM','SYSAUX') and ts.name not like '%UNDO%' and ts.name not like '%TEMP%'   order by df.name;
    spool off
    exit
EOF
    


    DB_INSTANCE_COUNT=`${ORACLE_HOME}/bin/srvctl status database -d ${DB_UNIQUE_NAME} |awk '{print $2}'| wc -l`
    DATAFILE_COUNT=`cat ${TDE_DB_DF_DIR}/${DB_UNIQUE_NAME}_DATAFILE_ENCRYPT_MAINLIST.log | wc -l`
    SPLIT_LINES_COUNT=`echo $(((${DATAFILE_COUNT} + ${DB_INSTANCE_COUNT} - 1)/${DB_INSTANCE_COUNT}))`
    
    split  --lines=${SPLIT_LINES_COUNT} --suffix-length=1 --numeric-suffixes=1 --additional-suffix=.sql ${TDE_DB_DF_DIR}/${DB_UNIQUE_NAME}_DATAFILE_ENCRYPT_MAINLIST.log ${TDE_DB_DF_ENCRYPT_DIR}/splitted_${DB_NAME}

    LAST_COMMAND_EXIT_STATUS=$?

    if [[ $LAST_COMMAND_EXIT_STATUS -ne 0 ]]
    then 
      echo -e "${RED} ENCRYPT_DATAFILES = ERROR, MAINLIST SPLIT FOR FILES FAILED ${ENDCOLOR}" | tee $TDE_FAILED_EXEC_DIR/FAILED_EXEC_${DATETIME}.log
	    echo -e "${RED} ENCRYPT_DATAFILES = ERROR, MAINLIST SPLIT FOR FILES FAILED ${ENDCOLOR}" >> $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
	    exit 1
    else  
      for INSTANCE_NUMBER in `${ORACLE_HOME}/bin/srvctl status database -d ${DB_UNIQUE_NAME} |awk '{print $2}'|awk '{print NR,$0}'|awk '{print $1}'`
      do  
        COUNTER=0
        DB_INSTANCE_NAME=`${ORACLE_HOME}/bin/srvctl status database -d ${DB_UNIQUE_NAME} |awk '{print $2}'|awk '{print NR,$0}'|awk '{print $2}'|awk -v INSTANCE_NUMBER=${INSTANCE_NUMBER} 'FNR == INSTANCE_NUMBER {print}'`
        while read line 
        do 
          COUNTER=`echo $((${COUNTER}+1))` 
          echo ". /oracle/stagenfs/scripts/shell/setoraenv.ksh ${DB_UNIQUE_NAME} > /dev/null" > ${TDE_DB_DF_ENCRYPT_DIR}/${DB_INSTANCE_NAME}_ENCRYPT_CMD_${COUNTER}.sh
          echo "sleep 30" >> ${TDE_DB_DF_ENCRYPT_DIR}/${DB_INSTANCE_NAME}_ENCRYPT_CMD_${COUNTER}.sh
          echo "$ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF > /dev/null" >> ${TDE_DB_DF_ENCRYPT_DIR}/${DB_INSTANCE_NAME}_ENCRYPT_CMD_${COUNTER}.sh
          echo "set echo on" >> ${TDE_DB_DF_ENCRYPT_DIR}/${DB_INSTANCE_NAME}_ENCRYPT_CMD_${COUNTER}.sh
          echo "set feedback on" >> ${TDE_DB_DF_ENCRYPT_DIR}/${DB_INSTANCE_NAME}_ENCRYPT_CMD_${COUNTER}.sh
          echo "set time on" >> ${TDE_DB_DF_ENCRYPT_DIR}/${DB_INSTANCE_NAME}_ENCRYPT_CMD_${COUNTER}.sh
          echo "set timi on" >> ${TDE_DB_DF_ENCRYPT_DIR}/${DB_INSTANCE_NAME}_ENCRYPT_CMD_${COUNTER}.sh
          echo "spool ${TDE_DB_DF_ENCRYPT_DIR}/${DB_INSTANCE_NAME}_ENCRYPT_CMD_${COUNTER}_ISRUNNING.log" >> ${TDE_DB_DF_ENCRYPT_DIR}/${DB_INSTANCE_NAME}_ENCRYPT_CMD_${COUNTER}.sh
          echo "${line}" >> ${TDE_DB_DF_ENCRYPT_DIR}/${DB_INSTANCE_NAME}_ENCRYPT_CMD_${COUNTER}.sh
          echo "spool off" >> ${TDE_DB_DF_ENCRYPT_DIR}/${DB_INSTANCE_NAME}_ENCRYPT_CMD_${COUNTER}.sh
          echo "exit" >> ${TDE_DB_DF_ENCRYPT_DIR}/${DB_INSTANCE_NAME}_ENCRYPT_CMD_${COUNTER}.sh
          echo "EOF" >> ${TDE_DB_DF_ENCRYPT_DIR}/${DB_INSTANCE_NAME}_ENCRYPT_CMD_${COUNTER}.sh
          echo "if [[ -f ${TDE_DB_DF_ENCRYPT_DIR}/${DB_INSTANCE_NAME}_ENCRYPT_CMD_${COUNTER}_ISRUNNING.log ]]" >> ${TDE_DB_DF_ENCRYPT_DIR}/${DB_INSTANCE_NAME}_ENCRYPT_CMD_${COUNTER}.sh
          echo "then" >> ${TDE_DB_DF_ENCRYPT_DIR}/${DB_INSTANCE_NAME}_ENCRYPT_CMD_${COUNTER}.sh
          echo "  if grep -q "ORA-" ${TDE_DB_DF_ENCRYPT_DIR}/${DB_INSTANCE_NAME}_ENCRYPT_CMD_${COUNTER}_ISRUNNING.log" >> ${TDE_DB_DF_ENCRYPT_DIR}/${DB_INSTANCE_NAME}_ENCRYPT_CMD_${COUNTER}.sh
          echo "  then" >> ${TDE_DB_DF_ENCRYPT_DIR}/${DB_INSTANCE_NAME}_ENCRYPT_CMD_${COUNTER}.sh
          echo "    mv ${TDE_DB_DF_ENCRYPT_DIR}/${DB_INSTANCE_NAME}_ENCRYPT_CMD_${COUNTER}_ISRUNNING.log ${TDE_DB_DF_ENCRYPT_DIR}/${DB_INSTANCE_NAME}_ENCRYPT_CMD_${COUNTER}_FAILED.log" >> ${TDE_DB_DF_ENCRYPT_DIR}/${DB_INSTANCE_NAME}_ENCRYPT_CMD_${COUNTER}.sh
          echo "  else" >> ${TDE_DB_DF_ENCRYPT_DIR}/${DB_INSTANCE_NAME}_ENCRYPT_CMD_${COUNTER}.sh
          echo "    mv ${TDE_DB_DF_ENCRYPT_DIR}/${DB_INSTANCE_NAME}_ENCRYPT_CMD_${COUNTER}_ISRUNNING.log ${TDE_DB_DF_ENCRYPT_DIR}/${DB_INSTANCE_NAME}_ENCRYPT_CMD_${COUNTER}_COMPLETED.log" >> ${TDE_DB_DF_ENCRYPT_DIR}/${DB_INSTANCE_NAME}_ENCRYPT_CMD_${COUNTER}.sh
          echo "  fi" >> ${TDE_DB_DF_ENCRYPT_DIR}/${DB_INSTANCE_NAME}_ENCRYPT_CMD_${COUNTER}.sh
          echo "fi" >> ${TDE_DB_DF_ENCRYPT_DIR}/${DB_INSTANCE_NAME}_ENCRYPT_CMD_${COUNTER}.sh
          chmod a+x ${TDE_DB_DF_ENCRYPT_DIR}/${DB_INSTANCE_NAME}_ENCRYPT_CMD_${COUNTER}.sh
        done < ${TDE_DB_DF_ENCRYPT_DIR}/splitted_${DB_NAME}${INSTANCE_NUMBER}.sql; 
      done
      
      LAST_COMMAND_EXIT_STATUS=$?

      if [[ $LAST_COMMAND_EXIT_STATUS -ne 0 ]]
      then 
        echo -e "${RED} ENCRYPT_DATAFILES = ERROR, FAILED AT CREATING DB INSTANCE ENCRYPT COMMANDS ${ENDCOLOR}" | tee $TDE_FAILED_EXEC_DIR/FAILED_EXEC_${DATETIME}.log
	      echo -e "${RED} ENCRYPT_DATAFILES = ERROR, FAILED AT CREATING DB INSTANCE ENCRYPT COMMANDS ${ENDCOLOR}" >> $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
	      exit 1
      else  
        for INSTANCE_NUMBER in `${ORACLE_HOME}/bin/srvctl status database -d ${DB_UNIQUE_NAME} |awk '{print $2}'|awk '{print NR,$0}'|awk '{print $1}'`
        do
          DB_INSTANCE_NAME=`${ORACLE_HOME}/bin/srvctl status database -d ${DB_UNIQUE_NAME} |awk '{print $2}'|awk '{print NR,$0}'|awk '{print $2}'|awk -v INSTANCE_NUMBER=${INSTANCE_NUMBER} 'FNR == INSTANCE_NUMBER {print}'`
          DB_HOST_NAME=`${ORACLE_HOME}/bin/srvctl status database -d ${DB_UNIQUE_NAME} |awk '{print $NF}'|awk '{print NR,$0}'|awk '{print $2}'|awk -v INSTANCE_NUMBER=${INSTANCE_NUMBER} 'FNR == INSTANCE_NUMBER {print}'`
          for ENCRYPT_SCRIPT in `ls ${TDE_DB_DF_ENCRYPT_DIR}/${DB_INSTANCE_NAME}_ENCRYPT_CMD_*.sh`
          do
            chmod a+x ${ENCRYPT_SCRIPT}
            ssh $DB_HOST_NAME "nohup ${ENCRYPT_SCRIPT} > /dev/null 2>&1 &"
          done
        done
        
        for INSTANCE_NUMBER in `${ORACLE_HOME}/bin/srvctl status database -d ${DB_UNIQUE_NAME} |awk '{print $2}'|awk '{print NR,$0}'|awk '{print $1}'`
        do
          DB_INSTANCE_NAME=`${ORACLE_HOME}/bin/srvctl status database -d ${DB_UNIQUE_NAME} |awk '{print $2}'|awk '{print NR,$0}'|awk '{print $2}'|awk -v INSTANCE_NUMBER=${INSTANCE_NUMBER} 'FNR == INSTANCE_NUMBER {print}'`
          DB_HOST_NAME=`${ORACLE_HOME}/bin/srvctl status database -d ${DB_UNIQUE_NAME} |awk '{print $NF}'|awk '{print NR,$0}'|awk '{print $2}'|awk -v INSTANCE_NUMBER=${INSTANCE_NUMBER} 'FNR == INSTANCE_NUMBER {print}'`
          RUNNING_SCRIPTS_COUNT=`ssh $DB_HOST_NAME "ps -ef|grep ${DB_INSTANCE_NAME}_ENCRYPT_CMD |grep -v grep |wc -l"`
          ENCRYPTED_DATAFILES_COMPLETED_COUNT=`ls -ltrh ${TDE_DB_DF_ENCRYPT_DIR}/${DB_NAME}*_ENCRYPT_CMD*COMPLETED.log 2>/dev/null |wc -l`
          ENCRYPTED_DATAFILES_FAILED_COUNT=`ls -ltrh ${TDE_DB_DF_ENCRYPT_DIR}/${DB_NAME}*_ENCRYPT_CMD*FAILED.log 2>/dev/null |wc -l`
          ENCRYPTED_DATAFILES_ISRUNNING_COUNT=`ls -ltrh ${TDE_DB_DF_ENCRYPT_DIR}/${DB_NAME}*_ENCRYPT_CMD*ISRUNNING.log 2>/dev/null |wc -l`

          
          if [[ ${ENCRYPTED_DATAFILES_COMPLETED_COUNT} -eq ${DATAFILE_COUNT} ]] && [[ ${ENCRYPTED_DATAFILES_FAILED_COUNT} -eq 0 ]] && [[ ${ENCRYPTED_DATAFILES_ISRUNNING_COUNT} -eq 0 ]]
          then
            if grep -q "ENCRYPT_DATAFILES" $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
            then
              sed -i '$d' $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
              ENCRYPTED_DATAFILES_COMPLETED_COUNT=`ls -ltrh ${TDE_DB_DF_ENCRYPT_DIR}/${DB_NAME}*_ENCRYPT_CMD*COMPLETED.log 2>/dev/null |wc -l`
              ENCRYPTED_DATAFILES_FAILED_COUNT=`ls -ltrh ${TDE_DB_DF_ENCRYPT_DIR}/${DB_NAME}*_ENCRYPT_CMD*FAILED.log 2>/dev/null |wc -l`
              ENCRYPTED_DATAFILES_ISRUNNING_COUNT=`ls -ltrh ${TDE_DB_DF_ENCRYPT_DIR}/${DB_NAME}*_ENCRYPT_CMD*ISRUNNING.log 2>/dev/null |wc -l`
              echo -e "${GREEN} ENCRYPT_DATAFILES = SUCCESS, ${ENCRYPTED_DATAFILES_COMPLETED_COUNT} OUT OF ${DATAFILE_COUNT} DATAFILES, ${ENCRYPTED_DATAFILES_FAILED_COUNT} DATAFILES FAILED ${ENDCOLOR}" | tee -a $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
            else
              ENCRYPTED_DATAFILES_COMPLETED_COUNT=`ls -ltrh ${TDE_DB_DF_ENCRYPT_DIR}/${DB_NAME}*_ENCRYPT_CMD*COMPLETED.log 2>/dev/null |wc -l`
              ENCRYPTED_DATAFILES_FAILED_COUNT=`ls -ltrh ${TDE_DB_DF_ENCRYPT_DIR}/${DB_NAME}*_ENCRYPT_CMD*FAILED.log 2>/dev/null |wc -l`
              ENCRYPTED_DATAFILES_ISRUNNING_COUNT=`ls -ltrh ${TDE_DB_DF_ENCRYPT_DIR}/${DB_NAME}*_ENCRYPT_CMD*ISRUNNING.log 2>/dev/null |wc -l`
              echo -e "${GREEN} ENCRYPT_DATAFILES = SUCCESS, ${ENCRYPTED_DATAFILES_COMPLETED_COUNT} OUT OF ${DATAFILE_COUNT} DATAFILES, ${ENCRYPTED_DATAFILES_FAILED_COUNT} DATAFILES FAILED ${ENDCOLOR}" | tee -a $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
            fi
          elif [[ ${ENCRYPTED_DATAFILES_COMPLETED_COUNT} -ne ${DATAFILE_COUNT} ]] && [[ ${ENCRYPTED_DATAFILES_FAILED_COUNT} -gt 0 ]] && [[ ${ENCRYPTED_DATAFILES_ISRUNNING_COUNT} -eq 0 ]]
          then
            if grep -q "ENCRYPT_DATAFILES" $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
            then
              sed -i '$d' $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
              ENCRYPTED_DATAFILES_COMPLETED_COUNT=`ls -ltrh ${TDE_DB_DF_ENCRYPT_DIR}/${DB_NAME}*_ENCRYPT_CMD*COMPLETED.log 2>/dev/null |wc -l`
              ENCRYPTED_DATAFILES_FAILED_COUNT=`ls -ltrh ${TDE_DB_DF_ENCRYPT_DIR}/${DB_NAME}*_ENCRYPT_CMD*FAILED.log 2>/dev/null |wc -l`
              ENCRYPTED_DATAFILES_ISRUNNING_COUNT=`ls -ltrh ${TDE_DB_DF_ENCRYPT_DIR}/${DB_NAME}*_ENCRYPT_CMD*ISRUNNING.log 2>/dev/null |wc -l`
              echo -e "${RED} ENCRYPT_DATAFILES = FAILED, ${ENCRYPTED_DATAFILES_COMPLETED_COUNT} OUT OF ${DATAFILE_COUNT} DATAFILES, ${ENCRYPTED_DATAFILES_FAILED_COUNT} DATAFILES FAILED ${ENDCOLOR}" | tee -a $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
              exit 1
            else
              ENCRYPTED_DATAFILES_COMPLETED_COUNT=`ls -ltrh ${TDE_DB_DF_ENCRYPT_DIR}/${DB_NAME}*_ENCRYPT_CMD*COMPLETED.log 2>/dev/null |wc -l`
              ENCRYPTED_DATAFILES_FAILED_COUNT=`ls -ltrh ${TDE_DB_DF_ENCRYPT_DIR}/${DB_NAME}*_ENCRYPT_CMD*FAILED.log 2>/dev/null |wc -l`
              ENCRYPTED_DATAFILES_ISRUNNING_COUNT=`ls -ltrh ${TDE_DB_DF_ENCRYPT_DIR}/${DB_NAME}*_ENCRYPT_CMD*ISRUNNING.log 2>/dev/null |wc -l`
              echo -e "${RED} ENCRYPT_DATAFILES = FAILED, ${ENCRYPTED_DATAFILES_COMPLETED_COUNT} OUT OF ${DATAFILE_COUNT} DATAFILES, ${ENCRYPTED_DATAFILES_FAILED_COUNT} DATAFILES FAILED ${ENDCOLOR}" | tee -a $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
              exit 1
            fi            
          else
            if grep -q "ENCRYPT_DATAFILES" $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
            then
              sed -i '$d' $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
              ENCRYPTED_DATAFILES_COMPLETED_COUNT=`ls -ltrh ${TDE_DB_DF_ENCRYPT_DIR}/${DB_NAME}*_ENCRYPT_CMD*COMPLETED.log 2>/dev/null |wc -l`
              ENCRYPTED_DATAFILES_FAILED_COUNT=`ls -ltrh ${TDE_DB_DF_ENCRYPT_DIR}/${DB_NAME}*_ENCRYPT_CMD*FAILED.log 2>/dev/null |wc -l`
              ENCRYPTED_DATAFILES_ISRUNNING_COUNT=`ls -ltrh ${TDE_DB_DF_ENCRYPT_DIR}/${DB_NAME}*_ENCRYPT_CMD*ISRUNNING.log 2>/dev/null |wc -l`
              echo -e "${GREEN} ENCRYPT_DATAFILES = RUNNING, ${ENCRYPTED_DATAFILES_COMPLETED_COUNT} OUT OF ${DATAFILE_COUNT} DATAFILES, ${ENCRYPTED_DATAFILES_FAILED_COUNT} DATAFILES FAILED ${ENDCOLOR}" | tee -a $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log 
            else
              ENCRYPTED_DATAFILES_COMPLETED_COUNT=`ls -ltrh ${TDE_DB_DF_ENCRYPT_DIR}/${DB_NAME}*_ENCRYPT_CMD*COMPLETED.log 2>/dev/null |wc -l`
              ENCRYPTED_DATAFILES_FAILED_COUNT=`ls -ltrh ${TDE_DB_DF_ENCRYPT_DIR}/${DB_NAME}*_ENCRYPT_CMD*FAILED.log 2>/dev/null |wc -l`
              ENCRYPTED_DATAFILES_ISRUNNING_COUNT=`ls -ltrh ${TDE_DB_DF_ENCRYPT_DIR}/${DB_NAME}*_ENCRYPT_CMD*ISRUNNING.log 2>/dev/null |wc -l`
              echo -e "${GREEN} ENCRYPT_DATAFILES = RUNNING, ${ENCRYPTED_DATAFILES_COMPLETED_COUNT} OUT OF ${DATAFILE_COUNT} DATAFILES, ${ENCRYPTED_DATAFILES_FAILED_COUNT} DATAFILES FAILED ${ENDCOLOR}" | tee -a $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
            fi
          fi

          while [ ${RUNNING_SCRIPTS_COUNT} -gt 0 ] || [ ${ENCRYPTED_DATAFILES_ISRUNNING_COUNT} -gt 0 ]
          do
            sed -i '$d' $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log 
            ENCRYPTED_DATAFILES_COMPLETED_COUNT=`ls -ltrh ${TDE_DB_DF_ENCRYPT_DIR}/${DB_NAME}*_ENCRYPT_CMD*COMPLETED.log 2>/dev/null |wc -l`
            ENCRYPTED_DATAFILES_FAILED_COUNT=`ls -ltrh ${TDE_DB_DF_ENCRYPT_DIR}/${DB_NAME}*_ENCRYPT_CMD*FAILED.log 2>/dev/null |wc -l`
            ENCRYPTED_DATAFILES_ISRUNNING_COUNT=`ls -ltrh ${TDE_DB_DF_ENCRYPT_DIR}/${DB_NAME}*_ENCRYPT_CMD*ISRUNNING.log 2>/dev/null |wc -l`
            echo -e "${GREEN} ENCRYPT_DATAFILES = RUNNING, ${ENCRYPTED_DATAFILES_COMPLETED_COUNT} OUT OF ${DATAFILE_COUNT} DATAFILES, ${ENCRYPTED_DATAFILES_FAILED_COUNT} DATAFILES FAILED ${ENDCOLOR}" | tee -a $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
            sleep 10
            RUNNING_SCRIPTS_COUNT=`ssh $DB_HOST_NAME "ps -ef|grep ${DB_INSTANCE_NAME}_ENCRYPT_CMD |grep -v grep |wc -l"`
            ENCRYPTED_DATAFILES_ISRUNNING_COUNT=`ls -ltrh ${TDE_DB_DF_ENCRYPT_DIR}/${DB_NAME}*_ENCRYPT_CMD*ISRUNNING.log 2>/dev/null |wc -l`
          done  
        done
        
        sleep 20
        sed -i '$d' $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
        ENCRYPTED_DATAFILES_COMPLETED_COUNT=`ls -ltrh ${TDE_DB_DF_ENCRYPT_DIR}/${DB_NAME}*_ENCRYPT_CMD*COMPLETED.log 2>/dev/null |wc -l`
        ENCRYPTED_DATAFILES_FAILED_COUNT=`ls -ltrh ${TDE_DB_DF_ENCRYPT_DIR}/${DB_NAME}*_ENCRYPT_CMD*FAILED.log 2>/dev/null |wc -l`
        ENCRYPTED_DATAFILES_ISRUNNING_COUNT=`ls -ltrh ${TDE_DB_DF_ENCRYPT_DIR}/${DB_NAME}*_ENCRYPT_CMD*ISRUNNING.log 2>/dev/null |wc -l`
        echo -e "${GREEN} ENCRYPT_DATAFILES = SUCCESS, ${ENCRYPTED_DATAFILES_COMPLETED_COUNT} OUT OF ${DATAFILE_COUNT} DATAFILES, ${ENCRYPTED_DATAFILES_FAILED_COUNT} DATAFILES FAILED ${ENDCOLOR}" | tee -a $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
      fi
    fi
  fi  

}





function UNENCRYPT_DATAFILES () {

  if [[ $HOST_TYPE == 'EXADATA' ]] && [[ $DB_VERSION -eq 19 ]] && [[ $OPTION == 'UNENCRYPT' ]]
  then

    

    $ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF > /dev/null
    set lines 200
    set pages 0
    set feedback off
    spool ${TDE_DB_DF_DIR}/${DB_UNIQUE_NAME}_DATAFILE_UNENCRYPT_MAINLIST.log
    select 'alter database datafile '||chr(39)||df.name||chr(39)||' decrypt;' COMMAND from v\$tablespace ts, v\$datafile df where ts.ts#=df.ts# and ts.name not in ('SYSTEM','SYSAUX') and ts.name not like '%UNDO%' and ts.name not like '%TEMP%'   order by df.name;
    spool off
    exit
EOF
    


    DB_INSTANCE_COUNT=`${ORACLE_HOME}/bin/srvctl status database -d ${DB_UNIQUE_NAME} |awk '{print $2}'| wc -l`
    DATAFILE_COUNT=`cat ${TDE_DB_DF_DIR}/${DB_UNIQUE_NAME}_DATAFILE_UNENCRYPT_MAINLIST.log | wc -l`
    SPLIT_LINES_COUNT=`echo $(((${DATAFILE_COUNT} + ${DB_INSTANCE_COUNT} - 1)/${DB_INSTANCE_COUNT}))`
    
    split  --lines=${SPLIT_LINES_COUNT} --suffix-length=1 --numeric-suffixes=1 --additional-suffix=.sql ${TDE_DB_DF_DIR}/${DB_UNIQUE_NAME}_DATAFILE_UNENCRYPT_MAINLIST.log ${TDE_DB_DF_UNENCRYPT_DIR}/splitted_${DB_NAME}

    LAST_COMMAND_EXIT_STATUS=$?

    if [[ $LAST_COMMAND_EXIT_STATUS -ne 0 ]]
    then 
      echo -e "${RED} UNENCRYPT_DATAFILES = ERROR, MAINLIST SPLIT FOR FILES FAILED ${ENDCOLOR}" | tee $TDE_FAILED_EXEC_DIR/FAILED_EXEC_${DATETIME}.log
	    echo -e "${RED} UNENCRYPT_DATAFILES = ERROR, MAINLIST SPLIT FOR FILES FAILED ${ENDCOLOR}" >> $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
	    exit 1
    else  
      for INSTANCE_NUMBER in `${ORACLE_HOME}/bin/srvctl status database -d ${DB_UNIQUE_NAME} |awk '{print $2}'|awk '{print NR,$0}'|awk '{print $1}'`
      do  
        COUNTER=0
        DB_INSTANCE_NAME=`${ORACLE_HOME}/bin/srvctl status database -d ${DB_UNIQUE_NAME} |awk '{print $2}'|awk '{print NR,$0}'|awk '{print $2}'|awk -v INSTANCE_NUMBER=${INSTANCE_NUMBER} 'FNR == INSTANCE_NUMBER {print}'`
        while read line 
        do 
          COUNTER=`echo $((${COUNTER}+1))` 
          echo ". /oracle/stagenfs/scripts/shell/setoraenv.ksh ${DB_UNIQUE_NAME} > /dev/null" > ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_INSTANCE_NAME}_UNENCRYPT_CMD_${COUNTER}.sh
          echo "sleep 30" >> ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_INSTANCE_NAME}_UNENCRYPT_CMD_${COUNTER}.sh
          echo "$ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF > /dev/null" >> ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_INSTANCE_NAME}_UNENCRYPT_CMD_${COUNTER}.sh
          echo "set echo on" >> ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_INSTANCE_NAME}_UNENCRYPT_CMD_${COUNTER}.sh
          echo "set feedback on" >> ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_INSTANCE_NAME}_UNENCRYPT_CMD_${COUNTER}.sh
          echo "set time on" >> ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_INSTANCE_NAME}_UNENCRYPT_CMD_${COUNTER}.sh
          echo "set timi on" >> ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_INSTANCE_NAME}_UNENCRYPT_CMD_${COUNTER}.sh
          echo "spool ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_INSTANCE_NAME}_UNENCRYPT_CMD_${COUNTER}_ISRUNNING.log" >> ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_INSTANCE_NAME}_UNENCRYPT_CMD_${COUNTER}.sh
          echo "${line}" >> ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_INSTANCE_NAME}_UNENCRYPT_CMD_${COUNTER}.sh
          echo "spool off" >> ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_INSTANCE_NAME}_UNENCRYPT_CMD_${COUNTER}.sh
          echo "exit" >> ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_INSTANCE_NAME}_UNENCRYPT_CMD_${COUNTER}.sh
          echo "EOF" >> ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_INSTANCE_NAME}_UNENCRYPT_CMD_${COUNTER}.sh
          echo "if [[ -f ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_INSTANCE_NAME}_UNENCRYPT_CMD_${COUNTER}_ISRUNNING.log ]]" >> ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_INSTANCE_NAME}_UNENCRYPT_CMD_${COUNTER}.sh
          echo "then" >> ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_INSTANCE_NAME}_UNENCRYPT_CMD_${COUNTER}.sh
          echo "  if grep -q "ORA-" ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_INSTANCE_NAME}_UNENCRYPT_CMD_${COUNTER}_ISRUNNING.log" >> ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_INSTANCE_NAME}_UNENCRYPT_CMD_${COUNTER}.sh
          echo "  then" >> ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_INSTANCE_NAME}_UNENCRYPT_CMD_${COUNTER}.sh
          echo "    mv ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_INSTANCE_NAME}_UNENCRYPT_CMD_${COUNTER}_ISRUNNING.log ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_INSTANCE_NAME}_UNENCRYPT_CMD_${COUNTER}_FAILED.log" >> ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_INSTANCE_NAME}_UNENCRYPT_CMD_${COUNTER}.sh
          echo "  else" >> ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_INSTANCE_NAME}_UNENCRYPT_CMD_${COUNTER}.sh
          echo "    mv ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_INSTANCE_NAME}_UNENCRYPT_CMD_${COUNTER}_ISRUNNING.log ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_INSTANCE_NAME}_UNENCRYPT_CMD_${COUNTER}_COMPLETED.log" >> ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_INSTANCE_NAME}_UNENCRYPT_CMD_${COUNTER}.sh
          echo "  fi" >> ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_INSTANCE_NAME}_UNENCRYPT_CMD_${COUNTER}.sh
          echo "fi" >> ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_INSTANCE_NAME}_UNENCRYPT_CMD_${COUNTER}.sh
          chmod a+x ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_INSTANCE_NAME}_UNENCRYPT_CMD_${COUNTER}.sh
        done < ${TDE_DB_DF_UNENCRYPT_DIR}/splitted_${DB_NAME}${INSTANCE_NUMBER}.sql; 
      done
      
      LAST_COMMAND_EXIT_STATUS=$?

      if [[ $LAST_COMMAND_EXIT_STATUS -ne 0 ]]
      then 
        echo -e "${RED} UNENCRYPT_DATAFILES = ERROR, FAILED AT CREATING DB INSTANCE UNENCRYPT COMMANDS ${ENDCOLOR}" | tee $TDE_FAILED_EXEC_DIR/FAILED_EXEC_${DATETIME}.log
	      echo -e "${RED} UNENCRYPT_DATAFILES = ERROR, FAILED AT CREATING DB INSTANCE UNENCRYPT COMMANDS ${ENDCOLOR}" >> $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
	      exit 1
      else  
        for INSTANCE_NUMBER in `${ORACLE_HOME}/bin/srvctl status database -d ${DB_UNIQUE_NAME} |awk '{print $2}'|awk '{print NR,$0}'|awk '{print $1}'`
        do
          DB_INSTANCE_NAME=`${ORACLE_HOME}/bin/srvctl status database -d ${DB_UNIQUE_NAME} |awk '{print $2}'|awk '{print NR,$0}'|awk '{print $2}'|awk -v INSTANCE_NUMBER=${INSTANCE_NUMBER} 'FNR == INSTANCE_NUMBER {print}'`
          DB_HOST_NAME=`${ORACLE_HOME}/bin/srvctl status database -d ${DB_UNIQUE_NAME} |awk '{print $NF}'|awk '{print NR,$0}'|awk '{print $2}'|awk -v INSTANCE_NUMBER=${INSTANCE_NUMBER} 'FNR == INSTANCE_NUMBER {print}'`
          for UNENCRYPT_SCRIPT in `ls ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_INSTANCE_NAME}_UNENCRYPT_CMD_*.sh`
          do
            chmod a+x ${UNENCRYPT_SCRIPT}
            ssh $DB_HOST_NAME "nohup ${UNENCRYPT_SCRIPT} > /dev/null 2>&1 &"
          done
        done
        
        for INSTANCE_NUMBER in `${ORACLE_HOME}/bin/srvctl status database -d ${DB_UNIQUE_NAME} |awk '{print $2}'|awk '{print NR,$0}'|awk '{print $1}'`
        do
          DB_INSTANCE_NAME=`${ORACLE_HOME}/bin/srvctl status database -d ${DB_UNIQUE_NAME} |awk '{print $2}'|awk '{print NR,$0}'|awk '{print $2}'|awk -v INSTANCE_NUMBER=${INSTANCE_NUMBER} 'FNR == INSTANCE_NUMBER {print}'`
          DB_HOST_NAME=`${ORACLE_HOME}/bin/srvctl status database -d ${DB_UNIQUE_NAME} |awk '{print $NF}'|awk '{print NR,$0}'|awk '{print $2}'|awk -v INSTANCE_NUMBER=${INSTANCE_NUMBER} 'FNR == INSTANCE_NUMBER {print}'`
          RUNNING_SCRIPTS_COUNT=`ssh $DB_HOST_NAME "ps -ef|grep ${DB_INSTANCE_NAME}_UNENCRYPT_CMD |grep -v grep |wc -l"`
          UNENCRYPTED_DATAFILES_COMPLETED_COUNT=`ls -ltrh ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_NAME}*_UNENCRYPT_CMD*COMPLETED.log 2>/dev/null |wc -l`
          UNENCRYPTED_DATAFILES_FAILED_COUNT=`ls -ltrh ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_NAME}*_UNENCRYPT_CMD*FAILED.log 2>/dev/null |wc -l`
          UNENCRYPTED_DATAFILES_ISRUNNING_COUNT=`ls -ltrh ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_NAME}*_UNENCRYPT_CMD*ISRUNNING.log 2>/dev/null |wc -l`

          
          if [[ ${UNENCRYPTED_DATAFILES_COMPLETED_COUNT} -eq ${DATAFILE_COUNT} ]] && [[ ${UNENCRYPTED_DATAFILES_FAILED_COUNT} -eq 0 ]] && [[ ${UNENCRYPTED_DATAFILES_ISRUNNING_COUNT} -eq 0 ]]
          then
            if grep -q "UNENCRYPT_DATAFILES" $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
            then
              sed -i '$d' $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
              UNENCRYPTED_DATAFILES_COMPLETED_COUNT=`ls -ltrh ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_NAME}*_UNENCRYPT_CMD*COMPLETED.log 2>/dev/null |wc -l`
              UNENCRYPTED_DATAFILES_FAILED_COUNT=`ls -ltrh ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_NAME}*_UNENCRYPT_CMD*FAILED.log 2>/dev/null |wc -l`
              UNENCRYPTED_DATAFILES_ISRUNNING_COUNT=`ls -ltrh ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_NAME}*_UNENCRYPT_CMD*ISRUNNING.log 2>/dev/null |wc -l`
              echo -e "${GREEN} UNENCRYPT_DATAFILES = SUCCESS, ${UNENCRYPTED_DATAFILES_COMPLETED_COUNT} OUT OF ${DATAFILE_COUNT} DATAFILES, ${UNENCRYPTED_DATAFILES_FAILED_COUNT} DATAFILES FAILED ${ENDCOLOR}" | tee -a $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
            else
              UNENCRYPTED_DATAFILES_COMPLETED_COUNT=`ls -ltrh ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_NAME}*_UNENCRYPT_CMD*COMPLETED.log 2>/dev/null |wc -l`
              UNENCRYPTED_DATAFILES_FAILED_COUNT=`ls -ltrh ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_NAME}*_UNENCRYPT_CMD*FAILED.log 2>/dev/null |wc -l`
              UNENCRYPTED_DATAFILES_ISRUNNING_COUNT=`ls -ltrh ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_NAME}*_UNENCRYPT_CMD*ISRUNNING.log 2>/dev/null |wc -l`
              echo -e "${GREEN} UNENCRYPT_DATAFILES = SUCCESS, ${UNENCRYPTED_DATAFILES_COMPLETED_COUNT} OUT OF ${DATAFILE_COUNT} DATAFILES, ${UNENCRYPTED_DATAFILES_FAILED_COUNT} DATAFILES FAILED ${ENDCOLOR}" | tee -a $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
            fi
          elif [[ ${UNENCRYPTED_DATAFILES_COMPLETED_COUNT} -ne ${DATAFILE_COUNT} ]] && [[ ${UNENCRYPTED_DATAFILES_FAILED_COUNT} -gt 0 ]] && [[ ${UNENCRYPTED_DATAFILES_ISRUNNING_COUNT} -eq 0 ]]
          then
            if grep -q "UNENCRYPT_DATAFILES" $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
            then
              sed -i '$d' $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
              UNENCRYPTED_DATAFILES_COMPLETED_COUNT=`ls -ltrh ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_NAME}*_UNENCRYPT_CMD*COMPLETED.log 2>/dev/null |wc -l`
              UNENCRYPTED_DATAFILES_FAILED_COUNT=`ls -ltrh ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_NAME}*_UNENCRYPT_CMD*FAILED.log 2>/dev/null |wc -l`
              UNENCRYPTED_DATAFILES_ISRUNNING_COUNT=`ls -ltrh ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_NAME}*_UNENCRYPT_CMD*ISRUNNING.log 2>/dev/null |wc -l`
              echo -e "${RED} UNENCRYPT_DATAFILES = FAILED, ${UNENCRYPTED_DATAFILES_COMPLETED_COUNT} OUT OF ${DATAFILE_COUNT} DATAFILES, ${UNENCRYPTED_DATAFILES_FAILED_COUNT} DATAFILES FAILED ${ENDCOLOR}" | tee -a $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
              exit 1
            else
              UNENCRYPTED_DATAFILES_COMPLETED_COUNT=`ls -ltrh ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_NAME}*_UNENCRYPT_CMD*COMPLETED.log 2>/dev/null |wc -l`
              UNENCRYPTED_DATAFILES_FAILED_COUNT=`ls -ltrh ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_NAME}*_UNENCRYPT_CMD*FAILED.log 2>/dev/null |wc -l`
              UNENCRYPTED_DATAFILES_ISRUNNING_COUNT=`ls -ltrh ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_NAME}*_UNENCRYPT_CMD*ISRUNNING.log 2>/dev/null |wc -l`
              echo -e "${RED} UNENCRYPT_DATAFILES = FAILED, ${UNENCRYPTED_DATAFILES_COMPLETED_COUNT} OUT OF ${DATAFILE_COUNT} DATAFILES, ${UNENCRYPTED_DATAFILES_FAILED_COUNT} DATAFILES FAILED ${ENDCOLOR}" | tee -a $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
              exit 1
            fi            
          else
            if grep -q "UNENCRYPT_DATAFILES" $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
            then
              sed -i '$d' $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
              UNENCRYPTED_DATAFILES_COMPLETED_COUNT=`ls -ltrh ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_NAME}*_UNENCRYPT_CMD*COMPLETED.log 2>/dev/null |wc -l`
              UNENCRYPTED_DATAFILES_FAILED_COUNT=`ls -ltrh ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_NAME}*_UNENCRYPT_CMD*FAILED.log 2>/dev/null |wc -l`
              UNENCRYPTED_DATAFILES_ISRUNNING_COUNT=`ls -ltrh ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_NAME}*_UNENCRYPT_CMD*ISRUNNING.log 2>/dev/null |wc -l`
              echo -e "${GREEN} UNENCRYPT_DATAFILES = RUNNING, ${UNENCRYPTED_DATAFILES_COMPLETED_COUNT} OUT OF ${DATAFILE_COUNT} DATAFILES, ${UNENCRYPTED_DATAFILES_FAILED_COUNT} DATAFILES FAILED ${ENDCOLOR}" | tee -a $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log 
            else
              UNENCRYPTED_DATAFILES_COMPLETED_COUNT=`ls -ltrh ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_NAME}*_UNENCRYPT_CMD*COMPLETED.log 2>/dev/null |wc -l`
              UNENCRYPTED_DATAFILES_FAILED_COUNT=`ls -ltrh ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_NAME}*_UNENCRYPT_CMD*FAILED.log 2>/dev/null |wc -l`
              UNENCRYPTED_DATAFILES_ISRUNNING_COUNT=`ls -ltrh ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_NAME}*_UNENCRYPT_CMD*ISRUNNING.log 2>/dev/null |wc -l`
              echo -e "${GREEN} UNENCRYPT_DATAFILES = RUNNING, ${UNENCRYPTED_DATAFILES_COMPLETED_COUNT} OUT OF ${DATAFILE_COUNT} DATAFILES, ${UNENCRYPTED_DATAFILES_FAILED_COUNT} DATAFILES FAILED ${ENDCOLOR}" | tee -a $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
            fi
          fi

          while [ ${RUNNING_SCRIPTS_COUNT} -gt 0 ] || [ ${UNENCRYPTED_DATAFILES_ISRUNNING_COUNT} -gt 0 ]
          do
            sed -i '$d' $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log 
            UNENCRYPTED_DATAFILES_COMPLETED_COUNT=`ls -ltrh ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_NAME}*_UNENCRYPT_CMD*COMPLETED.log 2>/dev/null |wc -l`
            UNENCRYPTED_DATAFILES_FAILED_COUNT=`ls -ltrh ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_NAME}*_UNENCRYPT_CMD*FAILED.log 2>/dev/null |wc -l`
            UNENCRYPTED_DATAFILES_ISRUNNING_COUNT=`ls -ltrh ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_NAME}*_UNENCRYPT_CMD*ISRUNNING.log 2>/dev/null |wc -l`
            echo -e "${GREEN} UNENCRYPT_DATAFILES = RUNNING, ${UNENCRYPTED_DATAFILES_COMPLETED_COUNT} OUT OF ${DATAFILE_COUNT} DATAFILES, ${UNENCRYPTED_DATAFILES_FAILED_COUNT} DATAFILES FAILED ${ENDCOLOR}" | tee -a $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
            sleep 10
            RUNNING_SCRIPTS_COUNT=`ssh $DB_HOST_NAME "ps -ef|grep ${DB_INSTANCE_NAME}_UNENCRYPT_CMD |grep -v grep |wc -l"`
            UNENCRYPTED_DATAFILES_ISRUNNING_COUNT=`ls -ltrh ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_NAME}*_UNENCRYPT_CMD*ISRUNNING.log 2>/dev/null |wc -l`
          done  
        done
        
        sleep 20
        sed -i '$d' $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
        UNENCRYPTED_DATAFILES_COMPLETED_COUNT=`ls -ltrh ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_NAME}*_UNENCRYPT_CMD*COMPLETED.log 2>/dev/null |wc -l`
        UNENCRYPTED_DATAFILES_FAILED_COUNT=`ls -ltrh ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_NAME}*_UNENCRYPT_CMD*FAILED.log 2>/dev/null |wc -l`
        UNENCRYPTED_DATAFILES_ISRUNNING_COUNT=`ls -ltrh ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_NAME}*_UNENCRYPT_CMD*ISRUNNING.log 2>/dev/null |wc -l`
        echo -e "${GREEN} UNENCRYPT_DATAFILES = SUCCESS, ${UNENCRYPTED_DATAFILES_COMPLETED_COUNT} OUT OF ${DATAFILE_COUNT} DATAFILES, ${UNENCRYPTED_DATAFILES_FAILED_COUNT} DATAFILES FAILED ${ENDCOLOR}" | tee -a $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
      fi
    fi

  elif [[ $HOST_TYPE == 'EXADATA' ]] && [[ $DB_VERSION -lt 19 ]] && [[ $OPTION == 'UNENCRYPT' ]]
  then
    $ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF > /dev/null
    set lines 200
    set pages 0
    set feedback off
    spool ${TDE_DB_DF_DIR}/${DB_UNIQUE_NAME}_DATAFILE_UNENCRYPT_MAINLIST.log
    select 'alter database datafile '||chr(39)||df.name||chr(39)||' decrypt;' COMMAND from v\$tablespace ts, v\$datafile df where ts.ts#=df.ts# and ts.name not in ('SYSTEM','SYSAUX') and ts.name not like '%UNDO%' and ts.name not like '%TEMP%'   order by df.name;
    spool off
    exit
EOF
    


    DB_INSTANCE_COUNT=`${ORACLE_HOME}/bin/srvctl status database -d ${DB_UNIQUE_NAME} |awk '{print $2}'| wc -l`
    DATAFILE_COUNT=`cat ${TDE_DB_DF_DIR}/${DB_UNIQUE_NAME}_DATAFILE_UNENCRYPT_MAINLIST.log | wc -l`
    SPLIT_LINES_COUNT=`echo $(((${DATAFILE_COUNT} + ${DB_INSTANCE_COUNT} - 1)/${DB_INSTANCE_COUNT}))`
    
    split  --lines=${SPLIT_LINES_COUNT} --suffix-length=1 --numeric-suffixes=1 --additional-suffix=.sql ${TDE_DB_DF_DIR}/${DB_UNIQUE_NAME}_DATAFILE_UNENCRYPT_MAINLIST.log ${TDE_DB_DF_UNENCRYPT_DIR}/splitted_${DB_NAME}

    LAST_COMMAND_EXIT_STATUS=$?

    if [[ $LAST_COMMAND_EXIT_STATUS -ne 0 ]]
    then 
      echo -e "${RED} UNENCRYPT_DATAFILES = ERROR, MAINLIST SPLIT FOR FILES FAILED ${ENDCOLOR}" | tee $TDE_FAILED_EXEC_DIR/FAILED_EXEC_${DATETIME}.log
	    echo -e "${RED} UNENCRYPT_DATAFILES = ERROR, MAINLIST SPLIT FOR FILES FAILED ${ENDCOLOR}" >> $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
	    exit 1
    else  
      for INSTANCE_NUMBER in `${ORACLE_HOME}/bin/srvctl status database -d ${DB_UNIQUE_NAME} |awk '{print $2}'|awk '{print NR,$0}'|awk '{print $1}'`
      do  
        COUNTER=0
        DB_INSTANCE_NAME=`${ORACLE_HOME}/bin/srvctl status database -d ${DB_UNIQUE_NAME} |awk '{print $2}'|awk '{print NR,$0}'|awk '{print $2}'|awk -v INSTANCE_NUMBER=${INSTANCE_NUMBER} 'FNR == INSTANCE_NUMBER {print}'`
        while read line 
        do 
          COUNTER=`echo $((${COUNTER}+1))` 
          echo ". /oracle/stagenfs/scripts/shell/setoraenv.ksh ${DB_UNIQUE_NAME} > /dev/null" > ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_INSTANCE_NAME}_UNENCRYPT_CMD_${COUNTER}.sh
          echo "sleep 30" >> ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_INSTANCE_NAME}_UNENCRYPT_CMD_${COUNTER}.sh
          echo "$ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF > /dev/null" >> ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_INSTANCE_NAME}_UNENCRYPT_CMD_${COUNTER}.sh
          echo "set echo on" >> ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_INSTANCE_NAME}_UNENCRYPT_CMD_${COUNTER}.sh
          echo "set feedback on" >> ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_INSTANCE_NAME}_UNENCRYPT_CMD_${COUNTER}.sh
          echo "set time on" >> ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_INSTANCE_NAME}_UNENCRYPT_CMD_${COUNTER}.sh
          echo "set timi on" >> ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_INSTANCE_NAME}_UNENCRYPT_CMD_${COUNTER}.sh
          echo "spool ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_INSTANCE_NAME}_UNENCRYPT_CMD_${COUNTER}_ISRUNNING.log" >> ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_INSTANCE_NAME}_UNENCRYPT_CMD_${COUNTER}.sh
          echo "${line}" >> ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_INSTANCE_NAME}_UNENCRYPT_CMD_${COUNTER}.sh
          echo "spool off" >> ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_INSTANCE_NAME}_UNENCRYPT_CMD_${COUNTER}.sh
          echo "exit" >> ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_INSTANCE_NAME}_UNENCRYPT_CMD_${COUNTER}.sh
          echo "EOF" >> ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_INSTANCE_NAME}_UNENCRYPT_CMD_${COUNTER}.sh
          echo "if [[ -f ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_INSTANCE_NAME}_UNENCRYPT_CMD_${COUNTER}_ISRUNNING.log ]]" >> ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_INSTANCE_NAME}_UNENCRYPT_CMD_${COUNTER}.sh
          echo "then" >> ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_INSTANCE_NAME}_UNENCRYPT_CMD_${COUNTER}.sh
          echo "  if grep -q "ORA-" ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_INSTANCE_NAME}_UNENCRYPT_CMD_${COUNTER}_ISRUNNING.log" >> ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_INSTANCE_NAME}_UNENCRYPT_CMD_${COUNTER}.sh
          echo "  then" >> ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_INSTANCE_NAME}_UNENCRYPT_CMD_${COUNTER}.sh
          echo "    mv ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_INSTANCE_NAME}_UNENCRYPT_CMD_${COUNTER}_ISRUNNING.log ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_INSTANCE_NAME}_UNENCRYPT_CMD_${COUNTER}_FAILED.log" >> ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_INSTANCE_NAME}_UNENCRYPT_CMD_${COUNTER}.sh
          echo "  else" >> ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_INSTANCE_NAME}_UNENCRYPT_CMD_${COUNTER}.sh
          echo "    mv ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_INSTANCE_NAME}_UNENCRYPT_CMD_${COUNTER}_ISRUNNING.log ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_INSTANCE_NAME}_UNENCRYPT_CMD_${COUNTER}_COMPLETED.log" >> ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_INSTANCE_NAME}_UNENCRYPT_CMD_${COUNTER}.sh
          echo "  fi" >> ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_INSTANCE_NAME}_UNENCRYPT_CMD_${COUNTER}.sh
          echo "fi" >> ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_INSTANCE_NAME}_UNENCRYPT_CMD_${COUNTER}.sh
          chmod a+x ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_INSTANCE_NAME}_UNENCRYPT_CMD_${COUNTER}.sh
        done < ${TDE_DB_DF_UNENCRYPT_DIR}/splitted_${DB_NAME}${INSTANCE_NUMBER}.sql; 
      done
      
      LAST_COMMAND_EXIT_STATUS=$?

      if [[ $LAST_COMMAND_EXIT_STATUS -ne 0 ]]
      then 
        echo -e "${RED} UNENCRYPT_DATAFILES = ERROR, FAILED AT CREATING DB INSTANCE UNENCRYPT COMMANDS ${ENDCOLOR}" | tee $TDE_FAILED_EXEC_DIR/FAILED_EXEC_${DATETIME}.log
	      echo -e "${RED} UNENCRYPT_DATAFILES = ERROR, FAILED AT CREATING DB INSTANCE UNENCRYPT COMMANDS ${ENDCOLOR}" >> $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
	      exit 1
      else  
        for INSTANCE_NUMBER in `${ORACLE_HOME}/bin/srvctl status database -d ${DB_UNIQUE_NAME} |awk '{print $2}'|awk '{print NR,$0}'|awk '{print $1}'`
        do
          DB_INSTANCE_NAME=`${ORACLE_HOME}/bin/srvctl status database -d ${DB_UNIQUE_NAME} |awk '{print $2}'|awk '{print NR,$0}'|awk '{print $2}'|awk -v INSTANCE_NUMBER=${INSTANCE_NUMBER} 'FNR == INSTANCE_NUMBER {print}'`
          DB_HOST_NAME=`${ORACLE_HOME}/bin/srvctl status database -d ${DB_UNIQUE_NAME} |awk '{print $NF}'|awk '{print NR,$0}'|awk '{print $2}'|awk -v INSTANCE_NUMBER=${INSTANCE_NUMBER} 'FNR == INSTANCE_NUMBER {print}'`
          for UNENCRYPT_SCRIPT in `ls ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_INSTANCE_NAME}_UNENCRYPT_CMD_*.sh`
          do
            chmod a+x ${UNENCRYPT_SCRIPT}
            ssh $DB_HOST_NAME "nohup ${UNENCRYPT_SCRIPT} > /dev/null 2>&1 &"
          done
        done
        
        for INSTANCE_NUMBER in `${ORACLE_HOME}/bin/srvctl status database -d ${DB_UNIQUE_NAME} |awk '{print $2}'|awk '{print NR,$0}'|awk '{print $1}'`
        do
          DB_INSTANCE_NAME=`${ORACLE_HOME}/bin/srvctl status database -d ${DB_UNIQUE_NAME} |awk '{print $2}'|awk '{print NR,$0}'|awk '{print $2}'|awk -v INSTANCE_NUMBER=${INSTANCE_NUMBER} 'FNR == INSTANCE_NUMBER {print}'`
          DB_HOST_NAME=`${ORACLE_HOME}/bin/srvctl status database -d ${DB_UNIQUE_NAME} |awk '{print $NF}'|awk '{print NR,$0}'|awk '{print $2}'|awk -v INSTANCE_NUMBER=${INSTANCE_NUMBER} 'FNR == INSTANCE_NUMBER {print}'`
          RUNNING_SCRIPTS_COUNT=`ssh $DB_HOST_NAME "ps -ef|grep ${DB_INSTANCE_NAME}_UNENCRYPT_CMD |grep -v grep |wc -l"`
          UNENCRYPTED_DATAFILES_COMPLETED_COUNT=`ls -ltrh ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_NAME}*_UNENCRYPT_CMD*COMPLETED.log 2>/dev/null |wc -l`
          UNENCRYPTED_DATAFILES_FAILED_COUNT=`ls -ltrh ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_NAME}*_UNENCRYPT_CMD*FAILED.log 2>/dev/null |wc -l`
          UNENCRYPTED_DATAFILES_ISRUNNING_COUNT=`ls -ltrh ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_NAME}*_UNENCRYPT_CMD*ISRUNNING.log 2>/dev/null |wc -l`

          
          if [[ ${UNENCRYPTED_DATAFILES_COMPLETED_COUNT} -eq ${DATAFILE_COUNT} ]] && [[ ${UNENCRYPTED_DATAFILES_FAILED_COUNT} -eq 0 ]] && [[ ${UNENCRYPTED_DATAFILES_ISRUNNING_COUNT} -eq 0 ]]
          then
            if grep -q "UNENCRYPT_DATAFILES" $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
            then
              sed -i '$d' $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
              UNENCRYPTED_DATAFILES_COMPLETED_COUNT=`ls -ltrh ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_NAME}*_UNENCRYPT_CMD*COMPLETED.log 2>/dev/null |wc -l`
              UNENCRYPTED_DATAFILES_FAILED_COUNT=`ls -ltrh ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_NAME}*_UNENCRYPT_CMD*FAILED.log 2>/dev/null |wc -l`
              UNENCRYPTED_DATAFILES_ISRUNNING_COUNT=`ls -ltrh ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_NAME}*_UNENCRYPT_CMD*ISRUNNING.log 2>/dev/null |wc -l`
              echo -e "${GREEN} UNENCRYPT_DATAFILES = SUCCESS, ${UNENCRYPTED_DATAFILES_COMPLETED_COUNT} OUT OF ${DATAFILE_COUNT} DATAFILES, ${UNENCRYPTED_DATAFILES_FAILED_COUNT} DATAFILES FAILED ${ENDCOLOR}" | tee -a $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
            else
              UNENCRYPTED_DATAFILES_COMPLETED_COUNT=`ls -ltrh ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_NAME}*_UNENCRYPT_CMD*COMPLETED.log 2>/dev/null |wc -l`
              UNENCRYPTED_DATAFILES_FAILED_COUNT=`ls -ltrh ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_NAME}*_UNENCRYPT_CMD*FAILED.log 2>/dev/null |wc -l`
              UNENCRYPTED_DATAFILES_ISRUNNING_COUNT=`ls -ltrh ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_NAME}*_UNENCRYPT_CMD*ISRUNNING.log 2>/dev/null |wc -l`
              echo -e "${GREEN} UNENCRYPT_DATAFILES = SUCCESS, ${UNENCRYPTED_DATAFILES_COMPLETED_COUNT} OUT OF ${DATAFILE_COUNT} DATAFILES, ${UNENCRYPTED_DATAFILES_FAILED_COUNT} DATAFILES FAILED ${ENDCOLOR}" | tee -a $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
            fi
          elif [[ ${UNENCRYPTED_DATAFILES_COMPLETED_COUNT} -ne ${DATAFILE_COUNT} ]] && [[ ${UNENCRYPTED_DATAFILES_FAILED_COUNT} -gt 0 ]] && [[ ${UNENCRYPTED_DATAFILES_ISRUNNING_COUNT} -eq 0 ]]
          then
            if grep -q "UNENCRYPT_DATAFILES" $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
            then
              sed -i '$d' $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
              UNENCRYPTED_DATAFILES_COMPLETED_COUNT=`ls -ltrh ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_NAME}*_UNENCRYPT_CMD*COMPLETED.log 2>/dev/null |wc -l`
              UNENCRYPTED_DATAFILES_FAILED_COUNT=`ls -ltrh ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_NAME}*_UNENCRYPT_CMD*FAILED.log 2>/dev/null |wc -l`
              UNENCRYPTED_DATAFILES_ISRUNNING_COUNT=`ls -ltrh ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_NAME}*_UNENCRYPT_CMD*ISRUNNING.log 2>/dev/null |wc -l`
              echo -e "${RED} UNENCRYPT_DATAFILES = FAILED, ${UNENCRYPTED_DATAFILES_COMPLETED_COUNT} OUT OF ${DATAFILE_COUNT} DATAFILES, ${UNENCRYPTED_DATAFILES_FAILED_COUNT} DATAFILES FAILED ${ENDCOLOR}" | tee -a $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
              exit 1
            else
              UNENCRYPTED_DATAFILES_COMPLETED_COUNT=`ls -ltrh ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_NAME}*_UNENCRYPT_CMD*COMPLETED.log 2>/dev/null |wc -l`
              UNENCRYPTED_DATAFILES_FAILED_COUNT=`ls -ltrh ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_NAME}*_UNENCRYPT_CMD*FAILED.log 2>/dev/null |wc -l`
              UNENCRYPTED_DATAFILES_ISRUNNING_COUNT=`ls -ltrh ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_NAME}*_UNENCRYPT_CMD*ISRUNNING.log 2>/dev/null |wc -l`
              echo -e "${RED} UNENCRYPT_DATAFILES = FAILED, ${UNENCRYPTED_DATAFILES_COMPLETED_COUNT} OUT OF ${DATAFILE_COUNT} DATAFILES, ${UNENCRYPTED_DATAFILES_FAILED_COUNT} DATAFILES FAILED ${ENDCOLOR}" | tee -a $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
              exit 1
            fi            
          else
            if grep -q "UNENCRYPT_DATAFILES" $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
            then
              sed -i '$d' $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
              UNENCRYPTED_DATAFILES_COMPLETED_COUNT=`ls -ltrh ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_NAME}*_UNENCRYPT_CMD*COMPLETED.log 2>/dev/null |wc -l`
              UNENCRYPTED_DATAFILES_FAILED_COUNT=`ls -ltrh ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_NAME}*_UNENCRYPT_CMD*FAILED.log 2>/dev/null |wc -l`
              UNENCRYPTED_DATAFILES_ISRUNNING_COUNT=`ls -ltrh ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_NAME}*_UNENCRYPT_CMD*ISRUNNING.log 2>/dev/null |wc -l`
              echo -e "${GREEN} UNENCRYPT_DATAFILES = RUNNING, ${UNENCRYPTED_DATAFILES_COMPLETED_COUNT} OUT OF ${DATAFILE_COUNT} DATAFILES, ${UNENCRYPTED_DATAFILES_FAILED_COUNT} DATAFILES FAILED ${ENDCOLOR}" | tee -a $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log 
            else
              UNENCRYPTED_DATAFILES_COMPLETED_COUNT=`ls -ltrh ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_NAME}*_UNENCRYPT_CMD*COMPLETED.log 2>/dev/null |wc -l`
              UNENCRYPTED_DATAFILES_FAILED_COUNT=`ls -ltrh ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_NAME}*_UNENCRYPT_CMD*FAILED.log 2>/dev/null |wc -l`
              UNENCRYPTED_DATAFILES_ISRUNNING_COUNT=`ls -ltrh ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_NAME}*_UNENCRYPT_CMD*ISRUNNING.log 2>/dev/null |wc -l`
              echo -e "${GREEN} UNENCRYPT_DATAFILES = RUNNING, ${UNENCRYPTED_DATAFILES_COMPLETED_COUNT} OUT OF ${DATAFILE_COUNT} DATAFILES, ${UNENCRYPTED_DATAFILES_FAILED_COUNT} DATAFILES FAILED ${ENDCOLOR}" | tee -a $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
            fi
          fi

          while [ ${RUNNING_SCRIPTS_COUNT} -gt 0 ] || [ ${UNENCRYPTED_DATAFILES_ISRUNNING_COUNT} -gt 0 ]
          do
            sed -i '$d' $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log 
            UNENCRYPTED_DATAFILES_COMPLETED_COUNT=`ls -ltrh ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_NAME}*_UNENCRYPT_CMD*COMPLETED.log 2>/dev/null |wc -l`
            UNENCRYPTED_DATAFILES_FAILED_COUNT=`ls -ltrh ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_NAME}*_UNENCRYPT_CMD*FAILED.log 2>/dev/null |wc -l`
            UNENCRYPTED_DATAFILES_ISRUNNING_COUNT=`ls -ltrh ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_NAME}*_UNENCRYPT_CMD*ISRUNNING.log 2>/dev/null |wc -l`
            echo -e "${GREEN} UNENCRYPT_DATAFILES = RUNNING, ${UNENCRYPTED_DATAFILES_COMPLETED_COUNT} OUT OF ${DATAFILE_COUNT} DATAFILES, ${UNENCRYPTED_DATAFILES_FAILED_COUNT} DATAFILES FAILED ${ENDCOLOR}" | tee -a $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
            sleep 10
            RUNNING_SCRIPTS_COUNT=`ssh $DB_HOST_NAME "ps -ef|grep ${DB_INSTANCE_NAME}_UNENCRYPT_CMD |grep -v grep |wc -l"`
            UNENCRYPTED_DATAFILES_ISRUNNING_COUNT=`ls -ltrh ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_NAME}*_UNENCRYPT_CMD*ISRUNNING.log 2>/dev/null |wc -l`
          done  
        done
        
        sleep 20
        sed -i '$d' $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
        UNENCRYPTED_DATAFILES_COMPLETED_COUNT=`ls -ltrh ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_NAME}*_UNENCRYPT_CMD*COMPLETED.log 2>/dev/null |wc -l`
        UNENCRYPTED_DATAFILES_FAILED_COUNT=`ls -ltrh ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_NAME}*_UNENCRYPT_CMD*FAILED.log 2>/dev/null |wc -l`
        UNENCRYPTED_DATAFILES_ISRUNNING_COUNT=`ls -ltrh ${TDE_DB_DF_UNENCRYPT_DIR}/${DB_NAME}*_UNENCRYPT_CMD*ISRUNNING.log 2>/dev/null |wc -l`
        echo -e "${GREEN} UNENCRYPT_DATAFILES = SUCCESS, ${UNENCRYPTED_DATAFILES_COMPLETED_COUNT} OUT OF ${DATAFILE_COUNT} DATAFILES, ${UNENCRYPTED_DATAFILES_FAILED_COUNT} DATAFILES FAILED ${ENDCOLOR}" | tee -a $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
      fi
    fi 
  fi  

}


  function ONLINE_TABLESPACES () {
  
  if [[ $HOST_TYPE == 'EXADATA' ]] && [[ $DB_VERSION -eq 19 ]] 
  then
    $ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF > /dev/null
    set serverout on
    set echo off
    set feedback off
    spool ${TDE_DB_POST_DIR}/ONLINE_TABLESPACES_AFTER.log
    BEGIN
       FOR v_unq_tbsp in (select name from v\$tablespace where name not in ('SYSTEM','SYSAUX') and  name not like '%UNDO%' and name not like '%TEMP%' order by name)
       LOOP
          BEGIN
              EXECUTE IMMEDIATE 'alter tablespace '||v_unq_tbsp.name||' online';
          EXCEPTION
            WHEN OTHERS THEN
              IF SQLCODE = -01539 THEN
                NULL; -- suppresses ORA-01539 exception
              ELSE
                RAISE;
              END IF;    
          END;
       END LOOP;
       FOR v_unq_tbsp in (select b.name name,a.status status from v\$datafile a, v\$tablespace b where a.ts# = b.ts# and b.name not in ('SYSTEM','SYSAUX') and b.name not like '%UNDO%' and b.name not like '%TEMP%' group by b.name,a.status)
       LOOP
          dbms_output.Put_line(v_unq_tbsp.name||' is '||v_unq_tbsp.status);
       END LOOP;    
    END;
    /

EOF

    IS_ANY_TBSP_OFFLINE=`cat ${TDE_DB_POST_DIR}/ONLINE_TABLESPACES_AFTER.log| grep 'OFFLINE'| wc -l `

    if [[ ${IS_ANY_TBSP_OFFLINE} -gt 0 ]] 
    then
      echo -e "${RED} ONLINE_TABLESPACES = ERROR, DATA TABLESPACES WERE NOT ONLINED AFTER ${OPTION} ${ENDCOLOR}" | tee $TDE_FAILED_EXEC_DIR/FAILED_EXEC_${DATETIME}.log
	    echo -e "${RED} ONLINE_TABLESPACES = ERROR, DATA TABLESPACES WERE NOT ONLINED AFTER ${OPTION}" >> $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
	    exit 1  
    else
      echo -e "${GREEN} ONLINE_TABLESPACES = SUCCESS, DATA TABLESPACES ARE NOW ONLINE AFTER ${OPTION}, MOVING ON TO NEXT STEP ${ENDCOLOR}" | tee -a $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
    fi        

  elif [[ $HOST_TYPE == 'EXADATA' ]] && [[ $DB_VERSION -eq 12 ]] 
  then
    $ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF > /dev/null
    set serverout on
    set echo off
    set feedback off
    spool ${TDE_DB_POST_DIR}/ONLINE_TABLESPACES_AFTER.log
    BEGIN
       FOR v_unq_tbsp in (select name from v\$tablespace where name not in ('SYSTEM','SYSAUX') and  name not like '%UNDO%' and name not like '%TEMP%' order by name)
       LOOP
          BEGIN
              EXECUTE IMMEDIATE 'alter tablespace '||v_unq_tbsp.name||' online';
          EXCEPTION
            WHEN OTHERS THEN
              IF SQLCODE = -01539 THEN
                NULL; -- suppresses ORA-01539 exception
              ELSE
                RAISE;
              END IF;    
          END;
       END LOOP;
       FOR v_unq_tbsp in (select b.name name,a.status status from v\$datafile a, v\$tablespace b where a.ts# = b.ts# and b.name not in ('SYSTEM','SYSAUX') and b.name not like '%UNDO%' and b.name not like '%TEMP%' group by b.name,a.status)
       LOOP
          dbms_output.Put_line(v_unq_tbsp.name||' is '||v_unq_tbsp.status);
       END LOOP;    
    END;
    /

EOF

    IS_ANY_TBSP_OFFLINE=`cat ${TDE_DB_POST_DIR}/ONLINE_TABLESPACES_AFTER.log| grep 'OFFLINE'| wc -l `

    if [[ ${IS_ANY_TBSP_OFFLINE} -gt 0 ]] 
    then
      echo -e "${RED} ONLINE_TABLESPACES = ERROR, DATA TABLESPACES WERE NOT ONLINED AFTER ${OPTION} ${ENDCOLOR}" | tee $TDE_FAILED_EXEC_DIR/FAILED_EXEC_${DATETIME}.log
	    echo -e "${RED} ONLINE_TABLESPACES = ERROR, DATA TABLESPACES WERE NOT ONLINED AFTER ${OPTION}" >> $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
	    exit 1  
    else
      echo -e "${GREEN} ONLINE_TABLESPACES = SUCCESS, DATA TABLESPACES ARE NOW ONLINE AFTER ${OPTION}, MOVING ON TO NEXT STEP ${ENDCOLOR}" | tee -a $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
    fi        

  elif [[ $HOST_TYPE == 'NONEXADATA' ]] && [[ $DB_VERSION -eq 19 ]] 
  then
    $ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF > /dev/null
    set serverout on
    set echo off
    set feedback off
    spool ${TDE_DB_POST_DIR}/ONLINE_TABLESPACES_AFTER.log
    BEGIN
       FOR v_unq_tbsp in (select name from v\$tablespace where name not in ('SYSTEM','SYSAUX') and  name not like '%UNDO%' and name not like '%TEMP%' order by name)
       LOOP
          BEGIN
              EXECUTE IMMEDIATE 'alter tablespace '||v_unq_tbsp.name||' online';
          EXCEPTION
            WHEN OTHERS THEN
              IF SQLCODE = -01539 THEN
                NULL; -- suppresses ORA-01539 exception
              ELSE
                RAISE;
              END IF;    
          END;
       END LOOP;
       FOR v_unq_tbsp in (select b.name name,a.status status from v\$datafile a, v\$tablespace b where a.ts# = b.ts# and b.name not in ('SYSTEM','SYSAUX') and b.name not like '%UNDO%' and b.name not like '%TEMP%' group by b.name,a.status)
       LOOP
          dbms_output.Put_line(v_unq_tbsp.name||' is '||v_unq_tbsp.status);
       END LOOP;    
    END;
    /

EOF

    IS_ANY_TBSP_OFFLINE=`cat ${TDE_DB_POST_DIR}/ONLINE_TABLESPACES_AFTER.log| grep 'OFFLINE'| wc -l `

    if [[ ${IS_ANY_TBSP_OFFLINE} -gt 0 ]] 
    then
      echo -e "${RED} ONLINE_TABLESPACES = ERROR, DATA TABLESPACES WERE NOT ONLINED AFTER ${OPTION} ${ENDCOLOR}" | tee $TDE_FAILED_EXEC_DIR/FAILED_EXEC_${DATETIME}.log
	    echo -e "${RED} ONLINE_TABLESPACES = ERROR, DATA TABLESPACES WERE NOT ONLINED AFTER ${OPTION}" >> $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
	    exit 1  
    else
      echo -e "${GREEN} ONLINE_TABLESPACES = SUCCESS, DATA TABLESPACES ARE NOW ONLINE AFTER ${OPTION}, MOVING ON TO NEXT STEP ${ENDCOLOR}" | tee -a $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
    fi        

  elif [[ $HOST_TYPE == 'NONEXADATA' ]] && [[ $DB_VERSION -eq 12 ]] 
  then
    $ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF > /dev/null
    set serverout on
    set echo off
    set feedback off
    spool ${TDE_DB_POST_DIR}/ONLINE_TABLESPACES_AFTER.log
    BEGIN
       FOR v_unq_tbsp in (select name from v\$tablespace where name not in ('SYSTEM','SYSAUX') and  name not like '%UNDO%' and name not like '%TEMP%' order by name)
       LOOP
          BEGIN
              EXECUTE IMMEDIATE 'alter tablespace '||v_unq_tbsp.name||' online';
          EXCEPTION
            WHEN OTHERS THEN
              IF SQLCODE = -01539 THEN
                NULL; -- suppresses ORA-01539 exception
              ELSE
                RAISE;
              END IF;    
          END;
       END LOOP;
       FOR v_unq_tbsp in (select b.name name,a.status status from v\$datafile a, v\$tablespace b where a.ts# = b.ts# and b.name not in ('SYSTEM','SYSAUX') and b.name not like '%UNDO%' and b.name not like '%TEMP%' group by b.name,a.status)
       LOOP
          dbms_output.Put_line(v_unq_tbsp.name||' is '||v_unq_tbsp.status);
       END LOOP;    
    END;
    /

EOF

    IS_ANY_TBSP_OFFLINE=`cat ${TDE_DB_POST_DIR}/ONLINE_TABLESPACES_AFTER.log| grep 'OFFLINE'| wc -l `

    if [[ ${IS_ANY_TBSP_OFFLINE} -gt 0 ]] 
    then
      echo -e "${RED} ONLINE_TABLESPACES = ERROR, DATA TABLESPACES WERE NOT ONLINED AFTER ${OPTION} ${ENDCOLOR}" | tee $TDE_FAILED_EXEC_DIR/FAILED_EXEC_${DATETIME}.log
	    echo -e "${RED} ONLINE_TABLESPACES = ERROR, DATA TABLESPACES WERE NOT ONLINED AFTER ${OPTION}" >> $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
	    exit 1  
    else
      echo -e "${GREEN} ONLINE_TABLESPACES = SUCCESS, DATA TABLESPACES ARE NOW ONLINE AFTER ${OPTION}, MOVING ON TO NEXT STEP ${ENDCOLOR}" | tee -a $TDE_DB_STATUS_DIR/MAIN_STATUS_${OPTION}_${DATETIME}.log
    fi    
  fi        



}




# IF EXADATA THEN

if [[ $HOST_TYPE == 'EXADATA' ]] && [[ $OPTION == 'ENCRYPT' ]]
then
  . /oracle/stagenfs/scripts/shell/setoraenv.ksh $DB_UNIQUE_NAME > /dev/null
  CREATE_LOG_DIRS_FUNC
  VERSION_OF_DB
  CREATE_SYSKM_DBUSER
  CREATE_WALLET_DIR
  . /oracle/stagenfs/scripts/shell/setoraenv.ksh $DB_UNIQUE_NAME > /dev/null
  CREATE_TNS_CONFIG_FILES_PRE_19
  SETUP_CLUSTER_PARAMETERS_PRE_19
  SETUP_DB_WALLET_PARAMS_19
  CREATE_KEYSTORE_AND_KEY
  OFFLINE_TABLESPACES
  ENCRYPT_DATAFILES
  ONLINE_TABLESPACES

elif [[ $HOST_TYPE == 'EXADATA' ]] && [[ $OPTION == 'UNENCRYPT' ]]
then
  . /oracle/stagenfs/scripts/shell/setoraenv.ksh $DB_UNIQUE_NAME > /dev/null
  CREATE_LOG_DIRS_FUNC
  VERSION_OF_DB
  . /oracle/stagenfs/scripts/shell/setoraenv.ksh $DB_UNIQUE_NAME > /dev/null
  OFFLINE_TABLESPACES
  UNENCRYPT_DATAFILES
  ONLINE_TABLESPACES
fi

#PASSWORD CHANGES
LOGDIR=/oracle_software/ftp_inbound/MiAppDBA/pwdchanges/db_links/logs/password_changes
PWD_FILE=/oracle_software/ftp_inbound/MiAppDBA/pwdchanges/db_links/master_password.txt
OPTION=$1
GREEN="\033[1;32;40m"
RED="\033[1;31;40m"
NORM="\033[0m"
ENDCOLOR="\e[0m"
HOST_NAME=`hostname`


function BACKUP_PASSWORDS () {

    srvctl config database -home|awk '{print $1 " " $2}'|while read DBNAME ORACLE_HOME
    do
        export ORACLE_HOME=${ORACLE_HOME}
        FIRST_INST_HOST_NAME=`${ORACLE_HOME}/bin/srvctl config database -d ${DBNAME} | grep 'Database instance'|awk '{print $3}'`
        export ORACLE_SID=${FIRST_INST_HOST_NAME}
        HOST_MAIN_DIR=${LOGDIR}/${HOST_NAME}
        DBLOGDIR=${LOGDIR}/${HOST_NAME}/${DBNAME}
        mkdir -p $DBLOGDIR
        rm -f $DBLOGDIR/*
        ROLE_OF_DB=`${ORACLE_HOME}/bin/srvctl config database -d ${DBNAME} |grep role| awk '{print $3}'`
        if [[ $ROLE_OF_DB == 'PRIMARY' ]]
        then
            DB_INST_CLOSED=`$ORACLE_HOME/bin/srvctl status database -d ${DBNAME} -v | grep 'not running\|Closed\|Dismounted'| wc -l`
            if [ $DB_INST_CLOSED -gt 0 ]
            then
                echo -e "${RED}${DBNAME} HAS ONE OR ALL INSTANCES ARE IN STOPPED,NOMOUNT,MOUNT STATUS. PLEASE START ALL INSTANCES. SKIPPING, FAILED${ENDCOLOR}" 
                echo -e "${RED}${DBNAME} HAS ONE OR ALL INSTANCES ARE IN STOPPED,NOMOUNT,MOUNT STATUS. PLEASE START ALL INSTANCES. SKIPPING, FAILED${ENDCOLOR}" > $HOST_MAIN_DIR/MAIN_STATUS_${OPTION}.log
                continue
            fi
        elif [[ $ROLE_OF_DB == 'PHYSICAL_STANDBY' ]]
        then
            echo -e "${RED}${DBNAME} IS A PHYSICAL STANDBY SKIPPING${ENDCOLOR}" 
            echo -e "${RED}${DBNAME} IS A PHYSICAL STANDBY SKIPPING${ENDCOLOR}" >> $HOST_MAIN_DIR/MAIN_STATUS_${OPTION}.log
            continue
        elif [[ $ROLE_OF_DB == 'FAR_SYNC' ]]
        then
            echo -e "${RED}${DBNAME} IS A FAR_SYNC STANDBY SKIPPING${ENDCOLOR}" 
            echo -e "${RED}${DBNAME} IS A FAR_SYNC STANDBY SKIPPING${ENDCOLOR}" >> $HOST_MAIN_DIR/MAIN_STATUS_${OPTION}.log
            continue
            
        fi

        export ORACLE_HOME=${ORACLE_HOME}
        FIRST_INST_HOST_NAME=`${ORACLE_HOME}/bin/srvctl config database -d ${DBNAME} | grep 'Database instance'|awk '{print $3}'`
        export ORACLE_SID=${FIRST_INST_HOST_NAME}
        DBLOGDIR=${LOGDIR}/${HOST_NAME}/${DBNAME}
        mkdir -p $DBLOGDIR
        rm -f $DBLOGDIR/*
    
    

        sqlplus -s / as sysdba <<EOF > /dev/null
        set head off
        set pages 2000
        set feedback off


        spool ${DBLOGDIR}/${DBNAME}_CHECK_IF_PDB.log
        select 'PDB_COUNT='||count(*) from v\$pdbs;
        spool off
        exit
EOF
        sed -i '/^$/d' ${DBLOGDIR}/${DBNAME}_CHECK_IF_PDB.log

        if grep -q "PDB_COUNT=0" ${DBLOGDIR}/${DBNAME}_CHECK_IF_PDB.log
        then
            ##BACKUP DB ALL USER PASSWORDS in NON CDBs
            $ORACLE_HOME/bin/sqlplus -S / as sysdba <<EOF > /dev/null
            SET PAGESIZE 0   ;
            SET FEEDBACK OFF ;
            spool ${DBLOGDIR}/backup_of_old_passwords.log
            select '-- Date: ' || to_char(sysdate, 'MM-DD-RRRR HH24:MI:SS') from dual;
            prompt -- Passwords for Oracle instance: ${ORACLE_SID}
            prompt
            set trimspool on
            set linesize 1024
            set heading off
            set feedback off
            set pagesize 0
            select
                case when b.account_status like '%LOCKED%'
                    then '-- Account locked on: ' || to_char(b.lock_date, 'MM/DD/YYYY HH:MI:SS')
                    else '-- Password expires on: ' || to_char(b.expiry_date,'MM/DD/YYYY HH:MI:SS')
                end  || chr(10) ||
                'alter user ' || a.name || ' profile default ; ' || chr(10) ||
                'alter user ' || a.name || ' account unlock ; ' || chr(10) ||
                case when a.spare4 is null
                    then 'alter user ' || a.name || ' identified by values ' ||chr(39)|| a.password ||chr(39)|| ' ; '
                    else 'alter user ' || a.name || ' identified by values ' ||chr(39)|| a.spare4 ||';'|| a.password ||chr(39)||' ; '
                end || chr(10) ||
                'alter user ' || a.name || ' profile ' || b.profile || ' ;'
                FROM SYS.user$ a, dba_users b
            where a.name = b.username
                and a.password <> 'EXTERNAL'
            order by a.name;
            spool off
            exit
EOF

            if ! grep -q "user SYSTEM" ${DBLOGDIR}/backup_of_old_passwords.log
            then
                echo -e "${RED}${DBNAME} BACKUP OF PASSWORDS FAILED ${ENDCOLOR}"
                echo -e "${RED}${DBNAME} BACKUP OF PASSWORDS FAILED ${ENDCOLOR}" >> $HOST_MAIN_DIR/MAIN_STATUS_${OPTION}.log
            else
                echo -e "${GREEN}${DBNAME} BACKUP OF PASSWORDS SUCCEEDED ${ENDCOLOR}"
                echo -e "${GREEN}${DBNAME} BACKUP OF PASSWORDS SUCCEEDED ${ENDCOLOR}" >> $HOST_MAIN_DIR/MAIN_STATUS_${OPTION}.log
            fi 

        else

            sqlplus -s / as sysdba <<EOF > /dev/null
            set head off
            set pages 2000
            set feedback off
            spool ${DBLOGDIR}/${DBNAME}_PDB_LIST.log
            select name from v\$pdbs where name not like '%SEED';
            spool off
            exit
EOF

            sed -i '/^$/d' ${DBLOGDIR}/${DBNAME}_PDB_LIST.log

            for pdb in `cat ${DBLOGDIR}/${DBNAME}_PDB_LIST.log`
            do
                sqlplus -s / as sysdba <<EOF > /dev/null
                alter session set container = ${pdb};
                SET PAGESIZE 0   ;
                SET FEEDBACK OFF ;
                spool ${DBLOGDIR}/${pdb}_backup_of_old_passwords.log
                select '-- Date: ' || to_char(sysdate, 'MM-DD-RRRR HH24:MI:SS') from dual;
                prompt -- Passwords for Oracle instance: ${pdb}
                prompt
                set trimspool on
                set linesize 1024
                set heading off
                set feedback off
                set pagesize 0
                select
                    case when b.account_status like '%LOCKED%'
                        then '-- Account locked on: ' || to_char(b.lock_date, 'MM/DD/YYYY HH:MI:SS')
                        else '-- Password expires on: ' || to_char(b.expiry_date,'MM/DD/YYYY HH:MI:SS')
                    end  || chr(10) ||
                    'alter user ' || a.name || ' profile default ; ' || chr(10) ||
                    'alter user ' || a.name || ' account unlock ; ' || chr(10) ||
                    case when a.spare4 is null
                        then 'alter user ' || a.name || ' identified by values ' ||chr(39)|| a.password ||chr(39)|| ' ; '
                        else 'alter user ' || a.name || ' identified by values ' ||chr(39)|| a.spare4 ||';'|| a.password ||chr(39)||' ; '
                    end || chr(10) ||
                    'alter user ' || a.name || ' profile ' || b.profile || ' ;'
                    FROM SYS.user$ a, dba_users b
                where a.name = b.username
                    and a.password <> 'EXTERNAL'
                order by a.name;
                spool off
                exit
EOF
                if ! grep -q "user SYSTEM" ${DBLOGDIR}/${pdb}_backup_of_old_passwords.log
                then
                    echo -e "${RED}${DBNAME} ${pdb} PDB BACKUP OF PASSWORDS FAILED ${ENDCOLOR}"
                    echo -e "${RED}${DBNAME} ${pdb} PDB BACKUP OF PASSWORDS FAILED ${ENDCOLOR}" >> $HOST_MAIN_DIR/MAIN_STATUS_${OPTION}.log
                else
                    echo -e "${GREEN}${DBNAME} ${pdb} PDB BACKUP OF PASSWORDS SUCCEEDED ${ENDCOLOR}"
                    echo -e "${GREEN}${DBNAME} ${pdb} PDB BACKUP OF PASSWORDS SUCCEEDED ${ENDCOLOR}" >> $HOST_MAIN_DIR/MAIN_STATUS_${OPTION}.log
                fi 

            done

        fi


    done

}






function CHANGE_PASSWORDS () {

    srvctl config database -home|awk '{print $1 " " $2}'|while read DBNAME ORACLE_HOME
    do
        export ORACLE_HOME=${ORACLE_HOME}
        FIRST_INST_HOST_NAME=`${ORACLE_HOME}/bin/srvctl config database -d ${DBNAME} | grep 'Database instance'|awk '{print $3}'`
        export ORACLE_SID=${FIRST_INST_HOST_NAME}
        HOST_MAIN_DIR=${LOGDIR}/${HOST_NAME}
        DBLOGDIR=${LOGDIR}/${HOST_NAME}/${DBNAME}
        mkdir -p $DBLOGDIR
        rm -f $DBLOGDIR/*
        ROLE_OF_DB=`${ORACLE_HOME}/bin/srvctl config database -d ${DBNAME} |grep role| awk '{print $3}'`
        if [[ $ROLE_OF_DB == 'PRIMARY' ]]
        then
            DB_INST_CLOSED=`$ORACLE_HOME/bin/srvctl status database -d ${DBNAME} -v | grep 'not running\|Closed\|Dismounted'| wc -l`
            if [ $DB_INST_CLOSED -gt 0 ]
            then
                echo -e "${RED}${DBNAME} HAS ONE OR ALL INSTANCES ARE IN STOPPED,NOMOUNT,MOUNT STATUS. PLEASE START ALL INSTANCES. SKIPPING, FAILED${ENDCOLOR}" 
                echo -e "${RED}${DBNAME} HAS ONE OR ALL INSTANCES ARE IN STOPPED,NOMOUNT,MOUNT STATUS. PLEASE START ALL INSTANCES. SKIPPING, FAILED${ENDCOLOR}" > $HOST_MAIN_DIR/MAIN_STATUS_${OPTION}.log
                continue
            fi
        elif [[ $ROLE_OF_DB == 'PHYSICAL_STANDBY' ]]
        then
            echo -e "${RED}${DBNAME} IS A PHYSICAL STANDBY SKIPPING${ENDCOLOR}" 
            echo -e "${RED}${DBNAME} IS A PHYSICAL STANDBY SKIPPING${ENDCOLOR}" >> $HOST_MAIN_DIR/MAIN_STATUS_${OPTION}.log
            continue
        elif [[ $ROLE_OF_DB == 'FAR_SYNC' ]]
        then
            echo -e "${RED}${DBNAME} IS A FAR_SYNC STANDBY SKIPPING${ENDCOLOR}" 
            echo -e "${RED}${DBNAME} IS A FAR_SYNC STANDBY SKIPPING${ENDCOLOR}" >> $HOST_MAIN_DIR/MAIN_STATUS_${OPTION}.log
            continue
            
        fi

        HOST_NAME=`hostname`

        export ORACLE_HOME=${ORACLE_HOME}
        FIRST_INST_HOST_NAME=`${ORACLE_HOME}/bin/srvctl config database -d ${DBNAME} | grep 'Database instance'|awk '{print $3}'`
        export ORACLE_SID=${FIRST_INST_HOST_NAME}
        DBLOGDIR=${LOGDIR}/${HOST_NAME}/${DBNAME}
        mkdir -p $DBLOGDIR
        rm -f $DBLOGDIR/*

        sqlplus -s / as sysdba <<EOF > /dev/null
        set head off
        set pages 2000
        set feedback off


        spool ${DBLOGDIR}/${DBNAME}_CHECK_IF_PDB.log
        select 'PDB_COUNT='||count(*) from v\$pdbs;
        spool off
        exit
EOF
        sed -i '/^$/d' ${DBLOGDIR}/${DBNAME}_CHECK_IF_PDB.log

        if grep -q "PDB_COUNT=0" ${DBLOGDIR}/${DBNAME}_CHECK_IF_PDB.log
        then
            cat $PWD_FILE|grep -iw "$HOST_NAME"|while read HOSTNAME DB_NAME USER_NAME ENV_NAME PASSWORD 
            do 

                ##CHECK IF USER EXISTS IN THIS DB
                DOES_USER_EXIST_IN_DB=$($ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF
                set heading off feedback off pagesize 0 trimspool on
                select count(username) from dba_users where username = '${USER_NAME}';
                exit
EOF
)

                if [[ ${DOES_USER_EXIST_IN_DB} -eq 1 ]]
                then
                    $ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF > /dev/null
                    spool $DBLOGDIR/${USER_NAME}_PASSWORD_CHANGE.log
                    alter user ${USER_NAME} account unlock identified by ${PASSWORD};
                    spool off
                    exit;     
EOF
                    $ORACLE_HOME/bin/sqlplus -s ${USER_NAME}/${PASSWORD} <<EOF > /dev/null
                    spool $DBLOGDIR/${USER_NAME}_AFTER_PASSWORD_CHANGE_LOGIN_VERIFICATION.log
                    show user;
                    spool off
                    exit
EOF

                    ANY_ERRORS_DURING_PASSWORD_CHANGE=`cat $DBLOGDIR/${USER_NAME}_PASSWORD_CHANGE.log 2>/dev/null | grep 'ORA-' | wc -l`
                    VERIFY_AFTER_PASSWORD_CHANGE=`cat $DBLOGDIR/${USER_NAME}_AFTER_PASSWORD_CHANGE_LOGIN_VERIFICATION.log 2>/dev/null | grep "${USER_NAME}" | wc -l`

                    if [[ ${ANY_ERRORS_DURING_PASSWORD_CHANGE} -eq 0 ]] && [[ ${VERIFY_AFTER_PASSWORD_CHANGE} -eq 1 ]]
                    then
                        echo -e "${GREEN}${DBNAME} : ${USER_NAME} PASSWORD CHANGE SUCCEEDED${ENDCOLOR}"
                        echo -e "${GREEN}${DBNAME} : ${USER_NAME} PASSWORD CHANGE SUCCEEDED${ENDCOLOR}" >> $HOST_MAIN_DIR/MAIN_STATUS_${OPTION}.log
                    else
                        echo -e "${RED}${DBNAME} : ${USER_NAME} PASSWORD CHANGE FAILED${ENDCOLOR}"
                        echo -e "${RED}${DBNAME} : ${USER_NAME} PASSWORD CHANGE FAILED${ENDCOLOR}" >> $HOST_MAIN_DIR/MAIN_STATUS_${OPTION}.log
                    fi
                else
                    continue
                fi
            done
        
        else
            sqlplus -s / as sysdba <<EOF > /dev/null
            set head off
            set pages 2000
            set feedback off
            spool ${DBLOGDIR}/${DBNAME}_PDB_LIST.log
            select name from v\$pdbs where name not like '%SEED';
            spool off
            exit
EOF

            sed -i '/^$/d' ${DBLOGDIR}/${DBNAME}_PDB_LIST.log

            for pdb in `cat ${DBLOGDIR}/${DBNAME}_PDB_LIST.log`
            do
                cat $PWD_FILE|grep -iw "$HOST_NAME"|while read HOSTNAME DB_NAME USER_NAME ENV_NAME PASSWORD 
                do 
                    ##CHECK IF USER EXISTS IN THIS DB
                    DOES_USER_EXIST_IN_DB=$($ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF
                    set heading off feedback off pagesize 0 trimspool on
                    alter session set container = ${pdb};
                    select count(username) from dba_users where username = '${USER_NAME}';
                    exit
EOF
)

                    if [[ ${DOES_USER_EXIST_IN_DB} -eq 1 ]]
                    then
                        $ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF > /dev/null
                        spool $DBLOGDIR/${pdb}_${USER_NAME}_PASSWORD_CHANGE.log
                        alter session set container = ${pdb};
                        alter user ${USER_NAME} account unlock identified by ${PASSWORD};
                        spool off
                        exit;     
EOF
                        $ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOF > /dev/null
                        spool $DBLOGDIR/${pdb}_${USER_NAME}_AFTER_PASSWORD_CHANGE_LOGIN_VERIFICATION.log
                        alter session set container = ${pdb};
                        connect ${USER_NAME}/${PASSWORD}@${pdb}
                        show user;
                        spool off
                        exit
EOF

                        ANY_ERRORS_DURING_PASSWORD_CHANGE=`cat $DBLOGDIR/${pdb}_${USER_NAME}_PASSWORD_CHANGE.log 2>/dev/null | grep 'ORA-' | wc -l`
                        VERIFY_AFTER_PASSWORD_CHANGE=`cat $DBLOGDIR/${pdb}_${USER_NAME}_AFTER_PASSWORD_CHANGE_LOGIN_VERIFICATION.log 2>/dev/null | grep "${USER_NAME}" | wc -l`

                        if [[ ${ANY_ERRORS_DURING_PASSWORD_CHANGE} -eq 0 ]] && [[ ${VERIFY_AFTER_PASSWORD_CHANGE} -eq 1 ]]
                        then
                            echo -e "${GREEN}${DBNAME} PDB ${pdb} : ${USER_NAME} PASSWORD CHANGE SUCCEEDED${ENDCOLOR}"
                            echo -e "${GREEN}${DBNAME} PDB ${pdb} : ${USER_NAME} PASSWORD CHANGE SUCCEEDED${ENDCOLOR}" >> $HOST_MAIN_DIR/MAIN_STATUS_${OPTION}.log
                        else
                            echo -e "${RED}${DBNAME} PDB ${pdb} : ${USER_NAME} PASSWORD CHANGE FAILED${ENDCOLOR}"
                            echo -e "${RED}${DBNAME} PDB ${pdb} : ${USER_NAME} PASSWORD CHANGE FAILED${ENDCOLOR}" >> $HOST_MAIN_DIR/MAIN_STATUS_${OPTION}.log
                        fi
                    else
                        continue
                    fi
                done
            done
        fi




    done



}


if [[ -z $OPTION ]]
then
    echo -e "${RED}NO OPTION SPECIFIED${ENDCOLOR}"
    echo -e "${RED}USAGE IS ./password_changes.sh BACKUP_PASSWORDS OR USAGE IS ./password_changes.sh CHANGE_PASSWORDS${ENDCOLOR}"
    exit 1
fi


if [[ $OPTION == 'BACKUP_PASSWORDS' ]]
then
    BACKUP_PASSWORDS
fi

if [[ $OPTION == 'CHANGE_PASSWORDS' ]]
then
    CHANGE_PASSWORDS
fi

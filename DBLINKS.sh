#DBLINKS
LOGDIR=/oracle_software/ftp_inbound/MiAppDBA/pwdchanges/db_links/logs/db_links
PWD_FILE=/oracle_software/ftp_inbound/MiAppDBA/pwdchanges/db_links/master_password.txt
GREEN="\033[1;32;40m"
RED="\033[1;31;40m"
NORM="\033[0m"
ENDCOLOR="\e[0m"
HOST_NAME=`hostname`

srvctl config database -home|awk '{print $1 " " $2}'|while read DBNAME ORACLE_HOME
do
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
        sqlplus -s / as sysdba <<EOF > /dev/null
        set head off
        set pages 2000
        set feedback off

        spool ${DBLOGDIR}/${DBNAME}_MAIN_DBLINK_LIST.csv
        select distinct owner from dba_db_links where owner not in ('SYS','SYSTEM') and username is not null;
        spool off
EOF

        sed -i '/^$/d' ${DBLOGDIR}/${DBNAME}_MAIN_DBLINK_LIST.csv

        for OWNER in `cat ${DBLOGDIR}/${DBNAME}_MAIN_DBLINK_LIST.csv |awk -F ',' '{print $1}'`
        do
            if [ ${OWNER} == 'PUBLIC' ]
            then
                sqlplus -s / as sysdba <<EOF > /dev/null
                set head off
                set pages 2000
                set feedback off

                spool ${DBLOGDIR}/${DBNAME}_${OWNER}_DBLINK_TARGET_USERNAMES.csv
                select owner||' '||db_link||' '||username||' '||host from dba_db_links where owner = 'PUBLIC' and username is not null;
                spool off
EOF
                sed -i '/^$/d' ${DBLOGDIR}/${DBNAME}_${OWNER}_DBLINK_TARGET_USERNAMES.csv
                cat ${DBLOGDIR}/${DBNAME}_${OWNER}_DBLINK_TARGET_USERNAMES.csv | while read LINKOWNER DB_LINK TARGET_USERNAME TARGET_HOST
                do
                    PASSWORD_OF_TARGET_USERNAME=`grep -iw "${TARGET_USERNAME}" $PWD_FILE |head -n 1 |awk '{print $5}'`
                    if [[ $PASSWORD_OF_TARGET_USERNAME == "" ]]
                    then
                        echo -e "------------" >> ${DBLOGDIR}/DBLINK_FAILED_COMMANDS.log
                        echo -e "${RED}--SOURCE OWNER ${OWNER} DBLINK ${DB_LINK} HAVENT BEEN FIXED AS THE TARGET OWNER PASSWORD WAS NOT FOUND IN MASTER_PASSWORD FILE${ENDCOLOR}" >> ${DBLOGDIR}/DBLINK_FAILED_COMMANDS.log
                        echo -e "------------" >> ${DBLOGDIR}/DBLINK_FAILED_COMMANDS.log
                    else
                        echo -e "export ORACLE_HOME=${ORACLE_HOME}" >> ${DBLOGDIR}/${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS.sh
                        echo -e "export ORACLE_SID=${ORACLE_SID}" >> ${DBLOGDIR}/${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS.sh
                        echo -e "${ORACLE_HOME}/bin/sqlplus / as sysdba <<EOF > /dev/null" >> ${DBLOGDIR}/${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS.sh
                        echo -e "set echo on" >> ${DBLOGDIR}/${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS.sh
                        echo -e "set feedback on" >> ${DBLOGDIR}/${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS.sh
                        echo -e "spool ${DBLOGDIR}/${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS.log" >> ${DBLOGDIR}/${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS.sh
                        echo -e "------------" >> ${DBLOGDIR}/${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS.sh
                        echo -e "drop public database link ${DB_LINK};" >> ${DBLOGDIR}/${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS.sh
                        echo -e "create public database link ${DB_LINK} connect to ${TARGET_USERNAME} identified by ${PASSWORD_OF_TARGET_USERNAME} using '${TARGET_HOST}';" >> ${DBLOGDIR}/${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS.sh
                        echo -e "------------" >> ${DBLOGDIR}/${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS.sh
                        echo -e "spool off" >> ${DBLOGDIR}/${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS.sh
                        echo -e "EOF" >> ${DBLOGDIR}/${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS.sh
                        echo -e "if grep -q 'ORA-' ${DBLOGDIR}/${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS.log" >> ${DBLOGDIR}/${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS.sh
                        echo -e "then" >> ${DBLOGDIR}/${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS.sh
                        echo -e "   mv ${DBLOGDIR}/${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS.log ${DBLOGDIR}/${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS_FAILED.log " >> ${DBLOGDIR}/${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS.sh
                        echo -e "else" >> ${DBLOGDIR}/${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS.sh
                        echo -e "   mv ${DBLOGDIR}/${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS.log ${DBLOGDIR}/${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS_SUCCESS.log" >> ${DBLOGDIR}/${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS.sh
                        echo -e "fi" >> ${DBLOGDIR}/${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS.sh


                    fi
                done


            else
                unset PASSWORD_OF_OWNER
                PASSWORD_OF_OWNER=`grep -iw "${OWNER}" ${PWD_FILE} | head -n 1 |awk '{print $5}'`
                if [[ $PASSWORD_OF_OWNER == "" ]]
                then
                    echo -e "${RED}--SOURCE OWNER ${OWNER} DBLINKS HAVENT BEEN FIXED AS THE SOURCE OWNER PASSWORD WAS NOT FOUND IN MASTER_PASSWORD FILE${ENDCOLOR}" >> ${DBLOGDIR}/DBLINK_FAILED_COMMANDS.log
                else
                    sqlplus -s ${OWNER}/${PASSWORD_OF_OWNER} <<EOF > /dev/null
                    set head off
                    set pages 2000
                    set feedback off
                    spool ${DBLOGDIR}/${DBNAME}_${OWNER}_PRIVATE_DBLINK_TARGET_USERNAMES.csv
                    select db_link||' '||username||' '||host from user_db_links where username is not null;
                    spool off;


EOF
                    sed -i '/^$/d' ${DBLOGDIR}/${DBNAME}_${OWNER}_PRIVATE_DBLINK_TARGET_USERNAMES.csv
                    cat ${DBLOGDIR}/${DBNAME}_${OWNER}_PRIVATE_DBLINK_TARGET_USERNAMES.csv | while read DB_LINK TARGET_USERNAME TARGET_HOST
                    do
                        PASSWORD_OF_TARGET_USERNAME=`grep -iw "${TARGET_USERNAME}" $PWD_FILE |head -n 1 |awk '{print $5}'`
                        if [[ $PASSWORD_OF_TARGET_USERNAME == "" ]]
                        then
                            echo -e "------------" >> ${DBLOGDIR}/DBLINK_FAILED_COMMANDS.log
                            echo -e "${RED}--SOURCE OWNER ${OWNER} DBLINK ${DB_LINK} HAVENT BEEN FIXED AS THE TARGET OWNER PASSWORD WAS NOT FOUND IN MASTER_PASSWORD FILE${ENDCOLOR}" >> ${DBLOGDIR}/DBLINK_FAILED_COMMANDS.log
                            echo -e "------------" >> ${DBLOGDIR}/DBLINK_FAILED_COMMANDS.log
                        else
                            echo -e "export ORACLE_HOME=${ORACLE_HOME}" >> ${DBLOGDIR}/${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS.sh
                            echo -e "export ORACLE_SID=${ORACLE_SID}" >> ${DBLOGDIR}/${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS.sh
                            echo -e "${ORACLE_HOME}/bin/sqlplus ${OWNER}/${PASSWORD_OF_OWNER} <<EOF > /dev/null" >> ${DBLOGDIR}/${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS.sh
                            echo -e "set echo on" >> ${DBLOGDIR}/${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS.sh
                            echo -e "set feedback on" >> ${DBLOGDIR}/${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS.sh
                            echo -e "spool ${DBLOGDIR}/${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS.log" >> ${DBLOGDIR}/${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS.sh
                            echo -e "------------" >> ${DBLOGDIR}/${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS.sh
                            echo -e "drop database link ${DB_LINK};" >> ${DBLOGDIR}/${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS.sh
                            echo -e "create database link ${DB_LINK} connect to ${TARGET_USERNAME} identified by ${PASSWORD_OF_TARGET_USERNAME} using '${TARGET_HOST}';" >> ${DBLOGDIR}/${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS.sh
                            echo -e "------------" >> ${DBLOGDIR}/${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS.sh
                            echo -e "spool off" >> ${DBLOGDIR}/${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS.sh
                            echo -e "EOF" >> ${DBLOGDIR}/${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS.sh
                            echo -e "if grep -q 'ORA-' ${DBLOGDIR}/${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS.log" >> ${DBLOGDIR}/${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS.sh
                            echo -e "then" >> ${DBLOGDIR}/${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS.sh
                            echo -e "   mv ${DBLOGDIR}/${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS.log ${DBLOGDIR}/${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS_FAILED.log " >> ${DBLOGDIR}/${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS.sh
                            echo -e "else" >> ${DBLOGDIR}/${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS.sh
                            echo -e "   mv ${DBLOGDIR}/${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS.log ${DBLOGDIR}/${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS_SUCCESS.log" >> ${DBLOGDIR}/${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS.sh
                            echo -e "fi" >> ${DBLOGDIR}/${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS.sh
                        fi
                    done

                fi


            fi

        done

    else

#    if ! grep -q "PDB_COUNT=0" ${DBLOGDIR}/${DBNAME}_CHECK_IF_PDB.log
#    then

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
            set head off
            set pages 2000
            set feedback off

            spool ${DBLOGDIR}/${DBNAME}_${pdb}_MAIN_DBLINK_LIST.csv
            select distinct owner from dba_db_links where owner not in ('SYS','SYSTEM') and username is not null;
            spool off
EOF
            sed -i '/^$/d' ${DBLOGDIR}/${DBNAME}_${pdb}_MAIN_DBLINK_LIST.csv

            for OWNER in `cat ${DBLOGDIR}/${DBNAME}_${pdb}_MAIN_DBLINK_LIST.csv |awk -F ',' '{print $1}'`
            do
                if [ ${OWNER} == 'PUBLIC' ]
                then
                    sqlplus -s / as sysdba <<EOF > /dev/null
                    alter session set container = ${pdb};
                    set head off
                    set pages 2000
                    set feedback off

                    spool ${DBLOGDIR}/${DBNAME}_${pdb}_${OWNER}_DBLINK_TARGET_USERNAMES.csv
                    select owner||' '||db_link||' '||username||' '||host from dba_db_links where owner = 'PUBLIC' and username is not null;
                    spool off
EOF


                    sed -i '/^$/d' ${DBLOGDIR}/${DBNAME}_${pdb}_${OWNER}_DBLINK_TARGET_USERNAMES.csv
                    cat ${DBLOGDIR}/${DBNAME}_${pdb}_${OWNER}_DBLINK_TARGET_USERNAMES.csv | while read LINKOWNER DB_LINK TARGET_USERNAME TARGET_HOST
                    do
                        PASSWORD_OF_TARGET_USERNAME=`grep -iw "${TARGET_USERNAME}" $PWD_FILE |head -n 1 |awk '{print $5}'`
                        if [[ $PASSWORD_OF_TARGET_USERNAME == "" ]]
                        then
                            echo -e "------------" >> ${DBLOGDIR}/DBLINK_${pdb}_FAILED_COMMANDS.log
                            echo -e "${RED}--SOURCE OWNER ${OWNER} DBLINK ${DB_LINK} HAVENT BEEN FIXED AS THE TARGET OWNER PASSWORD WAS NOT FOUND IN MASTER_PASSWORD FILE${ENDCOLOR}" >> ${DBLOGDIR}/DBLINK_${pdb}_FAILED_COMMANDS.log
                            echo -e "------------" >> ${DBLOGDIR}/DBLINK_${pdb}_FAILED_COMMANDS.log
                        else
                            echo -e "export ORACLE_HOME=${ORACLE_HOME}" >> ${DBLOGDIR}/${pdb}_${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS.sh
                            echo -e "export ORACLE_SID=${ORACLE_SID}" >> ${DBLOGDIR}/${pdb}_${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS.sh
                            echo -e "${ORACLE_HOME}/bin/sqlplus / as sysdba <<EOF > /dev/null" >> ${DBLOGDIR}/${pdb}_${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS.sh
                            echo -e "alter session set container = ${pdb};" >> ${DBLOGDIR}/${pdb}_${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS.sh
                            echo -e "set echo on" >> ${DBLOGDIR}/${pdb}_${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS.sh
                            echo -e "set feedback on" >> ${DBLOGDIR}/${pdb}_${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS.sh
                            echo -e "spool ${DBLOGDIR}/${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS.log" >> ${DBLOGDIR}/${pdb}_${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS.sh
                            echo -e "------------" >> ${DBLOGDIR}/${pdb}_${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS.sh
                            echo -e "drop public database link ${DB_LINK};" >> ${DBLOGDIR}/${pdb}_${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS.sh
                            echo -e "create public database link ${DB_LINK} connect to ${TARGET_USERNAME} identified by ${PASSWORD_OF_TARGET_USERNAME} using '${TARGET_HOST}';" >> ${DBLOGDIR}/${pdb}_${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS.sh
                            echo -e "------------" >> ${DBLOGDIR}/${pdb}_${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS.sh
                            echo -e "spool off" >> ${DBLOGDIR}/${pdb}_${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS.sh
                            echo -e "EOF" >> ${DBLOGDIR}/${pdb}_${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS.sh
                            echo -e "if grep -q 'ORA-' ${DBLOGDIR}/${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS.log" >> ${DBLOGDIR}/${pdb}_${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS.sh
                            echo -e "then" >> ${DBLOGDIR}/${pdb}_${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS.sh
                            echo -e "   mv ${DBLOGDIR}/${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS.log ${DBLOGDIR}/${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS_FAILED.log " >> ${DBLOGDIR}/${pdb}_${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS.sh
                            echo -e "else" >> ${DBLOGDIR}/${pdb}_${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS.sh
                            echo -e "   mv ${DBLOGDIR}/${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS.log ${DBLOGDIR}/${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS_SUCCESS.log" >> ${DBLOGDIR}/${pdb}_${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS.sh
                            echo -e "fi" >> ${DBLOGDIR}/${pdb}_${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS.sh


                        fi
                    done


                else
                    unset PASSWORD_OF_OWNER
                    PASSWORD_OF_OWNER=`grep -iw "${OWNER}" ${PWD_FILE} | head -n 1 |awk '{print $5}'`
                    if [[ $PASSWORD_OF_OWNER == "" ]]
                    then
                        echo -e "${RED}--SOURCE OWNER ${OWNER} DBLINKS HAVENT BEEN FIXED AS THE SOURCE OWNER PASSWORD WAS NOT FOUND IN MASTER_PASSWORD FILE${ENDCOLOR}" >> ${DBLOGDIR}/DBLINK_${pdb}_FAILED_COMMANDS.log
                    else
                        sqlplus -s ${OWNER}/${PASSWORD_OF_OWNER} <<EOF > /dev/null
                        alter session set container = ${pdb};
                        set head off
                        set pages 2000
                        set feedback off
                        spool ${DBLOGDIR}/${DBNAME}_${pdb}_${OWNER}_PRIVATE_DBLINK_TARGET_USERNAMES.csv
                        select db_link||' '||username||' '||host from user_db_links where username is not null;
                        spool off;


EOF
                        sed -i '/^$/d' ${DBLOGDIR}/${DBNAME}_${pdb}_${OWNER}_PRIVATE_DBLINK_TARGET_USERNAMES.csv
                        cat ${DBLOGDIR}/${DBNAME}_${pdb}_${OWNER}_PRIVATE_DBLINK_TARGET_USERNAMES.csv | while read DB_LINK TARGET_USERNAME TARGET_HOST
                        do
                            PASSWORD_OF_TARGET_USERNAME=`grep -iw "${TARGET_USERNAME}" $PWD_FILE |head -n 1 |awk '{print $5}'`
                            if [[ $PASSWORD_OF_TARGET_USERNAME == "" ]]
                            then
                                echo -e "------------" >> ${DBLOGDIR}/DBLINK_${pdb}_FAILED_COMMANDS.log
                                echo -e "${RED}--SOURCE OWNER ${OWNER} DBLINK ${DB_LINK} HAVENT BEEN FIXED AS THE TARGET OWNER PASSWORD WAS NOT FOUND IN MASTER_PASSWORD FILE${ENDCOLOR}" >> ${DBLOGDIR}/DBLINK_${pdb}_FAILED_COMMANDS.log
                                echo -e "------------" >> ${DBLOGDIR}/DBLINK_${pdb}_FAILED_COMMANDS.log
                            else
                                echo -e "export ORACLE_HOME=${ORACLE_HOME}" >> ${DBLOGDIR}/${pdb}_${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS.sh
                                echo -e "export ORACLE_SID=${ORACLE_SID}" >> ${DBLOGDIR}/${pdb}_${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS.sh
                                echo -e "${ORACLE_HOME}/bin/sqlplus ${OWNER}/${PASSWORD_OF_OWNER} <<EOF > /dev/null" >> ${DBLOGDIR}/${pdb}_${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS.sh
                                echo -e "alter session set container = ${pdb};" >> ${DBLOGDIR}/${pdb}_${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS.sh
                                echo -e "set echo on" >> ${DBLOGDIR}/${pdb}_${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS.sh
                                echo -e "set feedback on" >> ${DBLOGDIR}/${pdb}_${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS.sh
                                echo -e "spool ${DBLOGDIR}/${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS.log" >> ${DBLOGDIR}/${pdb}_${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS.sh
                                echo -e "------------" >> ${DBLOGDIR}/${pdb}_${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS.sh
                                echo -e "drop database link ${DB_LINK};" >> ${DBLOGDIR}/${pdb}_${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS.sh
                                echo -e "create database link ${DB_LINK} connect to ${TARGET_USERNAME} identified by ${PASSWORD_OF_TARGET_USERNAME} using '${TARGET_HOST}';" >> ${DBLOGDIR}/${pdb}_${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS.sh
                                echo -e "------------" >> ${DBLOGDIR}/${pdb}_${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS.sh
                                echo -e "spool off" >> ${DBLOGDIR}/${pdb}_${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS.sh
                                echo -e "EOF" >> ${DBLOGDIR}/${pdb}_${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS.sh
                                echo -e "if grep -q 'ORA-' ${DBLOGDIR}/${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS.log" >> ${DBLOGDIR}/${pdb}_${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS.sh
                                echo -e "then" >> ${DBLOGDIR}/${pdb}_${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS.sh
                                echo -e "   mv ${DBLOGDIR}/${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS.log ${DBLOGDIR}/${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS_FAILED.log " >> ${DBLOGDIR}/${pdb}_${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS.sh
                                echo -e "else" >> ${DBLOGDIR}/${pdb}_${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS.sh
                                echo -e "   mv ${DBLOGDIR}/${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS.log ${DBLOGDIR}/${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS_SUCCESS.log" >> ${DBLOGDIR}/${pdb}_${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS.sh
                                echo -e "fi" >> ${DBLOGDIR}/${pdb}_${OWNER}_to_${TARGET_USERNAME}_FIX_COMMANDS.sh
                            fi
                        done
                    fi
                fi
            done
        done

    fi
done

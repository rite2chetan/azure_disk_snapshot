#!/bin/bash
#### Copyright (c) SAP.
#### Licensed under the MIT license.
#### Pre/Post script for Azure Backup service. This only support snapshots.
#### Version 0.1 - 17.02.2021

function Set_Environment() {
    log_dir='/var/log/azure/Azure.DB2.AppSnap.Backup'
    timestamp='date +%F_%H.%M.%S'
    mints=$(date +%F_%H.%M) #This one needs to be fixed for reference to SQL statements, logs.
    sidadm='db2'${SID,,}
    success=0
    error=1
    warning=2
    status=${success}
}

function Set_Logging() {
    if [ ! -d ${log_dir} ]; then
        if ! mkdir ${log_dir} -p -m 755
        then
            status=${error}
            exit $status #Cannot do any logging here. Just exit with error.- no directory to write - bigger issue, should not happen.
        fi
    fi
    log_file=${log_dir}/db2_snapshot.log
    bid_file=${log_dir}/bckid.bid
    errorlog_file=error_${mints}.log
    errorlog=${log_dir}/${errorlog_file}
    db2err_file=${log_dir}/tempdb2err.log
}

function Do_Log() { #Simple logging - can be exetened, DEBUG supported
    text=$1
    LTS=$($timestamp)
    case $status in
        0) LSTS="INFO:   " ;;
        2) LSTS="WARNING:" ;;
        1) LSTS="ERROR:  " ;;
    esac
    case $2 in
        "E")
            printf "$LTS $LSTS %s\n" "$text" >> "${errorlog}"
        ;;
        "S")
            printf "$LTS %s\n" "$text" >> "${log_file}"
        ;;
        *)
            printf "$LTS $LSTS %s\n" "$text" >> "${log_file}"
        ;;
        
    esac
}

function CheckInput() {
    if [ -z "${PrePost}" ] || [ -z "${SID}" ]; then
        status=${error}
        Do_Log "Script not called with all parameters."
        Do_Log "Parameters should be Pre/Post <SID>"
        ExitProcessing "X"
        elif [ "$(echo ${#SID})" != 3 ] || [[ "${SID}" =~ [a-z] ]]; then
        status=$error
        Do_Log "Value of DB2 SID is inccorect. Value provided was ${SID}"
        ExitProcessing "X"
    fi
}

function Start_Logging() {
    Do_Log "******* Azure Backup ${PrePost} DB2 VM for ${SID} snapshot process started. *******" "S"
}

function Stop_Logging() {
    Do_Log "******* Azure Backup ${PrePost} DB2 VM for ${SID} snapshot process stopped *******" "S"
}

function Set_Executables() {
    DB2SQL="/db2/${sidadm}/sqllib/bin/db2"
    DB2EXE="/db2/${sidadm}/sqllib/bin/db2"
    DB2PDEXE="/db2/${sidadm}/sqllib/adm/db2pd"
    if [ ! -e "$DB2EXE" ]; then
        status=${error}
        Do_Log "Setting executables variables failed."
        Do_Log "Setting executables variables failed." "E"
        Do_Log "DB2SQL: ${DB2EXE}" "E"
        Do_Log "DB2EXE: ${DB2EXE}" "E"
        Do_Log "DB2PDEXE: ${DB2PDEXE}" "E"
    fi
}

function Set_Db2_SQLs() {
    # db2 commands
    SQL_CONNECT="connect to ${SID}"
    SQL_SNAPON="set write suspend for DB"
    SQL_SNAPOFF="set write resume for DB"
    # db2pd commands
    DB_SETTINGS="-db ${SID} -dbcfg"
    SUSPENDED_SETTING="Database is in write suspend state"
    HADR_SETTINGS="-db ${SID} -hadr"
    ROLE_SETTING="HADR_ROLE"
}

function Check_Hadr_Primary() {
    Do_Log "Check if pacemaker service is installed"
    systemctl status "pacemaker" | grep -Fq "not-found"
    if [ $? -eq 0 ]; then
        Do_Log "Pacemaker not found, HADR_ROLE will not be checked"
        return 0
    fi
    
    HADR_INFO=$(su - ${sidadm} -c "${DB2PDEXE} ${HADR_SETTINGS}" 2> ${db2err_file})
    Do_Log "Check if pacemaker service is active"
    echo "${HADR_INFO}" | grep -Fq "HADR is not active"
    if [ $? -eq 0 ]; then
        Do_Log "Pacemaker not active, HADR_ROLE will not be checked"
        return 0
    fi

    #HADR_ROLE=$(su - ${sidadm} -c "${DB2PDEXE} ${HADR_SETTINGS}" | grep "${ROLE_SETTING}" 2> ${db2err_file})
    #echo "${HADR_ROLE}" | grep -Fq "${ROLE_SETTING}"
    HADR_ROLE=$(echo "${HADR_INFO}" | grep -F "${ROLE_SETTING}")
    if [ $? -eq 0 ]; then
        Do_Log "${HADR_ROLE}"
        echo "${HADR_ROLE}" | grep "PRIMARY" &> /dev/null
        if [ $? -ne 0 ]; then
            # Not a primary Node.
            status=${error}
            echo "Host is not a Db2 Primary node"
            Do_Log "Host is not a Db2 Primary node" "E"
            ExitProcessing "X"
        fi
    else
        # error
        status=${error}
        Do_Log "Failed to check the HADR role."
        Do_Log "Failed to check the HADR role." "E"
        ExitProcessing "X"
    fi
}

function Check_Db2_Suspended_Status() {
    DB2STATE=$(su - ${sidadm} -c "${DB2PDEXE} ${DB_SETTINGS}" | grep "${SUSPENDED_SETTING}" 2> ${db2err_file})
    if [ $? -eq 0 ]; then
        Do_Log "${DB2STATE}"
        echo "${DB2STATE}" | grep 'YES' &> /dev/null
        if [ $? -eq 0 ]; then
            # Suspend ON
            SUSPENDED="1"
        else
            # Suspend OFF
            SUSPENDED="0"
        fi
    else
        # error
        status=${error}
        Do_Log "Failed to check the state of the database."
        Do_Log "Failed to check the state of the database." "E"
        ExitProcessing "X"
    fi
}

function Put_Db2_In_Snapshot_Mode() {
    su - ${sidadm} -c "${DB2SQL} '${SQL_CONNECT}'; ${DB2SQL} '${SQL_SNAPON}'" 2> ${db2err_file} 1> /dev/null
    if [ $? -eq 0 ]; then
        echo "DB2 in Suspended mode!"
        Do_Log "DB2 in Suspended mode!"
    else
        status=${error}
        Do_Log "Failed to set DB2 on SUSPEND mode."
        Do_Log "Failed to set DB2 on SUSPEND mode." "E"
    fi
}

function Put_Db2_Out_Snapshot_Mode() {
    su - ${sidadm} -c "${DB2SQL} '${SQL_CONNECT}'; ${DB2SQL} '${SQL_SNAPOFF}'" 2> ${db2err_file} 1> /dev/null
    if [ $? -eq 0 ]; then
        echo "DB2 out of Suspended mode!"
        Do_Log "DB2 out of Suspended mode!"
    else
        status=${error}
        Do_Log "Failed to set Db2 on RESUME mode."
        Do_Log "Failed to set Db2 on RESUME mode." "E"
    fi
}

function ExitProcessing() {
    case $1 in
        "")
            if [ $status == $error ]; then
                Do_Log "Execution failed additional errros in error log file ${errorlog_file}"
            elif [ $status == $warning ]; then
                Do_Log "Execution has warnings - check the this log file for warning messages"
            fi
            Stop_Logging
        ;;
        "X")
            true
        ;;
    esac
    exit $status
}

#Check if debug is enabled!
if [ "${3}" == "DEBUG" ]; then #Check if needed be enabled
    Set_Environment   #Just to get envirnemnt set. Will be called again and traced!
    trace_file=${log_dir}/trace$(${timestamp}).log
    exec 19>"${trace_file}"
    BASH_XTRACEFD=19
    set -x
fi

##################################################################
############      Script procesing - orcestration     ############
##################################################################

#Map script arguments to correct variables that are used in script
PrePost=$1
SID=$2

# Call Sript functions to get things working.
# Common Part
Set_Environment
Set_Logging
CheckInput
Start_Logging
Set_Executables
Set_Db2_SQLs
# Check if host has a Primary or Standby role
Check_Hadr_Primary
Check_Db2_Suspended_Status

case $PrePost in
    "Pre")
        if [ "${SUSPENDED}" = "0" ]; then
            Put_Db2_In_Snapshot_Mode
            status=${success}
        else
            status=${error}
            echo 'Database is already on suspended mode, another backup might be running already!'
            Do_Log "Database is already on suspended mode, another backup might be running already!"
            ExitProcessing
        fi
    ;;
    "Post")
        if [ "${SUSPENDED}" == "1" ]; then
            Put_Db2_Out_Snapshot_Mode
            status=${success}
        else
            # Do nothing since db is not suspended
            status=${success}
            echo "Database is not suspended."
            Do_Log "Database is not suspended."
            ExitProcessing
        fi
    ;;
esac

ExitProcessing

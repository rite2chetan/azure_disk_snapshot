#!/bin/bash
#### Copyright (c) SAP.
#### Licensed under the MIT license.
#### Create disks in a different availability zone.
#### Version 0.1 - 17.02.2021

#### Samples
# ./AzureCloneDisk "ResGroup" "SourceVM" "DestVM" [Lun# Lun# Lun#]
# ./AzureCloneDisk "ResGroup" "" "DestVM" [DiskName DiskName DiskName]

function Set_Environment() {
    log_dir='/var/log/azure/Azure.Clone.Disks'
    timestamp='date +%F_%H.%M.%S'
    mints=$(date +%F) #This one needs to be fixed for reference to SQL statements, logs.
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
    log_file=${log_dir}/clone_disks_${mints}.log
    errorlog_file=error_${mints}.log
    errorlog=${log_dir}/${errorlog_file}
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
    # Validate required arguments
    if [ -z "${ResGroup}" ] || [ -z "${DestVMName}" ]; then
        status=${error}
        Do_Log "Script not called with all parameters." "E"
        ExitProcessing "X"
    fi

    # If no source VM was provided, a List of disks is expected
    if [ -z "${SourceVMName}" ] && [ ${#DiskArgs[@]} -eq 0 ]; then
        status=${error}
        Do_Log "Script not called with all parameters." "E"
        Do_Log "If no source VM is provided, a list of disk names is required."
        ExitProcessing "X"
    fi

    az account show -o none
    if [ $? -ne 0 ]; then
        status=${error}
        Do_Log "You need to be logged into Azure to run this script." "E"
        ExitProcessing "X"
    fi

    # Fetch destination VM info from Azure
    DestVM=$(az vm show -g $ResGroup -n ${DestVMName})
    if [ $? -ne 0 ]; then
        status=${error}
        Do_Log "There was an error fetching the destination VM." "E"
        ExitProcessing "X"
    fi

    DiskList=()
    # Fetch Source VM Info from Azure if provided
    if [ -n "${SourceVMName}" ]; then
        OriginVM=$(az vm show -g $ResGroup -n ${SourceVMName})
        if [ $? -ne 0 ]; then
            status=${error}
            Do_Log "There was an error fetching the source VM." "E"
            ExitProcessing
        fi
        
        sourceDisks=$(echo "${OriginVM}" | jq -rc ".storageProfile.dataDisks[] | {name:.name, lun:.lun}")
        while read disk; do
            lun=$(echo "${disk}" | jq -r ".lun")
            if [[ ${#DiskArgs[@]} -ne 0 && ! " ${DiskArgs[@]} " =~ " ${lun} " ]]; then
                Do_Log "LUN ${lun} skipped"
                continue
            fi
            
            DiskList+=($(echo "${disk}" | jq -r ".name"))
        done <<< "$sourceDisks"
    else
        for diskName in ${DiskArgs[@]}; do
            az disk show -g "$ResGroup" -n "$diskName" -o none
            if [ $? -ne 0 ]; then
                status=${error}
                Do_Log "${diskName} not found" "E"
                continue
            fi
            DiskList+=(${diskName})
        done
    fi

    if [ $status == $error ]; then
        Do_Log "No disks to clone" "E"
        ExitProcessing
    fi

    if [ ${#DiskList[@]} == 0 ]; then 
        Do_Log "No disks to clone" "E"
        $status=${error}
        ExitProcessing
    fi
}

function CloneDisk() {
    local resGroup="$1"
    local diskPrefix="$2"
    local sourceDisk="$3"
    local destZone="$4"
    local status=0
    snapshotName="${diskPrefix}-snap"
    newDiskName="${diskPrefix}-restore"

    Do_Log "Creating snapshot ${snapshotName} from source ${sourceDisk}"
    az snapshot create -g "${resGroup}" -n "${snapshotName}" --source "${sourceDisk}" -o none
    if [ $? -ne 0 ]; then
        Do_Log "Unable to create snapshot ${snapshotName}" "E"
        exit 1
    fi

    Do_Log "Creating disk ${newDiskName} from snapshot ${snapshotName}"
    if [ -z "${destZone}" ]; then
        # Create disk in same zone
        az disk create -g ${resGroup} -n "${newDiskName}" --source ${snapshotName} -o none
    else
        # Create disk in different zone
        az disk create -g ${resGroup} -n "${newDiskName}" --source ${snapshotName} --zone ${destZone} -o none
    fi

    if [ $? -eq 0 ]; then
        echo "${newDiskName} created"
        Do_Log "${newDiskName} created"
    else
        Do_Log "There was an error while creating the file ${newDiskName}" "E"
        status=1
    fi

    Do_Log "Deleting snapshot ${snapshotName}"
    az snapshot delete -g ${resGroup} -n ${snapshotName} -o none
    if [ $? -eq 0 ]; then
        Do_Log "Deleted snapshot ${snapshotName} successfully"
    else
        Do_Log "There was an error while deleting the snapshot ${newDiskName}" "E"
        status=1
    fi
    
    exit ${status}
}

function PrepareClones() {
    # OriginVM=$(az vm show -g $ResGroup -n ${SourceVMName})
    # DestVM=$(az vm show -g $ResGroup -n ${DestVMName})
    DestVMZone=$(echo "${DestVM}" | jq -r '.zones[0]')
    local max_jobs=5
    local curr_jobs="\j"
    pids=()
    for diskName in ${DiskList[@]}; do
        while (( ${curr_jobs@P} >= ${max_jobs} )); do
           wait -n
        done

        diskPrefix="$(echo "${DestVMName}-$(echo "${diskName}" | sed 's/[A-Za-z0-9]*-//')")"
        CloneDisk "${ResGroup}" "${diskPrefix}" "${diskName}" $DestVMZone &
        pids+=("$!")
    done
    
    for pid in ${pids[*]}; do
        wait $pid
        if [ $? -ne 0 ]; then
            status=${error}
        fi 
    done
}

function TakeDetachedSnapshot() {
    diskDate=$(date +%Y%m%d-%H%M%S)

}

function Start_Logging() {
    Do_Log "******* Azure Clone Disk process started. *******" "S"
}

function Stop_Logging() {
    Do_Log "******* Azure Clone Disk process ended. *******" "S"
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
if [ "${4}" == "DEBUG" ]; then #Check if needed be enabled
    Set_Environment   #Just to get envirnemnt set. Will be called again and traced!
    trace_file=${log_dir}/trace$(${timestamp}).log
    exec 19>"${trace_file}"
    BASH_XTRACEFD=19
    set -x
    DiskArgs=("${@:5}")
else
    DiskArgs=("${@:4}")
fi

##################################################################
############      Script procesing - orcestration     ############
##################################################################

#Map script arguments to correct variables that are used in script
ResGroup=$1
SourceVMName=$2
DestVMName=$3

# Call Sript functions to get things working.
Set_Environment
Set_Logging
CheckInput
Start_Logging

PrepareClones

ExitProcessing

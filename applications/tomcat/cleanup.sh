#!/bin/bash -e

FILE_NAME=$0

SCRIPT_FOLDER="$(dirname $FILE_NAME)"
COMMON_SCRIPT_FILENAME="common.sh"

source $SCRIPT_FOLDER/$COMMON_SCRIPT_FILENAME

###########################################################################################################
# The function will read parameters and populate below global variables.
# IDENTITY_FILE, MASTER_IP, OUTPUT_SUMMARYFILE, USER_NAME
parse_commandline_arguments $@

log_level -i "------------------------------------------------------------------------"
log_level -i "                Input Parameters"
log_level -i "------------------------------------------------------------------------"
log_level -i "IDENTITY_FILE       : $IDENTITY_FILE"
log_level -i "MASTER_IP           : $MASTER_IP"
log_level -i "OUTPUT_SUMMARYFILE  : $OUTPUT_SUMMARYFILE"
log_level -i "USER_NAME           : $USER_NAME"
log_level -i "------------------------------------------------------------------------"

if
[[ -z "$IDENTITY_FILE" ]] || \
[[ -z "$MASTER_IP" ]] || \
[[ -z "$USER_NAME" ]] || \
[[ -z "$OUTPUT_SUMMARYFILE" ]]
then
    log_level -e "One of mandatory parameter is not passed correctly."
    print_usage
    exit 1
fi

OUTPUT_FOLDER="$(dirname $OUTPUT_SUMMARYFILE)"
LOG_FILENAME="$OUTPUT_FOLDER/cleanup.log"
touch $LOG_FILENAME
NAMESPACE="ns-tomcat"

{
    APPLICATION_NAME="tomcat"
    TEST_DIRECTORY="/home/$USER_NAME/$APPLICATION_NAME"
    log_level -i "------------------------------------------------------------------------"
    log_level -i "                Inner Variables"
    log_level -i "------------------------------------------------------------------------"
    log_level -i "APPLICATION_NAME           : $APPLICATION_NAME"
    log_level -i "TEST_DIRECTORY             : $TEST_DIRECTORY"
    log_level -i "------------------------------------------------------------------------"
    
    KNOWN_HOSTS_OPTIONS='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR'

    # Cleanup Tomcat app.
    tomcatReleaseName=$(ssh -i $IDENTITY_FILE ${KNOWN_HOSTS_OPTIONS} $USER_NAME@$MASTER_IP "helm ls -d -r --all-namespaces | grep 'deployed\(.*\)$APPLICATION_NAME' | grep -Eo '^[a-z,-]+\w+' || true")
    if [ -z "$tomcatReleaseName" ]; then
        log_level -w "No deployment found."
    else
        log_level -i "Removing helm deployment($tomcatReleaseName)"
        ssh -t -i ${KNOWN_HOSTS_OPTIONS}  $IDENTITY_FILE $USER_NAME@$MASTER_IP "helm delete $tomcatReleaseName"
        log_level -i "Wait for 30s for all pods to be deleted and removed."
        sleep 30s
    fi
    
    check_helm_app_release_cleanup $IDENTITY_FILE \
    $USER_NAME \
    $MASTER_IP \
    $APPLICATION_NAME
    
    if [[ $? != 0 ]]; then
        printf '{"result":"%s","error":"%s"}\n' "failed" "App($APPLICATION_NAME) cleanup was not successfull" >$OUTPUT_SUMMARYFILE
    else
        printf '{"result":"%s"}\n' "pass" >$OUTPUT_SUMMARYFILE
    fi
    
    log_level -i "Removing namespace"
    ssh -t -i ${KNOWN_HOSTS_OPTIONS}  $IDENTITY_FILE $USER_NAME@$MASTER_IP "kubectl delete namespace $NAMESPACE"
    
    ssh -t -i ${KNOWN_HOSTS_OPTIONS}  $IDENTITY_FILE $USER_NAME@$MASTER_IP "sudo rm -rf $TEST_DIRECTORY;"
    
    # Create result file, even if script ends with an error
    #trap final_changes EXIT
} 2>&1 | tee $LOG_FILENAME

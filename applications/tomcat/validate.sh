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

###########################################################################################################
# Define all inner varaibles.
OUTPUT_FOLDER="$(dirname $OUTPUT_SUMMARYFILE)"
LOG_FILENAME="$OUTPUT_FOLDER/validate.log"
touch $LOG_FILENAME
CONTEXT_NAME="tomcat-context"
NAMESPACE="ns-tomcat"

{
    APPLICATION_NAME="tomcat"
    log_level -i "------------------------------------------------------------------------"
    log_level -i "                Inner Variables"
    log_level -i "------------------------------------------------------------------------"
    log_level -i "APPLICATION_NAME           : $APPLICATION_NAME"
    log_level -i "------------------------------------------------------------------------"
    # Check application pod is up and running
    check_app_pod_status $IDENTITY_FILE \
    $USER_NAME \
    $MASTER_IP \
    "app=$APPLICATION_NAME" \
    "Running" \
    $NAMESPACE
    
    if [[ $? != 0 ]]; then
        printf '{"result":"%s","error":"%s"}\n' "failed" "Pod related to App($APPLICATION_NAME) was not successfull." >$OUTPUT_SUMMARYFILE
        exit 1
    fi
    
    # check_app_has_externalip set global variable IP_ADDRESS.
    APPLICATION_RELEASE_NAME=$(ssh -t -i $IDENTITY_FILE $USER_NAME@$MASTER_IP "helm ls -d -r --all-namespaces | grep 'deployed\(.*\)$APPLICATION_NAME' | grep -Eo '^[a-z,-]+\w+'")
    log_level -i "APPLICATION_RELEASE_NAME:$APPLICATION_RELEASE_NAME"
    SERVICE_NAME=`echo $APPLICATION_RELEASE_NAME | sed 's/\\r//g'`
    log_level -i "SERVICE_NAME:$SERVICE_NAME"
    
    check_app_has_externalip $IDENTITY_FILE \
    $USER_NAME \
    $MASTER_IP \
    $APPLICATION_NAME \
    $SERVICE_NAME \
    $NAMESPACE
    
    if [[ $? != 0 ]]; then
        printf '{"result":"%s","error":"%s"}\n' "failed" "External IP not found for $APPLICATION_NAME." >$OUTPUT_SUMMARYFILE
        exit 1
    fi
    
    log_level -i "Get cluster name"
    CLUSTER_NAME=$(ssh -t -i $IDENTITY_FILE $USER_NAME@$MASTER_IP "kubectl config current-context")
    
    log_level -i "Switch to $CONTEXT_NAME context"
    ssh -t -i $IDENTITY_FILE $USER_NAME@$MASTER_IP "kubectl config use-context $CONTEXT_NAME"
    
    log_level -i "Check if context is selected"
    CONTEXT_STATUS=$(ssh -t -i $IDENTITY_FILE $USER_NAME@$MASTER_IP "kubectl config current-context")
    CONTEXT_STATUS=`echo $CONTEXT_STATUS | sed 's/\\r//g'`
    
    if [[ $CONTEXT_STATUS == $CONTEXT_NAME ]]; then
        log_level -i "Correct context is selected"
    else
        log_level -e "An error occured"
        printf '{"result":"%s","error":"%s"}\n' "failed" "The context $CONTEXT_NAME could not be selected. Info ($CONTEXT_STATUS)" >$OUTPUT_SUMMARYFILE
        exit 1
    fi
    
    log_level -i "Check if context can create deployments in default namespace"
    CAN_DEPLOY_NS=$(ssh -t -i $IDENTITY_FILE $USER_NAME@$MASTER_IP "kubectl auth can-i create deployments --namespace ns-tomcat || echo error")
    
    log_level -i "CAN_DEPLOY_NS:$CAN_DEPLOY_NS"
    
    if [[ $CAN_DEPLOY_NS !=  *"yes"* ]]; then
        printf '{"result":"%s","error":"%s"}\n' "failed" "Permission error ($CONTEXT_NAME) cannot deploy in ns-tomcat" >$OUTPUT_SUMMARYFILE
        exit 1
    fi
    
    log_level -i "Check if context can create deployments in default namespace"
    CAN_DEPLOY_DEFAULT=$(ssh -t -i $IDENTITY_FILE $USER_NAME@$MASTER_IP "kubectl auth can-i create deployments --namespace default || echo error")
    
    log_level -i "CAN_DEPLOY_DEFAULT:$CAN_DEPLOY_DEFAULT"
    
    if [[ $CAN_DEPLOY_DEFAULT ==  *"yes"* ]]; then
        printf '{"result":"%s","error":"%s"}\n' "failed" "Permission error ($CONTEXT_NAME) can deploy in default namespace" >$OUTPUT_SUMMARYFILE
        exit 1
    fi
    
    log_level -i "Switch to $CLUSTER_NAME context"
    ssh -t -i $IDENTITY_FILE $USER_NAME@$MASTER_IP "kubectl config use-context $CLUSTER_NAME"
    
    # IP_ADDRESS variable is set in check_app_has_externalip function.
    check_app_listening_at_externalip $IP_ADDRESS
    if [[ $? != 0 ]]; then
        printf '{"result":"%s","error":"%s"}\n' "failed" "Not able to communicate to $IP_ADDRESS." >$OUTPUT_SUMMARYFILE
    else
        printf '{"result":"%s"}\n' "pass" >$OUTPUT_SUMMARYFILE
    fi
    
    # Create result file, even if script ends with an error
    #trap final_changes EXIT
    
} 2>&1 | tee $LOG_FILENAME

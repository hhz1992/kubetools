#!/bin/bash -e



FILE_NAME=$0

SCRIPT_FOLDER="$(dirname $FILE_NAME)"
GIT_REPROSITORY="${GIT_REPROSITORY:-msazurestackworkloads/kubetools}"
GIT_BRANCH="${GIT_BRANCH:-master}"
COMMON_SCRIPT_FILENAME="common.sh"

# Download common script file.
if [ ! -f $SCRIPT_FOLDER/$COMMON_SCRIPT_FILENAME ]; then
    curl -o $SCRIPT_FOLDER/$COMMON_SCRIPT_FILENAME \
    https://raw.githubusercontent.com/$GIT_REPROSITORY/$GIT_BRANCH/applications/common/$COMMON_SCRIPT_FILENAME
    if [ ! -f $SCRIPT_FOLDER/$COMMON_SCRIPT_FILENAME ]; then
        log_level -e "File($COMMON_SCRIPT_FILENAME) failed to download."
        exit 1
    fi
fi

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

if [[ -z "$IDENTITY_FILE" ]] || \
[[ -z "$MASTER_IP" ]] || \
[[ -z "$USER_NAME" ]] || \
[[ -z "$OUTPUT_SUMMARYFILE" ]]; then
    log_level -e "One of mandatory parameter is not passed correctly."
    print_usage
    exit 1
fi

###########################################################################################################

OUTPUT_FOLDER="$(dirname $OUTPUT_SUMMARYFILE)"
LOG_FILENAME="$OUTPUT_FOLDER/deploy.log"
touch $LOG_FILENAME

{
    APPLICATION_NAME="wordpress"
    APPLICATION_FOLDER="applications/common"
    TEMPLATE_FOLDER="applications/$APPLICATION_NAME"
    HELM_INSTALL_FILENAME="install_helm.sh"
    WORDPRESS_INSTALL_FILENAME="install_wordpress_using_helm.sh"
    TEST_FOLDER="/home/$USER_NAME/$APPLICATION_NAME"
    log_level -i "------------------------------------------------------------------------"
    log_level -i "                Inner Variables"
    log_level -i "------------------------------------------------------------------------"
    log_level -i "APPLICATION_NAME           : $APPLICATION_NAME"
    log_level -i "APPLICATION_FOLDER         : $APPLICATION_FOLDER"
    log_level -i "HELM_INSTALL_FILENAME      : $HELM_INSTALL_FILENAME"
    log_level -i "TEMPLATE_FOLDER            : $TEMPLATE_FOLDER"
    log_level -i "TEST_FOLDER                : $TEST_FOLDER"
    log_level -i "WORDPRESS_INSTALL_FILENAME : $WORDPRESS_INSTALL_FILENAME"    
    log_level -i "------------------------------------------------------------------------"
    
    ############################################################################################
    download_file_locally $GIT_REPROSITORY $GIT_BRANCH \
    $APPLICATION_FOLDER \
    $SCRIPT_FOLDER \
    $HELM_INSTALL_FILENAME
    
    if [[ $? != 0 ]]; then
        log_level -e "Download of file($HELM_INSTALL_FILENAME) failed."
        printf '{"result":"%s","error":"%s"}\n' "failed" "Download of file($HELM_INSTALL_FILENAME) was not successfull." > $OUTPUT_SUMMARYFILE
        exit 1
    fi

    download_file_locally $GIT_REPROSITORY $GIT_BRANCH \
    $TEMPLATE_FOLDER \
    $SCRIPT_FOLDER \
    $WORDPRESS_INSTALL_FILENAME

    if [[ $? != 0 ]]; then
        log_level -e "Download of file($WORDPRESS_INSTALL_FILENAME) failed."
        printf '{"result":"%s","error":"%s"}\n' "failed" "Download of file($WORDPRESS_INSTALL_FILENAME) was not successfull." > $OUTPUT_SUMMARYFILE
        exit 1
    fi

    KNOWN_HOSTS_OPTIONS='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR'

    ############################################################################################
    log_level -i "Create test folder($TEST_FOLDER)"
    ssh -t -i $IDENTITY_FILE ${KNOWN_HOSTS_OPTIONS} $USER_NAME@$MASTER_IP "mkdir -p $TEST_FOLDER"

    log_level -i "Copy file($HELM_INSTALL_FILENAME) to VM."
    scp -i $IDENTITY_FILE \
    $SCRIPT_FOLDER/$HELM_INSTALL_FILENAME \
    $USER_NAME@$MASTER_IP:$TEST_FOLDER/

    log_level -i "Copy file($WORDPRESS_INSTALL_FILENAME) to VM."
    scp -i $IDENTITY_FILE \
    $SCRIPT_FOLDER/$WORDPRESS_INSTALL_FILENAME \
    $USER_NAME@$MASTER_IP:$TEST_FOLDER/
    
    # Install Helm chart
    install_helm_chart $IDENTITY_FILE \
        $USER_NAME \
        $MASTER_IP \
        $TEST_FOLDER \
        $HELM_INSTALL_FILENAME

    if [[ $? != 0 ]]; then
        printf '{"result":"%s","error":"%s"}\n' "failed" "Installing Helm was not successfull." > $OUTPUT_SUMMARYFILE
        exit 1
    fi
    
    log_level -i "=========================================================================="
    log_level -i "Installing Wordpress app."
    # Install Wordpress app
    ssh -t -i $IDENTITY_FILE ${KNOWN_HOSTS_OPTIONS} \
    $USER_NAME@$MASTER_IP \
    "sudo chmod 744 $TEST_FOLDER/$WORDPRESS_INSTALL_FILENAME; cd $TEST_FOLDER; ./$WORDPRESS_INSTALL_FILENAME;"
    wpRelease=$(ssh -i $IDENTITY_FILE ${KNOWN_HOSTS_OPTIONS} $USER_NAME@$MASTER_IP "helm ls -d -r --all-namespaces | grep 'deployed\(.*\)wordpress' | grep -Eo '^[a-z,-]+\w+'")
    if [ -z "$wpRelease" ]; then
        log_level -e "Wordpress deployment failed using Helm."
        ssh -t -i $IDENTITY_FILE  ${KNOWN_HOSTS_OPTIONS} $USER_NAME@$MASTER_IP "sudo kubectl get all -o wide"
        result="failed"
        printf '{"result":"%s","error":"%s"}\n' "$result" "Wordpress deployment was not successfull." > $OUTPUT_SUMMARYFILE
        exit 1
    else
        log_level -i "Helm deployed wordpress app with deployment name as: $wpRelease."
    fi
    log_level -i "=========================================================================="
    result="pass"
    printf '{"result":"%s"}\n' "$result" > $OUTPUT_SUMMARYFILE
} 2>&1 | tee $LOG_FILENAME
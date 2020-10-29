#!/bin/bash -e

FILE_NAME=$0

SCRIPT_FOLDER="$(dirname $FILE_NAME)"
GIT_REPROSITORY="${GIT_REPROSITORY:-msazurestackworkloads/kubetools}"
GIT_BRANCH="${GIT_BRANCH:-master}"
COMMON_SCRIPT_FILENAME="common.sh"

# Download common script file.
curl -o $SCRIPT_FOLDER/$COMMON_SCRIPT_FILENAME \
https://raw.githubusercontent.com/$GIT_REPROSITORY/$GIT_BRANCH/applications/common/$COMMON_SCRIPT_FILENAME
if [ ! -f $SCRIPT_FOLDER/$COMMON_SCRIPT_FILENAME ]; then
    log_level -e "File($COMMON_SCRIPT_FILENAME) failed to download."
    exit 1
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
LOG_FILENAME="$OUTPUT_FOLDER/deploy.log"
touch $LOG_FILENAME

{
    HELM_INSTALL_FILENAME="install_helm.sh"
    APPLICATION_NAME="tomcat"
    TEST_FOLDER="/home/$USER_NAME/$APPLICATION_NAME"
    APPLICATION_FOLDER="applications/common"
    TEMPLATE_FOLDER="applications/tomcat"
    NAMESPACE="ns-tomcat"
    KUBE_CERT_LOCATION="/etc/kubernetes/certs"
    CLUSTER_USERNAME="tomcat-user"
    CONTEXT_NAME="tomcat-context"
    ROLE_BINDING_FILENAME="role-binding-deployment-manager.yaml"
    ROLE_DEPLOYMENT_FILENAME="role-deployment-manager.yaml"

    log_level -i "------------------------------------------------------------------------"
    log_level -i "                Inner Variables"
    log_level -i "------------------------------------------------------------------------"
    log_level -i "APPLICATION_FOLDER          : $APPLICATION_FOLDER"
    log_level -i "APPLICATION_NAME            : $APPLICATION_NAME"
    log_level -i "CLUSTER_USERNAME            : $CLUSTER_USERNAME"
    log_level -i "CONTEXT_NAME                : $CONTEXT_NAME"
    log_level -i "GIT_BRANCH                  : $GIT_BRANCH"
    log_level -i "GIT_REPROSITORY             : $GIT_REPROSITORY"
    log_level -i "HELM_INSTALL_FILENAME       : $HELM_INSTALL_FILENAME"
    log_level -i "KUBE_CERT_LOCATION          : $KUBE_CERT_LOCATION"
    log_level -i "NAMESPACE                   : $NAMESPACE"
    log_level -i "TEMPLATE_FOLDER             : $TEMPLATE_FOLDER"
    log_level -i "TEST_FOLDER                 : $TEST_FOLDER"
    log_level -i "------------------------------------------------------------------------"

    ###########################################################################################################
    download_file_locally $GIT_REPROSITORY $GIT_BRANCH \
    $APPLICATION_FOLDER \
    $SCRIPT_FOLDER \
    $HELM_INSTALL_FILENAME

    download_file_locally $GIT_REPROSITORY $GIT_BRANCH \
    $TEMPLATE_FOLDER \
    $SCRIPT_FOLDER \
    $ROLE_BINDING_FILENAME

    download_file_locally $GIT_REPROSITORY $GIT_BRANCH \
    $TEMPLATE_FOLDER \
    $SCRIPT_FOLDER \
    $ROLE_DEPLOYMENT_FILENAME

    if [[ $? != 0 ]]; then
        log_level -e "Download of file($HELM_INSTALL_FILENAME) failed."
        printf '{"result":"%s","error":"%s"}\n' "failed" "Download of file($HELM_INSTALL_FILENAME) was not successfull." >$OUTPUT_SUMMARYFILE
        exit 1
    fi

    KNOWN_HOSTS_OPTIONS='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR'

    log_level -i "Create test folder($TEST_FOLDER)"
    ssh -t -i ${KNOWN_HOSTS_OPTIONS}  $IDENTITY_FILE $USER_NAME@$MASTER_IP "mkdir -p $TEST_FOLDER"

    log_level -i "Copy file($HELM_INSTALL_FILENAME) to VM."
    scp -i $IDENTITY_FILE \
    $SCRIPT_FOLDER/$HELM_INSTALL_FILENAME \
    $USER_NAME@$MASTER_IP:$TEST_FOLDER/

    scp -i $IDENTITY_FILE \
    $SCRIPT_FOLDER/$ROLE_BINDING_FILENAME \
    $USER_NAME@$MASTER_IP:$TEST_FOLDER/

    scp -i $IDENTITY_FILE \
    $SCRIPT_FOLDER/$ROLE_DEPLOYMENT_FILENAME \
    $USER_NAME@$MASTER_IP:$TEST_FOLDER/

    # Install Helm chart
    install_helm_chart $IDENTITY_FILE \
    $USER_NAME \
    $MASTER_IP \
    $TEST_FOLDER \
    $HELM_INSTALL_FILENAME

    if [[ $? != 0 ]]; then
        printf '{"result":"%s","error":"%s"}\n' "failed" "Installing Helm was not successfull." >$OUTPUT_SUMMARYFILE
        exit 1
    fi

    log_level -i "Creating namespace ($NAMESPACE) for RBAC"
    ssh -t -i ${KNOWN_HOSTS_OPTIONS}  $IDENTITY_FILE $USER_NAME@$MASTER_IP "kubectl create namespace $NAMESPACE"

    log_level -i "Creating private key for user"
    ssh -t -i ${KNOWN_HOSTS_OPTIONS}  $IDENTITY_FILE $USER_NAME@$MASTER_IP "openssl genrsa -out $TEST_FOLDER/tomcat.key 2048"

    log_level -i "Creating certificate"
    ssh -t -i ${KNOWN_HOSTS_OPTIONS}  $IDENTITY_FILE $USER_NAME@$MASTER_IP "openssl req -new -key $TEST_FOLDER/tomcat.key -out $TEST_FOLDER/tomcat.csr -subj '/CN=$CLUSTER_USERNAME/O=tomcat'"

    log_level -i "Signing certificate"
    ssh -t -i ${KNOWN_HOSTS_OPTIONS}  $IDENTITY_FILE $USER_NAME@$MASTER_IP "sudo openssl x509 -req -in $TEST_FOLDER/tomcat.csr -CA $KUBE_CERT_LOCATION/ca.crt -CAkey $KUBE_CERT_LOCATION/ca.key -CAcreateserial -out $TEST_FOLDER/tomcat.crt -days 500"

    log_level -i "Moving certificates to secure location"
    ssh -t -i ${KNOWN_HOSTS_OPTIONS}  $IDENTITY_FILE $USER_NAME@$MASTER_IP "mkdir -p $TEST_FOLDER/.certs"
    ssh -t -i ${KNOWN_HOSTS_OPTIONS}  $IDENTITY_FILE $USER_NAME@$MASTER_IP "sudo mv $TEST_FOLDER/tomcat.crt $TEST_FOLDER/.certs/tomcat.crt"
    ssh -t -i ${KNOWN_HOSTS_OPTIONS}  $IDENTITY_FILE $USER_NAME@$MASTER_IP "sudo mv $TEST_FOLDER/tomcat.key $TEST_FOLDER/.certs/tomcat.key"

    log_level -i "Setting credentials for context"
    ssh -t -i ${KNOWN_HOSTS_OPTIONS}  $IDENTITY_FILE $USER_NAME@$MASTER_IP "kubectl config set-credentials $CLUSTER_USERNAME --client-certificate=$TEST_FOLDER/.certs/tomcat.crt  --client-key=$TEST_FOLDER/.certs/tomcat.key"

    log_level -i "Get cluster name"
    CLUSTER_NAME=$(ssh -t -i ${KNOWN_HOSTS_OPTIONS}  $IDENTITY_FILE $USER_NAME@$MASTER_IP "kubectl config current-context")

    log_level -i "Creating the context for the the new user with cluster name ($CLUSTER_NAME)"
    ssh -t -i ${KNOWN_HOSTS_OPTIONS}  $IDENTITY_FILE $USER_NAME@$MASTER_IP "kubectl config set-context $CONTEXT_NAME --cluster=$CLUSTER_NAME --namespace=$NAMESPACE --user=$CLUSTER_USERNAME"

    log_level -i "Creating role for cluster"
    ssh -t -i ${KNOWN_HOSTS_OPTIONS}  $IDENTITY_FILE $USER_NAME@$MASTER_IP "kubectl create -f $TEST_FOLDER/$ROLE_DEPLOYMENT_FILENAME"

    log_level -i "Creating role binding"
    ssh -t -i ${KNOWN_HOSTS_OPTIONS}  $IDENTITY_FILE $USER_NAME@$MASTER_IP "kubectl create -f $TEST_FOLDER/$ROLE_BINDING_FILENAME"

    install_helm_app $IDENTITY_FILE \
    $USER_NAME \
    $MASTER_IP \
    $APPLICATION_NAME \
    $NAMESPACE

    if [[ $? != 0 ]]; then
        printf '{"result":"%s","error":"%s"}\n' "failed" "Installing App($APPLICATION_NAME) was not successfull." >$OUTPUT_SUMMARYFILE
        exit 1
    else
        printf '{"result":"%s"}\n' "pass" >$OUTPUT_SUMMARYFILE
    fi

    # Create result file, even if script ends with an error
    #trap final_changes EXIT
} 2>&1 | tee $LOG_FILENAME

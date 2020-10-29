#!/bin/bash -e

log_level()
{
    case "$1" in
        -e) echo "$(date) [Err]  " ${@:2}
        ;;
        -w) echo "$(date) [Warn] " ${@:2}
        ;;
        -i) echo "$(date) [Info] " ${@:2}
        ;;
        *)  echo "$(date) [Debug] " ${@:2}
        ;;
    esac
}

printUsage()
{
    echo "      Usage:"
    echo "      $FILENAME --identity-file id_rsa --master 192.168.102.34 --user azureuser"
    echo  ""
    echo "            -i, --identity-file                         RSA Private Key file to connect kubernetes master VM, it starts with -----BEGIN RSA PRIVATE KEY-----"
    echo "            -m, --master                                Public ip of Kubernetes cluster master VM. Normally VM name starts with k8s-master- "
    echo "            -u, --user                                  User Name of Kubernetes cluster master VM "
    echo "            -o, --output-file                           Summary file providing result status of the deployment."
    exit 1
}

function final_changes {
    if [ ! -f "$OUTPUT_SUMMARYFILE" ]; then
        printf '{"result":"%s"}\n' "failed" > $OUTPUT_SUMMARYFILE
    fi
}

FILENAME=$0

while [[ "$#" -gt 0 ]]
do
    case $1 in
        -i|--identity-file)
            IDENTITY_FILE="$2"
        ;;
        -m|--master)
            MASTER_IP="$2"
        ;;
        -u|--user)
            USER_NAME="$2"
        ;;
        -o|--output-file)
            OUTPUT_SUMMARYFILE="$2"
        ;;
        *)
            echo ""
            echo "Incorrect parameter $1"
            echo ""
            printUsage
        ;;
    esac
    
    if [ "$#" -ge 2 ]
    then
        shift 2
    else
        shift
    fi
done

OUTPUT_FOLDER=$(dirname $OUTPUT_SUMMARYFILE)
LOG_FILENAME="$OUTPUT_FOLDER/deploy.log"
APP_SERVICE="$OUTPUT_FOLDER/nginx-service.txt"
touch $LOG_FILENAME

{
    # Github details.
    GIT_REPROSITORY="${GIT_REPROSITORY:-msazurestackworkloads/kubetools}"
    GIT_BRANCH="${GIT_BRANCH:-master}"
    TEST_DIRECTORY="/home/$USER_NAME/nginx"
    NGINX_DEPLOY_FILENAME="nginx-deploy.yaml"

    log_level -i "------------------------------------------------------------------------"
    log_level -i "                Input Parameters"
    log_level -i "------------------------------------------------------------------------"
    log_level -i "IDENTITY_FILE         : $IDENTITY_FILE"
    log_level -i "GIT_BRANCH            : $GIT_BRANCH"
    log_level -i "GIT_REPROSITORY       : $GIT_REPROSITORY"
    log_level -i "MASTER_IP             : $MASTER_IP"
    log_level -i "OUTPUT_SUMMARYFILE    : $OUTPUT_SUMMARYFILE"
    log_level -i "USER_NAME             : $USER_NAME"
    log_level -i "------------------------------------------------------------------------"
    
    log_level -i "------------------------------------------------------------------------"
    log_level -i "                Inner Variables"
    log_level -i "------------------------------------------------------------------------"
    log_level -i "TEST_DIRECTORY              : $TEST_DIRECTORY"
    log_level -i "NGINX_INSTALL_FILENAME      : $NGINX_DEPLOY_FILENAME"
    log_level -i "------------------------------------------------------------------------"
    
    curl -o $OUTPUT_FOLDER/$NGINX_DEPLOY_FILENAME \
    https://raw.githubusercontent.com/$GIT_REPROSITORY/$GIT_BRANCH/applications/nginx/$NGINX_DEPLOY_FILENAME
    if [ ! -f $OUTPUT_FOLDER/$NGINX_DEPLOY_FILENAME ]; then
        log_level -e "File($NGINX_DEPLOY_FILENAME) failed to download."
        result="failed"
        printf '{"result":"%s","error":"%s"}\n' "$result" "Download of file($NGINX_DEPLOY_FILENAME) was not successfull." > $OUTPUT_SUMMARYFILE
        exit 1
    fi
    
    KNOWN_HOSTS_OPTIONS='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR'
    
    log_level -i "Create test folder($TEST_DIRECTORY)"
    ssh -t -i ${KNOWN_HOSTS_OPTIONS} $IDENTITY_FILE $USER_NAME@$MASTER_IP "mkdir -p $TEST_DIRECTORY"

    log_level -i "Copy files to K8s master node."
    scp -i $IDENTITY_FILE \
    $OUTPUT_FOLDER/$NGINX_DEPLOY_FILENAME \
    $USER_NAME@$MASTER_IP:$TEST_DIRECTORY/
    
    log_level -i "=========================================================================="
    log_level -i "Installing nginx."

    ssh -t -i ${KNOWN_HOSTS_OPTIONS} $IDENTITY_FILE \
    $USER_NAME@$MASTER_IP \
    "sudo chmod 744 $TEST_DIRECTORY/$NGINX_DEPLOY_FILENAME; cd $TEST_DIRECTORY;"
    nginx=$(ssh -t -i ${KNOWN_HOSTS_OPTIONS} $IDENTITY_FILE $USER_NAME@$MASTER_IP "cd $TEST_DIRECTORY;kubectl create -f $NGINX_DEPLOY_FILENAME";sleep 10)
    nginx_deploy=$(ssh -t -i ${KNOWN_HOSTS_OPTIONS} $IDENTITY_FILE $USER_NAME@$MASTER_IP "cd $TEST_DIRECTORY;kubectl get deployment -o json > nginx_deploy.json")
    nginx_status=$(ssh -t -i ${KNOWN_HOSTS_OPTIONS} $IDENTITY_FILE $USER_NAME@$MASTER_IP "cd $TEST_DIRECTORY;cat nginx_deploy.json | jq '.items[0]."status"."conditions"[0].type'" | grep "Available";sleep 2m)
    nginx_services=$(ssh -t -i ${KNOWN_HOSTS_OPTIONS} $IDENTITY_FILE $USER_NAME@$MASTER_IP "cd $TEST_DIRECTORY;kubectl get services -o json > nginx_service.json")
    app_nginx=$(ssh -t -i ${KNOWN_HOSTS_OPTIONS} $IDENTITY_FILE $USER_NAME@$MASTER_IP "sudo kubectl get services nginxservice -o=custom-columns=NAME:.status.loadBalancer.ingress[0].ip | grep -oP '(\d{1,3}\.){1,3}\d{1,3}'")
    echo $app_nginx > $APP_SERVICE

    if [ $? == 0 ]; then
        log_level -i "Deployed nginx app."
    else    
        log_level -e "Nginx deployment failed."
        result="failed"
        printf '{"result":"%s","error":"%s"}\n' "$result" "Nginx deployment was not successfull." > $OUTPUT_SUMMARYFILE
        exit 1
    fi 
    log_level -i "=========================================================================="
    result="pass"
    printf '{"result":"%s"}\n' "$result" > $OUTPUT_SUMMARYFILE
    # Create result file, even if script ends with an error
    #trap final_changes EXIT
} 2>&1 | tee $LOG_FILENAME

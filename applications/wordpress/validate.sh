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
        -c|--configFile)
            CONFIG_FILE="$2"
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

OUTPUT_FOLDER="$(dirname $OUTPUT_SUMMARYFILE)"
LOG_FILENAME="$OUTPUT_FOLDER/validate.log"
touch $LOG_FILENAME
KNOWN_HOSTS_OPTIONS='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR'

{

    log_level -i "------------------------------------------------------------------------"
    log_level -i "                Input Parameters"
    log_level -i "------------------------------------------------------------------------"
    log_level -i "IDENTITY_FILE       : $IDENTITY_FILE"
    log_level -i "MASTER_IP           : $MASTER_IP"
    log_level -i "OUTPUT_SUMMARYFILE  : $OUTPUT_SUMMARYFILE"
    log_level -i "USER_NAME           : $USER_NAME"
    log_level -i "------------------------------------------------------------------------"
    
    # Check if pod is up and running
    log_level -i "Validate if pods are created and running."
    log_level -i "Get all nodes details."
    ssh -t -i $IDENTITY_FILE ${KNOWN_HOSTS_OPTIONS} $USER_NAME@$MASTER_IP "sudo kubectl get nodes -o wide"
    log_level -i "Get Helm deployment details."
    ssh -t -i $IDENTITY_FILE ${KNOWN_HOSTS_OPTIONS} $USER_NAME@$MASTER_IP "helm ls -d -r --all-namespaces"
    log_level -i "Get all pods details ."
    ssh -t -i $IDENTITY_FILE ${KNOWN_HOSTS_OPTIONS} $USER_NAME@$MASTER_IP "sudo kubectl get all -o wide"

    wordPressDeploymentName=$(ssh -i $IDENTITY_FILE ${KNOWN_HOSTS_OPTIONS} $USER_NAME@$MASTER_IP "helm ls -d -r --all-namespaces | grep -i 'deployed\(.*\)wordpress' | grep -Eo '^[a-z,-]+\w+'")
    mariadbPodstatus=$(ssh -i $IDENTITY_FILE ${KNOWN_HOSTS_OPTIONS} $USER_NAME@$MASTER_IP "sudo kubectl get pods --selector app=mariadb | grep 'Running'")
    wdpressPodstatus=$(ssh -i $IDENTITY_FILE ${KNOWN_HOSTS_OPTIONS} $USER_NAME@$MASTER_IP "kubectl get pods --selector app.kubernetes.io/instance=${wordPressDeploymentName} | grep 'Running'")
    failedPods=""
    if [ -z "$mariadbPodstatus" ]; then
        failedPods="mariadb"
    fi
    
    if [ -z "$wdpressPodstatus" ]; then
        failedPods="wordpress, "$failedPods
    fi
    
    if [ ! -z "$failedPods" ]; then
        log_level -e "Validation failed because pods ($failedPods) not running."
        result="failed"
        printf '{"result":"%s","error":"%s"}\n' "$result" "Pods ($failedPods) are not in running state." > $OUTPUT_SUMMARYFILE
        exit 1
    else
        log_level -i "Wordpress and mariadb pods are up and running."
    fi
    
    # Check if App got external IP
    log_level -i "Validate if Pods got external IP address."
    externalIp=$(ssh -i $IDENTITY_FILE ${KNOWN_HOSTS_OPTIONS} $USER_NAME@$MASTER_IP "sudo kubectl get services ${wordPressDeploymentName} -o=custom-columns=NAME:.status.loadBalancer.ingress[0].ip | grep -oP '(\d{1,3}\.){1,3}\d{1,3}'")
    if [ -z "$externalIp" ]; then
        log_level -e "External IP not found for wordpress."
        result="failed"
        printf '{"result":"%s","error":"%s"}\n' "$result" "No external IP found." > $OUTPUT_SUMMARYFILE
        exit 1
    else
        log_level -i "Found external IP address ($externalIp)."
    fi
    
    # Check portal status    
    i=0
    while [ $i -lt 20 ];do
        portalState="$(curl http://${externalIp} --head -s | grep '200 OK')"
        if [ -z "$portalState" ]; then
            log_level -i "Portal communication validation failed. We we will retry after some time."
            sleep 30s
        else
            break
        fi
        let i=i+1
    done
    
    if [ -z "$portalState" ]; then
        log_level -e "Not able to communicate wordpress web endpoint. Please check if app is up and running."
        result="failed"
        printf '{"result":"%s","error":"%s"}\n' "$result" "Not able to communicate wordpress web endpoint." > $OUTPUT_SUMMARYFILE
        exit 1
    else
        log_level -i "Able to communicate wordpress web endpoint. ($portalState)"
    fi

    result="pass"
    printf '{"result":"%s"}\n' "$result" > $OUTPUT_SUMMARYFILE
    
    # Create result file, even if script ends with an error
    #trap final_changes EXIT
    
} 2>&1 | tee $LOG_FILENAME

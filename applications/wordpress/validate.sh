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
    if [ ! -f "$OUTPUT_FILE" ]; then
        printf '{"result":"%s"}\n' "fail" > $OUTPUT_FILE
    fi
}

FILENAME=$0

while [[ "$#" -gt 0 ]]
do
    case $1 in
        -i|--identity-file)
            IDENTITYFILE="$2"
        ;;
        -m|--master)
            MASTERVMIP="$2"
        ;;
        -u|--user)
            AZUREUSER="$2"
        ;;
        -o|--output-file)
            OUTPUT_FILE="$2"
        ;;
        -c|--configFile)
            PARAMETERFILE="$2"
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

OUTPUTFOLDER="$(dirname $OUTPUT_FILE)"
LOGFILENAME="$OUTPUTFOLDER/validate.log"
touch $LOGFILENAME

{
    log_level -i "------------------------------------------------------------------------"
    log_level -i "Input Parameters"
    log_level -i "------------------------------------------------------------------------"
    log_level -i "Identity-file   : $IDENTITYFILE"
    log_level -i "Master IP       : $MASTERVMIP"
    log_level -i "OUTPUT_FILE     : $OUTPUT_FILE"
    log_level -i "User            : $AZUREUSER"
    log_level -i "------------------------------------------------------------------------"
    
    # Check if pod is up and running
    log_level -i "Validate if Pods are created and running."
    wpRelease=$(ssh -t -i $IDENTITYFILE $AZUREUSER@$MASTERVMIP "helm ls -d -r | grep 'DEPLOYED\(.*\)wordpress' | grep -Eo '^[a-z,-]+'")
    mariadbPodstatus=$(ssh -t -i $IDENTITYFILE $AZUREUSER@$MASTERVMIP "sudo kubectl get pods --selector app=mariadb | grep 'Running'")
    wdpressPodstatus=$(ssh -t -i $IDENTITYFILE $AZUREUSER@$MASTERVMIP "sudo kubectl get pods --selector app=${wpRelease}-wordpress | grep 'Running'")
    failedPods=""
    if [ -z "$mariadbPodstatus" ]; then
        failedPods="mariadb"
    fi
    
    if [ -z "$wdpressPodstatus" ]; then
        failedPods="wordpress, "$failedPods
    fi
    
    if [ ! -z "$failedPods" ]; then
        log_level -e "Validation failed because pods ($failedPods) not running."
        exit 1
    else
        log_level -i "Wordpress and mariadb pods are up and running."
    fi
    
    # Check if App got external IP
    log_level -i "Validate if Pods got external IP address."
    externalIp=$(ssh -t -i $IDENTITYFILE $AZUREUSER@$MASTERVMIP "sudo kubectl get services ${wpRelease}-wordpress -o=custom-columns=NAME:.status.loadBalancer.ingress[0].ip | grep -oP '(\d{1,3}\.){1,3}\d{1,3}'")
    if [ -z "$externalIp" ]; then
        log_level -e "External IP not found for wordpress."
        exit 1
    else
        log_level -i "Found external IP address ($externalIp)."
    fi
    
    # Check portal status    
    i=0
    while [ $i -lt 20 ];do
        portalState="$(curl http://${externalIp} --head -s | grep '200 OK')"
        if [ -z "$portalState" ]; then
            log_level -w "Portal communication validation failed. We we will retry after some time."
            sleep 30s
        else
            break
        fi
        let i=i+1
    done
    
    if [ -z "$portalState" ]; then
        log_level -e "Portal communication validation failed. Please check if app is up and running."
    else
        log_level -i "Able to communicate wordpress portal. ($portalState)"
    fi

    result="pass"
    printf '{"result":"%s"}\n' "$result" > $OUTPUT_FILE
    
    # Create result file, even if script ends with an error
    #trap final_changes EXIT
    
} 2>&1 | tee $LOGFILENAME
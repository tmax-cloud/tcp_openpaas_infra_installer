#!/bin/bash
export kubectl_opt="-v=0"
[[ "$0" != "$BASH_SOURCE" ]] && export install_dir=$(dirname "$BASH_SOURCE") || export install_dir=$(dirname $0)
. "$install_dir/console.config"


function prepare_online(){
  echo  "========================================================================="
  echo  "========================  Preparing for Console =========================="
  echo  "========================================================================="
  sudo docker pull "tmaxcloudck/hypercloud-console:${CONSOLE_VER}"
  sudo docker save "tmaxcloudck/hypercloud-console:${CONSOLE_VER}" > "${install_dir}/tar/console_${CONSOLE_VER}.tar"

	sudo docker pull "tmaxcloudck/console-operator:${OPERATOR_VER}"
  sudo docker save "tmaxcloudck/hypercloud-console:${OPERATOR_VER}" > "${install_dir}/tar/operator_${OPERATOR_VER}.tar"

  sudo docker pull "jettech/kube-webhook-certgen:v1.3.0"
  sudo docker save "jettech/kube-webhook-certgen:v1.3.0" > "${install_dir}/tar/certgen_v1.3.0.tar"
}

function prepare_offline(){
  echo  "========================================================================="
  echo  "========================  Preparing for Console =========================="
  echo  "========================================================================="

  sudo docker load < ${install_dir}/tar/console_${CONSOLE_VER}.tar
  sudo docker tag docker.io/tmaxcloudck/hypercloud-console:${CONSOLE_VER} ${REGISTRY}/tmaxcloudck/hypercloud-console:${CONSOLE_VER}
  sudo docker push ${REGISTRY}/tmaxcloudck/hypercloud-console:${CONSOLE_VER}

  sudo docker load < ${install_dir}/tar/operator_${OPERATOR_VER}.tar
  sudo docker tag docker.io/tmaxcloudck/console-operator:${OPERATOR_VER} ${REGISTRY}/tmaxcloudck/console-operator:${OPERATOR_VER}
  sudo docker push ${REGISTRY}/tmaxcloudck/console-operator:${OPERATOR_VER}

  #tls 인증서 생성을 위한 도커 이미지 로드
  sudo docker load < ${install_dir}/tar/certgen_v1.3.0.tar
  sudo docker tag docker.io/jettech/kube-webhook-certgen:v1.3.0 ${REGISTRY}/jettech/kube-webhook-certgen:v1.3.0
  sudo docker push ${REGISTRY}/jettech/kube-webhook-certgen:v1.3.0
}

function install(){
  echo  "========================================================================="
  echo  "=======================  Start Installing Console ======================="
  echo  "========================================================================="

  echo ""
  echo "=========================================================================="
  echo "STEP 1. ENV Setting"
  echo "=========================================================================="
  cat console.config
  file_Dir="${install_dir}/yaml"
  temp_Dir="${install_dir}/yaml_temp"
  crd_temp="${temp_Dir}/1.crd.yaml"
  init_temp="${temp_Dir}/2.init.yaml"
  job_temp="${temp_Dir}/3.job.yaml"
  svc_temp="${temp_Dir}/4.svc-lb.yaml"
  deploy_temp="${temp_Dir}/5.deploy.yaml"

  if [[ $REALM == "" || $KEYCLOAK == "" || $CLIENTID == "" ]]; then 
    echo "========================================================================="
    echo "=========                    ERROR                       ================"
    echo "=========  MUST configure RELAM, KEYCLOAK and CLIENTID   ================"
    echo "========================================================================="
    exit
  fi

  if [[ $KIALI == "" ]]; then
    KIALI_IP=$(kubectl get ingress kiali -n istio-system -o=jsonpath="{.status.loadBalancer.ingress[0].ip}")
    KIALI_PORT="" # default https port = 433
    if [[ -z $KIALI_IP ]]; then
      echo "Cannot find Ingress KIALI_IP in istio-system. Is kiali installed on Ingress?"
      KIALI_IP="0.0.0.0"
      KIALI_PORT="20001"
      echo "Failed to find KIALI, so KIALI=0.0.0.0:20001"
    fi
    KIALI=${KIALI_IP}:${KIALI_PORT}
  fi

  if [[ $KIBANA == "" ]]; then
    KIBANA="kibana.kube-logging.svc.cluster.local:5601"
  fi

  if [[ $KUBEFLOW == "" ]]; then
    KUBEFLOW="0.0.0.0"
  fi

  if [[ $GITLAB == "" ]]; then
    GITLAB=$(kubectl -n gitlab-system exec -t $(kubectl -n gitlab-system get pod | grep gitlab | awk '{print $1}') -- cat /tmp/shared/omnibus.env 2>/dev/null | grep -oP "external_url '\K[^']*(?=')")
    if [[ $GITLAB == "" ]]; then
        echo "Failed to find GITLAB URL, so GITLAB=http://0.0.0.0"
        GITLAB="http://0.0.0.0/"
    fi
  fi

  if [[ $HYPERREGISTRY == "" ]]; then
      echo "HYPERREGISTRY=http://0.0.0.0"
      HYPERREGISTRY="http://0.0.0.0/"
  fi
  
  # Inject ENV into yaml
  rm -rf $temp_Dir
  cp -r $file_Dir $temp_Dir
  
  sed -i "s%@@OPERATOR_VER@@%${OPERATOR_VER}%g" "${deploy_temp}"
  sed -i "s%@@CONSOLE_VER@@%${CONSOLE_VER}%g" "${deploy_temp}"

  sed -i "s%@@CLIENTID@@%${CLIENTID}%g" "${deploy_temp}"
  sed -i "s%@@KEYCLOAK@@%${KEYCLOAK}%g" "${deploy_temp}"
  sed -i "s%@@REALM@@%${REALM}%g" "${deploy_temp}"

  sed -i "s%@@MC_MODE@@%${MC_MODE}%g" "${deploy_temp}"

  sed -i "s%@@KIALI@@%${KIALI}%g" "${deploy_temp}"
  sed -i "s%@@KIBANA@@%${KIBANA}%g" "${deploy_temp}"
  sed -i "s%@@KUBEFLOW@@%${KUBEFLOW}%g" "${deploy_temp}"
  sed -i "s%@@GITLAB@@%${GITLAB}%g" "${deploy_temp}"
  sed -i "s%@@HYPERREGISTRY@@%${HYPERREGISTRY}%g" "${deploy_temp}"

  if [[ "$REGISTRY" != "" ]]; then
    sed -i "s%docker.io%$REGISTRY/docker.io%g" "${job_temp}"
    sed -i "s%tmaxcloudck/hypercloud%$REGISTRY/tmaxcloudck/hypercloud%g" "${deploy_temp}"
    sed -i "s%tmaxcloudck/console%$REGISTRY/tmaxcloudck/console%g" "${deploy_temp}"
  fi

  if [[ "$RELEASE_MODE" == "false" ]]; then
  sed -i -r -e "/- gateway/a\            - --release-mode=false" "${deploy_temp}"
  fi

  echo ""
  echo "=========================================================================="
  echo "STEP 2. Install Console"
  echo "=========================================================================="
  # Create CRD
  kubectl apply -f "${crd_temp}" "$kubectl_opt"
  # Create NS, SA, CRB, CR
  kubectl apply -f "${init_temp}" "$kubectl_opt"
  # Create TLS Secret
  kubectl apply -f "${job_temp}" "$kubectl_opt"
  # Create Service (Load-Balancer Type)
  kubectl apply -f "${svc_temp}" "$kubectl_opt"
  # Create Deploy
  kubectl apply -f "${deploy_temp}" "$kubectl_opt"

  echo ""
  echo "=========================================================================="
  echo "STEP 3. Verifying for running Console"
  echo "=========================================================================="
  NAMESPACE="console-system"
  TRIAL=1
  while true; do
    echo "Trial $TRIAL..."
    sleep 3s
    TRIAL=$((TRIAL+1))
    kubectl -n "${NAMESPACE}" get po -l app=console
    RUNNING_FLAG=$(kubectl get po -n ${NAMESPACE} -l app=console | grep console | awk '{print $3}')
    if [[ ${RUNNING_FLAG} == "Running" ]]; then
      echo  "========================================================================="
      echo  "=======================  Successfully Installed Console ================="
      echo  "========================================================================="
      URL=$(kubectl get svc -n "${NAMESPACE}" | awk '{print $4}' | tail -1)
      echo " Access URL is ${URL}"
      break
    elif [[ ${TRIAL} == 20 ]]; then
      echo "Failed to Install Console, Something is wrong"
      break
    fi
  done
}

function uninstall(){
  echo  "========================================================================="
  echo  "======================  Start Uninstalling Console ======================"
  echo  "========================================================================="

  kubectl delete namespace console-system "$kubectl_opt"

  echo  "========================================================================="
  echo  "===================  Successfully Uninstalled Console ==================="
  echo  "========================================================================="
}

function main(){
  case "${1:-}" in
    install)
      install
      ;;
    uninstall)
      uninstall
      ;;
    prepare-online)
      prepare_online
      ;;
    prepare-offline)
      prepare_offline
      ;;
    *)
      echo "Usage: $0 [install|uninstall|prepare-online|prepare-offline]"
      ;;
  esac
}

main "$1"

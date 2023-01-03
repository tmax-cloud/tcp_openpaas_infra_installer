#!/bin/bash


#install hyperauth
source ./k8s.config
set -x
SCRIPTDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
HYPERAUTH_HOME=$SCRIPTDIR/yaml/hyperauth

pushd $HYPERAUTH_HOME

  sed -i 's/POSTGRES_VERSION/'${POSTGRES_VERSION}'/g' 1.initialization.yaml
  sed -i 's/HYPERAUTH_VERSION/'${HYPERAUTH_VERSION}'/g' 3.hyperauth_deployment.yaml
  
  # step0 install yum, cert-manager v1.5.4 & tmaxcloud-ca clusterissuer
  wget https://github.com/mikefarah/yq/releases/download/v4.5.0/yq_linux_amd64 -O /usr/bin/yq &&
  chmod +x /usr/bin/yq
  wget https://cbs.centos.org/kojifiles/packages/sshpass/1.06/8.el8/x86_64/sshpass-1.06-8.el8.x86_64.rpm
  dnf install -y ./sshpass-1.06-8.el8.x86_64.rpm
  kubectl apply -f https://github.com/jetstack/cert-manager/releases/download/v1.5.4/cert-manager.yaml
  timeout 1m kubectl -n cert-manager rollout status deployment/cert-manager-webhook
  sleep 20
  kubectl apply -f tmaxcloud-issuer.yaml

  # step1 1.initialization.yaml
  kubectl patch storageclass csi-cephfs-sc -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
  kubectl apply -f 1.initialization.yaml
  sleep 60

  # step2 Generate Certs for hyperauth
  export ip=`kubectl get node -owide | awk '{print $6}' | sed -n 2p`
  sed -i 's/HYPERAUTH_EXTERNAL_IP/'$ip'/g' 2.hyperauth_certs.yaml
  kubectl apply -f 2.hyperauth_certs.yaml
  sleep 20

  kubectl get secret hyperauth-https-secret -n hyperauth -o jsonpath="{['data']['tls\.crt']}" | base64 -d > /etc/kubernetes/pki/hyperauth.crt
  kubectl get secret hyperauth-https-secret -n hyperauth -o jsonpath="{['data']['ca\.crt']}" | base64 -d > /etc/kubernetes/pki/hypercloud-root-ca.crt


  ## send Certs to Another Master Node
  IFS=' ' read -r -a masters <<< $(kubectl get nodes --selector=node-role.kubernetes.io/master -o jsonpath='{$.items[*].status.addresses[?(@.type=="InternalIP")].address}')
  for master in "${masters[@]}"
  do
      if [ $master == $MAIN_MASTER_IP ]; then
      continue
      fi
      sshpass -p "$MASTER_NODE_ROOT_PASSWORD" scp hypercloud-root-ca.crt ${MASTER_NODE_ROOT_USER}@"$master":/etc/kubernetes/pki/hypercloud-root-ca.crt
      sshpass -p "$MASTER_NODE_ROOT_PASSWORD" scp hyperauth.crt ${MASTER_NODE_ROOT_USER}@"$master":/etc/kubernetes/pki/hyperauth.crt

  done

  # step3 Hyperauth Deploymennt
  kubectl apply -f 3.hyperauth_deployment.yaml


  # step5 oidc with kubernetes ( modify kubernetes api-server manifest )
  cp /etc/kubernetes/manifests/kube-apiserver.yaml .
  yq e '.spec.containers[0].command += "--oidc-issuer-url=https://'$ip':31301/auth/realms/tmax"' -i ./kube-apiserver.yaml
  yq e '.spec.containers[0].command += "--oidc-client-id=hypercloud5"' -i ./kube-apiserver.yaml
  yq e '.spec.containers[0].command += "--oidc-username-claim=preferred_username"' -i ./kube-apiserver.yaml
  yq e '.spec.containers[0].command += "--oidc-username-prefix=-"' -i ./kube-apiserver.yaml
  yq e '.spec.containers[0].command += "--oidc-groups-claim=group"' -i ./kube-apiserver.yaml
  yq e '.spec.containers[0].command += "--oidc-ca-file=/etc/kubernetes/pki/hypercloud-root-ca.crt"' -i ./kube-apiserver.yaml
  mv -f ./kube-apiserver.yaml /etc/kubernetes/manifests/kube-apiserver.yaml
    
  set +xe
  for ((i=0; i<31; i++))
  do
    kubectl wait  --for=condition=ready pod --timeout=-3m -l component=kube-apiserver -n kube-system
    is_success=`echo $?`
    if [ $is_success == 0 ]; then
      break
    elif [ $i == 30 ]; then
      echo "Timeout Error"
      exit 1
    else
      echo "Waiting for kube-apiserver pod to be ready"
      sleep 10s
    fi
  done
  echo "kube-apiserver pod is ready"
  set -x

popd

#install hypercloud-api-server
#!/bin/bash
HYPERCLOUD_API_SERVER_HOME=$SCRIPTDIR/yaml/hypercloud-api-server
source $SCRIPTDIR/k8s.config
KA_YAML=`sudo yq e '.spec.containers[0].command' /etc/kubernetes/manifests/kube-apiserver.yaml`
HYPERAUTH_URL=`echo "${KA_YAML#*--oidc-issuer-url=}" | tr -d '\12' | cut -d '-' -f1`
set -xe

# Check if namespace exists
if [ -z "$(kubectl get ns | grep hypercloud5-system | awk '{print $1}')" ]; then
   kubectl create ns hypercloud5-system
fi

# step 1  - create pki and secret
if [ -z "$(kubectl get cm -n hypercloud5-system | grep html-config | awk '{print $1}')" ]; then
  sudo chmod +777 $HYPERCLOUD_API_SERVER_HOME/html/cluster-invitation.html
  kubectl create configmap html-config --from-file=$HYPERCLOUD_API_SERVER_HOME/html/cluster-invitation.html -n hypercloud5-system
fi

if [ -z "$(kubectl get secret -n hypercloud5-system | grep hypercloud-kafka-secret | awk '{print $1}')"]; then
  pushd $HYPERCLOUD_API_SERVER_HOME
    kubectl apply -f  kafka-secret.yaml
  popd
fi

# step 2  - sed manifests
if [ $REGISTRY != "{REGISTRY}" ]; then
  sudo sed -i 's#tmaxcloudck/hypercloud-api-server#'${REGISTRY}'/tmaxcloudck/hypercloud-api-server#g' ${HYPERCLOUD_API_SERVER_HOME}/03_hypercloud-api-server.yaml
  sudo sed -i 's#tmaxcloudck/timescaledb-cron#'${REGISTRY}'/tmaxcloudck/timescaledb-cron#g' ${HYPERCLOUD_API_SERVER_HOME}/02_timescaledb-create.yaml
fi
sudo sed -i 's/{HPCD_API_SERVER_VERSION}/b'${HPCD_API_SERVER_VERSION}'/g'  ${HYPERCLOUD_API_SERVER_HOME}/03_hypercloud-api-server.yaml
sudo sed -i 's/{HPCD_MODE}/'${HPCD_MODE}'/g'  ${HYPERCLOUD_API_SERVER_HOME}/03_hypercloud-api-server.yaml
sudo sed -i 's/{HPCD_TIMESCALEDB_VERSION}/b'${HPCD_TIMESCALEDB_VERSION}'/g'  ${HYPERCLOUD_API_SERVER_HOME}/02_timescaledb-create.yaml
sudo sed -i 's/{KAFKA_ENABLED}/'${KAFKA_ENABLED}'/g' ${HYPERCLOUD_API_SERVER_HOME}/03_hypercloud-api-server.yaml
sudo sed -i 's/{KAFKA_GROUP_ID}/'hypercloud-api-server-$HOSTNAME-$(($RANDOM%100))'/g' ${HYPERCLOUD_API_SERVER_HOME}/03_hypercloud-api-server.yaml
sudo sed -i 's#{HYPERAUTH_URL}#'${HYPERAUTH_URL}'#g'  ${HYPERCLOUD_API_SERVER_HOME}/01_init.yaml
sudo sed -i 's/{API_SERVER_LOG_LEVEL}/'${API_SERVER_LOG_LEVEL}'/g'  ${HYPERCLOUD_API_SERVER_HOME}/03_hypercloud-api-server.yaml
sudo sed -i 's/{TIMESCALEDB_LOG_LEVEL}/'${TIMESCALEDB_LOG_LEVEL}'/g'  ${HYPERCLOUD_API_SERVER_HOME}/02_timescaledb-create.yaml

# step 3  - apply manifests
pushd $HYPERCLOUD_API_SERVER_HOME
  kubectl apply -f  01_init.yaml
  kubectl apply -f  02_timescaledb-create.yaml
  kubectl apply -f  03_hypercloud-api-server.yaml
  kubectl apply -f  04_default-role.yaml
popd

# waiting for running hypercloud-api-server correctly
timeout 3m kubectl -n hypercloud5-system rollout status deployment/hypercloud5-api-server

#  step 4 - create and apply config
pushd $HYPERCLOUD_API_SERVER_HOME/config
  sudo chmod +x *.sh
  sudo ./gen-audit-config.sh
  sudo cp audit-policy.yaml /etc/kubernetes/pki/
  sudo cp audit-webhook-config /etc/kubernetes/pki/
  kubectl apply -f webhook-configuration.yaml
popd
#  step 5 - modify kubernetes api-server manifest
sudo cp /etc/kubernetes/manifests/kube-apiserver.yaml .
sudo yq e '.spec.containers[0].command += "--audit-webhook-mode=batch"' -i ./kube-apiserver.yaml
sudo yq e '.spec.containers[0].command += "--audit-policy-file=/etc/kubernetes/pki/audit-policy.yaml"' -i ./kube-apiserver.yaml
sudo yq e '.spec.containers[0].command += "--audit-webhook-config-file=/etc/kubernetes/pki/audit-webhook-config"' -i ./kube-apiserver.yaml
sudo yq e 'del(.spec.dnsPolicy)' -i kube-apiserver.yaml
sudo yq e '.spec.dnsPolicy += "ClusterFirstWithHostNet"' -i kube-apiserver.yaml
sudo mv -f ./kube-apiserver.yaml /etc/kubernetes/manifests/kube-apiserver.yaml

# waiting for running kube-api-server correctly
set +xe
for ((i=0; i<31; i++))
do
  kubectl wait  --for=condition=ready pod --timeout=-3m -l component=kube-apiserver -n kube-system
  is_success=`echo $?`
  if [ $is_success == 0 ]; then
    break
  elif [ $i == 30 ]; then
    echo "Timeout Error"
    exit 1
  else
    echo "Waiting for kube-apiserver pod to be ready"
    sleep 10s
  fi
done
echo "kube-apiserver pod is ready"
set -x

## install api-gateway
GATEWAY_HOME=$SCRIPTDIR/yaml/gateway
kubectl apply -f ${GATEWAY_HOME}/0.crds
kubectl apply -f ${GATEWAY_HOME}/1.ns.yaml
kubectl apply -f ${GATEWAY_HOME}/2.gateway.yaml
kubectl apply -f ${GATEWAY_HOME}/3.ingressroute.yaml

### script to install hypercloud-console
HYPERAUTH_IP=$ip:31301
CONSOLE_HOME=$SCRIPTDIR/yaml/console
sudo sed -i 's/{HYPERAUTH_IP}/'${HYPERAUTH_IP}'/g' ${CONSOLE_HOME}/console.config
${CONSOLE_HOME}/installer.sh install
sudo sed -i 's/'${HYPERAUTH_IP}'/{HYPERAUTH_IP}/g' ${CONSOLE_HOME}/console.config
# sudo sed -i 's#{HYPERAUTH_IP}#'${HYPERAUTH_IP}'#g'  ${CONSOLE_HOME}/console.config
# ${CONSOLE_HOME}/installer.sh install
# sudo sed -i 's'${HYPERAUTH_IP}'##{HYPERAUTH_IP}#g'  ${CONSOLE_HOME}/console.config



### install ingressroute for reverse proxy of hypercloud-api-server 
cd ..

### end of installing hypercloud-console

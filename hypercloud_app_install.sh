#!/bin/bash


#install hyperauth
source k8s.config
set -x
SCRIPTDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
HYPERAUTH_HOME=$SCRIPTDIR/yaml/hyperauth

pushd $HYPERAUTH_HOME

  sed -i 's/POSTGRES_VERSION/'${POSTGRES_VERSION}'/g' 1.initialization.yaml
  sed -i 's/HYPERAUTH_VERSION/'${HYPERAUTH_VERSION}'/g' 3.hyperauth_deployment.yaml

  # step0 install cert-manager v1.5.4 & tmaxcloud-ca clusterissuer
  wget https://cbs.centos.org/kojifiles/packages/sshpass/1.06/8.el8/x86_64/sshpass-1.06-8.el8.x86_64.rpm
  dnf install -y ./sshpass-1.06-8.el8.x86_64.rpm
  kubectl apply -f https://github.com/jetstack/cert-manager/releases/download/v1.5.4/cert-manager.yaml
  sleep 20
  kubectl apply -f tmaxcloud-issuer.yaml

  # step1 1.initialization.yaml
  kubectl apply -f 1.initialization.yaml
  sleep 60

  # step2 Generate Certs for hyperauth
  export ip=`kubectl get node -owide | awk '{print $6}' | sed -n 2p`
  sed -i 's/HYPERAUTH_EXTERNAL_IP/'$ip'/g' 2.hyperauth_certs.yaml
  kubectl apply -f 2.hyperauth_certs.yaml
  sleep 5

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
  mv -f ./kube-apiserver.yaml /etc/kubernetes/manifests/kube-apiserver.yaml

popd

#install hypercloud-operator
#!/bin/bash
HYPERCLOUD_API_SERVER_HOME=$SCRIPTDIR/yaml/hypercloud-api-server
HYPERCLOUD_SINGLE_OPERATOR_HOME=$SCRIPTDIR/yaml/hypercloud-single-operator
HYPERCLOUD_MULTI_OPERATOR_HOME=$SCRIPTDIR/yaml/hypercloud-multi-operator
HYPERCLOUD_MULTI_AGENT_HOME=$SCRIPTDIR/yaml/hypercloud-multi-agent
source $SCRIPTDIR/k8s.config
KUSTOMIZE_VERSION=${KUSTOMIZE_VERSION:-"v3.8.5"}
YQ_VERSION=${YQ_VERSION:-"v4.5.0"}
INGRESS_DNSURL="hypercloud5-api-server-service.hypercloud5-system.svc/audit"
INGRESS_IPADDR=$(kubectl get svc ingress-nginx-shared-controller -n ingress-nginx-shared -o jsonpath='{.status.loadBalancer.ingress[0:].ip}')
INGRESS_SVCURL="hypercloud5-api-server-service."${INGRESS_IPADDR}".nip.io"
KA_YAML=`sudo yq e '.spec.containers[0].command' /etc/kubernetes/manifests/kube-apiserver.yaml`
HYPERAUTH_URL=`echo "${KA_YAML#*--oidc-issuer-url=}" | tr -d '\12' | cut -d '-' -f1`
set -xe

# Check if namespace exists
if [ -z "$(kubectl get ns | grep hypercloud5-system | awk '{print $1}')" ]; then
   kubectl create ns hypercloud5-system
fi

# Install hypercloud-single-server
pushd $HYPERCLOUD_SINGLE_OPERATOR_HOME
  if [ $REGISTRY != "{REGISTRY}" ]; then
    sudo sed -i 's#tmaxcloudck/hypercloud-single-operator#'${REGISTRY}'/tmaxcloudck/hypercloud-single-operator#g' hypercloud-single-operator-v${HPCD_SINGLE_OPERATOR_VERSION}.yaml
    sudo sed -i 's#gcr.io/kubebuilder/kube-rbac-proxy#'${REGISTRY}'/gcr.io/kubebuilder/kube-rbac-proxy#g' hypercloud-single-operator-v${HPCD_SINGLE_OPERATOR_VERSION}.yaml
  fi
  kubectl apply -f  hypercloud-single-operator-v${HPCD_SINGLE_OPERATOR_VERSION}.yaml
popd

# Install hypercloud-api-server
# step 1  - create pki and secret
if [ ! -f "$HYPERCLOUD_API_SERVER_HOME/pki/hypercloud-api-server.crt" ] || [ ! -f "$HYPERCLOUD_API_SERVER_HOME/pki/hypercloud-api-server.key" ]; then
pushd $HYPERCLOUD_API_SERVER_HOME/pki
  sudo chmod +x *.sh
  sudo touch ~/.rnd
  sudo ./generateTls.sh -name=hypercloud-api-server -dns=hypercloud5-api-server-service.hypercloud5-system.svc -dns=hypercloud5-api-server-service.hypercloud5-system.svc.cluster.local
  sudo chmod +777 hypercloud-api-server.*
  if [ -z "$(kubectl get secret hypercloud5-api-server-certs -n hypercloud5-system | awk '{print $1}')" ]; then
    kubectl -n hypercloud5-system create secret generic hypercloud5-api-server-certs \
    --from-file=$HYPERCLOUD_API_SERVER_HOME/pki/hypercloud-api-server.crt \
    --from-file=$HYPERCLOUD_API_SERVER_HOME/pki/hypercloud-api-server.key
  else
    kubectl -n hypercloud5-system delete secret  hypercloud5-api-server-certs
    kubectl -n hypercloud5-system create secret generic hypercloud5-api-server-certs \
    --from-file=$HYPERCLOUD_API_SERVER_HOME/pki/hypercloud-api-server.crt \
    --from-file=$HYPERCLOUD_API_SERVER_HOME/pki/hypercloud-api-server.key
  fi
popd
fi

if [ -z "$(kubectl get cm -n hypercloud5-system | grep html-config | awk '{print $1}')" ]; then
  sudo chmod +777 $HYPERCLOUD_API_SERVER_HOME/html/cluster-invitation.html
  kubectl create configmap html-config --from-file=$HYPERCLOUD_API_SERVER_HOME/html/cluster-invitation.html -n hypercloud5-system
fi

if [ -z "$(kubectl get secret -n hypercloud5-system | grep hypercloud-kafka-secret | awk '{print $1}')"]; then
  sudo cp /etc/kubernetes/pki/hypercloud-root-ca.crt $HYPERCLOUD_API_SERVER_HOME/pki/
  sudo chmod +777 $HYPERCLOUD_API_SERVER_HOME/pki/hypercloud-root-ca.crt
  sudo chmod +777 $HYPERCLOUD_API_SERVER_HOME/pki/hypercloud-api-server.*
  kubectl -n hypercloud5-system create secret generic hypercloud-kafka-secret \
  --from-file=$HYPERCLOUD_API_SERVER_HOME/pki/hypercloud-root-ca.crt \
  --from-file=$HYPERCLOUD_API_SERVER_HOME/pki/hypercloud-api-server.crt \
  --from-file=$HYPERCLOUD_API_SERVER_HOME/pki/hypercloud-api-server.key
fi

# step 2  - sed manifests
if [ $REGISTRY != "{REGISTRY}" ]; then
  sudo sed -i 's#tmaxcloudck/hypercloud-api-server#'${REGISTRY}'/tmaxcloudck/hypercloud-api-server#g' ${HYPERCLOUD_API_SERVER_HOME}/03_hypercloud-api-server.yaml
  sudo sed -i 's#tmaxcloudck/postgres-cron#'${REGISTRY}'/tmaxcloudck/postgres-cron#g' ${HYPERCLOUD_API_SERVER_HOME}/02_postgres-create.yaml
fi
if [ $KAFKA1_ADDR != "{KAFKA1_ADDR}" ] && [ $KAFKA2_ADDR != "{KAFKA2_ADDR}" ] && [ $KAFKA3_ADDR != "{KAFKA3_ADDR}" ]; then
  sudo sed -i 's/{KAFKA1_ADDR}/'${KAFKA1_ADDR}'/g'  ${HYPERCLOUD_API_SERVER_HOME}/03_hypercloud-api-server.yaml
  sudo sed -i 's/{KAFKA2_ADDR}/'${KAFKA2_ADDR}'/g'  ${HYPERCLOUD_API_SERVER_HOME}/03_hypercloud-api-server.yaml
  sudo sed -i 's/{KAFKA3_ADDR}/'${KAFKA3_ADDR}'/g'  ${HYPERCLOUD_API_SERVER_HOME}/03_hypercloud-api-server.yaml
else
  sudo sed -i 's/{KAFKA1_ADDR}/'DNS'/g'  ${HYPERCLOUD_API_SERVER_HOME}/03_hypercloud-api-server.yaml
  sudo sed -i 's/{KAFKA2_ADDR}/'DNS'/g'  ${HYPERCLOUD_API_SERVER_HOME}/03_hypercloud-api-server.yaml
  sudo sed -i 's/{KAFKA3_ADDR}/'DNS'/g'  ${HYPERCLOUD_API_SERVER_HOME}/03_hypercloud-api-server.yaml
fi
sudo sed -i 's/{HPCD_API_SERVER_VERSION}/b'${HPCD_API_SERVER_VERSION}'/g'  ${HYPERCLOUD_API_SERVER_HOME}/03_hypercloud-api-server.yaml
sudo sed -i 's/{HPCD_MODE}/'${HPCD_MODE}'/g'  ${HYPERCLOUD_API_SERVER_HOME}/03_hypercloud-api-server.yaml
sudo sed -i 's/{HPCD_POSTGRES_VERSION}/b'${HPCD_POSTGRES_VERSION}'/g'  ${HYPERCLOUD_API_SERVER_HOME}/02_postgres-create.yaml
sudo sed -i 's/{INVITATION_TOKEN_EXPIRED_DATE}/'${INVITATION_TOKEN_EXPIRED_DATE}'/g'  ${HYPERCLOUD_API_SERVER_HOME}/02_postgres-create.yaml
sudo sed -i 's/{INVITATION_TOKEN_EXPIRED_DATE}/'${INVITATION_TOKEN_EXPIRED_DATE}'/g'  ${HYPERCLOUD_API_SERVER_HOME}/03_hypercloud-api-server.yaml
sudo sed -i 's/{KAFKA_GROUP_ID}/'hypercloud-api-server-$HOSTNAME-$(($RANDOM%100))'/g' ${HYPERCLOUD_API_SERVER_HOME}/03_hypercloud-api-server.yaml
sudo sed -i 's#{INGRESS_SVCURL}#'${INGRESS_SVCURL}'#g' ${HYPERCLOUD_API_SERVER_HOME}/03_hypercloud-api-server.yaml
sudo sed -i 's#{HYPERAUTH_URL}#'${HYPERAUTH_URL}'#g'  ${HYPERCLOUD_API_SERVER_HOME}/01_init.yaml

# step 3  - apply manifests
pushd $HYPERCLOUD_API_SERVER_HOME
  kubectl apply -f  01_init.yaml
  kubectl apply -f  02_postgres-create.yaml
  kubectl apply -f  03_hypercloud-api-server.yaml
  kubectl apply -f  04_default-role.yaml
popd

#  step 4 - create and apply config
pushd $HYPERCLOUD_API_SERVER_HOME/config
  sudo chmod +x *.sh
  sudo ./gen-audit-config.sh
  sudo ./gen-webhook-config.sh
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

#Install hypercloud-multi-server
if [ $HPCD_MODE == "multi" ]; then
pushd $HYPERCLOUD_MULTI_OPERATOR_HOME

# step 1 - put oidc, audit configuration to cluster-template yaml file
# oidc configuration
  sed -i 's#${HYPERAUTH_URL}#'${HYPERAUTH_URL}'#g' ./capi-*-template-v${HPCD_MULTI_OPERATOR_VERSION}.yaml
# audit configuration
  FILE=("hyperauth.crt" "audit-webhook-config" "audit-policy.yaml")
  PARAM=("\${HYPERAUTH_CERT}" "\${AUDIT_WEBHOOK_CONFIG}" "\${AUDIT_POLICY}")
  for i in ${!FILE[*]}
  do
    sudo awk '{print "          " $0}' /etc/kubernetes/pki/${FILE[$i]} > ./${FILE[$i]}
    sudo sed -e '/'${PARAM[$i]}'/r ./'${FILE[$i]}'' -e '/'${PARAM[$i]}'/d' -i ./capi-*-template-v${HPCD_MULTI_OPERATOR_VERSION}.yaml
    rm -f ./${FILE[$i]}
  done
  sed -i 's#'${INGRESS_DNSURL}'#'${INGRESS_SVCURL}'\/audit\/${Namespace}\/${clusterName}#g' ./capi-*-template-v${HPCD_MULTI_OPERATOR_VERSION}.yaml

# step 2 - install hypercloud multi operator
  if [ $REGISTRY != "{REGISTRY}" ]; then
    sudo sed -i 's#tmaxcloudck/hypercloud-multi-operator#'${REGISTRY}'/tmaxcloudck/hypercloud-multi-operator#g' hypercloud-multi-operator-v${HPCD_MULTI_OPERATOR_VERSION}.yaml
    sudo sed -i 's#gcr.io/kubebuilder/kube-rbac-proxy#'${REGISTRY}'/gcr.io/kubebuilder/kube-rbac-proxy#g' hypercloud-multi-operator-v${HPCD_MULTI_OPERATOR_VERSION}.yaml
  fi
  kubectl apply -f hypercloud-multi-operator-v${HPCD_MULTI_OPERATOR_VERSION}.yaml

  for capi_provider_template in capi-*-template-v${HPCD_MULTI_OPERATOR_VERSION}.yaml
  do
      kubectl apply -f ${capi_provider_template}
  done
popd

pushd $HYPERCLOUD_MULTI_AGENT_HOME
  sudo sed -i 's/{HPCD_MULTI_AGENT_VERSION}/b'${HPCD_MULTI_AGENT_VERSION}'/g'  ${HYPERCLOUD_MULTI_AGENT_HOME}/03_federate-deployment.yaml
  if [ $REGISTRY != "{REGISTRY}" ]; then
    sudo sed -i 's#tmaxcloudck/hypercloud-multi-agent#'${REGISTRY}'/tmaxcloudck/hypercloud-multi-agent#g' ${HYPERCLOUD_MULTI_AGENT_HOME}/03_federate-deployment.yaml
  fi
  kubectl apply -f ${HYPERCLOUD_MULTI_AGENT_HOME}/01_federate-namespace.yaml
  kubectl apply -f ${HYPERCLOUD_MULTI_AGENT_HOME}/02_federate-clusterRoleBinding.yaml
  kubectl apply -f ${HYPERCLOUD_MULTI_AGENT_HOME}/03_federate-deployment.yaml
popd
fi

### script to install hypercloud-console
HYPERAUTH_IP="hyperauth.hyperauth.svc"
CONSOLE_HOME=$SCRIPTDIR/yaml/console/
sudo sed -i 's#{HYPERAUTH_IP}#'${HYPERAUTH_IP}'#g'  ${CONSOLE_HOME}/console.config
.${CONSOLE_HOME}/installer.sh install
sudo sed -i 's'${HYPERAUTH_IP}'##{HYPERAUTH_IP}#g'  ${CONSOLE_HOME}/console.config

cd ..

### end of installing hypercloud-console

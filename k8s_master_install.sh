#!/bin/bash

install_dir=$(dirname "$0")
. ${install_dir}/k8s.config

yaml_dir="${install_dir}/yaml"

sudo yum update -y
sudo yum install wget -y

#crio repo

if [[ -z ${crioVersion} ]]; then
  VERSION=1.17
else
  echo crio version
  VERSION=${crioVersion}
fi

sudo curl -L -o /etc/yum.repos.d/devel:kubic:libcontainers:stable.repo https://download.opensuse.org/repositories/devel:kubic:libcontainers:stable/CentOS_7/devel:kubic:libcontainers:stable.repo
sudo curl -L -o /etc/yum.repos.d/devel:kubic:libcontainers:stable:cri-o:${VERSION}.repo https://download.opensuse.org/repositories/devel:kubic:libcontainers:stable:cri-o:${VERSION}/CentOS_7/devel:kubic:libcontainers:stable:cri-o:${VERSION}.repo

#install crio
echo install crio
sudo yum -y install cri-o
systemctl enable crio
systemctl start crio

#remove cni0
rm -rf /etc/cni/net.d/*
sed -i 's/\"\/usr\/libexec\/cni\"/\"\/usr\/libexec\/cni\"\,\"\/opt\/cni\/bin\"/g' /etc/crio/crio.conf
systemctl restart crio

#disable firewall
systemctl stop firewalld
systemctl disable firewalld

#swapoff
swapoff -a
sed s/\\/dev\\/mapper\\/centos-swap/#\ \\/dev\\/mapper\\/centos-swap/g -i /etc/fstab

#selinux mode
setenforce 0
sed -i 's/^SELINUX=enforcing$/SELINUX=permissive/' /etc/selinux/config

#kubernetes repo
cat <<EOF > /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://packages.cloud.google.com/yum/repos/kubernetes-el7-x86_64
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://packages.cloud.google.com/yum/doc/yum-key.gpg https://packages.cloud.google.com/yum/doc/rpm-package-key.gpg
EOF

#install kubernetes
if [[ -z ${k8sVersion} ]]; then
  k8sVersion=1.17.6
else
  echo k8s version
  k8sVersion=${k8sVersion}
fi

echo install kubernetes
yum install -y kubeadm-${k8sVersion}-0 kubelet-${k8sVersion}-0 kubectl-${k8sVersion}-0
systemctl enable --now kubelet

#crio-kube set
modprobe overlay
modprobe br_netfilter

cat > /etc/sysctl.d/99-kubernetes-cri.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF

echo '1' > /proc/sys/net/ipv4/ip_forward
echo '1' > /proc/sys/net/bridge/bridge-nf-call-iptables

if [[ -z ${apiServer} ]]; then
  apiServer=127.0.0.1
else
  apiServer=${apiServer}
fi
if [[ -z ${podSubnet} ]]; then
  podSubnet=10.244.0.0/16
else
  podSubnet=${podSubnet}
fi

sed -i "s|{k8sVersion}|v${k8sVersion}|g" ${yaml_dir}/kubeadm-config.yaml
sed -i "s|{apiServer}|${apiServer}|g" ${yaml_dir}/kubeadm-config.yaml
sed -i "s|{podSubnet}|\"${podSubnet}\"|g" ${yaml_dir}/kubeadm-config.yaml

echo kube init
kubeadm init --config=${yaml_dir}/kubeadm-config.yaml

mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

#install calico
if [[ -z ${calicoVersion} ]]; then
  calicoVersion=3.13
  echo calicoVersion=3.13
  kubectl apply -f ${yaml_dir}/calico.yaml
else
  calicoVersion=${calicoVersion}
  kubectl apply -f https://docs.projectcalico.org/${calicoVersion}/manifests/calico.yaml
fi

#install kubevirt-operator
if [[ -z ${kubevirtVersion} ]]; then
  echo kubevirtVersion=0.27.0
  kubevirtVersion=0.27.0
  kubectl apply -f ${yaml_dir}/kubevirt-operator.yaml
  kubectl apply -f ${yaml_dir}/kubevirt-cr.yaml
else
  kubevirtVersion=${kubevirtVersion}
  kubectl apply -f https://github.com/kubevirt/kubevirt/releases/download/${kubevirtVersion}/kubevirt-operator.yaml
  kubectl apply -f https://github.com/kubevirt/kubevirt/releases/download/${kubevirtVersion}/kubevirt-cr.yaml  
fi

#install hyperauth
source k8s.config
set -x
SCRIPTDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
HYPERAUTH_HOME=$SCRIPTDIR/yaml/hyperauth

pushd $HYPERAUTH_HOME

  sed -i 's/POSTGRES_VERSION/'${POSTGRES_VERSION}'/g' 1.initialization.yaml
  sed -i 's/HYPERAUTH_VERSION/'${HYPERAUTH_VERSION}'/g' 3.hyperauth_deployment.yaml

  # step0 install cert-manager v1.5.4 & tmaxcloud-ca clusterissuer
  kubectl apply -f https://github.com/jetstack/cert-manager/releases/download/v1.5.4/cert-manager.yaml
  kubectl apply -f tmaxcloud-issuer.yaml

  # step1 1.initialization.yaml
  kubectl apply -f 1.initialization.yaml
  sleep 60

  # step2 Generate Certs for hyperauth
  export ip=`kubectl describe service hyperauth -n hyperauth | grep 'LoadBalancer Ingress' | cut -d ' ' -f7`
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
  yq e '.spec.containers[0].command += "--oidc-issuer-url=https://'$ip'/auth/realms/tmax"' -i ./kube-apiserver.yaml
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
#sudo yq e 'del(.spec.dnsPolicy)' -i kube-apiserver.yaml
#sudo yq e '.spec.dnsPolicy += "ClusterFirstWithHostNet"' -i kube-apiserver.yaml
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

CONSOLE_GIT_DIR="https://raw.githubusercontent.com/tmax-cloud/hypercloud-console/hc-release/"
CONSOLE_GIT_YAML_DIR=$CONSOLE_GIT_DIR"install-yaml/"
CONSOLE_GIT_TLS_DIR=$CONSOLE_GIT_DIR"tls/"

console_file_initialization="1.initialization.yaml"
console_file_initialization_temp="1.initialization-temp.yaml"
console_file_svc_lb="2.svc-lb.yaml"
console_file_svc_lb_temp="2.svc-lb-temp.yaml"
console_file_deployment_pod="3.deployment-pod.yaml"
console_file_deployment_pod_temp="3.deployment-pod-temp.yaml"

mkdir hypercloud-console
cd hypercloud-console

if [ -z $CONSOLE_VERSION ]; then
    CONSOLE_VERSION="1.1.26.0"
fi
echo "CONSOLE_VERSION = ${CONSOLE_VERSION}"

HC4_IP=$(kubectl get svc -A | grep hypercloud4-operator-service | awk '{print $4}')
HC4_PORT=$(kubectl get svc -A | grep hypercloud4-operator-service | awk '{print $6}' | awk 'match($0, ":"){print substr($0,1,RSTART-1)}')
if [ -z $HC4_IP ]; then 
    echo "Cannot find HC4_IP in hypercloud4-operator-service. Is hypercloud4 operator installed?"
    HC4_IP="0.0.0.0"
    HC4_PORT="28677"
    echo "HC4_IP dummy value temporarily set to $HC4_IP:$HC4_PORT."
fi 
HC4=${HC4_IP}:${HC4_PORT}
echo "Hypercloud Addr = ${HC4}"

PROM_IP=$(kubectl get svc -A | grep prometheus-k8s | awk '{print $4}')
PROM_PORT=$(kubectl get svc -A | grep prometheus-k8s | awk '{print $6}' | awk 'match($0, ":"){print substr($0,1,RSTART-1)}')
if [ -z $PROM_IP ]; then 
    echo "Cannot find PROMETHEUS_IP in prometheus-k8s. Is prometheus installed?"
    PROM_IP="0.0.0.0"
    PROM_PORT="9090"
    echo "PROMETHEUS_IP dummy value temporarily set to $PROM_IP:$PROM_PORT."
fi 
PROM=${PROM_IP}:${PROM_PORT}
echo "Prometheus Addr = ${PROM}"

wget $CONSOLE_GIT_YAML_DIR$console_file_initialization
wget $CONSOLE_GIT_YAML_DIR$console_file_svc_lb
wget $CONSOLE_GIT_YAML_DIR$console_file_deployment_pod

cp $console_file_initialization $console_file_initialization_temp
cp $console_file_svc_lb $console_file_svc_lb_temp
cp $console_file_deployment_pod $console_file_deployment_pod_temp

mkdir tls
cd tls
wget $CONSOLE_GIT_TLS_DIR"tls.crt"
wget $CONSOLE_GIT_TLS_DIR"tls.key"
cd ..

sed -i "s%@@NAME_NS@@%console-system%g" ${console_file_initialization_temp}
sed -i "s%@@NAME_NS@@%console-system%g" ${console_file_svc_lb_temp}
sed -i "s%@@NAME_NS@@%console-system%g" ${console_file_deployment_pod_temp}
sed -i "s%@@HC4@@%${HC4}%g" ${console_file_deployment_pod_temp}
sed -i "s%@@PROM@@%${PROM}%g" ${console_file_deployment_pod_temp}
sed -i "s%@@VER@@%${CONSOLE_VERSION}%g" ${console_file_deployment_pod_temp}
sed -i '/--hdc-mode=/d' ${console_file_deployment_pod_temp}
sed -i '/--tmaxcloud-portal=/d' ${console_file_deployment_pod_temp}

kubectl create -f ${console_file_initialization_temp}
kubectl create secret tls console-https-secret --cert=tls/tls.crt --key=tls/tls.key -n console-system
kubectl create -f ${console_file_svc_lb_temp}
kubectl create -f ${console_file_deployment_pod_temp}

count=0
stop=60 
while :
do
    sleep 1
    count=$(($count+1))
    echo "Waiting for $count sec(s)..."
    kubectl get po -n console-system
    RUNNING_FLAG=$(kubectl get po -n console-system | grep console | awk '{print $3}')
    if [ ${RUNNING_FLAG} == "Running" ]; then
        echo "Console has been successfully deployed."
        break 
    fi
    if [ $count -eq $stop ]; then 
        echo "It seems that something went wrong! Check the log."
        kubectl logs -n console-system $(kubectl get po -n console-system | grep console | awk '{print $1}') 
        break
    fi
done

cd ..

### end of installing hypercloud-console



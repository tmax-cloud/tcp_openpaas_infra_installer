#!/bin/bash

install_dir=$(dirname $(realpath $0))
. ${install_dir}/k8s.config

yaml_dir="${install_dir}/yaml"

if [[ -z ${calicoVersion} ]]; then
  calicoVersion=3.24.1
  echo calicoVersion=3.24.1
else
  calicoVersion=${calicoVersion}
fi

kubectl delete -f ${install_dir}/calico.yaml

kubeadm reset -f

sed -i "s|v${k8sVersion}|{k8sVersion}|g" ${yaml_dir}/kubeadm-config.yaml
sed -i "s|${apiServer}|{apiServer}|g" ${yaml_dir}/kubeadm-config.yaml
sed -i "s|\"${podSubnet}\"|{podSubnet}|g" ${yaml_dir}/kubeadm-config.yaml

rm -rf $HOME/.kube
rm -rf /etc/yum.repos.d/kubernetes.repo
rm -rf /etc/yum.repos.d/devel\:kubic\:libcontainers\:stable*

yum remove -y kubeadm kubelet kubectl

systemctl stop crio
systemctl disable crio
cd ${install_dir}/cri-o
make clean

rm -rf ${install_dir}/cri-o


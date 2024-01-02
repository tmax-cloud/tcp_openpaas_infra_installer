#!/bin/bash

install_dir=$(dirname $(realpath $0))
. ${install_dir}/k8s.config

yaml_dir="${install_dir}/yaml"

if [[ -z ${calicoVersion} ]]; then
  calicoVersion=3.27.0
  echo calicoVersion=3.27.0
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

systemctl stop containerd
ctr --namespace moby c rm $(sudo ctr --namespace moby c ls -q)
ctr --namespace moby i rm $(sudo ctr --namespace moby i ls -q)
rm -rf /var/lib/containerd/*
rm -rf /etc/containerd/*
systemctl disable containerd

#install cni plugin
if [[ -z ${cniVersion} ]]; then
  VERSION=1.4.0
else
  echo cni version
  VERSION=${cniVersion}
fi

cd ${install_dir}
rm -rf cni-plugins-linux-amd64-v${VERSION}.tgz
rm -rf /opt/cni/bin

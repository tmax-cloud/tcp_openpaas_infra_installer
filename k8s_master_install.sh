#!/bin/bash

install_dir=$(dirname "$0")
. ${install_dir}/k8s.config

yaml_dir="${install_dir}/yaml"

sudo yum update -y
sudo yum install wget -y

#crio repo

if [[ -z ${crioVersion} ]]; then
  VERSION=1.22
else
  echo crio version
  VERSION=${crioVersion}
fi

sudo curl -L -o /etc/yum.repos.d/devel:kubic:libcontainers:stable.repo https://download.opensuse.org/repositories/devel:kubic:libcontainers:stable/CentOS_8/devel:kubic:libcontainers:stable.repo
sudo curl -L -o /etc/yum.repos.d/devel:kubic:libcontainers:stable:cri-o:${VERSION}.repo https://download.opensuse.org/repositories/devel:kubic:libcontainers:stable:cri-o:${VERSION}/CentOS_8/devel:kubic:libcontainers:stable:cri-o:${VERSION}.repo

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
#sed s/\\/dev\\/mapper\\/centos-swap/#\ \\/dev\\/mapper\\/centos-swap/g -i /etc/fstab
sed s/\\/dev\\/mapper/#\\/dev\\/mapper/g -i /etc/fstab

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
  k8sVersion=1.22.2
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
  calicoVersion=3.20
  echo calicoVersion=3.20
  kubectl apply -f ${yaml_dir}/calico.yaml
else
  calicoVersion=${calicoVersion}
  kubectl apply -f https://docs.projectcalico.org/v${calicoVersion}/manifests/calico.yaml
fi


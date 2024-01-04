#!/bin/bash

install_dir=$(dirname $(realpath $0))
. ${install_dir}/k8s.config

yaml_dir="${install_dir}/yaml"

sudo yum update -y &&
sudo yum install wget -y &&

#kubernetes node prerequisites
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay &&
sudo modprobe br_netfilter &&

##sysctl params required by setup, params persist across reboots
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

##Apply sysctl params without reboot
sudo sysctl --system &&

#install containerd
echo install containerd &&

##set repository
yum install -y yum-utils &&
yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo &&

yum install -y containerd.io &&

#install cni plugin
if [[ -z ${cniPluginVersion} ]]; then
  VERSION=1.4.0
else
  echo cni version
  VERSION=${cniPluginVersion}
fi

yum install -y curl &&
curl -o ${install_dir}/cni-plugins-linux-amd64-v${VERSION}.tgz -L https://github.com/containernetworking/plugins/releases/download/v${VERSION}/cni-plugins-linux-amd64-v${VERSION}.tgz &&
mkdir -p /opt/cni/bin &&
tar Cxzvf /opt/cni/bin cni-plugins-linux-amd64-v${VERSION}.tgz &&

# setting containerd
containerd config default > /etc/containerd/config.toml &&
sed -i "s|SystemdCgroup = false|SystemdCgroup = true|" /etc/containerd/config.toml &&
sed -i "s|pause:3.6|pause:3.2|" /etc/containerd/config.toml &&

# restart containerd
systemctl restart containerd &&

#disable firewall
systemctl stop firewalld &&
systemctl disable firewalld &&

#swapoff
swapoff -a &&
sed -E 's@(^/dev/mapper/.* swap .*$)@#\1@g' -i /etc/fstab &&

#selinux mode
setenforce 0 &&
sed -i 's/^SELINUX=enforcing$/SELINUX=permissive/' /etc/selinux/config &&

#install kubernetes
if [[ -z ${k8sVersion} ]]; then
  k8sVersion=1.29.0
else
  echo k8s version
  k8sVersion=${k8sVersion}
fi

k8sMajor=$(echo ${k8sVersion} | awk -F'.' '{print $1"."$2}') &&

##kubernetes repo
cat <<EOF | sudo tee /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v${k8sMajor}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v${k8sMajor}/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF

echo install kubernetes
yum install -y kubelet kubeadm kubectl --disableexcludes=kubernetes &&
systemctl enable --now kubelet

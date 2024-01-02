#!/bin/bash

install_dir=$(dirname $(realpath $0))
. ${install_dir}/k8s.config

yaml_dir="${install_dir}/yaml"

sudo yum update -y
sudo yum install wget -y

#kubernetes node prerequisites
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter

##sysctl params required by setup, params persist across reboots
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

##Apply sysctl params without reboot
sudo sysctl --system

#install containerd
echo install containerd

##set repository
yum install -y yum-utils
yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo

yum install -y containerd.io

#install cni plugin
if [[ -z ${cniVersion} ]]; then
  VERSION=1.4.0
else
  echo cni version
  VERSION=${cniVersion}
fi

yum install -y curl
curl -o ${install_dir}/cni-plugins-linux-amd64-v${VERSION}.tgz -L https://github.com/containernetworking/plugins/releases/download/v${VERSION}/cni-plugins-linux-amd64-v${VERSION}.tgz
mkdir -p /opt/cni/bin
tar Cxzvf /opt/cni/bin cni-plugins-linux-amd64-v${VERSION}.tgz

# setting containerd
containerd config default > /etc/containerd/config.toml
sed -i "s|SystemdCgroup = false|SystemdCgroup = true|" /etc/containerd/config.toml
sed -i "s|pause:3.6|pause:3.2|" /etc/containerd/config.toml

# restart containerd
systemctl restart containerd

#disable firewall
systemctl stop firewalld
systemctl disable firewalld

#swapoff
swapoff -a
sed -E 's@(^/dev/mapper/.* swap .*$)@#\1@g' -i /etc/fstab

#selinux mode
setenforce 0
sed -i 's/^SELINUX=enforcing$/SELINUX=permissive/' /etc/selinux/config

#install kubernetes
if [[ -z ${k8sVersion} ]]; then
  k8sVersion=1.29.0
else
  echo k8s version
  k8sVersion=${k8sVersion}
fi

##kubernetes repo
cat <<EOF | sudo tee /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v${k8sVersion}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v${k8sVersion}/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF

echo install kubernetes
yum install -y kubelet kubeadm kubectl --disableexcludes=kubernetes
systemctl enable --now kubelet

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
  calicoVersion=3.27.0
  echo calicoVersion=3.27.0
else
  calicoVersion=${calicoVersion}
fi

curl https://raw.githubusercontent.com/projectcalico/calico/v${calicoVersion}/manifests/calico.yaml -o ${install_dir}/calico.yaml

sed -i "s|# - name: CALICO_IPV4POOL_CIDR|- name: CALICO_IPV4POOL_CIDR|g" ${install_dir}/calico.yaml
sed -i "s|#   value: \"192.168.0.0/16\"|  value: \""${podSubnet}"\"|g" ${install_dir}/calico.yaml
kubectl apply -f ${install_dir}/calico.yaml


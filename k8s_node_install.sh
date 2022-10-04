#!/bin/bash

install_dir=$(dirname $(realpath $0))
. ${install_dir}/k8s.config

yaml_dir="${install_dir}/yaml"

sudo yum update -y

#crio repo

if [[ -z ${crioVersion} ]]; then
  VERSION=1.25
else
  echo crio version
  VERSION=${crioVersion}
fi

sudo curl -L -o /etc/yum.repos.d/devel:kubic:libcontainers:stable.repo https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable/CentOS_8_Stream/devel:kubic:libcontainers:stable.repo
sudo curl -L -o /etc/yum.repos.d/devel:kubic:libcontainers:stable:cri-o:${VERSION}.repo https://download.opensuse.org/repositories/devel:kubic:libcontainers:stable:cri-o:${VERSION}/CentOS_8_Stream/devel:kubic:libcontainers:stable:cri-o:${VERSION}.repo

#CentOS 9 Repo

cat <<EOF > /etc/yum.repos.d/CentOS-9-Stream.repo
[CentOS-9-baseos]
name=CentOS - 9 - BaseOS
baseurl=https://rpmfind.net/linux/centos-stream/9-stream/BaseOS/x86_64/os/
enabled=1
gpgcheck=0

[CentOS-9-appstream]
name=CentOS - 9 - AppStream
baseurl=https://rpmfind.net/linux/centos-stream/9-stream/AppStream/x86_64/os/
enabled=1
gpgcheck=0

[CentOS-9-CRB]
name=CentOS - 9 - CRB
baseurl=http://rpmfind.net/linux/centos-stream/9-stream/CRB/x86_64/os/
enabled=1
gpgcheck=0
EOF

#install crio build and run dependencies
yum install -y \
  containers-common \
  device-mapper-devel \
  git \
  glib2-devel \
  glibc-devel \
  glibc-static \
  go \
  gpgme-devel \
  libassuan-devel \
  libgpg-error-devel \
  libseccomp-devel \
  libselinux-devel \
  pkgconf-pkg-config \
  make \
  runc \
  gcc

#get cri-o source
git clone https://github.com/cri-o/cri-o
cd ${install_dir}/cri-o
git checkout release-${crioVersion}

#build cri-o
make
sudo make install

sudo make install.config

#set systemd for cri-o
sudo make install.systemd
mkdir /var/lib/crio

# start cri-o
sudo systemctl daemon-reload
sudo systemctl enable crio
sudo systemctl start crio

#Set CNI plugin directory
sed -i "/Paths to directories where CNI plugin binaries are located/a\plugin_dirs = [\"/opt/cni/bin/\"]" /etc/crio/crio.conf
systemctl restart crio

#disable firewall
systemctl stop firewalld
systemctl disable firewalld

#swapoff
swapoff -a
sed -E 's@(^/dev/mapper/.* swap .*$)@#\1@g' -i /etc/fstab

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
  k8sVersion=1.25.0
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


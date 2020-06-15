#!/bin/bash

install_dir=$(dirname "$0")
. ${install_dir}/k8s.config

yaml_dir="${install_dir}/yaml"

kubectl delete -f ${yaml_dir}/calico.yaml
kubeadm delete -f ${yaml_dir}/kubevirt-cr.yaml
kubeadm delete -f ${yaml_dir}/kubevirt-operator.yaml

kubeadm reset -force



rm -rf $HOME/.kube
rm -rf /etc/yum.repos.d/kubernetes.repo
rm -rf /etc/yum.repos.d/devel\:kubic\:libcontainers\:stable*

yum remove -y kubeadm kubelet kubectl
yum remove -y crio

# TCP OpenPaaS

## TCP OpenPaaS Infra
### Prerequisites
- ProLinux 8.6
- Configure /etc/hosts for master and worker nodes

### Setup master node
Install Kubernetes, Containerd, Calico and TCP OpenPaaS
1. Download installer file in our repository
    ```
    git clone https://github.com/tmax-cloud//tcp_openpaas_infra_installer.git
    ```
2. Modify `k8s.config` to suit your environment
    * `cniPluginVersion` : cni plugin version
    * `k8sVersion` : kubeadm, kubelet, kubectl version
    * `apiServer` : The IP address the API Server will advertise it's listening on.
      * ex : apiServer={Kubernetes master IP}
      * ex : apiServer=172.22.5.2
    * `podSubnet` : Pod IPs will be chosen from this range. This should fall within `--cluster-cidr`.
      * ex : podSubnet={POD_IP_POOL}/{CIDR}
      * ex : podSubnet=10.244.0.0/16
    * `calicoVersion` : calico network plugin version(OPTIONAL)
      * If nothing is specified, the default version(v3.27.0) is installed.
      * ex : calicoVersion=3.27.0
3. Execute installer script
    ```
    ./k8s_master_install.sh
    ```
4.  Get the join command for worker node
    ```
    kubeadm token create --print-join-command
    ```
    You can get the result in this format:
    ```
    kubeadm join 192.168.122.50:6443 --token mnp5b8.u7tl2cruk73gh0zh     --discovery-token-ca-cert-hash sha256:662a697f67ecbb8b376898dcd5bf4df806249175ea4a90c2d3014be399c6c18a
    ```
5. If you create a single node Kubernetes cluster, you have to untaint the master node
    ```
    kubectl taint nodes --all node-role.kubernetes.io/master-
    ```
6. If the installation process fails, execute uninstaller script then installer script again
    ```
    ./k8s_uninstall.sh
    ./k8s_master_install.sh
    ```
### Setup worker nodes
Install Kubernetes and Containerd
1. Download installer file in our repository
    ```
    git clone https://github.com/tmax-cloud//tcp_openpaas_infra_installer.git
    ```
2. Modify `k8s.config` to suit your environment
    * `cniPluginVersion` : cni plugin version
    * `k8sVersion` : kubeadm, kubelet, kubectl version
3. Execute installer script
    ```
    ./k8s_node_install.sh
    ```
4. Execute the join command
    ```
    kubeadm join 192.168.122.50:6443 --token mnp5b8.u7tl2cruk73gh0zh     --discovery-token-ca-cert-hash sha256:662a697f67ecbb8b376898dcd5bf4df806249175ea4a90c2d3014be399c6c18a
    ```
5. If the installation process fails, execute uninstaller script then installer script again
    ```
    ./k8s_uninstall.sh
    ./k8s_node_install.sh
    ```

## TCP OpenPaaS NFS Storage
### Prerequisites

- All nodes in the k8s cluster require the  `nfs-utils` package to be installed

### Setup all nodes
Install nfs packages

1. install nfs-utils packages
    ```
    sudo yum install -y nfs-utils
    ``` 

### Setup master node
Install NFS-Server, NFS-Provisioning

1. Modify nfs_install.sh 

    - NFS_PATH : NFS directory path
        - ex : NFS_PATH=/mnt/nfs-shared-dir
    - If no directory is specified, the default path is /mnt/nfs-shared-dir

2. Execute NFS installer script

    ```
    ./nfs_install.sh
    ```

3. Enter Master Node IP after Execute NFS installer script

    ```
    ./nfs_install.sh
    Enter Master IP: ex)172.21.7.5
    ```

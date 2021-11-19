# HyperCloud

## HyperCloud Infra
### Prerequisites
- CentOS 8

### Setup master node
Install Kubernetes, CRI-O, Calico and HyperCloud
1. Download installer file in our repository
    ```
    git clone https://github.com/tmax-cloud/hypercloud_infra_installer.git
    ```
2. Modify `k8s.config` to suit your environment
    * `crioVersion` : cri-o runtime version
    * `k8sVersion` : kubeadm, kubelet, kubectl version
      * CRI-O major and minor versions must match Kubernetes major and minor versions.
      * ex : crioVersion=1.17 k8sVersion=1.17.6        
      * ex : crioVersion=1.18 k8sVersion=1.18.3
      * ex : crioVersion=1.19 k8sVersion=1.19.4
      * ex : crioVersion=1.22 k8sVersion=1.22.2
    * `apiServer` : The IP address the API Server will advertise it's listening on.
      * ex : apiServer={Kubernetes master IP}
      * ex : apiServer=172.22.5.2
    * `podSubnet` : Pod IPs will be chosen from this range. This should fall within `--cluster-cidr`.
      * ex : podSubnet={POD_IP_POOL}/{CIDR}
      * ex : podSubnet=10.244.0.0/16
    * `calicoVersion` : calico network plugin version(OPTIONAL)
      * If nothing is specified, the default version(v3.20) is installed.
      * ex : calicoVersion=3.20
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
Install Kubernetes and CRI-O
1. Download installer file in our repository
    ```
    git clone https://github.com/tmax-cloud/hypercloud_infra_installer.git
    ```
2. Modify `k8s.config` to suit your environment
    * `crioVersion` : cri-o runtime version
    * `k8sVersion` : kubeadm, kubelet, kubectl version
      * CRI-O major and minor versions must match Kubernetes major and minor versions.
      * ex : crioVersion=1.17 k8sVersion=1.17.6        
      * ex : crioVersion=1.18 k8sVersion=1.18.3
      * ex : crioVersion=1.19 k8sVersion=1.19.4
      * ex : crioVersion=1.22 k8sVersion=1.22.2
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
### Install HyperCloud application
Install hyperauth, hypercloud-operator, hypercloud-single-server, hypercloud-api-server and hypercloud-multi-server.
1. Execute installer script in master node
    ```
    ./hypercloud_app_install.sh
    ```
## HyperCloud Storage (hcsctl)

`hcsctl` provides installation, removal and management of HyperCloud Storage.

### Prerequisite

- kubectl (>= 1.17)
- kubernetes Cluster
- `lvm2` package (should be installed on storage node)

### Default installed version

- Rook-Ceph v1.4.2

### Getting Started

- Rook-Ceph yaml files are required to install hypercloud-storage. You can easily create them by using hcsctl.

   ``` shell
   $ hcsctl create-inventory {$inventory_name}
   # Ex) hcsctl create-inventory myInventory
   ```
- Then, a directory is created on the current path with the given inventory name. Inside of the inventory directory, a directory is created named as rook.
  - `./myInventory/rook/*.yaml` are yaml files for Rook-Ceph installation
- Please note that all the generated yamls are just for example. Go through each files and change values to suit your host environment
  - **Do not modify the name of folders and files.**
  - Take a look at [rook documentation](https://rook.github.io/docs/rook/v1.4/ceph-cluster-crd.html) before modify each fields under `./myInventory/rook/` path
- After modifying the inventory files to suit the environment, install hypercloud-storage with hcsctl
   ``` shell
   $ hcsctl install {$inventory_name}
   # Ex) hcsctl install myInventory
   ```
    - After installation is completed, you can use HyperCloud Block Storage and Shared Filesystem.
- Verify if hypercloud-storage is installed completely with `rook.test` command
    ``` shell
    $ rook.test
    ```
  - This command will execute various test cases to verify that hypercloud-storage is installed properly
  - It will take up to 15 minutes to complete the test


### Uninstall

- Remove hypercloud-storage with hcsctl. You need the same exact inventory name that you installed with hcsctl

    ``` shell
    $ hcsctl uninstall {$inventory_name}
    # Ex) hcsctl uninstall myInventory
    ```
    - You may need additional work to do depends on the message that is displayed when the uninstallation is completed to clean up remaining ceph related data

### Additional features

- In addition to installation and uninstallation, various additional functions are also provided with hcsctl for convenience

You can execute following ceph commands with hcsctl.

``` shell
$ hcsctl ceph status
$ hcsctl ceph exec {$ceph_cmd}
# Commands frequently used to check the status are as follows.
$ hcsctl ceph status
$ hcsctl ceph exec ceph osd status
$ hcsctl ceph exec ceph df
```

### Compatibility
- This project has been verified in the following versions.
    - Kubernetes
        - `kubectl` version compatible with each kubernetes server version is required.
        - v1.19
        - v1.18        
        - v1.17
        - v1.16
        - v1.15
    - OS
        - Ubuntu 18.04
        - CentOS 8.1, 7.7
        - ProLinux 7.5

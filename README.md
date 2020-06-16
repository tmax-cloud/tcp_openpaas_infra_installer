# hypercloud_infra_installer

## HyperCloud Storage(hcsctl)
`hcsctl` provides installation, removal and management of HyperCloud Storage.

### Prerequisite
- kubectl (>= 1.15)
- Fully-installed Kubernetes Cluster

### Getting Started
- Before installing hypercloud-storage with hcsctl, create yaml files is required for installation and change it to suit your environment.

   ``` shell
   $ hcsctl create-inventory {$inventory_name}
   # Ex) hcsctl create-inventory myInventory
   ```

- Two directories of rook and cdi are created in the created inventory. `./myInventory/rook/*.yaml` are yaml files used for Rook-Ceph installation, and `./myInventory/cdi/*.yaml` are yaml files used for KubeVirt-CDI installation.
- Since all the generated yaml files are for sample provision, you have to use the contents of each yaml file after **modifying to your environment**.<strong> Do not modify the folder and file name. </strong>
- Modify yaml contents created under `./myInventory/rook/` path to fit your environment. Refer to https://rook.github.io/docs/rook/v1.3/ceph-cluster-crd.html
- For yaml files created under the path `./myInventory/cdi/`, you need to change the version of `OPERATOR_VERSION` and container image in the `operator.yaml` file only if you need to change the KubeVirt-CDI version to install.


- After modifying the inventory files to suit the environment, install hypercloud-storage with hcsctl.
   ``` shell
   $ hcsctl install {$inventory_name}
   # Ex) hcsctl install myInventory
   ```

    - When installation is completed normally, you can use hypercloud-storage. After installation, you can use Block Storage and Shared Filesystem.


- Verify whether hypercloud-storage is properly installed with hcsctl.test.
    ``` shell
    $ hcsctl.test
    ```
    - To check whether hypercloud-storage can be used normally, various scenario tests are performed.

### Uninstall
- Remove hypercloud-storage by referring to inventory used when installing with hcsctl.
    ``` shell
    $ hcsctl uninstall {$inventory_name}
    # Ex) hcsctl uninstall myInventory
    ```
    - You need additional work by checking the message displayed after the removal is completed.

### Additional features
- In addition to basic installation and uninstallation, various additional functions are also provided for efficient use.

    You can run ceph with hcsctl.

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
        - v1.17
        - v1.16
        - v1.15
    - OS
        - Ubuntu 18.04
        - CentOS 8.1, 7.7
        - ProLinux 7.5
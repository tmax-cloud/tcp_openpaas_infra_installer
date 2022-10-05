#NFS Server install
install_dir=$(dirname "$0")

read -p "Enter Master IP: "  NFS_IP
NFS_PATH=/mnt/nfs-shared-dir

sudo dnf update -y
sudo dnf install nfs-utils -y

sudo systemctl enable nfs-server.service
sudo systemctl start nfs-server.service

sudo mkdir -p ${NFS_PATH}
#sudo chown -R root:root /mnt/nfs-shared-dir
sudo chmod 777 ${NFS_PATH}

#sudo tee /etc/exports

cat << EOF > /etc/exports
${NFS_PATH} *(rw,sync,no_subtree_check)
EOF

exportfs -a
showmount -e

#NFS Client Provisioner
NS=nfs
NAMESPACE=${NS:-nfs}

NFS_PATH=${NFS_PATH//'/'/'\/'}

#namespace
sudo sed -i'' "s/name:.*/name: $NAMESPACE/g" ${install_dir}/yaml/hypercloud-nfs-provisioning/namespace.yaml
sudo sed -i'' "s/namespace:.*/namespace: $NAMESPACE/g" ${install_dir}/yaml/hypercloud-nfs-provisioning/rbac.yaml ${install_dir}/yaml/hypercloud-nfs-provisioning/deployment.yaml

#NFS IP
sudo sed -i'' "32s/value:.*/value: ${NFS_IP}/g" ${install_dir}/yaml/hypercloud-nfs-provisioning/deployment.yaml

#NFS PATH
sudo sed -i "34s/value:.*/value: ${NFS_PATH}/g" ${install_dir}/yaml/hypercloud-nfs-provisioning/deployment.yaml

sudo sed -i'' "s/server:.*/server: ${NFS_IP}/g" ${install_dir}/yaml/hypercloud-nfs-provisioning/deployment.yaml
sudo sed -i'' "s/path:.*/path: ${NFS_PATH}/g" ${install_dir}/yaml/hypercloud-nfs-provisioning/deployment.yaml

kubectl apply -f ${install_dir}/yaml/hypercloud-nfs-provisioning/namespace.yaml
kubectl apply -f ${install_dir}/yaml/hypercloud-nfs-provisioning/rbac.yaml
kubectl apply -f ${install_dir}/yaml/hypercloud-nfs-provisioning/deployment.yaml
kubectl apply -f ${install_dir}/yaml/hypercloud-nfs-provisioning/class.yaml

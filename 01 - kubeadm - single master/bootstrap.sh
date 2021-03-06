#!/usr/bin/env bash

system_upgrade() {
  apt-get update
  apt-get dist-upgrade -y
}

install_docker() {
  apt-get update
  apt-get install -y apt-transport-https ca-certificates curl software-properties-common
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
  add-apt-repository \
    "deb [arch=amd64] https://download.docker.com/linux/ubuntu \
    $(lsb_release -cs) \
    stable"
  apt-get update && apt-get install -y docker-ce
  apt-mark hold docker-ce
  cat > /etc/docker/daemon.json <<EOF
  {
    "exec-opts": ["native.cgroupdriver=systemd"],
    "log-driver": "json-file",
    "log-opts": {
      "max-size": "100m"
    },
    "storage-driver": "overlay2"
  }
EOF

  mkdir -p /etc/systemd/system/docker.service.d
  systemctl daemon-reload
  systemctl restart docker
}

install_cni() {
  echo "Installing flannel."
  sysctl net.bridge.bridge-nf-call-iptables=1
  kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/a70459be0084506e4ec919aa1c114638878db11b/Documentation/kube-flannel.yml
}

install_k8s() {
  apt-get update && apt-get install -y apt-transport-https curl
  curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
  cat <<EOF >/etc/apt/sources.list.d/kubernetes.list
  deb https://apt.kubernetes.io/ kubernetes-xenial main
EOF
  apt-get update
  apt-get install -y kubelet kubeadm kubectl
  apt-mark hold kubelet kubeadm kubectl
  curl -sLo /usr/local/bin/stern https://github.com/wercker/stern/releases/download/1.10.0/stern_linux_amd64
  chmod +x /usr/local/bin/stern
}

init_k8s() {
  mkdir -p /vagrant/kubeadm/
  kubeadm config images pull
  kubeadm init --apiserver-advertise-address=192.168.0.43 --pod-network-cidr=10.244.0.0/16 | tee /vagrant/kubeadm/kubeadm_init_output

  mkdir -p $HOME/.kube
  cp -f /etc/kubernetes/admin.conf $HOME/.kube/config
  cp -f /etc/kubernetes/admin.conf /vagrant/kubeadm/kube_config
  chown $(id -u):$(id -g) $HOME/.kube/config

  install_cni
}

join_k8s() {
  sysctl net.bridge.bridge-nf-call-iptables=1
  echo "Joining worker..."
  while [ ! -f /vagrant/kubeadm/kubeadm_init_output ]; do
    echo "* /vagrant/kubeadm/kubeadm_init_output not present yet, sleeping 10..."
    sleep 10
  done
  grep "kubeadm join" /vagrant/kubeadm/kubeadm_init_output -A1 | sh -
  mkdir -p $HOME/.kube
  while [ ! -f /vagrant/kubeadm/kube_config ]; do
    echo "* /vagrant/kubeadm/kube_config not present yet, sleeping 10..."
    sleep 10
  done
  cp -f /vagrant/kubeadm/kube_config $HOME/.kube/config
  chown $(id -u):$(id -g) $HOME/.kube/config
  kubectl label node $1 node-role.kubernetes.io/worker=
}

bootstrap_master_single() {
  install_docker
  install_k8s
  init_k8s
}

bootstrap_worker() {
  install_docker
  install_k8s
  join_k8s $1
}

hostname=$(hostname)

system_upgrade

case "$hostname" in
  "master") bootstrap_master_single ;;
  worker*) bootstrap_worker $hostname ;;
  *) echo "No bootstrap assigned to this hostname"
esac

########################################
# Create and set up network components #
########################################
module "k8s-gcp-network" {
  source = "../gcp/network"
  compute_address_name = "k8s-the-hard-way-terraform"
  region = "${var.region}"
  network_name = "${var.network_name}"
  subnet_name = "${var.subnet_name}"
  subnet_cidr = "${var.subnet_cidr}"
  vpc_firewall_source_ranges = ["10.240.0.0/24","10.200.0.0/16"]
  vpc_firewall_allow_tcp_ports = ["22","6443"]
}

########################################
# Create and set up network components #
########################################
# Create k8s controllers
module "k8s-gcp-controllers" {
  source = "../gcp/compute"
  zone = "${var.zone}"
  subnet_name = "${var.subnet_name}"
  instances_count = "${var.k8s_controllers_qty}"
  root_ip = "10.240.0.1"
  machine_type = "n1-standard-1"
  name_base = "controller"
  image = "ubuntu-os-cloud/ubuntu-1604-lts"
  tags = ["kubernetes-the-hard-way-terraform","controller"]

  ## Waiting for the fix: https://github.com/hashicorp/terraform/issues/10462 to be able to set dependencies between modules. Our work around until this capability gets released is just run terraform apply 2 times.
  # depends_on = ["google_compute_subnetwork.k8s-the-hard-way-terraform-subnet"]
}

# Create k8s workers
module "k8s-gcp-workers" {
  source = "../gcp/compute"
  zone = "${var.zone}"
  subnet_name = "${var.subnet_name}"
  instances_count = "${var.k8s_workers_qty}"
  root_ip = "10.240.0.2"
  machine_type = "n1-standard-1"
  name_base = "worker"
  image = "ubuntu-os-cloud/ubuntu-1604-lts"
  tags = ["kubernetes-the-hard-way-terraform","controller"]

  ## Waiting for the fix: https://github.com/hashicorp/terraform/issues/10462 to be able to set dependencies between modules. Our work around until this capability gets released is just run terraform apply 2 times.
  # depends_on = ["google_compute_subnetwork.k8s-the-hard-way-terraform-subnet"]
}



###################################################
# Configuring TLS Certs, Auth and Data Encryption #
###################################################
# Generate Certs and private keys
resource "null_resource" "gen_cert_key" {

  ## Generate the CA cert and private key
  provisioner "local-exec" {
      command = "cfssl gencert -initca certs/ca-csr.json | cfssljson -bare ca"
  }


  ## Generate the admin client cert and private key
  provisioner "local-exec" {
      command = "cfssl gencert -ca=certs/ca.pem -ca-key=certs/ca-key.pem -config=certs/ca-config.json -profile=kubernetes certs/admin-csr.json | cfssljson -bare admin"
  }


  ## Generate cert and private key for each k8s worker node
  count = "${var.k8s_workers_qty}"
  provisioner "local-exec" {
      command = <<EOT
       cat > certs/worker-${count.index}-csr.json <<EOF
       {
          \"CN\": \"system:node:worker-${count.index}\",
          \"key\": {
             \"algo\": \"rsa\",
             \"size\": 2048
          },
          \"names\": [
            {
               \"C\": \"US\",
               \"L\": \"Portland\",
               \"O\": \"system:nodes\",
               \"OU\": \"Kubernetes The Hard Way\",
               \"ST\": \"Oregon\"
            }
          ]
         }
       EOF
      EOT
      command = <<EOT
        EXTERNAL_IP=\$$(gcloud compute instances describe worker-${count.index} --format 'value(networkInterfaces[0].accessConfigs[0].natIP)')
        INTERNAL_IP=\$$(gcloud compute instances describe worker-${count.index} --format 'value(networkInterfaces[0].networkIP)')
        cfssl gencert -ca=certs/ca.pem -ca-key=certs/ca-key.pem -config=certs/ca-config.json -hostname=worker-${count.index},\$${EXTERNAL_IP},\$${INTERNAL_IP} -profile=kubernetes certs/worker-${count.index}-csr.json | cfssljson -bare worker-${count.index}
      EOT
  }

  ## Generate kube-controller-manager client cert and private key
  provisioner "local-exec" {
      command = "cfssl gencert -ca=certs/ca.pem -ca-key=certs/ca-key.pem -config=certs/ca-config.json -profile=kubernetes certs/kube-controller-manager-csr.json | cfssljson -bare kube-controller-manager"
  }


  ## Generate the kube-scheduler client certificate and private key
  provisioner "local-exec" {
      command = "cfssl gencert -ca=certs/ca.pem -ca-key=certs/ca-key.pem -config=certs/ca-config.json -profile=kubernetes certs/kube-scheduler-csr.json | cfssljson -bare kube-scheduler"
  }

  ## Generate the Kubernetes API Server certificate and private key
  provisioner "local-exec" {
      command =<<EOT
           KUBERNETES_PUBLIC_ADDRESS=\$$(gcloud compute addresses describe kubernetes-the-hard-way --region \$$(gcloud config get-value compute/region) --format 'value(address)')
           cfssl gencert -ca=certs/ca.pem -ca-key=certs/ca-key.pem -config=certs/ca-config.json -hostname=10.32.0.1,10.240.0.10,10.240.0.11,10.240.0.12,\$${KUBERNETES_PUBLIC_ADDRESS},127.0.0.1,kubernetes.default -profile=kubernetes certs/kubernetes-csr.json | cfssljson -bare kubernetes
      EOT
  }  

  ## Generate the service-account certificate and private key
  provisioner "local-exec" {
      command = "cfssl gencert -ca=certs/ca.pem -ca-key=certs/ca-key.pem -config=certs/ca-config.json -profile=kubernetes certs/service-account-csr.json | cfssljson -bare service-account"
  }
}

# Distribute the Certificates to each Worker instances
resource "null_resource" "dist_worker_certs_keys" {
count = "${var.k8s_workers_qty}"
    # Copy the appropriate certificates and private keys to each worker instance
    provisioner "local-exec" {
      command = "gcloud compute scp certs/ca.pem certs/worker-${count.index}-key.pem certs/worker-${count.index}.pem certs/worker-${count.index}:~/"
  }

}

# Distribute the Certificates to each Controller instance
resource "null_resource" "dist_controller_certs_keys" {
count = "${var.k8s_controllers_qty}"
    # Copy the appropriate certificates and private keys to each controller instance
    provisioner "local-exec" {
      command = "gcloud compute scp certs/ca.pem certs/ca-key.pem certs/kubernetes-key.pem certs/kubernetes.pem certs/service-account-key.pem certs/service-account.pem controller-${count.index}:~/"
  }

}


# Generating k8s Config Files for Auth
  ## Generate kubelet configuration file
  resource "null_resource" "gen_k8s_kubelet_config" {
    count = "${var.k8s_workers_qty}"
    provisioner "local-exec" {
        command =<<EOT
            KUBERNETES_PUBLIC_ADDRESS=\$$(gcloud compute addresses describe kubernetes-the-hard-way --region \$$(gcloud config get-value compute/region) --format 'value(address)')
            kubectl config set-cluster kubernetes-the-hard-way --certificate-authority=certs/ca.pem --embed-certs=true --server=https://\$${KUBERNETES_PUBLIC_ADDRESS}:6443 --kubeconfig=configs/worker-${count.index}.kubeconfig
            kubectl config set-credentials system:node:worker-${count.index} --client-certificate=certs/worker-${count.index}.pem --client-key=certs/worker-${count.index}-key.pem --embed-certs=true --kubeconfig=configs/worker-${count.index}.kubeconfig
            kubectl config set-context default --cluster=kubernetes-the-hard-way --user=system:node:worker-${count.index} --kubeconfig=configs/worker-${count.index}.kubeconfig
            kubectl config use-context default --kubeconfig=configs/worker-${count.index}.kubeconfig
        EOT
    }

  }

  ## Generate kube-proxy configuration file
  resource "null_resource" "gen_k8s_kubeproxy_config" {
    provisioner "local-exec" {
        command =<<EOT
            KUBERNETES_PUBLIC_ADDRESS=\$$(gcloud compute addresses describe kubernetes-the-hard-way --region \$$(gcloud config get-value compute/region) --format 'value(address)')
            kubectl config set-cluster kubernetes-the-hard-way --certificate-authority=certs/ca.pem --embed-certs=true --server=https://\$${KUBERNETES_PUBLIC_ADDRESS}:6443 --kubeconfig=configs/kube-proxy.kubeconfig
            kubectl config set-credentials system:kube-proxy --client-certificate=certs/kube-proxy.pem --client-key=certs/kube-proxy-key.pem --embed-certs=true --kubeconfig=configs/kube-proxy.kubeconfig
            kubectl config set-context default --cluster=kubernetes-the-hard-way --user=system:kube-proxy --kubeconfig=configs/kube-proxy.kubeconfig
            kubectl config use-context default --kubeconfig=configs/kube-proxy.kubeconfig
        EOT
    }   
  }

  ## Generate kube-controller-manager configuration file
  resource "null_resource" "gen_k8s_kubecontrollermanager_config" {
    provisioner "local-exec" {
        command =<<EOT
            kubectl config set-cluster kubernetes-the-hard-way --certificate-authority=certs/ca.pem --embed-certs=true --server=https://127.0.0.1:6443 --kubeconfig=configs/kube-controller-manager.kubeconfig
            kubectl config set-credentials system:kube-controller-manager --client-certificate=certs/kube-controller-manager.pem --client-key=certs/kube-controller-manager-key.pem --embed-certs=true --kubeconfig=configs/kube-controller-manager.kubeconfig
            kubectl config set-context default --cluster=kubernetes-the-hard-way --user=system:kube-controller-manager --kubeconfig=configs/kube-controller-manager.kubeconfig
            kubectl config use-context default --kubeconfig=configs/kube-controller-manager.kubeconfig
        EOT
    }   
  }


  ## Generate kube-scheduler configuration file
  resource "null_resource" "gen_k8s_kubescheduler_config" {
    provisioner "local-exec" {
        command =<<EOT
            kubectl config set-cluster kubernetes-the-hard-way --certificate-authority=certs/ca.pem --embed-certs=true --server=https://127.0.0.1:6443 --kubeconfig=configs/kube-scheduler.kubeconfig    
            kubectl config set-credentials system:kube-scheduler --client-certificate=certs/kube-scheduler.pem --client-key=certs/kube-scheduler-key.pem --embed-certs=true --kubeconfig=configs/kube-scheduler.kubeconfig
            kubectl config set-context default --cluster=kubernetes-the-hard-way --user=system:kube-scheduler --kubeconfig=configs/kube-scheduler.kubeconfig
            kubectl config use-context default --kubeconfig=configs/kube-scheduler.kubeconfig
        EOT
    }   
  }


  ## Generate admin configuration file
  resource "null_resource" "gen_k8s_admin_config" {
    provisioner "local-exec" {
        command =<<EOT
            kubectl config set-cluster kubernetes-the-hard-way --certificate-authority=certs/ca.pem --embed-certs=true --server=https://127.0.0.1:6443 --kubeconfig=configs/admin.kubeconfig
            kubectl config set-credentials admin --client-certificate=certs/admin.pem --client-key=certs/admin-key.pem --embed-certs=true --kubeconfig=configs/admin.kubeconfig
            kubectl config set-context default --cluster=kubernetes-the-hard-way --user=admin --kubeconfig=configs/admin.kubeconfig
            kubectl config use-context default --kubeconfig=configs/admin.kubeconfig
        EOT
    }   
  }

# Distribute the Configuration Files to each Worker instances
resource "null_resource" "dist_worker_certs_keys" {
    count = "${var.k8s_workers_qty}"
    provisioner "local-exec" {
      command = "gcloud compute scp configs/worker-${count.index}.kubeconfig configs/kube-proxy.kubeconfig worker-${count.index}:~/"
  }

}

# Distribute the Configuration Files to each Controller instance
resource "null_resource" "dist_controller_certs_keys" {
    count = "${var.k8s_controllers_qty}"
    provisioner "local-exec" {
      command = "gcloud compute scp configs/admin.kubeconfig configs/kube-controller-manager.kubeconfig configs/kube-scheduler.kubeconfig  controller-${count.index}:~/"
  }
}



# Generating  Data Encryption Config and Key
resource "null_resource" "gen_data_encryption_config_key" {
    count = "${var.k8s_controllers_qty}"
   provisioner "local-exec" {
    command = <<EOT
       ENCRYPTION_KEY=\$$(head -c 32 /dev/urandom | base64)
       cat > configs/encryption-config.yaml <<EOF
       kind: EncryptionConfig
       apiVersion: v1
       resources:
        - resources:
        - secrets
       providers:
        - aescbc:
            keys:
              - name: key1
                secret: \$${ENCRYPTION_KEY}
        - identity: {}
      EOF
    EOT
    command = "gcloud compute scp encryption-config.yaml controller-${count.index}:~/"
  }
}


##############################
# Bootstrapping etcd Cluster #
##############################





###################################
# Bootstrapping k8s control panel #
###################################




##################################
# Bootstrapping k8s worker nodes #
##################################
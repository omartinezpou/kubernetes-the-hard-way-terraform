module "k8s-gcp" {
  source = "../../../modules/gcp"
  source               = "../../modules/k8s"  
  zone                 = "${var.zone}" 
  network_name         = "${var.network_name}" 
  gcp_project          = "${var.gcp_project}"
  subnet_name          = "${var.subnet_name}"  
  subnet_cidr          = "${var.subnet_cidr}"  
  region               = "${var.region}"
  credentials          = "${var.credentials}"
  region               = "${var.region}"
  k8s_workers_qty      = "${var.k8s_workers_qty}"
  k8s_controllers_qty  = "${var.k8s_controllers_qty}"  
}


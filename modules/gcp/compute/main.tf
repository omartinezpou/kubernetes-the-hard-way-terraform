# Create k8s controllers
resource "google_compute_instance" "gcp_compute_instance" {
   //count = "${var.k8s_workers_qty}"
   count = "${var.instances_count}"
   name = "${var.name_base}-${count.index}"
   zone = "${var.zone}"
   machine_type = "${var.machine_type}" 
   boot_disk {
      initialize_params {
         image = "${var.image}"
         size  = 200
      }
   }
   can_ip_forward = true
   network_interface {
      network_ip = "${var.root_ip}${count.index}"
      subnetwork = "${var.subnet_name}"
      access_config = {} 
   }
   metadata {
      pod-cidr = "${var.name_base == "worker" ? "10.200.${count.index}.0/24" : "" }"
   }
   service_account {
      scopes = ["compute-rw", "storage-ro", "service-management", "service-control", "logging-write", "monitoring"]
   }

   tags = "${var.tags}"
}
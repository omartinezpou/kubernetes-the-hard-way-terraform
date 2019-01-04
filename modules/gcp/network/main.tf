// Create VPC
resource "google_compute_network" "terraform-vpc" {
 name                    = "${var.network_name}"
 auto_create_subnetworks = "false"
}

// Create Subnet
resource "google_compute_subnetwork" "terraform-subnet" {
 name          = "${var.subnet_name}"
 ip_cidr_range = "${var.subnet_cidr}"
 network       = "${var.network_name}"
 depends_on    = ["google_compute_network.terraform-vpc"]
 region      = "${var.region}"
}

// VPC firewall configuration
resource "google_compute_firewall" "terraform-firewall-internal" {
  name    = "${var.network_name}-allow-internal"
  network = "${var.network_name}"
  //subnetwork = "${var.subnet_name}"
  allow {
    protocol = "icmp"
  }

  allow {
    protocol = "udp"
  }

  allow {
    protocol = "tcp"
  }

  source_ranges = "${var.vpc_firewall_source_ranges}"
  depends_on    = ["google_compute_network.terraform-vpc"]
}


// VPC firewall configuration
resource "google_compute_firewall" "terraform-firewall-external" {
  name    = "${var.network_name}-allow-external"
  network = "${var.network_name}"
  // subnetwork = "${var.subnet_name}"
  allow {
    protocol = "icmp"
  }

  allow {
    protocol = "tcp"
    ports    = "${var.vpc_firewall_allow_tcp_ports}"
  }

  source_ranges = ["0.0.0.0/0"]
  depends_on    = ["google_compute_network.terraform-vpc"]
}

resource "google_compute_address" "terraform-ip-address" {
  name = "${var.compute_address_name}"
  region = "${var.region}"
}
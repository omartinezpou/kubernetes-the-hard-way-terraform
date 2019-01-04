variable "region" {}
variable "compute_address_name" {}
variable "network_name" {}
variable "subnet_name" {}
variable "subnet_cidr" {}
variable "vpc_firewall_source_ranges" { default = [] }
variable "vpc_firewall_allow_tcp_ports" { default = [] }
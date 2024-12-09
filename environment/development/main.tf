# Specify the Terraform version
terraform {
  required_version = ">= 1.5.0"
  required_providers {
    linode = {
      source  = "linode/linode"
      version = "~> 2.31.1"
    }
  }
}

# Create a Virtual Private Cloud (VPC)
resource "linode_vpc" "main_vpc" {
  label      = "devxparty-vpc"
  region     = "us-ord"
}

# Create a VPC Subnet
resource "linode_vpc_subnet" "main_subnet" {
  vpc_id = linode_vpc.main_vpc.id
  label  = "primary"
  ipv4   = "192.168.1.0/24"
}

# Create a Firewall
resource "linode_firewall" "main_firewall" {
  label = "devxparty-firewall"
  inbound_policy = "DROP"
  outbound_policy = "ACCEPT"

  inbound {
    label    = "allow-ssh"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "22"
    ipv4     = ["172.234.215.93/32"]
  }
  inbound {
    label    = "allow-nxclient"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "4000"
    ipv4     = ["172.234.215.93/32"]
  }

  # Allow NodeBalancer health checks
  inbound {
    label    = "allow-nodebalancer"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "22"
    ipv4     = ["192.168.0.0/16"]  # VPC range
  }

  linodes = [for instance in linode_instance.web : instance.id]
}

# Updated Linode Instance configuration
resource "linode_instance" "web" {
  count     = 1
  label     = "devxpartybox-${count.index + 1}"
  region    = "us-ord"
  type      = "g6-dedicated-16"
  image     = "linode/ubuntu22.04"
  root_pass = var.root_password
  private_ip = true

  authorized_keys = [
    "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQCpuRZXmsY/vAWu1HN3sdMtikpgncOqVbCqINz8dRXWLiKKRG3h6nFmt7aunW3+5nuAGf4DSwK15cMBlYKxwLgLlNbdPm+4qeae1v+GtGiVZgX9SYFgxkyvdrLcU1rxydekrU7kxIO0xFJSXJEp6Kw+Z+5KiJW+AbiUKmxX59g2LwgMtWnN7TOCK+xGPN1zxxUa+AzuM+61PTRVeNK9qVg7DsoBG3hFrP+oAp7gff90XXp/+/rqBCMQyfCUlaEZw/MeNOyL6i7ErezgFkFGdrERGLzn3VkloCyMiM2QQILOIX/fMrdtCyLpbvQL8BoLloZxRwwm4jmQ36gsaUsZ+Ow6AF88LOJ8p9B064fkPYsqXPBJPhkxpZ0+OwUO04PcZWtWm/agpEk7Iu2N8REI2G9ayxLkeysjDjqagc0LOHSyv3c0kGwfWOgcyeE5atCuVxkJeP+ZQIz6H1lPlFNtDAOqXyq9T/PGBP5tUHR0ofw0lzwCE2yJ54UEuFKxpkY6WBwjl7BMxn6L4+BmpwC6xReRV+wKgUuOZlipDBgqLtM74d4GokGMbtVSJpFRWjP1OjDB2lKWRzzK6VwkbS+DyJwK5bSRJA+Mv/MWAV0YlNtayINqH0kiIXEtrR47rUnMk0WzrFmSNQdH0IHuhUQVYHIIxMOkPOpQb2vvmFPo/nBh2Q== developer@localhost"
  ]

  # VPC Interface
  interface {
    purpose      = "vpc"
    ipam_address = "192.168.1.${count.index + 10}/24"
    subnet_id    = linode_vpc_subnet.main_subnet.id
  }

  # Public Interface
  interface {
    purpose = "public"
    ipam_address = "any"
  }

  stackscript_id = linode_stackscript.instance_init.id
  stackscript_data = {
    "userdata" = file("cloud-init.yaml")
  }

  tags = ["devxpartybox"]
}

# Create a NodeBalancer
resource "linode_nodebalancer" "main_lb" {
  label  = "main-nodebalancer"
  region = "us-ord"
}

# SSH Config
resource "linode_nodebalancer_config" "ssh_config" {
  nodebalancer_id = linode_nodebalancer.main_lb.id
  port            = 22
  protocol        = "tcp"
  check_timeout   = 5
  check_attempts  = 3
  check_interval  = 15
  check_path      = ""
  check_passive   = true
  stickiness      = "table"
}

# NoMachine Config
resource "linode_nodebalancer_config" "nomachine_config" {
  nodebalancer_id = linode_nodebalancer.main_lb.id
  port            = 4000
  protocol        = "tcp"
  check_timeout   = 5
  check_attempts  = 3
  check_interval  = 15
  check_path      = ""
  check_passive   = true
  stickiness      = "table"
}

# NoMachine Web Companion Config
resource "linode_nodebalancer_config" "nomachine_web_config" {
  nodebalancer_id = linode_nodebalancer.main_lb.id
  port            = 4080
  protocol        = "tcp"
  check_timeout   = 5
  check_attempts  = 3
  check_interval  = 15
  check_path      = ""
  check_passive   = true
  stickiness      = "table"
}

# Configure NodeBalancer Nodes for SSH
resource "linode_nodebalancer_node" "ssh_nodes" {
  count            = 1
  nodebalancer_id  = linode_nodebalancer.main_lb.id
  config_id        = linode_nodebalancer_config.ssh_config.id
  label            = "${linode_instance.web[count.index].label}-ssh"
  address          = "${linode_instance.web[count.index].private_ip_address}:22"
  weight           = 100
}

# Configure NodeBalancer Nodes for NoMachine
resource "linode_nodebalancer_node" "nomachine_nodes" {
  count            = 1
  nodebalancer_id  = linode_nodebalancer.main_lb.id
  config_id        = linode_nodebalancer_config.nomachine_config.id
  label            = "${linode_instance.web[count.index].label}-nomachine"
  address          = "${linode_instance.web[count.index].private_ip_address}:4000"
  weight           = 100
}

# Configure NodeBalancer Nodes for NoMachine Web
resource "linode_nodebalancer_node" "nomachine_web_nodes" {
  count            = 1
  nodebalancer_id  = linode_nodebalancer.main_lb.id
  config_id        = linode_nodebalancer_config.nomachine_web_config.id
  label            = "${linode_instance.web[count.index].label}-nomachine-web"
  address          = "${linode_instance.web[count.index].private_ip_address}:4080"
  weight           = 100
}

# Create StackScript for instance initialization
resource "linode_stackscript" "instance_init" {
  label       = "instance-init-script"
  description = "Initialize instance with cloud-init configuration"
  script      = file("stackscript.sh")
  images      = ["linode/ubuntu22.04"]
  is_public   = false
  rev_note    = "Initial version"
}


# Variables file recommendation
variable "root_password" {
  description = "Root password for Linode instances"
  type        = string
  sensitive   = true
  default = "yourpassword"
}
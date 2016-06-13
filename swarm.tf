resource "null_resource" "discovery_url_template" {
    count = "${var.generate_discovery_url}"
    provisioner "local-exec" {
        command = "curl -s 'https://discovery.etcd.io/new?size=${var.cluster_size}' > templates/discovery_url"
    }
}

resource "null_resource" "generate_ssl" {
    count = "${var.generate_ssl}"
    provisioner "local-exec" {
        command = "bash files/ssl/generate-ssl.sh"
    }
}

resource "template_file" "discovery_url" {
    template = "templates/discovery_url"
    depends_on = [
        "null_resource.discovery_url_template"
    ]
}

resource "template_file" "cloud_init" {
    template = "templates/cloud-init"
    vars {
        cluster_token = "${var.cluster_name}"
        discovery_url = "${template_file.discovery_url.rendered}"
        swarm_version = "${var.swarm_version}"
    }
}

resource "template_file" "10_docker_service" {
    template = "templates/10-docker-service.conf"
}

resource "template_file" "primary_consul" {
    template = "templates/primary_consul.env"
}

resource "template_file" "secondary_consul" {
    template = "templates/secondary_consul.env"
    vars {
        primary_ip = "${openstack_compute_instance_v2.coreos.0.network.0.fixed_ip_v4}"
    }
}

resource "openstack_networking_floatingip_v2" "coreos" {
    count = "${var.cluster_size}"
    pool = "${var.floatingip_pool}"
}

resource "openstack_compute_keypair_v2" "coreos" {
    name = "swarm-${var.cluster_name}"
    public_key = "${file(var.public_key_path)}"
}

resource "openstack_compute_instance_v2" "coreos" {
    name = "swarm-${var.cluster_name}-${count.index}"
    count = "${var.cluster_size}"
    image_name = "${var.image_name}"
    flavor_name = "${var.flavor}"
    key_pair = "${openstack_compute_keypair_v2.coreos.name}"
    network {
        name = "${var.network_name}"
    }
    security_groups = [
        "${openstack_compute_secgroup_v2.swarm_base.name}"
    ]
    floating_ip = "${element(openstack_networking_floatingip_v2.coreos.*.address, count.index)}"
    user_data = "${template_file.cloud_init.rendered}"
    provisioner "file" {
        source = "files"
        destination = "/tmp/files"
        connection {
            user = "core"
        }
    }
    provisioner "remote-exec" {
        inline = [
            # Create TLS certs
            "mkdir -p /home/core/.docker",
            "cp /tmp/files/ssl/ca.pem /home/core/.docker/",
            "cp /tmp/files/ssl/cert.pem /home/core/.docker/",
            "cp /tmp/files/ssl/key.pem /home/core/.docker/",
            "echo 'subjectAltName = @alt_names' >> /tmp/files/ssl/openssl.cnf",
            "echo '[alt_names]' >> /tmp/files/ssl/openssl.cnf",
            "echo 'IP.1 = ${self.network.0.fixed_ip_v4}' >> /tmp/files/ssl/openssl.cnf",
            "echo 'IP.2 = ${element(openstack_networking_floatingip_v2.coreos.*.address, count.index)}' >> /tmp/files/ssl/openssl.cnf",
            "echo 'DNS.1 = ${var.fqdn}' >> /tmp/files/ssl/openssl.cnf",
            "echo 'DNS.2 = ${element(openstack_networking_floatingip_v2.coreos.*.address, count.index)}.xip.io' >> /tmp/files/ssl/openssl.cnf",
            "openssl req -new -key /tmp/files/ssl/key.pem -out /tmp/files/ssl/cert.csr -subj '/CN=docker-client' -config /tmp/files/ssl/openssl.cnf",
            "openssl x509 -req -in /tmp/files/ssl/cert.csr -CA /tmp/files/ssl/ca.pem -CAkey /tmp/files/ssl/ca-key.pem \\",
            "-CAcreateserial -out /tmp/files/ssl/cert.pem -days 365 -extensions v3_req -extfile /tmp/files/ssl/openssl.cnf",
            "sudo mkdir -p /etc/docker/ssl",
            "sudo cp /tmp/files/ssl/ca.pem /etc/docker/ssl/",
            "sudo cp /tmp/files/ssl/cert.pem /etc/docker/ssl/",
            "sudo cp /tmp/files/ssl/key.pem /etc/docker/ssl/",
            # Apply localized settings to services
            "sudo mkdir -p /etc/systemd/system/{docker,swarm-agent,swarm-manager}.service.d",
            "cat <<'EOF' > /tmp/10-docker-service.conf\n${template_file.10_docker_service.rendered}\nEOF",
            "sudo mv /tmp/10-docker-service.conf /etc/systemd/system/docker.service.d/",
            "sudo systemctl daemon-reload",
            "sudo systemctl restart docker.service",
            "sudo systemctl start swarm-agent.service",
            "sudo systemctl start swarm-manager.service",
            "sleep 10",
        ]
        connection {
            user = "core"
        }
    }
    depends_on = [
        "template_file.cloud_init"
    ]
}

resource "null_resource" "start_consul" {
    count = "${var.cluster_size}"
    provisioner "remote-exec" {
        inline = [
            "if [[ ${count.index} -eq 0 ]]; then",
            "   cat <<'EOF' > /home/core/consul.env\n${template_file.primary_consul.rendered}\nEOF",
            "else",
            "   cat <<'EOF' > /home/core/consul.env\n${template_file.secondary_consul.rendered}\nEOF",
            "fi",
            "sudo cp /home/core/consul.env /etc/consul.env",
            "sudo systemctl start consul.service",
            "sleep 10",
        ]
        connection {
            user = "core"
            host = "${element(openstack_networking_floatingip_v2.coreos.*.address, count.index)}"
        }
    }
}

resource "null_resource" "elk_up" {
    provisioner "local-exec" {
        command = "DOCKER_HOST=tcp://${openstack_networking_floatingip_v2.coreos.0.address}:2375 DOCKER_TLS_VERIFY=1 DOCKER_CERT_PATH=${path.module}/files/ssl docker-compose -p elk up -d"
    }
    provisioner "local-exec" {
        command = "DOCKER_HOST=tcp://${openstack_networking_floatingip_v2.coreos.0.address}:2375 DOCKER_TLS_VERIFY=1 DOCKER_CERT_PATH=${path.module}/files/ssl docker-compose -p elk scale elasticsearch=3 kibana=3 logstash=3 logspout=3"
    }
    depends_on = [
        "null_resource.start_consul"
    ]
}

output "swarm_cluster" {
    value = "\nEnvironment Variables for accessing Docker Swarm via floating IP of first host:\nexport DOCKER_HOST=tcp://${openstack_networking_floatingip_v2.coreos.0.address}:2375\nexport DOCKER_TLS_VERIFY=1\nexport DOCKER_CERT_PATH=${path.module}/files/ssl"
}

output "public_ips" {
    value = "\n${join(", ", openstack_networking_floatingip_v2.coreos.*.address )}"
}

output "clicky_clicky_web_things" {
    value = "\nkibana: http://${openstack_networking_floatingip_v2.coreos.0.address}:5601\n consul: http://${openstack_networking_floatingip_v2.coreos.0.address}:8500"
}

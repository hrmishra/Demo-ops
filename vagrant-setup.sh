#!/bin/bash

# Exit on error
set -e

# Check if Vagrant is installed
if ! command -v vagrant &> /dev/null; then
    echo "Vagrant is not installed. Exiting."
    exit 1
fi

# Check if Ansible is installed
ansible_version_required="2.12.0"
if ! command -v ansible &> /dev/null; then
    echo "Ansible is not installed. Installing Ansible..."
    sudo apt-get update
    sudo apt-get install -y ansible
else
    ansible_version_installed=$(ansible --version | awk 'NR==1{print $2}')
    if dpkg --compare-versions "$ansible_version_installed" "lt" "$ansible_version_required"; then
        echo "Ansible version $ansible_version_required or later is required. Updating Ansible..."
        sudo apt-get update
        sudo apt-get install -y ansible
    fi
fi

# Check if the Vagrant box exists
vagrant_box="ubuntu/bionic64"
if ! vagrant box list | grep -q "$vagrant_box"; then
    echo "Vagrant box '$vagrant_box' not found. Adding the box..."
    vagrant box add "$vagrant_box"
fi

# Check if the Vagrant machine is running
if ! vagrant status | grep -q "running"; then
    echo "Starting Vagrant machine..."
    vagrant up
fi

# Create Vagrant box
vagrant init ubuntu/bionic64

# Start Vagrant box
vagrant up

# Provision VM using Ansible
cat <<EOL > playbook.yml
---
- hosts: all
  become: yes
  tasks:
    - name: Set hostname to demo-ops
      hostname:
        name: 'demo-ops2'

    - name: Create user demo
      user:
        name: demo

    - name: Harden security
      block:
        - name: Disable root login
          replace:
            path: /etc/ssh/sshd_config
            regexp: '^PermitRootLogin yes'
            replace: 'PermitRootLogin no'
          notify: Restart SSH

        - name: Set up UFW firewall
          apt:
            name: ufw
            state: present
          become: yes

        - name: Allow SSH
          command: ufw allow OpenSSH
          become: yes

        - name: Enable UFW firewall
          command: ufw --force enable
          become: yes
      when: ansible_distribution == 'Ubuntu'

    - name: Configure sysctl for sane defaults
      sysctl:
        name: "{{ item.name }}"
        value: "{{ item.value }}"
        sysctl_file: /etc/sysctl.conf
      loop:
        - { name: "fs.file-max", value: "65535" }
        - { name: "net.ipv4.ip_local_port_range", value: "2000 65535" }
        - { name: "net.ipv4.tcp_fin_timeout", value: "30" }
      register: sysctl_changes

    - name: Set system timezone to Asia/Kolkata
      timezone:
        name: "Asia/Kolkata"

    - name: Install Docker and Docker-Compose
      apt:
        name: "{{ item }}"
        state: present
      loop:
        - docker.io
        - docker-compose

    - name: Deploy docker-compose.yml
      copy:
        src: docker-compose.yml
        dest: /etc/demo-ops/docker-compose.yml

    - name: Start Docker services
      shell: docker-compose -f /etc/demo-ops/docker-compose.yml up -d
      args:
        chdir: /etc/demo-ops

    - name: Install Prometheus
      apt:
        name: prometheus
        state: present

    - name: Install Grafana
      apt:
        name: grafana
        state: present

    - name: Copy Prometheus configuration file
      copy:
        src: prometheus.yml
        dest: /etc/prometheus/prometheus.yml

    - name: Start Prometheus service
      systemd:
        name: prometheus
        state: started
        enabled: yes

    - name: Install Redis Exporter
      get_url:
        url: https://github.com/oliver006/redis_exporter/releases/download/v1.22.1/redis_exporter-v1.22.1.linux-amd64.tar.gz
        dest: /tmp/redis_exporter.tar.gz

    - name: Extract Redis Exporter
      ansible.builtin.unarchive:
        src: /tmp/redis_exporter.tar.gz
        dest: /opt/
        remote_src: yes

    - name: Move Redis Exporter binary
      command: mv /opt/redis_exporter-v1.22.1.linux-amd64/redis_exporter /usr/local/bin/

    - name: Create Redis Exporter systemd service
      copy:
        src: redis_exporter.service
        dest: /etc/systemd/system/redis_exporter.service

    - name: Start Redis Exporter service
      systemd:
        name: redis_exporter
        state: started
        enabled: yes

    - name: Install Grafana CLI
      shell: grafana-cli --version
      register: grafana_cli_version
      changed_when: false
      failed_when: grafana_cli_version.rc not in [0, 2]

    - name: Install Plugins
      shell: grafana-cli plugins install grafana-clock-panel grafana-simple-json-datasource grafana-piechart-panel
      args:
        creates: "/var/lib/grafana/plugins/"
      register: grafana_plugin_install
      changed_when: false
      failed_when: grafana_plugin_install.rc not in [0, 2]

    - name: Start Grafana service
      systemd:
        name: grafana-server
        state: started
        enabled: yes

  handlers:
    - name: Restart SSH
      service:
        name: ssh
        state: restarted

EOL

# Run Ansible playbook
ansible-playbook -i "localhost," -c local playbook.yml

# Clean up temporary playbook file
rm playbook.yml

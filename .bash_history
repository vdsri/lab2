pwd
cd /etc/ansible/
ls
cd roles/
ls
exit
ansible all --list-hosts
ansible all -m ping -v
cat /etc/ansible/hosts
ansible windows -m win_ping
ansible windows -m win_ping
yum -y install python-devel krb5-devel krb5-libs krb5-workstation python-pip gcc
pip install "pywinrm>=0.2.2"
pip install --upgrade pip
ansible windows -m win_ping
ls
pwd
sudo -i
cd ~/
exit
clear
wget http://www.opentlc.com/download/ansible_bootcamp/openstack_keys/openstack.pem -O ~/.ssh/openstack.pem
chmod 400 ~/.ssh/openstack.pem
cat << EOF >> ssh.cfg
Host workstation-${OSPGUID}.rhpds.opentlc.com
 Hostname workstation-${OSPGUID}.rhpds.opentlc.com
 IdentityFile ~/.ssh/openstack.pem
 ForwardAgent yes
 User cloud-user
 StrictHostKeyChecking no
 PasswordAuthentication no

Host 10.10.10.*
 User cloud-user
 IdentityFile ~/.ssh/openstack.pem
 ProxyCommand ssh cloud-user@workstation-${OSPGUID}.rhpds.opentlc.com -W %h:%p -vvv
 StrictHostKeyChecking no
EOF

vi ssh.cfg
cat << EOF > osp_jumpbox_inventory
[jumpbox]
workstation-${OSPGUID}.rhpds.opentlc.com ansible_ssh_user=cloud-user ansible_ssh_private_key_file=~/.ssh/openstack.pem
EOF

vi osp_jumpbox_inventory
ansible -i osp_jumpbox_inventory all -m ping
ansible -i osp_jumpbox_inventory jumpbox -m os_user_facts -a cloud=ospcloud -v
cat << EOF > ansible.cfg
[defaults]
inventory=./osp_jumpbox_inventory

[privilege_escalation]
become=True
become_method=sudo

[ssh_connection]
ssh_args=" -F ./ssh.cfg -o ControlMaster=auto -o ControlPersist=60s"
host_key_checking=False
EOF

cat << EOF > osp_create_network.yml
- hosts: jumpbox
  tasks:
  - os_network:
      cloud: ospcloud
      state: present
      name: ext_network
      external: true
  - os_subnet:
      cloud: ospcloud
      state: present
      network_name: ext_network
      name: external_subnet
      cidr: 10.10.10.0/24
      dns_nameservers:
         - 8.8.8.7
         - 8.8.8.8
      host_routes:
         - destination: 0.0.0.0/0
           nexthop: 10.10.10.0
         - destination: 192.168.0.0/24
           nexthop: 192.168.0.0
  - os_network:
      cloud: ospcloud
      state: present
      name: int_network
      external: false
    register: internal
    tags:
     - tested
  - os_subnet:
      cloud: ospcloud
      state: present
      network_name: int_network
      name: int_subnet
      cidr: 20.20.20.0/24
      dns_nameservers:
         - 8.8.8.7
         - 8.8.8.8
      host_routes:
         - destination: 0.0.0.0/0
           nexthop: 192.168.0.0
         - destination: 192.168.0.0/24
           nexthop: 192.168.0.0

  - os_router:
      cloud: ospcloud
      state: present
      name: router1
      network: ext_network
      external_fixed_ips:
        - subnet: external_subnet
      interfaces:
        - int_subnet
EOF

ansible-playbook osp_create_network.yml --check
ansible-playbook osp_create_network.yml 
cat << EOF > osp_create_security.yml
- hosts: jumpbox
  tasks:
  - os_security_group:
      cloud: ospcloud
      state: present
      name: ICMP_and_SSH
      description: ICMP and SSH enabled
    tags:
      - tested
  - os_security_group_rule:
      cloud: ospcloud
      security_group: ICMP_and_SSH
      protocol: tcp
      port_range_min: 22
      port_range_max: 22
      remote_ip_prefix: 0.0.0.0/0
    tags:
      - tested
  - os_security_group_rule:
      cloud: ospcloud
      security_group: ICMP_and_SSH
      protocol: tcp
      port_range_min: 80
      port_range_max: 80
      remote_ip_prefix: 0.0.0.0/0
  - os_security_group_rule:
      cloud: ospcloud
      security_group: ICMP_and_SSH
      protocol: icmp
      remote_ip_prefix: 0.0.0.0/0
    tags:
      - tested
  - name: Generate key files
    user:
      name: "{{ ansible_env.USER }}"
      generate_ssh_key: yes
      ssh_key_file: .ssh/test_id_rsa
    tags:
      - tested
  - os_keypair:
      cloud: ospcloud
      state: present
      name: ansible_ssh
      public_key_file: "{{ ansible_env.HOME }}/.ssh/test_id_rsa.pub"
    tags:
      - tested

EOF

ansible-playbook osp_create_security.yml --check
ansible-playbook osp_create_security.yml 
cat << EOF > osp_flavor.yml
- hosts: jumpbox
  tasks:
  - name: Create m2.small flavor
    os_nova_flavor:
     cloud: ospcloud
     state: present
     name: m2.small
     ram: 2048
     vcpus: 1
     disk: 10
EOF

ansible-playbook osp_flavor.yml --check
ansible-playbook osp_flavor.yml 
cat << EOF > osp_create_instances.yml
- hosts: jumpbox
  gather_facts: false
  vars:
    webserver_name: web1
    databaseserver_name: db1
    flavor_name: m1.small
    webserver_group: webservers
    database_group: databaseservers
    deployment: dev
  tasks:
  - name: Create a server instance
    os_server:
      cloud: ospcloud
      name: "{{ webserver_name }}"
      image: rhel-guest
      meta: "group={{ webserver_group }},deployment_name={{ deployment }}"
      flavor: "{{ flavor_name }}"
      security_groups: ICMP_and_SSH
      key_name: ansible_ssh
      nics:
      - net-name: int_network
      userdata: |
        curl -o /tmp/openstack.pub http://www.opentlc.com/download/ansible_bootcamp/openstack_keys/openstack.pub
        cat /tmp/openstack.pub >> /home/cloud-user/.ssh/authorized_keys
        curl -o /tmp/internal.repo http://www.opentlc.com/download/ansible_bootcamp/repo/internal.repo
        cp /tmp/internal.repo /etc/yum.repos.d/internal.repo
    register: webserverip
  - name: Add floating IP to webserver
    os_floating_ip:
      cloud: ospcloud
      state: present
      reuse: yes
      server: "{{ webserver_name }}"
      network: ext_network
      wait: true
      timeout: 180
    register: webserverfloatingip
  - name: Show webserver public IP
    debug: var=webserverfloatingip.floating_ip.floating_ip_address
  - name: Show webserver private IP
    debug: var=webserverip.openstack.private_v4
EOF

ansible-playbook osp_create_instances.yml --check
ansible-playbook osp_create_instances.yml
cat << EOF > osp-test-instances.yml
- hosts: jumpbox
  gather_facts: false
  tasks:

   - name: Fetch Instance Info
     os_server_facts:
      cloud: ospcloud
      region_name: RegionOne
     register: result
   - name: Add host to
     add_host:
      name: "{{ item.public_v4 }}"
      group: "{{ item.metadata.group }}"
     with_items: "{{result.ansible_facts.openstack_servers}}"
   - name: Add host
     add_host:
      name: "{{ item.public_v4 }}"
      group: "{{ item.metadata.deployment_name }}"
     with_items: "{{result.ansible_facts.openstack_servers}}"

- hosts: webservers
  gather_facts: false
  become: yes
  tasks:
  - name: install apache/httpd
    yum:
      name: httpd
      state: latest
  - name: start and enable apache/httpd service
    service:
      name: httpd
      state: started
      enabled: yes
  - name: create default index.html
    copy:
     content: "Hello World"
     dest: /var/www/html/index.html
EOF

ansible-playbook osp-test-instances.yml --check
ansible-playbook osp-test-instances.yml 
ping 10.10.10.3
clear
ansible-playbook osp-test-instances.yml 
clear
ansible-playbook osp-test-instances.yml 
vi osp-test-instances.yml 
cp osp-test-instances.yml osp-test-instances1.yml
vi osp-test-instances.yml 
ansible-playbook osp-test-instances.yml 
vi ssh.cfg
clear
ansible-playbook osp-test-instances1.yml 
pwd
vi ssh.cfg
ansible-playbook osp-test-instances1.yml 
ansible-playbook osp-test-instances.yml 
vi ssh.cfg
ansible-playbook osp-test-instances1.yml 
vi ssh.cfg
cat osp_jumpbox_inventory
ls ~/.ssh/
osp_jumpbox_inventory all -m ping
ansible -i osp_jumpbox_inventory all -m ping
clear
ls
ansible all --list-hosts
cat /etc/ansible/hosts
ls
cp osp_create_instances.yml osp_create_instances1.yml
vi osp_create_instances.yml
cat osp_create_instances.yml
mkdir roles
cd roles
ansible-galaxy init create_instance
cd create_instance/
cd tasks
ls
cd ..
ls
vi main.yml
ls
pwd
mv main.yml /root/roles/create_instance/tasks
ls
cd tasks
ls
cat main.yml
cd ..
cd var
ls
cd vars
ls
vi app1.yml
vi app2.yml
vi db.yml
vi app2.yml
vi frontend.yml
vi main.yml
cd ..
ansible-galaxy init create-facts
cd create-facts/
cd tasks/
vi main.yml
cd ..
cd vars
cd ..
ansible-galaxy init create-flavor
cd create-flavor
cd tasks/
vi main.yml
cd ..
cd vars
cd ..
ls
ansible-galaxy init create-keypair
cd create-keypair/
cd tasks
vi main.yml
cd ..
ansible-galaxy init create-network
cd create-network/
cd tasks/
vi main.yml
cd ..
cd vars
cd ..
ls
vi osp_create.yml
ansible-playbook osp_create.yml --check
vi osp_create.yml
ansible-playbook osp_create.yml --check
vi osp_create.yml
clear
ansible-playbook osp_create.yml --check
vi osp_create.yml
clear
ansible-playbook osp_create.yml --check
vi osp_create.yml
ansible-playbook osp_create.yml --check
vi osp_create.yml
clear
ansible-playbook osp_create.yml --check
vi main.yml
vi osp_create.yml
ansible-playbook osp_create.yml 
vi osp_create.yml
ansible-playbook osp_create.yml --check
vi osp_create.yml
ansible-playbook osp_create.yml --check
clear
ansible-playbook osp_create.yml 
ls
cat osp-test-instances1.yml
clear
cat osp_create_instances1.yml
ls
cd roles
ls
ls -ltr
cd create_instance
cd tasks
ls -ltr
cd ..
cd vars
ls -ltr
vi frontend.yml
vi main.yml
cd ..
cd tasks
vi main.yml
cd ..
cd tasks/
vi main.yml
cd ..
cd vars
ls
vi frontend.yml 
cat frontend.yml
cat db.yml
cd ..
cd tasks/
vi main.yml
ls
cd ..
ansible-galaxy init create-securitygroup
cd create-securitygroup/
cd tasks
vi main.yml
ls -lr
cd ..
ls -ltr
cd create_instance
cd tasks
vi main.yml

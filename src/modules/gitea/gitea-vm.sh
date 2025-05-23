#
#
# TODO: this is just some scrap code, need to create a proper module
#
#
msg_info "Step 3: Installing Gitea, Ansible and Terraform in VM"
# get VM IP
VMIP=$(qm guest exec $VMID -- ip -4 addr show dev eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
ssh ubuntu@$VMIP "sudo wget -q -O gitea https://dl.gitea.com/gitea/1.23.8/gitea-1.23.8-linux-amd64" >/dev/null
ssh ubuntu@$VMIP "sudo adduser --system --shell /bin/bash --gecos 'Git Version Control' --group --disabled-password --home /home/git  git" >/dev/null
ssh ubuntu@$VMIP "sudo mkdir -p /var/lib/gitea/{custom,data,log}; sudo chown -R git:git /var/lib/gitea/; sudo chmod -R 750 /var/lib/gitea/; sudo mkdir /etc/gitea; sudo chown root:git /etc/gitea; sudo chmod 770 /etc/gitea"
ssh ubuntu@$VMIP "sudo mv gitea /usr/local/bin/gitea; sudo chmod +x /usr/local/bin/gitea"
# set it as a systemd service
ssh ubuntu@$VMIP "sudo tee /etc/systemd/system/gitea.service >/dev/null" <<EOF
[Unit]
Description=Gitea (Git with a cup of tea)
After=network.target
[Service]
RestartSec=2s
Type=simple
User=git
Group=git
WorkingDirectory=/var/lib/gitea/
ExecStart=/usr/local/bin/gitea web --config /etc/gitea/app.ini
Restart=always
Environment=USER=git HOME=/home/git GITEA_WORK_DIR=/var/lib/gitea
[Install]
WantedBy=multi-user.target
EOF
ssh ubuntu@$VMIP sudo systemctl enable gitea --now
sleep 2
# Now to the inital registration
# curl -H "Content-type: application/x-www-form-urlencoded" -d "db_type=SQLite3" -d "db_path=/var/lib/gitea/data/gitea.db" -d "app_name=\"Local TAPaaS Git Repository\"" -d "repo_root_path=/var/lib/gitea/data/git-repositories" -d "lfs_root_path=/var/liv/gitea/data/lfs" -d "run_user=git" -d "domain=192.168.14.57" -d "ssh_port=22" -d "http_port=3000" -d "app_url=http://192.158.14.57:3000/" -d "log_root_path=/var/lib/gitea/log" -d "default_allow_create_organization=on"  -X POST  http://192.168.14.57:3000/

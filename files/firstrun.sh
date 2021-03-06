#!/usr/bin/env bash
set -e

# Configure ECS Agent
echo "ECS_CLUSTER=${ECS_CLUSTER}" > /etc/ecs/ecs.config;echo ECS_BACKEND_HOST= >> /etc/ecs/ecs.config;

# Set HTTP Proxy URL if provided
# https://stackoverflow.com/questions/3869072/test-for-non-zero-length-string-in-bash-n-var-or-var
if [[ -n $PROXY_URL ]]
then
  #echo export HTTPS_PROXY=$PROXY_URL >> /etc/sysconfig/docker
  # https://docs.docker.com/config/daemon/systemd/#httphttps-proxy
  sudo mkdir -p /etc/systemd/system/docker.service.d
  cat <<'EOF' | sudo tee /etc/systemd/system/docker.service.d/http-proxy.conf
[Service]
Environment="HTTP_PROXY=http://proxy.example.com:80"
Environment="HTTPS_PROXY=https://proxy.example.com:443"
Environment="NO_PROXY=localhost,127.0.0.1,169.254.169.254,169.254.170.2,/var/run/docker.sock"
EOF
  sudo systemctl daemon-reload
  sudo systemctl restart docker 
  echo HTTPS_PROXY=$PROXY_URL >> /etc/ecs/ecs.config
  echo NO_PROXY=169.254.169.254,169.254.170.2,/var/run/docker.sock >> /etc/ecs/ecs.config
  echo HTTP_PROXY=$PROXY_URL >> /etc/awslogs/proxy.conf
  echo HTTPS_PROXY=$PROXY_URL >> /etc/awslogs/proxy.conf
  echo NO_PROXY=169.254.169.254 >> /etc/awslogs/proxy.conf
fi

# Write AWS Logs region
sudo tee /etc/awslogs/awscli.conf << EOF > /dev/null
[plugins]
cwlogs = cwlogs
[default]
region = ${AWS_DEFAULT_REGION}
EOF

# Write AWS Logs config
sudo tee /etc/awslogs/awslogs.conf << EOF > /dev/null
[general]
state_file = /var/lib/awslogs/agent-state

[/var/log/dmesg]
file = /var/log/dmesg
log_group_name = /${STACK_NAME}/ec2/${AUTOSCALING_GROUP}/var/log/dmesg
log_stream_name = {instance_id}

[/var/log/messages]
file = /var/log/messages
log_group_name = /${STACK_NAME}/ec2/${AUTOSCALING_GROUP}/var/log/messages
log_stream_name = {instance_id}
datetime_format = %b %d %H:%M:%S

# linux 2 uses journald
#[/var/log/docker]
#file = /var/log/docker
#log_group_name = /${STACK_NAME}/ec2/${AUTOSCALING_GROUP}/var/log/docker
#log_stream_name = {instance_id}
#datetime_format = %Y-%m-%dT%H:%M:%S.%f

[/var/log/ecs/ecs-init.log]
file = /var/log/ecs/ecs-init.log*
log_group_name = /${STACK_NAME}/ec2/${AUTOSCALING_GROUP}/var/log/ecs/ecs-init
log_stream_name = {instance_id}
datetime_format = %Y-%m-%dT%H:%M:%SZ
time_zone = UTC

[/var/log/ecs/ecs-agent.log]
file = /var/log/ecs/ecs-agent.log*
log_group_name = /${STACK_NAME}/ec2/${AUTOSCALING_GROUP}/var/log/ecs/ecs-agent
log_stream_name = {instance_id}
datetime_format = %Y-%m-%dT%H:%M:%SZ
time_zone = UTC

[/var/log/ecs/audit.log]
file = /var/log/ecs/audit.log*
log_group_name = /${STACK_NAME}/ec2/${AUTOSCALING_GROUP}/var/log/ecs/audit.log
log_stream_name = {instance_id}
datetime_format = %Y-%m-%dT%H:%M:%SZ
time_zone = UTC
EOF

sudo systemctl enable awslogsd.service
sudo systemctl start awslogsd.service
# --now switch was added in version 220, linux 2 ami (centos 7?) is currently on version 219.
sudo systemctl enable docker.service
sudo systemctl start docker.service
# https://github.com/aws/amazon-ecs-agent/issues/1707
sudo cp /usr/lib/systemd/system/ecs.service /etc/systemd/system/ecs.service
sudo sed -i '/After=cloud-final.service/d' /etc/systemd/system/ecs.service
sudo systemctl daemon-reload
sudo systemctl enable ecs.service
sudo systemctl start ecs.service

# Health check
# Loop until ECS agent has registered to ECS cluster
echo "Checking ECS agent is joined to ${ECS_CLUSTER}"
until [[ "$(curl --fail --silent http://localhost:51678/v1/metadata | jq '.Cluster // empty' -r -e)" == ${ECS_CLUSTER} ]]
 do printf '.'
 sleep 5
done
echo "ECS agent successfully joined to ${ECS_CLUSTER}"


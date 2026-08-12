#!/usr/bin/env bash
# Launch ONE fresh Graviton m7g.xlarge, rsync this repo up, run the litellm-rust
# calibration control, pull results/calibration back, TERMINATE the box.
# Same infra (keypair + SSH-from-here SG) as bench/run-on-ec2.sh.
set -euo pipefail
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ITYPE="m7g.xlarge"
SSM="/aws/service/canonical/ubuntu/server/24.04/stable/current/arm64/hvm/ebs-gp3/ami-id"
KEYNAME="aigwbench-key"; KEYFILE="${TMPDIR:-/tmp}/${KEYNAME}.pem"; SGNAME="aigwbench-sg"
SSHOPT="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=12 -i $KEYFILE"
log() { echo "[$(date +%H:%M:%S)] $*"; }

if [[ ! -f "$KEYFILE" ]]; then
  aws ec2 delete-key-pair --key-name "$KEYNAME" >/dev/null 2>&1 || true
  aws ec2 create-key-pair --key-name "$KEYNAME" --query KeyMaterial --output text > "$KEYFILE"; chmod 600 "$KEYFILE"
fi
SG=$(aws ec2 describe-security-groups --group-names "$SGNAME" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)
[[ -z "$SG" || "$SG" == "None" ]] && SG=$(aws ec2 create-security-group --group-name "$SGNAME" --description "AIGatewayBench SSH" --query GroupId --output text)
MYIP=$(curl -s https://checkip.amazonaws.com)
aws ec2 authorize-security-group-ingress --group-id "$SG" --protocol tcp --port 22 --cidr "${MYIP}/32" >/dev/null 2>&1 || true

AMI=$(aws ssm get-parameter --name "$SSM" --query Parameter.Value --output text)
log "launching $ITYPE ($AMI)"
IID=$(aws ec2 run-instances --image-id "$AMI" --instance-type "$ITYPE" --key-name "$KEYNAME" \
  --security-group-ids "$SG" \
  --block-device-mappings 'DeviceName=/dev/sda1,Ebs={VolumeSize=40,VolumeType=gp3}' \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=aigwbench-calibrate},{Key=purpose,Value=aigwbench}]' \
  --query 'Instances[0].InstanceId' --output text)
trap 'log "TERMINATING $IID"; aws ec2 terminate-instances --instance-ids "$IID" >/dev/null 2>&1 || true' EXIT
log "launched $IID — waiting for running"
aws ec2 wait instance-running --instance-ids "$IID"
IP=$(aws ec2 describe-instances --instance-ids "$IID" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
log "ip=$IP — waiting for ssh"
for _ in $(seq 1 40); do ssh $SSHOPT ubuntu@"$IP" true 2>/dev/null && break || sleep 8; done

log "installing base build deps on box"
ssh $SSHOPT ubuntu@"$IP" 'sudo apt-get update -q && sudo apt-get install -y -q build-essential pkg-config libssl-dev python3-venv python3-pip git' 2>&1 | sed 's/^/  [setup] /'

log "rsync repo up (excluding target/.git/results/node_modules)"
rsync -az --delete -e "ssh $SSHOPT" \
  --exclude target --exclude .git --exclude results --exclude node_modules --exclude '*/target' \
  "$HERE/" ubuntu@"$IP":~/ai-gateway-bench/

log "running calibration on the box (build + 2 variants; takes a while)…"
ssh $SSHOPT ubuntu@"$IP" 'cd ~/ai-gateway-bench && bash bench/calibrate-litellm-rust.sh' 2>&1 | sed 's/^/  [calib] /'

log "pulling results/calibration back"
mkdir -p "$HERE/results/calibration"
rsync -az -e "ssh $SSHOPT" ubuntu@"$IP":~/ai-gateway-bench/results/calibration/ "$HERE/results/calibration/" || true
log "done — report at results/calibration/report.json"

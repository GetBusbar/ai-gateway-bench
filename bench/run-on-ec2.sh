#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# One-click AIGatewayBench on a FRESH EC2 box.
#
# Spins up a clean Ubuntu 24.04 instance (matching the disclosed hardware:
# 4 vCPU / 16 GB; Graviton m7g.xlarge on arm64, or m7i.xlarge on x86), runs the
# full benchmark via bench/run-all.sh, pulls the results + regenerated charts
# back, and TERMINATES the instance. Nothing persists between runs, so the
# numbers are reproducible from a cold box — run it as many times as you like.
#
#   ./bench/run-on-ec2.sh --arch arm64            # one fresh Graviton run
#   ./bench/run-on-ec2.sh --arch x86  --runs 3    # three fresh x86 runs
#
# Requires: awscli v2 (configured creds + a region), ssh, rsync, git.
# The Graviton box's $/vCPU-hour ($0.1632/4 = $0.0408) matches AIGatewayBench's
# own $0.04/vCPU-hour cost model — i.e. their published numbers are Graviton.
# ---------------------------------------------------------------------------
set -euo pipefail

ARCH="arm64"
RUNS=1
FORK_URL="https://github.com/GetBusbar/ai-gateway-bench.git"
REGION="${AWS_DEFAULT_REGION:-us-east-1}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch) ARCH="$2"; shift 2 ;;
    --runs) RUNS="$2"; shift 2 ;;
    --region) REGION="$2"; shift 2 ;;
    --fork) FORK_URL="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
export AWS_DEFAULT_REGION="$REGION"

case "$ARCH" in
  arm64) ITYPE="m7g.xlarge"; SSM="/aws/service/canonical/ubuntu/server/24.04/stable/current/arm64/hvm/ebs-gp3/ami-id" ;;
  x86)   ITYPE="m7i.xlarge"; SSM="/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id" ;;
  *) echo "--arch must be arm64 or x86" >&2; exit 2 ;;
esac

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEYNAME="aigwbench-key"
KEYFILE="${TMPDIR:-/tmp}/${KEYNAME}.pem"
SGNAME="aigwbench-sg"
SSHOPT="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -i $KEYFILE"

log() { echo "[$(date +%H:%M:%S)] $*"; }

# ── one-time infra: keypair + SSH-from-here security group ──────────────────
ensure_infra() {
  if [[ ! -f "$KEYFILE" ]]; then
    aws ec2 delete-key-pair --key-name "$KEYNAME" >/dev/null 2>&1 || true
    aws ec2 create-key-pair --key-name "$KEYNAME" --query KeyMaterial --output text > "$KEYFILE"
    chmod 600 "$KEYFILE"
  fi
  SG=$(aws ec2 describe-security-groups --group-names "$SGNAME" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)
  if [[ -z "$SG" || "$SG" == "None" ]]; then
    SG=$(aws ec2 create-security-group --group-name "$SGNAME" --description "AIGatewayBench SSH" --query GroupId --output text)
  fi
  local myip; myip=$(curl -s https://checkip.amazonaws.com)
  aws ec2 authorize-security-group-ingress --group-id "$SG" --protocol tcp --port 22 --cidr "${myip}/32" >/dev/null 2>&1 || true
  echo "$SG"
}

one_run() {
  local run_no="$1" sg="$2" ami iid ip
  ami=$(aws ssm get-parameter --name "$SSM" --query Parameter.Value --output text)
  log "run $run_no/$RUNS · $ARCH · $ITYPE · $ami"
  iid=$(aws ec2 run-instances --image-id "$ami" --instance-type "$ITYPE" --key-name "$KEYNAME" \
    --security-group-ids "$sg" \
    --block-device-mappings 'DeviceName=/dev/sda1,Ebs={VolumeSize=40,VolumeType=gp3}' \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=aigwbench-${ARCH}-r${run_no}},{Key=purpose,Value=aigwbench}]" \
    --query 'Instances[0].InstanceId' --output text)
  # Always terminate, even on error.
  trap 'log "terminating $iid"; aws ec2 terminate-instances --instance-ids "$iid" >/dev/null 2>&1 || true' RETURN
  log "launched $iid — waiting for running"
  aws ec2 wait instance-running --instance-ids "$iid"
  ip=$(aws ec2 describe-instances --instance-ids "$iid" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
  log "ip=$ip — waiting for ssh"
  for _ in $(seq 1 30); do ssh $SSHOPT ubuntu@"$ip" true 2>/dev/null && break || sleep 8; done

  local out="$HERE/results/${ARCH}/run${run_no}"
  mkdir -p "$out"
  log "running bench/run-all.sh on the box (this takes a while)…"
  ssh $SSHOPT ubuntu@"$ip" "set -e; git clone --depth 1 $FORK_URL ~/ai-gateway-bench && cd ~/ai-gateway-bench && bash bench/run-all.sh" 2>&1 | sed "s/^/  [$ARCH r$run_no] /"
  log "pulling results → results/${ARCH}/run${run_no}/"
  rsync -az -e "ssh $SSHOPT" ubuntu@"$ip":~/ai-gateway-bench/results/ "$out/" || true
}

SG=$(ensure_infra)
log "arch=$ARCH type=$ITYPE runs=$RUNS region=$REGION sg=$SG"
for n in $(seq 1 "$RUNS"); do ( one_run "$n" "$SG" ); done
log "done — results under results/${ARCH}/run*/"

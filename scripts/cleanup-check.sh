#!/usr/bin/env bash
#
# cleanup-check.sh
#
# A read-only audit of everything still costing money in your AWS Academy
# account, against the fixed $50 you get for the whole term.
#
# It DELETES NOTHING. It tells you what is there and prints the command
# that would remove each item, so that you decide.
#
# Run it at the end of every session. The most common way to run out of
# budget is an instance from three weeks ago that nobody looked at again.
#
# Usage:  ./scripts/cleanup-check.sh

set -uo pipefail

if ! command -v aws >/dev/null 2>&1; then
  echo "The AWS CLI is not installed. Are you on the workstation?" >&2
  exit 1
fi

if ! aws sts get-caller-identity >/dev/null 2>&1; then
  echo "AWS credentials are not working. Click Start Lab on Vocareum and retry." >&2
  exit 1
fi

FOUND=0
hdr() { echo ""; echo "== $*"; }
item() { echo "   $*"; FOUND=$((FOUND+1)); }
cmd()  { echo "      -> $*"; }

# ---------- running and stopped instances ----------
# A stopped instance costs nothing for compute but its root volume still
# bills, so both are worth seeing. The workstation is called out by name
# rather than hidden -- it is meant to survive, but you should still know
# it is there.
hdr "EC2 instances"
while read -r id state itype name; do
    [ -z "${id:-}" ] && continue
    if [ "${name:-}" = "acs730-workstation" ]; then
      echo "   $id  $state  $itype  $name   (your workstation -- keep this)"
    else
      item "$id  $state  $itype  ${name:-no-name}"
      cmd "aws ec2 terminate-instances --instance-ids $id"
    fi
done < <(aws ec2 describe-instances \
  --filters "Name=instance-state-name,Values=running,stopped" \
  --query 'Reservations[].Instances[].[InstanceId,State.Name,InstanceType,(Tags[?Key==`Name`].Value|[0])]' \
  --output text 2>/dev/null)

# ---------- AMIs and the snapshots behind them ----------
# Deregistering an AMI does not delete its snapshot, and the snapshot is
# the part that bills. This is the single most-missed leftover in Lab 6.
hdr "Your AMIs (and their snapshots)"
while read -r ami name snap; do
    [ -z "${ami:-}" ] && continue
    item "$ami  ${name:-}  snapshot ${snap:-none}"
    cmd "aws ec2 deregister-image --image-id $ami"
    [ -n "${snap:-}" ] && [ "$snap" != "None" ] && cmd "aws ec2 delete-snapshot --snapshot-id $snap"
done < <(aws ec2 describe-images --owners self \
  --query 'Images[].[ImageId,Name,BlockDeviceMappings[0].Ebs.SnapshotId]' \
  --output text 2>/dev/null)

# ---------- unattached volumes ----------
hdr "Unattached EBS volumes"
while read -r vol size vtype; do
    [ -z "${vol:-}" ] && continue
    item "$vol  ${size}GiB  $vtype"
    cmd "aws ec2 delete-volume --volume-id $vol"
done < <(aws ec2 describe-volumes --filters "Name=status,Values=available" \
  --query 'Volumes[].[VolumeId,Size,VolumeType]' --output text 2>/dev/null)

# ---------- snapshots not tied to an AMI ----------
hdr "Snapshots you own"
while read -r snap size desc; do
    [ -z "${snap:-}" ] && continue
    item "$snap  ${size}GiB  ${desc:-}"
    cmd "aws ec2 delete-snapshot --snapshot-id $snap"
done < <(aws ec2 describe-snapshots --owner-ids self \
  --query 'Snapshots[].[SnapshotId,VolumeSize,Description]' --output text 2>/dev/null)

# ---------- security groups you made ----------
hdr "Non-default security groups"
while read -r sg sgname; do
    [ -z "${sg:-}" ] && continue
    item "$sg  $sgname"
    cmd "aws ec2 delete-security-group --group-id $sg"
done < <(aws ec2 describe-security-groups \
  --query 'SecurityGroups[?GroupName!=`default`].[GroupId,GroupName]' \
  --output text 2>/dev/null)

# ---------- Terraform state that still tracks live resources ----------
# A tfstate with resources in it means Terraform thinks something exists.
# If you destroy by hand instead of with terraform destroy, the state and
# reality drift apart and the next apply does something surprising.
hdr "Terraform state files that still track resources"
while IFS= read -r st; do
  [ -z "$st" ] && continue
  N="$(python3 -c "import json,sys;print(len(json.load(open(sys.argv[1])).get('resources',[])))" "$st" 2>/dev/null || echo "?")"
  if [ "$N" != "0" ] && [ -n "$N" ]; then
    item "$st  tracks $N resource(s)"
    cmd "cd $(dirname "$st") && terraform destroy"
  fi
done < <(find . -name '*.tfstate' -not -path './.git/*' 2>/dev/null)

echo ""
if [ "$FOUND" -eq 0 ]; then
  echo "Nothing left over. Your account is clean."
else
  echo "Review the items above. This script deleted nothing."
fi
echo ""

#!/usr/bin/env bash
# prep-team-vpcs.sh - build each team's Lab 3 network ahead of time (VPC, subnets, internet gateway,
# route tables, security groups), tagged team=<number>.
#
# Usage:
#   ./prep-team-vpcs.sh [-n] [-r region] [-o dir] [team ...]      create (default teams: 1 2 3 4)
#   ./prep-team-vpcs.sh -D [-y] [-r region] team [team ...]       delete what this script created
#   ./prep-team-vpcs.sh -D -A [-y] [-r region]                    delete ALL teams (1 to 4) at once, one confirmation
#
#   -n   dry run: show what would be created or skipped, change nothing
#   -r   region (default: your CLI default region)
#   -o   directory for the per-team value files (default ./team-vpcs)
#   -D   delete mode. Refuses if anything else (instances, endpoints, extra security groups,
#        extra subnets) has been added to the VPC, so it cannot remove students' work.
#   -A   with -D: delete teams 1 to 4 in one go (asks once, not per team)
#   -y   skip the confirmation prompt in delete mode
#
# Per team N this creates, all tagged team=N:
#   VPC            10.(10+N).0.0/16   (team1 10.11, team2 10.12, team3 10.13, team4 10.14)
#   subnets        public  10.x.1.0/24 (AZ a), 10.x.2.0/24 (AZ b)   private 10.x.11.0/24 (AZ a), 10.x.12.0/24 (AZ b)
#   internet gateway, attached
#   public route table  0.0.0.0/0 -> internet gateway, associated with the two public subnets ONLY
#   private subnets stay on the VPC's main route table (local route only)
#   security groups     lab3-teamN-web (80 from anywhere), lab3-teamN-app (8080 from the web group only)
# It is safe to re-run: a team whose VPC already exists is skipped.
# Each team gets a file team-vpcs/team-N.env with the IDs, ready for the Lab 7 and Lab 8 guides.

set -euo pipefail

DRY=0; DELETE=0; ALL=0; YES=0; REGION=""; OUTDIR="team-vpcs"
while getopts ":nDAyr:o:h" opt; do
  case "$opt" in
    n) DRY=1 ;;
    D) DELETE=1 ;;
    A) ALL=1 ;;
    y) YES=1 ;;
    r) REGION="$OPTARG" ;;
    o) OUTDIR="$OPTARG" ;;
    h) sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: -$OPTARG" >&2; exit 1 ;;
  esac
done
shift $((OPTIND - 1))
TEAMS=("$@")
if [ "$ALL" -eq 1 ] && [ "$DELETE" -ne 1 ]; then
  echo "-A only applies to delete mode (-D). To create all teams, just leave the team numbers out." >&2; exit 1
fi
if [ "${#TEAMS[@]}" -eq 0 ]; then
  if [ "$DELETE" -eq 1 ] && [ "$ALL" -ne 1 ]; then
    echo "Delete mode needs team numbers, or -A for all four teams." >&2; exit 1
  fi
  TEAMS=(1 2 3 4)
elif [ "$ALL" -eq 1 ]; then
  echo "Use either -A or a list of teams, not both." >&2; exit 1
fi
for t in "${TEAMS[@]}"; do
  [[ "$t" =~ ^[1-4]$ ]] || { echo "Team must be 1, 2, 3 or 4 (got: $t)" >&2; exit 1; }
done

command -v aws >/dev/null || { echo "Missing required tool: aws" >&2; exit 1; }
if [ -z "$REGION" ]; then
  REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-$(aws configure get region 2>/dev/null || true)}}"
fi
[ -n "$REGION" ] || { echo "No region. Pass -r <region> or set a default region." >&2; exit 1; }
# AWS_REGION outranks AWS_DEFAULT_REGION in the CLI, and CloudShell sets it for you, so set both.
# Otherwise -r would be ignored and the work would land in the console's region.
export AWS_REGION="$REGION" AWS_DEFAULT_REGION="$REGION"
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
echo "Account $ACCOUNT, region $REGION, profile ${AWS_PROFILE:-default}"

find_vpc() {
  aws ec2 describe-vpcs --filters "Name=tag:Name,Values=leap-team$1-vpc" "Name=tag:team,Values=$1" \
    --query 'Vpcs[0].VpcId' --output text
}

# ---------------------------------------------------------------------------------------------
if [ "$DELETE" -eq 1 ]; then
  if [ "$ALL" -eq 1 ] && [ "$DRY" -ne 1 ] && [ "$YES" -ne 1 ]; then
    read -r -p "Delete the network for ALL teams (1 to 4) in $REGION? Teams with extra resources are skipped. [y/N] " a
    [[ "$a" =~ ^[Yy]$ ]] || { echo "Cancelled."; exit 1; }
    YES=1
  fi
  for N in "${TEAMS[@]}"; do
    VPC=$(find_vpc "$N")
    if [ "$VPC" = "None" ] || [ -z "$VPC" ]; then echo "team$N: no VPC found, nothing to delete"; continue; fi

    ENIS=$(aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$VPC" --query 'length(NetworkInterfaces)' --output text)
    SUBNETS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC" --query 'Subnets[].SubnetId' --output text)
    NSUB=$(wc -w <<<"$SUBNETS")
    SGS=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC" \
          --query "SecurityGroups[?GroupName!='default'].[GroupId,GroupName]" --output text)
    OTHERSG=$(grep -v -E "[[:space:]]lab3-team$N-(web|app)\$" <<<"$SGS" | grep -c . || true)
    ENDPOINTS=$(aws ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=$VPC" --query 'length(VpcEndpoints)' --output text)
    NATS=$(aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$VPC" "Name=state,Values=pending,available" \
           --query 'length(NatGateways)' --output text)
    if [ "$ENIS" != "0" ] || [ "$NSUB" -ne 4 ] || [ "$OTHERSG" != "0" ] || [ "$ENDPOINTS" != "0" ] || [ "$NATS" != "0" ]; then
      echo "team$N: $VPC has more in it than this script created (network interfaces: $ENIS, subnets: $NSUB, other security groups: $OTHERSG, endpoints: $ENDPOINTS, NAT gateways: $NATS)."
      echo "        Delete those first (stacks, tasks, endpoints), then run this again. Skipping."
      continue
    fi
    echo "team$N: will delete $VPC, its 4 subnets, route table, internet gateway and 2 security groups"
    if [ "$DRY" -eq 1 ]; then continue; fi
    if [ "$YES" -ne 1 ]; then
      read -r -p "Delete team$N network now? [y/N] " a
      [[ "$a" =~ ^[Yy]$ ]] || { echo "skipped"; continue; }
    fi
    while read -r gid gname; do
      [ "$gname" = "lab3-team$N-app" ] && aws ec2 delete-security-group --group-id "$gid"
    done <<<"$SGS"
    while read -r gid gname; do
      [ "$gname" = "lab3-team$N-web" ] && aws ec2 delete-security-group --group-id "$gid"
    done <<<"$SGS"
    for rt in $(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC" "Name=tag:Name,Values=leap-team$N-public-rt" \
                --query 'RouteTables[].RouteTableId' --output text); do
      for assoc in $(aws ec2 describe-route-tables --route-table-ids "$rt" \
                     --query 'RouteTables[0].Associations[?Main==`false`].RouteTableAssociationId' --output text); do
        aws ec2 disassociate-route-table --association-id "$assoc"
      done
      aws ec2 delete-route-table --route-table-id "$rt"
    done
    for igw in $(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC" \
                 --query 'InternetGateways[].InternetGatewayId' --output text); do
      aws ec2 detach-internet-gateway --internet-gateway-id "$igw" --vpc-id "$VPC"
      aws ec2 delete-internet-gateway --internet-gateway-id "$igw"
    done
    for s in $SUBNETS; do aws ec2 delete-subnet --subnet-id "$s"; done
    aws ec2 delete-vpc --vpc-id "$VPC"
    rm -f "$OUTDIR/team-$N.env"
    echo "team$N: deleted"
  done
  exit 0
fi

# ---------------------------------------------------------------------------------------------
mapfile -t AZS < <(aws ec2 describe-availability-zones --filters Name=state,Values=available \
                   --query 'AvailabilityZones[0:2].ZoneName' --output text | tr '\t' '\n')
[ "${#AZS[@]}" -eq 2 ] || { echo "Could not find two Availability Zones in $REGION" >&2; exit 1; }
case "${AZS[0]}" in "$REGION"*) ;; *) echo "The CLI is working in a different region than $REGION (zone ${AZS[0]}). Stopping." >&2; exit 1 ;; esac
echo "Availability Zones: ${AZS[0]} ${AZS[1]}"
mkdir -p "$OUTDIR"

for N in "${TEAMS[@]}"; do
  X=$((10 + N))
  CIDR="10.$X.0.0/16"
  EXISTING=$(find_vpc "$N")
  if [ "$EXISTING" != "None" ] && [ -n "$EXISTING" ]; then
    echo "team$N: VPC $EXISTING already exists, skipping"
    continue
  fi
  if [ "$DRY" -eq 1 ]; then
    echo "team$N: would create VPC $CIDR; public 10.$X.1.0/24 10.$X.2.0/24; private 10.$X.11.0/24 10.$X.12.0/24; IGW; public route table; 2 security groups"
    continue
  fi

  tags() { echo "ResourceType=$1,Tags=[{Key=Name,Value=$2},{Key=team,Value=$N}]"; }
  echo "team$N: creating network $CIDR ..."

  VPC=$(aws ec2 create-vpc --cidr-block "$CIDR" --tag-specifications "$(tags vpc leap-team$N-vpc)" \
        --query 'Vpc.VpcId' --output text)
  aws ec2 wait vpc-available --vpc-ids "$VPC"
  # DNS support and hostnames are needed later for VPC interface endpoints (Lab 8).
  aws ec2 modify-vpc-attribute --vpc-id "$VPC" --enable-dns-support '{"Value":true}'
  aws ec2 modify-vpc-attribute --vpc-id "$VPC" --enable-dns-hostnames '{"Value":true}'

  mk_subnet() { # name cidr az
    aws ec2 create-subnet --vpc-id "$VPC" --cidr-block "$2" --availability-zone "$3" \
      --tag-specifications "$(tags subnet "$1")" --query 'Subnet.SubnetId' --output text
  }
  PUB_A=$(mk_subnet "leap-team$N-public-a"  "10.$X.1.0/24"  "${AZS[0]}")
  PUB_B=$(mk_subnet "leap-team$N-public-b"  "10.$X.2.0/24"  "${AZS[1]}")
  PRIV_A=$(mk_subnet "leap-team$N-private-a" "10.$X.11.0/24" "${AZS[0]}")
  PRIV_B=$(mk_subnet "leap-team$N-private-b" "10.$X.12.0/24" "${AZS[1]}")
  for s in "$PUB_A" "$PUB_B"; do aws ec2 modify-subnet-attribute --subnet-id "$s" --map-public-ip-on-launch; done

  IGW=$(aws ec2 create-internet-gateway --tag-specifications "$(tags internet-gateway leap-team$N-igw)" \
        --query 'InternetGateway.InternetGatewayId' --output text)
  aws ec2 attach-internet-gateway --internet-gateway-id "$IGW" --vpc-id "$VPC"
  ATTACHED=$(aws ec2 describe-internet-gateways --internet-gateway-ids "$IGW" \
             --query 'InternetGateways[0].Attachments[0].VpcId' --output text)
  [ "$ATTACHED" = "$VPC" ] || { echo "team$N: internet gateway $IGW did not attach to $VPC" >&2; exit 1; }

  # The public route table has the internet route and goes on the two public subnets only. The
  # private subnets are left on the VPC's main route table, which has only the local route.
  RT=$(aws ec2 create-route-table --vpc-id "$VPC" --tag-specifications "$(tags route-table leap-team$N-public-rt)" \
       --query 'RouteTable.RouteTableId' --output text)
  aws ec2 create-route --route-table-id "$RT" --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW" >/dev/null
  aws ec2 associate-route-table --route-table-id "$RT" --subnet-id "$PUB_A" >/dev/null
  aws ec2 associate-route-table --route-table-id "$RT" --subnet-id "$PUB_B" >/dev/null
  MAIN_RT=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC" "Name=association.main,Values=true" \
            --query 'RouteTables[0].RouteTableId' --output text)
  aws ec2 create-tags --resources "$MAIN_RT" --tags "Key=Name,Value=leap-team$N-main-rt" "Key=team,Value=$N"

  WEB_SG=$(aws ec2 create-security-group --group-name "lab3-team$N-web" --description "Lab 3 web tier, HTTP from anywhere" \
           --vpc-id "$VPC" --tag-specifications "$(tags security-group lab3-team$N-web)" --query 'GroupId' --output text)
  aws ec2 authorize-security-group-ingress --group-id "$WEB_SG" --protocol tcp --port 80 --cidr 0.0.0.0/0 >/dev/null
  APP_SG=$(aws ec2 create-security-group --group-name "lab3-team$N-app" --description "Lab 3 app tier, port 8080 from the web group only" \
           --vpc-id "$VPC" --tag-specifications "$(tags security-group lab3-team$N-app)" --query 'GroupId' --output text)
  aws ec2 authorize-security-group-ingress --group-id "$APP_SG" --protocol tcp --port 8080 --source-group "$WEB_SG" >/dev/null

  # Check by route table, not by subnet flags (README step 9): the public ones must have a route
  # to the internet gateway, and the private ones must not.
  PUBLIC_COUNT=$(aws ec2 describe-route-tables --route-table-ids "$RT" \
                 --query 'length(RouteTables[0].Associations[?SubnetId!=`null`])' --output text)
  [ "$PUBLIC_COUNT" = "2" ] || { echo "team$N: expected 2 public subnet associations, found $PUBLIC_COUNT" >&2; exit 1; }

  cat > "$OUTDIR/team-$N.env" <<ENV
# Team $N network, region $REGION. Use:  source team-$N.env
export REGION=$REGION
export TEAM=$N
export VPC=$VPC
export PUB="$PUB_A,$PUB_B"
export PRIV="$PRIV_A,$PRIV_B"
export PUBLIC_RT=$RT
export IGW=$IGW
# Lab 3 security groups only, for the Lab 3 exercise. They do NOT go on Lab 7 or Lab 8 tasks:
# the Lab 7 stack creates its own app security group (its AppSecurityGroupId output) for those.
export LAB3_WEB_SG=$WEB_SG
export LAB3_APP_SG=$APP_SG
ENV
  echo "team$N: done. VPC $VPC  public $PUB_A,$PUB_B  private $PRIV_A,$PRIV_B  -> $OUTDIR/team-$N.env"
done
echo "Finished."

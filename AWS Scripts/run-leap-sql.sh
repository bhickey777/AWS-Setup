#!/usr/bin/env bash
# run-sql.sh - run .sql files against a LEAP team's RDS PostgreSQL database.
#
# Run this from a CloudShell VPC environment created in the team's region, with the
# stack's TasksSecurityGroup attached (the database only accepts that group on 5432).
#
# Usage:
#   ./run-sql.sh [-y] [-t] <team> <file.sql|directory> [more files or directories...]
#
#   <team>   team1 .. team5
#   -y       skip the confirmation prompt
#   -t       run each file in a single transaction (psql -1). Do not use for scripts
#            containing CREATE DATABASE, VACUUM, CREATE INDEX CONCURRENTLY, etc.
#
# A directory runs its *.sql files in name order (so 01_schema.sql, 02_data.sql ...).
# Any SQL error stops the run (ON_ERROR_STOP).
#
# Environment overrides: REGION, STACK_NAME, DB_NAME, DB_USER

set -euo pipefail

# ---- per-team regions ------------------------------------------------------
declare -A TEAM_REGION=(
  [team1]=us-east-1
  [team2]=us-east-2
  [team3]=us-west-1
  [team4]=us-west-2
  [team5]=ca-central-1
)

usage() { sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-1}"; }

ASSUME_YES=0
SINGLE_TX=0
while getopts ":yth" opt; do
  case "$opt" in
    y) ASSUME_YES=1 ;;
    t) SINGLE_TX=1 ;;
    h) usage 0 ;;
    *) echo "Unknown option: -$OPTARG" >&2; usage ;;
  esac
done
shift $((OPTIND - 1))

[ $# -ge 2 ] || usage

TEAM="$1"; shift
REGION="${REGION:-${TEAM_REGION[$TEAM]:-}}"
[ -n "$REGION" ] || { echo "Unknown team '$TEAM' (expected team1..team5, or set REGION)." >&2; exit 1; }

STACK_NAME="${STACK_NAME:-leap-$TEAM}"
DB_INSTANCE="leap-$TEAM-postgres"
DB_NAME="${DB_NAME:-leap}"
DB_USER="${DB_USER:-leapadmin}"

# ---- collect the SQL files up front, so a typo fails before anything runs ---
FILES=()
for arg in "$@"; do
  if [ -d "$arg" ]; then
    mapfile -t found < <(find "$arg" -maxdepth 1 -type f -name '*.sql' | sort)
    [ "${#found[@]}" -gt 0 ] || { echo "No .sql files in directory: $arg" >&2; exit 1; }
    FILES+=("${found[@]}")
  elif [ -f "$arg" ]; then
    FILES+=("$arg")
  else
    echo "Not a file or directory: $arg" >&2; exit 1
  fi
done

# ---- tools -----------------------------------------------------------------
for tool in aws jq; do
  command -v "$tool" >/dev/null || { echo "Missing required tool: $tool" >&2; exit 1; }
done
if ! command -v psql >/dev/null; then
  echo "psql not found; installing the PostgreSQL client (needs outbound access via the NAT gateway)..."
  sudo dnf install -y postgresql15 >/dev/null
fi

# ---- look up the database --------------------------------------------------
echo "Looking up $DB_INSTANCE in $REGION ..."
HOST=$(aws rds describe-db-instances --region "$REGION" \
  --db-instance-identifier "$DB_INSTANCE" \
  --query 'DBInstances[0].Endpoint.Address' --output text)
PORT=$(aws rds describe-db-instances --region "$REGION" \
  --db-instance-identifier "$DB_INSTANCE" \
  --query 'DBInstances[0].Endpoint.Port' --output text)
SECRET_ARN=$(aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK_NAME" \
  --query "Stacks[0].Outputs[?OutputKey=='DatabaseMasterSecretArn'].OutputValue" --output text)

if [ -z "$HOST" ] || [ "$HOST" = "None" ] || [ -z "$SECRET_ARN" ] || [ "$SECRET_ARN" = "None" ]; then
  echo "Could not find the database endpoint or secret for $TEAM in $REGION." >&2
  exit 1
fi

# ---- confirm, so the wrong team is not loaded by accident --------------------
echo
echo "  Team:      $TEAM"
echo "  Region:    $REGION"
echo "  Database:  $DB_NAME on $HOST:$PORT (user $DB_USER)"
echo "  Mode:      $([ "$SINGLE_TX" -eq 1 ] && echo 'each file in one transaction' || echo 'statement by statement')"
echo "  Files:"
printf '    %s\n' "${FILES[@]}"
echo
if [ "$ASSUME_YES" -ne 1 ]; then
  read -r -p "Run these against $TEAM? [y/N] " answer
  [[ "$answer" =~ ^[Yy]$ ]] || { echo "Cancelled."; exit 1; }
fi

# ---- fetch the password (never printed) ----------------------------------------
PGPASSWORD=$(aws secretsmanager get-secret-value --region "$REGION" --secret-id "$SECRET_ARN" \
  --query SecretString --output text | jq -r .password)
export PGPASSWORD
export PGCONNECT_TIMEOUT=10
trap 'unset PGPASSWORD' EXIT

CONN="host=$HOST port=$PORT dbname=$DB_NAME user=$DB_USER sslmode=require"

# ---- connectivity check, with a hint for the usual mistake --------------------
if ! psql "$CONN" -qtAc 'select 1' >/dev/null 2>&1; then
  cat >&2 <<EOF
Could not connect to the database.
The usual cause is running outside the team's VPC. Check that:
  - this CloudShell is a VPC environment created in $REGION,
  - it uses a private subnet of the $STACK_NAME VPC,
  - the stack's TasksSecurityGroup is attached to it.
EOF
  exit 1
fi

# ---- run the files -------------------------------------------------------------
PSQL_FLAGS=(-v ON_ERROR_STOP=1 -X)
[ "$SINGLE_TX" -eq 1 ] && PSQL_FLAGS+=(-1)

for f in "${FILES[@]}"; do
  echo "=== Running $f"
  psql "$CONN" "${PSQL_FLAGS[@]}" -f "$f"
done

echo
echo "Done: ${#FILES[@]} file(s) applied to $TEAM ($DB_NAME)."

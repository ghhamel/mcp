#!/usr/bin/env bash
#
# Wrapper for the RDS Proxy auto-detection e2e harness.
#
# Refreshes AWS credentials with `ada`, then runs the proxy harness against RDS
# instances that ALREADY EXIST in your account. Unlike run_e2e.sh, this
# provisions nothing and deletes nothing, and every query it issues is a SELECT.
#
# What it needs from you:
#   --db-instance-identifier  a standalone RPG instance that IS fronted by a proxy
#   --no-proxy-instance       an instance with NO proxy (the control; recommended)
#
# Instances are named by DB instance IDENTIFIER (or ARN), and --database is the
# PostgreSQL database name inside the instance. --secret-arn is OPTIONAL: the
# server discovers the instance's MasterUserSecret on its own. Supply it only if
# the instance has no managed master password, or to also exercise the per-target
# secret override path.
#
# Network: RDS Proxy endpoints are normally private, so this generally has to run
# from inside the VPC, or over VPN with the proxy's security group allowing your
# egress. A 30s TLS handshake timeout in the harness usually means reachability,
# not a certificate problem.
#
# Usage:
#   tests/e2e/run_proxy_e2e.sh \
#       --account-id 123456789012 \
#       --role ReadOnly \
#       --region us-east-1 \
#       --db-instance-identifier my-proxied-instance \
#       [--no-proxy-instance my-bare-instance] \
#       [--database postgres] \
#       [--secret-arn arn:aws:secretsmanager:...]   # optional, see below \
#       [--auth-type pg_wire_secret|pg_wire_iam] \
#       [--sslmode verify-full] \
#       [--ca-bundle path|system] \
#       [--privilege-check off|warn|enforce] \
#       [--log-level INFO] \
#       [--log-file path.log] \
#       [--provider isengard] \
#       [--skip-cred-refresh]
#
# A ReadOnly role is sufficient and preferred: the harness only calls describe_*
# RDS APIs, reads one Secrets Manager secret, and runs SELECTs.
#
# Anything after a literal `--` is passed straight through to the harness.
set -euo pipefail

usage() {
  awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"
  exit "${1:-0}"
}

# --- defaults -------------------------------------------------------------
ACCOUNT_ID=""
ROLE=""
REGION=""
DB_INSTANCE=""
NO_PROXY_INSTANCE=""
DATABASE=""
SECRET_ARN=""
AUTH_TYPE=""
SSLMODE=""
CA_BUNDLE=""
PRIVILEGE_CHECK=""
PROVIDER="isengard"
LOG_LEVEL="INFO"
LOG_FILE=""
SKIP_CRED_REFRESH="false"
PASSTHROUGH=()

# --- parse args -----------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --account-id)              ACCOUNT_ID="$2"; shift 2 ;;
    --role)                    ROLE="$2"; shift 2 ;;
    --region)                  REGION="$2"; shift 2 ;;
    --db-instance-identifier)  DB_INSTANCE="$2"; shift 2 ;;
    --no-proxy-instance)       NO_PROXY_INSTANCE="$2"; shift 2 ;;
    --database)                DATABASE="$2"; shift 2 ;;
    --secret-arn)              SECRET_ARN="$2"; shift 2 ;;
    --auth-type)               AUTH_TYPE="$2"; shift 2 ;;
    --sslmode)                 SSLMODE="$2"; shift 2 ;;
    --ca-bundle)               CA_BUNDLE="$2"; shift 2 ;;
    --privilege-check)         PRIVILEGE_CHECK="$2"; shift 2 ;;
    --provider)                PROVIDER="$2"; shift 2 ;;
    --log-level)               LOG_LEVEL="$2"; shift 2 ;;
    --log-file)                LOG_FILE="$2"; shift 2 ;;
    --skip-cred-refresh)       SKIP_CRED_REFRESH="true"; shift ;;
    -h|--help)                 usage 0 ;;
    --)                        shift; PASSTHROUGH+=("$@"); break ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage 1 ;;
  esac
done

# --- validate -------------------------------------------------------------
missing=()
[[ -z "$REGION" ]] && missing+=("--region")
[[ -z "$DB_INSTANCE" ]] && missing+=("--db-instance-identifier")
if [[ "$SKIP_CRED_REFRESH" != "true" ]]; then
  [[ -z "$ACCOUNT_ID" ]] && missing+=("--account-id")
  [[ -z "$ROLE" ]] && missing+=("--role")
fi
if [[ ${#missing[@]} -gt 0 ]]; then
  echo "ERROR: missing required argument(s): ${missing[*]}" >&2
  usage 1
fi

if [[ -z "$NO_PROXY_INSTANCE" ]]; then
  echo ">> WARNING: no --no-proxy-instance given; the direct-connection fallback"
  echo ">>          will not be exercised."
fi

# Run from the package root so `uv run` and the relative test path resolve
# regardless of the caller's working directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

if [[ -z "$LOG_FILE" ]]; then
  LOG_FILE="$REPO_ROOT/proxy-e2e-$(date +%Y%m%d-%H%M%S).log"
fi

# --- refresh credentials --------------------------------------------------
if [[ "$SKIP_CRED_REFRESH" == "true" ]]; then
  echo ">> Skipping credential refresh (--skip-cred-refresh)"
else
  if ! command -v ada >/dev/null 2>&1; then
    echo "ERROR: 'ada' not found on PATH; install it or pass --skip-cred-refresh" >&2
    exit 1
  fi
  echo ">> Refreshing AWS credentials via ada (account=$ACCOUNT_ID role=$ROLE provider=$PROVIDER)"
  ada credentials update \
    --account="$ACCOUNT_ID" \
    --provider="$PROVIDER" \
    --role="$ROLE" \
    --once
fi

if ! aws sts get-caller-identity --region "$REGION" >/dev/null 2>&1; then
  echo "ERROR: AWS credentials are not valid (aws sts get-caller-identity failed)." >&2
  echo "       Refresh them (ada) or check --account-id/--role/--provider." >&2
  exit 1
fi

# --- build harness command ------------------------------------------------
cmd=(uv run --frozen python tests/e2e/proxy_e2e_test.py
     --region "$REGION"
     --db-instance-identifier "$DB_INSTANCE"
     --log-level "$LOG_LEVEL")
[[ -n "$NO_PROXY_INSTANCE" ]] && cmd+=(--no-proxy-instance "$NO_PROXY_INSTANCE")
[[ -n "$DATABASE" ]] && cmd+=(--database "$DATABASE")
[[ -n "$SECRET_ARN" ]] && cmd+=(--secret-arn "$SECRET_ARN")
[[ -n "$AUTH_TYPE" ]] && cmd+=(--auth-type "$AUTH_TYPE")
[[ -n "$SSLMODE" ]] && cmd+=(--sslmode "$SSLMODE")
[[ -n "$CA_BUNDLE" ]] && cmd+=(--ca-bundle "$CA_BUNDLE")
[[ -n "$PRIVILEGE_CHECK" ]] && cmd+=(--privilege-check "$PRIVILEGE_CHECK")
if [[ ${#PASSTHROUGH[@]} -gt 0 ]]; then
  cmd+=("${PASSTHROUGH[@]}")
fi

echo ">> proxied-instance=$DB_INSTANCE control=${NO_PROXY_INSTANCE:-<none>}"
echo ">> Running: ${cmd[*]}"
echo ">> Logging to: $LOG_FILE"

set +e
"${cmd[@]}" 2>&1 | tee "$LOG_FILE"
status=${PIPESTATUS[0]}
set -e

echo ">> proxy e2e exited with status $status (log: $LOG_FILE)"
exit "$status"

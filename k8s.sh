#!/bin/bash

set -euo pipefail

# ============================================================
# Colors for output
# ============================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ============================================================
# Helper Functions
# ============================================================
print_status()   { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warning()  { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error()    { echo -e "${RED}[ERROR]${NC} $1"; }
print_header()   { echo -e "${BLUE}=== $1 ===${NC}"; }
print_success()  { echo -e "${GREEN}[SUCCESS]${NC} $1"; }

# ============================================================
# Configuration Variables
# ============================================================
# Deployment environment selects k8s/values/<DEPLOY_ENV>.yaml
DEPLOY_ENV="${DEPLOY_ENV:-uat}"

# Helm values file for this environment
VALUES_FILE="${VALUES_FILE:-k8s/values/${DEPLOY_ENV}.yaml}"

# Namespace ต้องอ่านมาจาก values file แหล่งเดียว เพราะทุก template ตั้ง
# metadata.namespace จาก .Values.namespace ถ้า kubectl กับ helm ใช้คนละ namespace
# ConfigMap จะไปอยู่คนละที่กับ Deployment แล้ว pod จะค้างที่ CreateContainerConfigError
if [ -z "${NAMESPACE:-}" ] && [ -f "$VALUES_FILE" ]; then
  NAMESPACE="$(awk '/^namespace:/ { print $2; exit }' "$VALUES_FILE")"
fi
NAMESPACE="${NAMESPACE:-apcms}"

# Helm release name — all resources are prefixed with this
# (Deployments/Services are named "<RELEASE>-<component>[-service]",
#  pod labels are "app=<RELEASE>-<component>"). Must match k8s/templates/*.
RELEASE="${RELEASE:-apcms-${DEPLOY_ENV}}"

# Environment file for the app ConfigMap
ENV_FILE="${ENV_FILE:-.env}"

# ConfigMap / Secret names (must match k8s/templates/*.yaml)
CONFIGMAP_NAME="${CONFIGMAP_NAME:-apcms-env}"
DOTENV_CONFIGMAP_NAME="${DOTENV_CONFIGMAP_NAME:-apcms-dotenv}"
POSTGRES_SECRET_NAME="${POSTGRES_SECRET_NAME:-apcms-postgres-secret}"

# ============================================================
# Namespace Management
# ============================================================
create_namespace() {
  print_header "Creating Namespace"

  if kubectl get namespace "$NAMESPACE" &>/dev/null; then
    print_status "Namespace $NAMESPACE already exists"
  else
    kubectl create namespace "$NAMESPACE"
    print_success "Namespace created: $NAMESPACE"
  fi
}

# ============================================================
# ConfigMap Management
# ============================================================
create_configmap() {
  print_header "Creating AP CMS ConfigMaps"

  if [ ! -f "$ENV_FILE" ]; then
    print_error "Environment file not found: $ENV_FILE"
    exit 1
  fi

  print_status "Creating ConfigMap from: $ENV_FILE"

  kubectl delete configmap "$CONFIGMAP_NAME" -n "$NAMESPACE" 2>/dev/null || true

  kubectl create configmap "$CONFIGMAP_NAME" \
    --from-env-file="$ENV_FILE" \
    --namespace="$NAMESPACE"

  print_success "ConfigMap created: $CONFIGMAP_NAME"

  # The mail image reads config from a real .env FILE at /app/.env, not from
  # OS env vars, so we also publish the raw file as a single-key ConfigMap
  # that the mail Deployment mounts.
  print_status "Creating dotenv-file ConfigMap: $DOTENV_CONFIGMAP_NAME"

  kubectl delete configmap "$DOTENV_CONFIGMAP_NAME" -n "$NAMESPACE" 2>/dev/null || true

  kubectl create configmap "$DOTENV_CONFIGMAP_NAME" \
    --from-file=.env="$ENV_FILE" \
    --namespace="$NAMESPACE"

  print_success "ConfigMap created: $DOTENV_CONFIGMAP_NAME"
}

# ============================================================
# Secret Management
# ============================================================
create_secret() {
  print_header "Creating PostgreSQL Secret"

  if [ -z "${POSTGRES_USER:-}" ] || [ -z "${POSTGRES_PASSWORD:-}" ] || [ -z "${POSTGRES_DB:-}" ]; then
    print_error "POSTGRES_USER, POSTGRES_PASSWORD and POSTGRES_DB must be set in the environment"
    print_status "Usage: POSTGRES_USER=... POSTGRES_PASSWORD=... POSTGRES_DB=... $0 create-secret"
    exit 1
  fi

  kubectl delete secret "$POSTGRES_SECRET_NAME" -n "$NAMESPACE" 2>/dev/null || true

  kubectl create secret generic "$POSTGRES_SECRET_NAME" \
    --from-literal=POSTGRES_USER="$POSTGRES_USER" \
    --from-literal=POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
    --from-literal=POSTGRES_DB="$POSTGRES_DB" \
    --namespace="$NAMESPACE"

  print_success "Secret created: $POSTGRES_SECRET_NAME"
}

# ============================================================
# Deployment Management
# ============================================================
deploy() {
  print_header "Deploying with Helm"

  local chart_dir="k8s"

  if [ ! -f "$VALUES_FILE" ]; then
    print_error "Values file not found: $VALUES_FILE"
    exit 1
  fi

  print_status "Deploying release: $RELEASE"
  print_status "Deploying to namespace: $NAMESPACE"
  print_status "Using values file: $VALUES_FILE"

  helm upgrade --install "$RELEASE" "$chart_dir" \
    --namespace "$NAMESPACE" \
    --values "$VALUES_FILE" \
    --wait

  print_success "Deployment completed successfully"
  echo ""
  print_status "Pods status:"
  kubectl get pods -n "$NAMESPACE"
}

# ============================================================
# Pod Management
# ============================================================
get_pods() {
  print_header "Getting Pods Status"
  kubectl get pods -n "$NAMESPACE" -o wide
}

get_all() {
  print_header "Getting All Resources"
  kubectl get all -n "$NAMESPACE"
}

get_ingress() {
  print_header "Getting Ingress"
  kubectl get ingress -n "$NAMESPACE"
}

describe_pod() {
  local pod_name="${2:-}"

  if [ -z "$pod_name" ]; then
    print_error "Pod name required. Usage: $0 describe <pod-name>"
    exit 1
  fi

  print_header "Describing Pod: $pod_name"
  kubectl describe pod "$pod_name" -n "$NAMESPACE"
}

# ============================================================
# Logs Management
# ============================================================
logs_api() {
  print_header "API Logs"
  local follow="${2:-}"

  if [ "$follow" == "-f" ] || [ "$follow" == "--follow" ]; then
    kubectl logs -n "$NAMESPACE" -l app=${RELEASE}-api --tail=100 -f
  else
    kubectl logs -n "$NAMESPACE" -l app=${RELEASE}-api --tail=100
  fi
}

logs_mail() {
  print_header "Mail Service Logs"
  local follow="${2:-}"

  if [ "$follow" == "-f" ] || [ "$follow" == "--follow" ]; then
    kubectl logs -n "$NAMESPACE" -l app=${RELEASE}-mail --tail=100 -f
  else
    kubectl logs -n "$NAMESPACE" -l app=${RELEASE}-mail --tail=100
  fi
}

logs_redis() {
  print_header "Redis Logs"
  local follow="${2:-}"

  if [ "$follow" == "-f" ] || [ "$follow" == "--follow" ]; then
    kubectl logs -n "$NAMESPACE" -l app=${RELEASE}-redis --tail=100 -f
  else
    kubectl logs -n "$NAMESPACE" -l app=${RELEASE}-redis --tail=100
  fi
}

logs_postgres() {
  print_header "PostgreSQL Logs"
  local follow="${2:-}"

  if [ "$follow" == "-f" ] || [ "$follow" == "--follow" ]; then
    kubectl logs -n "$NAMESPACE" -l app=${RELEASE}-postgres --tail=100 -f
  else
    kubectl logs -n "$NAMESPACE" -l app=${RELEASE}-postgres --tail=100
  fi
}

logs_pod() {
  local pod_name="${2:-}"
  local follow="${3:-}"

  if [ -z "$pod_name" ]; then
    print_error "Pod name required. Usage: $0 logs-pod <pod-name> [-f]"
    exit 1
  fi

  print_header "Logs for Pod: $pod_name"

  if [ "$follow" == "-f" ] || [ "$follow" == "--follow" ]; then
    kubectl logs -n "$NAMESPACE" "$pod_name" --tail=100 -f
  else
    kubectl logs -n "$NAMESPACE" "$pod_name" --tail=100
  fi
}

# ============================================================
# Restart Management
# ============================================================
restart_api() {
  print_header "Restarting API Deployment"
  kubectl rollout restart deployment/${RELEASE}-api -n "$NAMESPACE"
  print_success "API restart initiated"
  kubectl rollout status deployment/${RELEASE}-api -n "$NAMESPACE"
}

restart_mail() {
  print_header "Restarting Mail Deployment"
  kubectl rollout restart deployment/${RELEASE}-mail -n "$NAMESPACE"
  print_success "Mail restart initiated"
  kubectl rollout status deployment/${RELEASE}-mail -n "$NAMESPACE"
}

restart_redis() {
  print_header "Restarting Redis Deployment"
  kubectl rollout restart deployment/${RELEASE}-redis -n "$NAMESPACE"
  print_success "Redis restart initiated"
  kubectl rollout status deployment/${RELEASE}-redis -n "$NAMESPACE"
}

restart_postgres() {
  print_header "Restarting PostgreSQL Deployment"
  kubectl rollout restart deployment/${RELEASE}-postgres -n "$NAMESPACE"
  print_success "PostgreSQL restart initiated"
  kubectl rollout status deployment/${RELEASE}-postgres -n "$NAMESPACE"
}

restart_all() {
  print_header "Restarting All Deployments"
  restart_api
  restart_mail
  print_success "All application deployments restarted"
}

restart_infra() {
  print_header "Restarting Infrastructure Services"
  restart_postgres
  restart_redis
  print_success "All infrastructure services restarted"
}

# ============================================================
# Port Forward Management
# ============================================================
pf_api() {
  local local_port="${2:-3000}"
  print_header "Port Forwarding API"
  print_status "Forwarding localhost:$local_port -> api:3000"
  kubectl port-forward -n "$NAMESPACE" svc/${RELEASE}-api-service "$local_port":3000
}

pf_mail() {
  local local_port="${2:-8081}"
  print_header "Port Forwarding Mail"
  print_status "Forwarding localhost:$local_port -> mail:8081"
  kubectl port-forward -n "$NAMESPACE" svc/${RELEASE}-mail-service "$local_port":8081
}

pf_redis() {
  local local_port="${2:-6379}"
  print_header "Port Forwarding Redis"
  print_status "Forwarding localhost:$local_port -> redis:6379"
  kubectl port-forward -n "$NAMESPACE" svc/${RELEASE}-redis-service "$local_port":6379
}

pf_postgres() {
  local local_port="${2:-5432}"
  print_header "Port Forwarding PostgreSQL"
  print_status "Forwarding localhost:$local_port -> postgres:5432"
  kubectl port-forward -n "$NAMESPACE" svc/${RELEASE}-postgres-service "$local_port":5432
}

# ============================================================
# Shell Access
# ============================================================
shell_api() {
  print_header "Opening Shell in API Pod"
  local pod
  pod=$(kubectl get pods -n "$NAMESPACE" -l app=${RELEASE}-api -o jsonpath='{.items[0].metadata.name}')
  kubectl exec -it -n "$NAMESPACE" "$pod" -- /bin/bash
}

shell_mail() {
  print_header "Opening Shell in Mail Pod"
  local pod
  pod=$(kubectl get pods -n "$NAMESPACE" -l app=${RELEASE}-mail -o jsonpath='{.items[0].metadata.name}')
  kubectl exec -it -n "$NAMESPACE" "$pod" -- /bin/bash
}

shell_redis() {
  print_header "Opening Redis CLI"
  local pod
  pod=$(kubectl get pods -n "$NAMESPACE" -l app=${RELEASE}-redis -o jsonpath='{.items[0].metadata.name}')
  kubectl exec -it -n "$NAMESPACE" "$pod" -- redis-cli
}

shell_postgres() {
  print_header "Opening PostgreSQL Shell"
  local pod
  pod=$(kubectl get pods -n "$NAMESPACE" -l app=${RELEASE}-postgres -o jsonpath='{.items[0].metadata.name}')
  # POSTGRES_USER / POSTGRES_DB are injected into the pod from the
  # apcms-postgres-secret Secret, so read them back from the pod
  # instead of hardcoding credentials here.
  kubectl exec -it -n "$NAMESPACE" "$pod" -- bash -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
}

# ============================================================
# Database Management
# ============================================================
db_backup() {
  print_header "Backing up PostgreSQL Database"
  local pod
  pod=$(kubectl get pods -n "$NAMESPACE" -l app=${RELEASE}-postgres -o jsonpath='{.items[0].metadata.name}')
  local backup_file="backup-$(date +%Y%m%d-%H%M%S).sql"

  print_status "Creating backup: $backup_file"
  kubectl exec -n "$NAMESPACE" "$pod" -- bash -c 'pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB"' > "$backup_file"
  print_success "Backup created: $backup_file"
}

db_restore() {
  local backup_file="${2:-}"

  if [ -z "$backup_file" ]; then
    print_error "Backup file required. Usage: $0 db-restore <backup-file.sql>"
    exit 1
  fi

  if [ ! -f "$backup_file" ]; then
    print_error "Backup file not found: $backup_file"
    exit 1
  fi

  print_header "Restoring PostgreSQL Database"
  local pod
  pod=$(kubectl get pods -n "$NAMESPACE" -l app=${RELEASE}-postgres -o jsonpath='{.items[0].metadata.name}')

  print_warning "This will restore the database. Are you sure?"
  read -p "Continue? (yes/no): " confirm

  if [ "$confirm" == "yes" ]; then
    kubectl exec -i -n "$NAMESPACE" "$pod" -- bash -c 'psql -U "$POSTGRES_USER" "$POSTGRES_DB"' < "$backup_file"
    print_success "Database restored from: $backup_file"
  else
    print_status "Restore cancelled"
  fi
}

# ============================================================
# Cleanup
# ============================================================
delete_all() {
  print_header "Deleting All Resources"
  print_warning "This will delete all resources in namespace: $NAMESPACE"
  read -p "Are you sure? (yes/no): " confirm

  if [ "$confirm" == "yes" ]; then
    helm uninstall "$RELEASE" -n "$NAMESPACE" 2>/dev/null || true
    kubectl delete all --all -n "$NAMESPACE"
    print_status "PVCs are kept on purpose — use 'delete-pvcs' to remove Postgres data"
    print_success "All resources deleted"
  else
    print_status "Deletion cancelled"
  fi
}

delete_pvcs() {
  print_header "Deleting Persistent Volume Claims"
  print_warning "This will delete all PVCs and their data in namespace: $NAMESPACE"
  read -p "Are you sure? (yes/no): " confirm

  if [ "$confirm" == "yes" ]; then
    kubectl delete pvc --all -n "$NAMESPACE"
    print_success "All PVCs deleted"
  else
    print_status "Deletion cancelled"
  fi
}

# ============================================================
# Help
# ============================================================
help() {
  printf "${CYAN}╔════════════════════════════════════════════════════════════════╗\n"
  printf "║           AP CMS Kubernetes Management Tool                    ║\n"
  printf "╚════════════════════════════════════════════════════════════════╝${NC}\n\n"

  printf "${YELLOW}Usage:${NC} $0 [COMMAND] [OPTIONS]\n\n"

  printf "${YELLOW}Namespace Management:${NC}\n"
  printf "  create-np                  Create Kubernetes namespace\n\n"

  printf "${YELLOW}ConfigMap / Secret Management:${NC}\n"
  printf "  create-cf                  Create app ConfigMaps (apcms-env, apcms-dotenv)\n"
  printf "  create-secret              Create PostgreSQL Secret (needs POSTGRES_USER,\n"
  printf "                             POSTGRES_PASSWORD, POSTGRES_DB in env)\n\n"

  printf "${YELLOW}Deployment:${NC}\n"
  printf "  deploy                     Deploy application using Helm (uses DEPLOY_ENV)\n\n"

  printf "${YELLOW}Status & Information:${NC}\n"
  printf "  pods                       List all pods\n"
  printf "  all                        List all resources\n"
  printf "  ingress                    List ingress resources\n"
  printf "  describe <pod-name>        Describe a specific pod\n\n"

  printf "${YELLOW}Logs:${NC}\n"
  printf "  logs-api [-f]              Show API logs (-f to follow)\n"
  printf "  logs-mail [-f]             Show Mail service logs (-f to follow)\n"
  printf "  logs-redis [-f]            Show Redis logs (-f to follow)\n"
  printf "  logs-postgres [-f]         Show PostgreSQL logs (-f to follow)\n"
  printf "  logs-pod <pod-name> [-f]   Show logs for specific pod (-f to follow)\n\n"

  printf "${YELLOW}Restart:${NC}\n"
  printf "  restart-api                Restart API deployment\n"
  printf "  restart-mail               Restart Mail deployment\n"
  printf "  restart-redis              Restart Redis deployment\n"
  printf "  restart-postgres           Restart PostgreSQL deployment\n"
  printf "  restart-all                Restart all application deployments\n"
  printf "  restart-infra              Restart all infrastructure services\n\n"

  printf "${YELLOW}Port Forward:${NC}\n"
  printf "  pf-api [port]              Port forward to API (default: 3000)\n"
  printf "  pf-mail [port]             Port forward to Mail (default: 8081)\n"
  printf "  pf-redis [port]            Port forward to Redis (default: 6379)\n"
  printf "  pf-postgres [port]         Port forward to PostgreSQL (default: 5432)\n\n"

  printf "${YELLOW}Shell Access:${NC}\n"
  printf "  shell-api                  Open shell in API pod\n"
  printf "  shell-mail                 Open shell in Mail pod\n"
  printf "  shell-redis                Open Redis CLI\n"
  printf "  shell-postgres             Open PostgreSQL shell\n\n"

  printf "${YELLOW}Database Management:${NC}\n"
  printf "  db-backup                  Backup PostgreSQL database\n"
  printf "  db-restore <file.sql>      Restore PostgreSQL database from backup\n\n"

  printf "${YELLOW}Cleanup:${NC}\n"
  printf "  delete-all                 Delete all resources (with confirmation)\n"
  printf "  delete-pvcs                Delete all PVCs (with confirmation)\n\n"

  printf "${YELLOW}Environment Variables:${NC}\n"
  printf "  NAMESPACE                  Kubernetes namespace (default: read from VALUES_FILE)\n"
  printf "  DEPLOY_ENV                 Values file / release suffix (default: uat)\n"
  printf "  VALUES_FILE                Helm values file (default: k8s/values/<DEPLOY_ENV>.yaml)\n"
  printf "  RELEASE                    Helm release name (default: apcms-<DEPLOY_ENV>)\n"
  printf "  ENV_FILE                   Environment file (default: .env)\n\n"

  printf "${YELLOW}Current resolved config:${NC}\n"
  printf "  DEPLOY_ENV=%s  NAMESPACE=%s  RELEASE=%s\n" "$DEPLOY_ENV" "$NAMESPACE" "$RELEASE"
  printf "  VALUES_FILE=%s\n\n" "$VALUES_FILE"

  printf "${YELLOW}Examples:${NC}\n"
  printf "  export KUBECONFIG=tai.yaml\n"
  printf "  $0 create-np                              Create the namespace\n"
  printf "  POSTGRES_USER=apcms POSTGRES_PASSWORD=xxx POSTGRES_DB=apcms \\\\\n"
  printf "    $0 create-secret                        Create the PostgreSQL secret\n"
  printf "  $0 create-cf                               Create the app ConfigMap\n"
  printf "  DEPLOY_ENV=uat $0 deploy                   Deploy using values/uat.yaml\n"
  printf "  $0 logs-api -f                             Follow API logs\n"
  printf "  $0 restart-all                             Restart all services\n"
  printf "  $0 pf-postgres 5432                        Forward PostgreSQL to localhost:5432\n"
  printf "  $0 shell-postgres                          Connect to PostgreSQL shell\n"
  printf "  $0 db-backup                               Backup database\n\n"

  printf "${YELLOW}Help:${NC}\n"
  printf "  help                       Show this help message\n\n"
}

# ============================================================
# Main Command Router
# ============================================================
case "${1:-help}" in
    # Namespace
    create-np)
        create_namespace
        ;;

    # ConfigMap / Secret
    create-cf)
        create_configmap
        ;;
    create-secret)
        create_secret
        ;;

    # Deployment
    deploy)
        deploy
        ;;

    # Status
    pods)
        get_pods
        ;;
    all)
        get_all
        ;;
    ingress)
        get_ingress
        ;;
    describe)
        describe_pod "$@"
        ;;

    # Logs
    logs-api)
        logs_api "$@"
        ;;
    logs-mail)
        logs_mail "$@"
        ;;
    logs-redis)
        logs_redis "$@"
        ;;
    logs-postgres)
        logs_postgres "$@"
        ;;
    logs-pod)
        logs_pod "$@"
        ;;

    # Restart
    restart-api)
        restart_api
        ;;
    restart-mail)
        restart_mail
        ;;
    restart-redis)
        restart_redis
        ;;
    restart-postgres)
        restart_postgres
        ;;
    restart-all)
        restart_all
        ;;
    restart-infra)
        restart_infra
        ;;

    # Port Forward
    pf-api)
        pf_api "$@"
        ;;
    pf-mail)
        pf_mail "$@"
        ;;
    pf-redis)
        pf_redis "$@"
        ;;
    pf-postgres)
        pf_postgres "$@"
        ;;

    # Shell
    shell-api)
        shell_api
        ;;
    shell-mail)
        shell_mail
        ;;
    shell-redis)
        shell_redis
        ;;
    shell-postgres)
        shell_postgres
        ;;

    # Database
    db-backup)
        db_backup
        ;;
    db-restore)
        db_restore "$@"
        ;;

    # Cleanup
    delete-all)
        delete_all
        ;;
    delete-pvcs)
        delete_pvcs
        ;;

    # Help
    help|*)
        help
        exit 0
        ;;
esac

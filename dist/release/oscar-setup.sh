#!/usr/bin/env bash
set -Eeuo pipefail

script_path=${BASH_SOURCE[0]}
case $script_path in */*) script_parent=${script_path%/*} ;; *) script_parent=. ;; esac
script_dir=$(CDPATH= cd -- "$script_parent" && pwd)
command_name=${1:-help}
if (($#)); then shift; fi

hostname_value=''
port_value=443
tls_mode='self-signed'
certificate_path=''
private_key_path=''
add_hosts=true
non_interactive=false
skip_start=false
log_service=all
log_tail=200
log_follow=false

usage() {
    cat <<'EOF'
OSCAR deployment administration

  sudo ./oscar.sh init [--hostname oscar.local] [--port 443]
      [--tls-mode self-signed|import] [--certificate FILE --private-key FILE]
      [--add-hosts-entry] [--skip-hosts-entry] [--skip-start]
  sudo ./oscar.sh check|start|stop|restart|status|upgrade
  sudo ./oscar.sh logs [--service all|oscar|postgres|gateway] [--tail 200] [--follow]

For automated setup, use --non-interactive and provide
OSCAR_SETUP_ADMIN_PASSWORD in the process environment.
EOF
}

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
heading() { printf '\n== %s ==\n' "$*"; }

while (($#)); do
    case "$1" in
        --hostname) hostname_value=${2:?missing hostname}; shift 2 ;;
        --port) port_value=${2:?missing port}; shift 2 ;;
        --tls-mode) tls_mode=${2:?missing TLS mode}; shift 2 ;;
        --certificate) certificate_path=${2:?missing certificate path}; shift 2 ;;
        --private-key) private_key_path=${2:?missing private-key path}; shift 2 ;;
        --add-hosts-entry) add_hosts=true; shift ;;
        --skip-hosts-entry) add_hosts=false; shift ;;
        --non-interactive) non_interactive=true; shift ;;
        --skip-start) skip_start=true; shift ;;
        --service) log_service=${2:?missing service}; shift 2 ;;
        --tail) log_tail=${2:?missing tail count}; shift 2 ;;
        --follow) log_follow=true; shift ;;
        --help|-h) usage; exit 0 ;;
        *) fail "Unknown option: $1" ;;
    esac
done

require_admin() {
    [[ ${EUID:-$(id -u)} -eq 0 ]] || fail 'Run this command as root (for example, with sudo).'
}

assert_offline_bundle_integrity() {
    [[ -f $script_dir/SHA256SUMS ]] || return 0
    heading 'Offline bundle integrity'
    [[ -f $script_dir/verify-bundle.sh ]] || fail 'The offline bundle verifier is missing.'
    bash "$script_dir/verify-bundle.sh" || fail 'Offline bundle integrity verification failed.'
}

docker_ready() {
    command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1 && docker info >/dev/null 2>&1
}

install_bundled_prerequisites() {
    heading 'Docker prerequisite'
    case "$(uname -s)" in
        Linux)
            local installer_dir="$script_dir/installers/ubuntu-24.04-x86_64"
            local packages=()
            if [[ -d $installer_dir ]]; then
                while IFS= read -r -d '' package; do packages+=("$package"); done < <(find "$installer_dir" -maxdepth 1 -type f -name '*.deb' -print0)
            fi
            ((${#packages[@]})) || fail "Docker is unavailable. Place the official Ubuntu 24.04 x86-64 Docker .deb bundle in $installer_dir and run setup again."
            printf 'Installing bundled official Docker packages...\n'
            dpkg -i "${packages[@]}"
            systemctl enable --now docker
            ;;
        Darwin)
            local installer="$script_dir/installers/macos-arm64/Docker.dmg"
            [[ -f $installer ]] || fail "Docker is unavailable. Place the official Apple Silicon Docker.dmg at $installer and run setup again."
            open "$installer"
            if $non_interactive; then fail 'Complete the Docker Desktop installer, start Docker, then run setup again.'; fi
            read -r -p 'Complete the official Docker Desktop installation, start it, then press Enter to resume: '
            ;;
        *) fail "Unsupported setup host: $(uname -s)" ;;
    esac

    for _attempt in {1..90}; do
        docker_ready && return
        sleep 2
    done
    fail 'Docker is installed but its engine is not ready. Start Docker, then run setup again.'
}

require_docker() {
    docker_ready || install_bundled_prerequisites
    docker_ready || fail 'Docker Engine and Docker Compose are required.'
}

is_ip_address() {
    local value=$1
    if [[ $value =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        local octet
        IFS=. read -r -a octets <<<"$value"
        for octet in "${octets[@]}"; do ((10#$octet <= 255)) || return 1; done
        return 0
    fi
    [[ $value == *:* && $value =~ ^[0-9A-Fa-f:]+$ ]]
}

valid_hostname() {
    local value=$1 label
    is_ip_address "$value" && return 0
    ((${#value} >= 1 && ${#value} <= 253)) || return 1
    IFS=. read -r -a labels <<<"$value"
    for label in "${labels[@]}"; do
        ((${#label} >= 1 && ${#label} <= 63)) || return 1
        [[ $label =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ || $label =~ ^[A-Za-z0-9]$ ]] || return 1
    done
}

set_env_value() {
    local name=$1 value=$2 env_file="$script_dir/.env" source_file="$script_dir/.env.example" temp_file
    [[ -f $env_file ]] && source_file=$env_file
    temp_file=$(mktemp "$script_dir/.env.tmp.XXXXXX")
    awk -v name="$name" -v value="$value" -F= '
        BEGIN { found=0 }
        $1 == name { print name "=" value; found=1; next }
        { print }
        END { if (!found) print name "=" value }
    ' "$source_file" >"$temp_file"
    chmod 600 "$temp_file"
    mv -f "$temp_file" "$env_file"
}

random_password() { head -c 32 /dev/urandom | base64 | tr -d '\r\n'; }

read_admin_password() {
    if [[ -n ${OSCAR_SETUP_ADMIN_PASSWORD:-} ]]; then
        ((${#OSCAR_SETUP_ADMIN_PASSWORD} >= 14)) || fail 'OSCAR_SETUP_ADMIN_PASSWORD must contain at least 14 characters.'
        printf '%s' "$OSCAR_SETUP_ADMIN_PASSWORD"
        return
    fi
    $non_interactive && fail 'Set OSCAR_SETUP_ADMIN_PASSWORD for non-interactive initialization.'
    local first second
    while true; do
        read -r -s -p 'Initial OSCAR administrator password: ' first; printf '\n' >&2
        read -r -s -p 'Confirm administrator password: ' second; printf '\n' >&2
        ((${#first} >= 14)) || { printf 'Use at least 14 characters.\n' >&2; continue; }
        [[ $first == "$second" ]] || { printf 'Passwords do not match.\n' >&2; continue; }
        printf '%s' "$first"
        return
    done
}

write_secret() {
    local path=$1 value=$2
    [[ -e $path ]] || printf '%s' "$value" >"$path"
}

ensure_federation_key() {
    mkdir -p "$script_dir/secrets"
    [[ -e $script_dir/secrets/oscar-federation-key.txt ]] || write_secret "$script_dir/secrets/oscar-federation-key.txt" "$(random_password)"
}

protect_deployment_files() {
    chmod 700 "$script_dir/secrets" "$script_dir/tls"
    # Compose file-backed secrets retain host file modes. The protected parent
    # prevents host traversal while 0644 lets the non-root containers read mounts.
    chmod 644 "$script_dir"/secrets/*.txt "$script_dir/tls/server.crt" "$script_dir/tls/server.key"
    chmod 600 "$script_dir/.env"
}

allow_docker_desktop_bind_mount_access() {
    [[ $(uname -s) == Darwin ]] || return 0
    [[ -n ${SUDO_UID:-} && -n ${SUDO_GID:-} ]] || return 0
    chown "$SUDO_UID:$SUDO_GID" "$script_dir/secrets" "$script_dir/tls"
}

oscar_image() {
    local version=local
    if [[ -f $script_dir/.env ]]; then
        version=$(awk -F= '$1 == "OSCAR_VERSION" { print substr($0, index($0, "=") + 1); exit }' "$script_dir/.env")
        [[ -n $version ]] || version=local
    fi
    printf 'oscar:%s' "$version"
}

container_image_exists() { docker image inspect "$1" >/dev/null 2>&1; }

required_images() {
    printf '%s\n' "$(oscar_image)" 'oscar-postgis:16-3.5' 'nginxinc/nginx-unprivileged:1.28.1-alpine'
}

assert_deployment_images_available() {
    local missing=() image
    while IFS= read -r image; do container_image_exists "$image" || missing+=("$image"); done < <(required_images)
    ((${#missing[@]} == 0)) || fail "Required container images are unavailable: ${missing[*]}. Run 'oscar init' or 'oscar upgrade'."
}

prepare_deployment_images() {
    local missing=() image
    while IFS= read -r image; do container_image_exists "$image" || missing+=("$image"); done < <(required_images)
    ((${#missing[@]} == 0)) && return

    if [[ -f $script_dir/offline-images.tar ]]; then
        heading 'Importing offline container images'
        docker load --input "$script_dir/offline-images.tar"
    else
        heading 'Building deployment images'
        compose build oscar postgres
        compose pull gateway
    fi

    missing=()
    while IFS= read -r image; do container_image_exists "$image" || missing+=("$image"); done < <(required_images)
    ((${#missing[@]} == 0)) || fail "Required container images are unavailable: ${missing[*]}"
}

initialize_tls() {
    local name=$1 tls_dir="$script_dir/tls" cert="$script_dir/tls/server.crt" key="$script_dir/tls/server.key" image san_type
    if [[ (-e $cert && ! -e $key) || (! -e $cert && -e $key) ]]; then fail 'TLS setup is incomplete. Remove the partial certificate/key pair or provide both files.'; fi
    image=$(oscar_image)

    if [[ ! -e $cert && ! -e $key ]]; then
        case "$tls_mode" in
            import)
                [[ -f $certificate_path ]] || fail 'A valid --certificate PEM file is required.'
                [[ -f $private_key_path ]] || fail 'A valid --private-key PEM file is required.'
                cp "$certificate_path" "$cert"
                cp "$private_key_path" "$key"
                ;;
            self-signed)
                san_type=DNS
                is_ip_address "$name" && san_type=IP
                docker run --rm --user 0:0 --entrypoint openssl --volume "${tls_dir}:/out" "$image" \
                    req -x509 -newkey rsa:3072 -sha256 -nodes -days 365 -subj "/CN=$name" \
                    -addext "subjectAltName=${san_type}:$name" -keyout /out/server.key -out /out/server.crt
                ;;
            *) fail "Unsupported TLS mode: $tls_mode" ;;
        esac
    fi

    # The parent directory remains mode 0700, while file-backed Compose secrets
    # must be readable by the deliberately non-root service processes.
    chmod 644 "$cert" "$key"
    docker run --rm --entrypoint sh --volume "${tls_dir}:/tls:ro" "$image" -c \
        'openssl x509 -in /tls/server.crt -pubkey -noout >/tmp/cert.pub && openssl pkey -in /tls/server.key -pubout >/tmp/key.pub && cmp -s /tmp/cert.pub /tmp/key.pub' \
        || fail 'The TLS certificate and private key are invalid or do not match.'
    local name_check=-checkhost
    is_ip_address "$name" && name_check=-checkip
    docker run --rm --entrypoint openssl --volume "${tls_dir}:/tls:ro" "$image" \
        x509 -in /tls/server.crt -noout "$name_check" "$name" \
        || fail "The TLS certificate is not valid for $name."
}

add_local_hosts_mapping() {
    local name=$1 hosts_file=/etc/hosts
    is_ip_address "$name" && return
    grep -Eq "^[[:space:]]*127\.0\.0\.1[[:space:]].*\b${name//./\\.}\b" "$hosts_file" && return
    printf '\n127.0.0.1\t%s\t# OSCAR setup\n' "$name" >>"$hosts_file"
}

configured() {
    local required
    for required in secrets/oscar-admin-password.txt secrets/oscar-db-password.txt secrets/postgres-bootstrap-password.txt secrets/oscar-federation-key.txt tls/server.crt tls/server.key .env; do
        [[ -s $script_dir/$required ]] || return 1
    done
}

compose() { (cd "$script_dir" && docker compose "$@"); }

case "$command_name" in
    help) usage ;;
    check)
        heading 'Prerequisite check'
        printf 'Administrator: %s\n' "$([[ ${EUID:-$(id -u)} -eq 0 ]] && echo true || echo false)"
        printf 'Docker CLI: %s\n' "$(command -v docker >/dev/null 2>&1 && echo true || echo false)"
        printf 'Docker ready: %s\n' "$(docker_ready && echo true || echo false)"
        printf 'Offline bundle: %s\n' "$([[ -f $script_dir/offline-images.tar ]] && echo true || echo false)"
        printf 'Configured: %s\n' "$(configured && echo true || echo false)"
        # TODO(offline-maps): add MBTiles validation/import after deployment requirements are defined.
        ;;
    init)
        require_admin
        assert_offline_bundle_integrity
        require_docker
        if [[ -z $hostname_value ]]; then
            if $non_interactive; then fail '--hostname is required in non-interactive mode.'; fi
            read -r -p 'Hostname or IP address [oscar.local]: ' hostname_value
            hostname_value=${hostname_value:-oscar.local}
        fi
        valid_hostname "$hostname_value" || fail "Invalid hostname or IP address: $hostname_value"
        [[ $port_value =~ ^[0-9]+$ ]] && ((port_value >= 1 && port_value <= 65535)) || fail 'Port must be between 1 and 65535.'
        mkdir -p "$script_dir/secrets" "$script_dir/tls"
        allow_docker_desktop_bind_mount_access
        set_env_value OSCAR_HTTPS_PORT "$port_value"
        set_env_value OSCAR_HOSTNAME "$hostname_value"
        [[ -e $script_dir/secrets/oscar-admin-password.txt ]] || write_secret "$script_dir/secrets/oscar-admin-password.txt" "$(read_admin_password)"
        [[ -e $script_dir/secrets/oscar-db-password.txt ]] || write_secret "$script_dir/secrets/oscar-db-password.txt" "$(random_password)"
        [[ -e $script_dir/secrets/postgres-bootstrap-password.txt ]] || write_secret "$script_dir/secrets/postgres-bootstrap-password.txt" "$(random_password)"
        [[ -e $script_dir/secrets/oscar-federation-key.txt ]] || write_secret "$script_dir/secrets/oscar-federation-key.txt" "$(random_password)"
        prepare_deployment_images
        initialize_tls "$hostname_value"
        protect_deployment_files
        $add_hosts && add_local_hosts_mapping "$hostname_value"
        configured || fail 'Setup did not produce every required deployment file.'
        $skip_start || compose up --detach --no-build --pull never --wait --wait-timeout 240
        printf '\nOSCAR setup complete: https://%s:%s/sensorhub/admin\n' "$hostname_value" "$port_value"
        ;;
    start)
        require_admin; require_docker; ensure_federation_key; protect_deployment_files; configured || fail 'Run init before starting OSCAR.'
        assert_deployment_images_available
        compose up --detach --no-build --pull never --wait --wait-timeout 240
        ;;
    stop)
        require_admin; require_docker; ensure_federation_key; protect_deployment_files; configured || fail 'Run init before stopping OSCAR.'
        compose stop
        printf 'OSCAR stopped. Persistent application and database data were retained.\n'
        ;;
    restart)
        require_admin; require_docker; ensure_federation_key; protect_deployment_files; configured || fail 'Run init before restarting OSCAR.'
        assert_deployment_images_available
        compose restart
        compose up --detach --no-build --pull never --wait --wait-timeout 240
        ;;
    status)
        require_docker; compose ps
        if configured; then
            local_hostname=$(awk -F= '$1 == "OSCAR_HOSTNAME" { print substr($0, index($0, "=") + 1); exit }' "$script_dir/.env")
            local_port=$(awk -F= '$1 == "OSCAR_HTTPS_PORT" { print substr($0, index($0, "=") + 1); exit }' "$script_dir/.env")
            printf 'OSCAR URL: https://%s:%s/sensorhub/admin\n' "${local_hostname:-oscar.local}" "${local_port:-443}"
        fi
        ;;
    logs)
        require_docker; configured || fail 'Run init before reading OSCAR logs.'
        [[ $log_service =~ ^(all|oscar|postgres|gateway)$ ]] || fail '--service must be all, oscar, postgres, or gateway.'
        [[ $log_tail =~ ^[0-9]+$ ]] && ((log_tail >= 1 && log_tail <= 10000)) || fail '--tail must be between 1 and 10000.'
        log_args=(logs --tail "$log_tail")
        $log_follow && log_args+=(--follow)
        [[ $log_service == all ]] || log_args+=("$log_service")
        compose "${log_args[@]}"
        ;;
    upgrade)
        require_admin; require_docker; ensure_federation_key; protect_deployment_files; configured || fail 'This release directory has not been initialized.'
        heading 'Upgrade preflight'
        compose config --quiet
        prepare_deployment_images
        compose up --detach --no-build --pull never --wait --wait-timeout 240
        printf 'Upgrade deployment completed. Persistent OSCAR and PostgreSQL volumes were retained.\n'
        ;;
    *) fail "Unknown command: $command_name" ;;
esac

terraform {
  required_providers {
    coder = {
      source = "coder/coder"
    }
    docker = {
      source = "kreuzwerker/docker"
    }
  }
}

# --- Subnet Router Configuration Variable ---
variable "subnet_router_ip" {
  type        = string
  description = "The LAN IP of the Raspberry Pi acting as the Tailscale subnet router."
  default     = "192.168.18.9"
}

provider "docker" {
  host     = "ssh://workspaces@host.containers.internal:22"
  ssh_opts = ["-o", "StrictHostKeyChecking=no"]
}

locals {
  username = data.coder_workspace_owner.me.name

  coder_server_ip   = "169.254.1.5"
  coder_server_port = 7080
  coder_server_url  = "http://${local.coder_server_ip}:${local.coder_server_port}/"

  # Unique name for containers and resources
  resource_name = "coder-${local.username}-${lower(data.coder_workspace.me.name)}"

  # Calculate the working directory based on git clone settings
  folder_name = data.coder_parameter.enable_git_clone.value == "true" ? replace(basename(try(data.coder_parameter.repo_url[0].value, "")), "/\\.git$/", "") : try(data.coder_parameter.manual_folder_name[0].value, "")
  workdir     = "/workspaces/${local.folder_name}"

  # Whether GPU device mounts should be enabled (true when install_de is selected)
  enable_gpu = data.coder_parameter.install_de.value == "true" ? true : (data.coder_parameter.enable_gpu.value == "true")

  # Whether hardware virtualization (KVM) should be enabled
  enable_kvm = data.coder_parameter.enable_kvm.value == "true"

  # Select container image dynamically across the 4 workspace combinations
  container_image = (
    data.coder_parameter.install_de.value == "true" && data.coder_parameter.enable_devcontainer.value == "true" ? docker_image.workspace_desktop_podman.image_id : (
      data.coder_parameter.install_de.value == "true" && data.coder_parameter.enable_devcontainer.value == "false" ? docker_image.workspace_desktop.image_id : (
        data.coder_parameter.enable_devcontainer.value == "true" && data.coder_parameter.install_de.value == "false" ? docker_image.workspace_podman.image_id : docker_image.workspace.image_id
      )
    )
  )

  # Compile standard hardware devices to mount
  gpu_devices  = local.enable_gpu ? ["/dev/dri/card0", "/dev/dri/renderD128"] : []
  kvm_devices  = local.enable_kvm ? ["/dev/kvm"] : []
  fuse_devices = data.coder_parameter.enable_devcontainer.value == "true" ? ["/dev/fuse"] : []

  # Combine all required devices cleanly
  device_list = concat(local.gpu_devices, local.kvm_devices, local.fuse_devices)
}

data "coder_parameter" "install_de" {
  type         = "bool"
  name         = "install_de"
  display_name = "Desktop Environment"
  description  = "Install XFCE, KasmVNC, and Google Chrome for GUI access? (Uses enterprise-desktop image)"
  default      = "false"
  mutable      = true
}

data "coder_parameter" "enable_git_clone" {
  type         = "bool"
  name         = "enable_git_clone"
  display_name = "Clone a Repository?"
  description  = "If yes, enter the cloning URL. Else, provide a local folder name to create"
  default      = "false"
  form_type    = "checkbox"
}

data "coder_parameter" "enable_devcontainer" {
  type         = "bool"
  name         = "enable_devcontainer"
  display_name = "Enable Devcontainers"
  description  = "Installs local Podman engine to support nested execution environments."
  default      = "false"
  mutable      = true
}

data "coder_parameter" "trusted" {
  type         = "bool"
  name         = "trusted"
  display_name = "Trusted?"
  description  = "Mark this workspace directory as trusted to automatically authorize mise configurations."
  default      = "false"
  mutable      = true
}

data "coder_parameter" "enable_gpu" {
  type         = "bool"
  name         = "enable_gpu"
  display_name = "Enable GPU Acceleration"
  description  = "Mount host GPU devices /dev/dri/card0 and /dev/dri/renderD128 into the workspace container for hardware acceleration."
  default      = data.coder_parameter.install_de.value == "true" ? "true" : "false"
  mutable      = true
}

data "coder_parameter" "enable_kvm" {
  type         = "bool"
  name         = "enable_kvm"
  display_name = "Hardware Virtualization (KVM)"
  description  = "Mount host /dev/kvm into the workspace container to support nested hardware-accelerated VMs (QEMU/KVM)."
  default      = "false"
  mutable      = true
}

data "coder_parameter" "repo_url" {
  count        = data.coder_parameter.enable_git_clone.value == "true" ? 1 : 0
  type         = "string"
  name         = "repo_url"
  display_name = "Git Repository URL"
  default      = "https://github.com/coder/coder"
}

data "coder_parameter" "manual_folder_name" {
  count        = data.coder_parameter.enable_git_clone.value == "false" ? 1 : 0
  type         = "string"
  name         = "manual_folder_name"
  display_name = "New Folder Name"
  description  = "Enter the name of the folder to create in /workspaces."
  default      = "my-workspace"
}

data "coder_provisioner" "me" {}
data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}
data "coder_task" "me" {}

data "coder_external_auth" "github" {
  id = "github"
}

module "git-commit-signing" {
  count    = data.coder_workspace.me.start_count
  source   = "registry.coder.com/coder/git-commit-signing/coder"
  version  = "1.0.31"
  agent_id = coder_agent.main[count.index].id
}

resource "coder_agent" "main" {
  arch           = "amd64"
  os             = "linux"
  count          = data.coder_workspace.me.start_count
  startup_script = <<-EOT
    set -e

    # Prepare user home with default files on first start.
    if [ ! -f ~/.init_done ]; then
      cp -rT /etc/skel ~
      touch ~/.init_done
    fi

    # Create workspace folder if not using git clone
    if [ "${data.coder_parameter.enable_git_clone.value}" = "false" ]; then
      mkdir -p ${local.workdir}
    fi

    # Automatically trust mise configuration if the workspace is marked as trusted
    if [ "${data.coder_parameter.trusted.value}" = "true" ]; then
      echo "Workspace is trusted. Authorizing mise in background..."
      (
        for i in {1..30}; do
          if [ -d "${local.workdir}" ]; then
            mise trust "${local.workdir}" 2>/dev/null || true
            break
          fi
          sleep 1
        done
      ) </dev/null >/dev/null 2>&1 &
    fi
  EOT

  connection_timeout = 120

  env = {
    GIT_AUTHOR_NAME     = coalesce(data.coder_workspace_owner.me.full_name, data.coder_workspace_owner.me.name)
    GIT_AUTHOR_EMAIL    = "${data.coder_workspace_owner.me.email}"
    GIT_COMMITTER_NAME  = coalesce(data.coder_workspace_owner.me.full_name, data.coder_workspace_owner.me.name)
    GIT_COMMITTER_EMAIL = "${data.coder_workspace_owner.me.email}"
    DISPLAY             = ":1"
    MISE_DATA_DIR       = "/opt/mise/data"
    MISE_CACHE_DIR      = "/opt/mise/cache"
    CODER_AGENT_URL     = local.coder_server_url
  }

  metadata {
    display_name = "CPU Usage"
    key          = "0_cpu_usage"
    script       = "sudo /tmp/coder.*/coder stat cpu"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "RAM Usage"
    key          = "1_ram_usage"
    script       = "sudo /tmp/coder.*/coder stat mem"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "CPU Usage (Host)"
    key          = "2_cpu_usage_host"
    script       = "coder stat cpu --host"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "Memory Usage (Host)"
    key          = "3_mem_usage_host"
    script       = "coder stat mem --host"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "Disk Usage (Host)"
    key          = "4_home_disk"
    script       = "coder stat disk --path $${HOME}"
    interval     = 60
    timeout      = 1
  }

  metadata {
    display_name = "Load Average (Host)"
    key          = "5_load_host"
    script       = <<EOT
      echo "`cat /proc/loadavg | awk '{ print $1 }'` `nproc`" | awk '{ printf "%0.2f", $1/$2 }'
    EOT
    interval     = 60
    timeout      = 1
  }

  metadata {
    display_name = "Swap Usage (Host)"
    key          = "7_swap_host"
    script       = <<EOT
      free -b | awk '/^Swap/ { printf("%.1f/%.1f", $3/1024.0/1024.0/1024.0, $2/1024.0/1024.0/1024.0) }'
    EOT
    interval     = 10
    timeout      = 1
  }
}

module "code-server" {
  count  = data.coder_workspace.me.start_count
  source = "registry.coder.com/coder/code-server/coder"

  version = "~> 1.0"
  folder  = local.workdir

  extensions = ["catppuccin.catppuccin-vsc-icons", "github.vscode-pull-request-github", "catppuccin.catppuccin-vsc"]

  settings = {
    "git.autofetch" : true,
    "git.enableSmartCommit" : true,
    "git.confirmSync" : false,
    "workbench.iconTheme" : "catppuccin-mocha",
    "workbench.colorTheme" : "Catppuccin Mocha"
  }

  open_in   = "tab"
  subdomain = true
  agent_id  = coder_agent.main[count.index].id
  order     = 1
}

module "jetbrains_gateway" {
  count  = data.coder_workspace.me.start_count
  source = "registry.coder.com/coder/jetbrains-gateway/coder"

  jetbrains_ides = ["IU", "PS", "WS", "PY", "CL", "GO", "RM", "RD", "RR"]
  default        = "IU"
  folder         = local.workdir

  version = "~> 1.0"

  agent_id   = coder_agent.main[count.index].id
  agent_name = "main"
  order      = 2
}

module "antigravity" {
  count    = data.coder_workspace.me.start_count
  source   = "registry.coder.com/coder/antigravity/coder"
  version  = "~> 1.0.1"
  agent_id = coder_agent.main[count.index].id
  folder   = local.workdir

  mcp = jsonencode({
    mcpServers = {
      "github" : {
        "url" : "https://api.githubcopilot.com/mcp/",
        "headers" : {
          "Authorization" : "Bearer ${data.coder_external_auth.github.access_token}",
        },
        "type" : "http"
      }
    }
  })
}

module "git-clone" {
  count    = (data.coder_workspace.me.start_count > 0 && data.coder_parameter.enable_git_clone.value == "true") ? 1 : 0
  source   = "registry.coder.com/coder/git-clone/coder"
  version  = "~> 1.0"
  agent_id = coder_agent.main[0].id
  url      = data.coder_parameter.repo_url[0].value
  base_dir = "/workspaces"
}

module "kasmvnc" {
  count               = (data.coder_workspace.me.start_count > 0 && data.coder_parameter.install_de.value == "true") ? 1 : 0
  source              = "registry.coder.com/coder/kasmvnc/coder"
  version             = "1.2.3"
  agent_id            = coder_agent.main[0].id
  desktop_environment = "xfce"
  subdomain           = true
}

module "devcontainers-cli" {
  source             = "registry.coder.com/coder/devcontainers-cli/coder"
  version            = "1.1.0"
  count              = data.coder_workspace.me.start_count
  agent_id           = coder_agent.main[count.index].id
  start_blocks_login = false
}

resource "docker_volume" "home_volume" {
  name = "coder-${data.coder_workspace.me.name}-home"
  lifecycle {
    ignore_changes = all
  }
  labels {
    label = "coder.owner"
    value = data.coder_workspace_owner.me.name
  }
  labels {
    label = "coder.owner_id"
    value = data.coder_workspace_owner.me.id
  }
  labels {
    label = "coder.workspace_id"
    value = data.coder_workspace.me.id
  }
  labels {
    label = "coder.workspace_name_at_creation"
    value = data.coder_workspace.me.name
  }
}

resource "docker_volume" "workspaces_volume" {
  name = "coder-${data.coder_workspace.me.name}-workspaces"
  lifecycle {
    ignore_changes = all
  }
  labels {
    label = "coder.owner"
    value = data.coder_workspace_owner.me.name
  }
  labels {
    label = "coder.owner_id"
    value = data.coder_workspace_owner.me.id
  }
  labels {
    label = "coder.workspace_id"
    value = data.coder_workspace.me.id
  }
  labels {
    label = "coder.workspace_name_at_creation"
    value = data.coder_workspace.me.name
  }
}

resource "docker_volume" "podman_storage" {
  name = "coder-${data.coder_workspace.me.name}-podman-storage"
  lifecycle {
    ignore_changes = all
  }
  labels {
    label = "coder.owner"
    value = data.coder_workspace_owner.me.name
  }
  labels {
    label = "coder.workspace_id"
    value = data.coder_workspace.me.id
  }
}

# Workspace-specific, dedicated named volume for unprivileged rootless Podman image caches.
# Using a workspace-specific naming pattern guarantees separate environments and prevents lock/corruption conflicts.
resource "docker_volume" "podman_cache" {
  name = "coder-${data.coder_workspace.me.name}-podman-cache"
  lifecycle {
    ignore_changes = all
  }
  labels {
    label = "coder.owner"
    value = data.coder_workspace_owner.me.name
  }
  labels {
    label = "coder.workspace_id"
    value = data.coder_workspace.me.id
  }
}


# 1. Base CLI Workspace (Non-Podman)
data "docker_registry_image" "workspace" {
  name = "ghcr.io/sairam-suresh/workspace:latest"
}

resource "docker_image" "workspace" {
  name          = "${data.docker_registry_image.workspace.name}@${data.docker_registry_image.workspace.sha256_digest}"
  pull_triggers = [data.docker_registry_image.workspace.sha256_digest]
  triggers = {
    digest = data.docker_registry_image.workspace.sha256_digest
  }
  keep_locally = true
}

# 2. CLI Workspace with Nested local Podman Engine
data "docker_registry_image" "workspace_podman" {
  name = "ghcr.io/sairam-suresh/workspace-podman:latest"
}

resource "docker_image" "workspace_podman" {
  name          = "${data.docker_registry_image.workspace_podman.name}@${data.docker_registry_image.workspace_podman.sha256_digest}"
  pull_triggers = [data.docker_registry_image.workspace_podman.sha256_digest]
  triggers = {
    digest = data.docker_registry_image.workspace_podman.sha256_digest
  }
  keep_locally = true
}

# 3. GUI Desktop Workspace (Non-Podman)
data "docker_registry_image" "workspace_desktop" {
  name = "ghcr.io/sairam-suresh/workspace-desktop:latest"
}

resource "docker_image" "workspace_desktop" {
  name          = "${data.docker_registry_image.workspace_desktop.name}@${data.docker_registry_image.workspace_desktop.sha256_digest}"
  pull_triggers = [data.docker_registry_image.workspace_desktop.sha256_digest]
  triggers = {
    digest = data.docker_registry_image.workspace_desktop.sha256_digest
  }
  keep_locally = true
}

# 4. GUI Desktop Workspace with Nested local Podman Engine
data "docker_registry_image" "workspace_desktop_podman" {
  name = "ghcr.io/sairam-suresh/workspace-desktop-podman:latest"
}

resource "docker_image" "workspace_desktop_podman" {
  name          = "${data.docker_registry_image.workspace_desktop_podman.name}@${data.docker_registry_image.workspace_desktop_podman.sha256_digest}"
  pull_triggers = [data.docker_registry_image.workspace_desktop_podman.sha256_digest]
  triggers = {
    digest = data.docker_registry_image.workspace_desktop_podman.sha256_digest
  }
  keep_locally = true
}

# 5. Firewall Sidecar Image
resource "docker_image" "firewall" {
  name         = "docker.io/library/alpine:3.19"
  keep_locally = true
}

# The Sidecar Firewall Container (owns the pasta network stack)
resource "docker_container" "firewall" {
  count = data.coder_workspace.me.start_count
  image = docker_image.firewall.image_id
  name  = "${local.resource_name}-firewall"

  network_mode = "pasta:--map-guest-addr,${local.coder_server_ip},-t,none,-T,none,-u,auto"

  capabilities {
    add = ["NET_ADMIN"]
  }

  entrypoint = ["/bin/sh", "-c"]
  command = [<<-EOT
    set -e
    apk add --no-cache nftables

    cat <<EOF > /etc/nftables.conf
flush ruleset

table inet filter {
  chain input {
    type filter hook input priority 0; policy accept;
    ct state established,related accept
  }
  chain forward {
    type filter hook forward priority 0; policy accept;
  }
  chain output {
    type filter hook output priority 0; policy accept;

    # 1. Allow loopback traffic
    oif "lo" accept

    # 2. Fast-track established & related return traffic (highest volume)
    ct state established,related accept

    # 3. Allow DHCP configuration requests
    udp dport 67 accept

    # 4. Allow DNS resolution
    udp dport 53 accept
    tcp dport 53 accept

    # 5. Allow STUN discovery for direct connections
    udp dport 3478 accept

    # 6. Explicitly allow outbound traffic to the Coder server
    ip daddr ${local.coder_server_ip} tcp dport ${local.coder_server_port} accept

    # 7. Allow Tailscale CGNAT IP range (for direct WireGuard connections to laptop)
    ip daddr 100.64.0.0/10 accept

    # 8. Allow return/peer traffic to the Raspberry Pi subnet router
    ip daddr ${var.subnet_router_ip} accept

    # 9. Block internal private networks (LAN egress filter)
    ip daddr 10.0.0.0/8 drop
    ip daddr 172.16.0.0/12 drop
    ip daddr 192.168.0.0/16 drop
    ip daddr 169.254.0.0/16 drop
    ip daddr 224.0.0.0/4 drop
    ip daddr 240.0.0.0/4 drop
  }
}
EOF

    echo "[Firewall] Applying nftables configuration..."
    nft -f /etc/nftables.conf

    echo "[Firewall] Firewall rules applied successfully. Keeping sidecar active..."
    exec sleep infinity
  EOT
  ]

  restart = "unless-stopped"

  labels {
    label = "coder.owner"
    value = data.coder_workspace_owner.me.name
  }
  labels {
    label = "coder.workspace_id"
    value = data.coder_workspace.me.id
  }
}

resource "docker_container" "workspace" {
  count    = data.coder_workspace.me.start_count
  image    = local.container_image
  name     = local.resource_name
  hostname = data.coder_workspace.me.name

  # Connect to the Firewall's network namespace
  network_mode = "container:${docker_container.firewall[count.index].name}"

  userns_mode = "keep-id:uid=1000,gid=1000"
  user        = "1000:1000"

  security_opts = data.coder_parameter.enable_devcontainer.value == "true" ? [
    "label:disable",
    "seccomp=unconfined",
    "unmask=all"
  ] : []

  capabilities {
    add = data.coder_parameter.enable_devcontainer.value == "true" ? ["SYS_ADMIN", "SYS_PTRACE"] : []
  }

  entrypoint = ["bash", "-c"]
  command = [<<-EOT
    set -e
    echo "Aligning home directory permissions..."
    sudo chown -R 1000:1000 "$HOME" || true

    # Ensure shared Mise volume directories exist and are owned by coder
    sudo mkdir -p /opt/mise/data /opt/mise/cache
    sudo chown -R 1000:1000 /opt/mise
    sudo chmod -R 775 /opt/mise

    # Ensure /workspaces directory exists and is owned by coder
    sudo mkdir -p /workspaces
    sudo chown -R 1000:1000 /workspaces
    sudo chmod 775 /workspaces

    sudo apt update

    # Create certificate directory and copy system bundle for nested container runtimes
    CERT_DIR="$HOME/.local/share/ca-certificates"
    mkdir -p "$CERT_DIR"
    cp -f /etc/ssl/certs/ca-certificates.crt "$CERT_DIR/ca-bundle.crt" 2>/dev/null || true

    export SSL_CERT_FILE="$CERT_DIR/ca-bundle.crt"
    export REQUESTS_CA_BUNDLE="$CERT_DIR/ca-bundle.crt"
    export CURL_CA_BUNDLE="$CERT_DIR/ca-bundle.crt"
    export NODE_EXTRA_CA_CERTS="$CERT_DIR/ca-bundle.crt"

    # Map Coder host alias to the direct server IP
    if ! grep -q "coder.service.internal" /etc/hosts 2>/dev/null; then
      echo "${local.coder_server_ip} coder.service.internal" | sudo tee -a /etc/hosts
    fi

    # Ensure Podman global configuration sets CODER_AGENT_URL for child containers (devcontainers)
    # Safely modify existing containers.conf without replacing its critical PinP engine settings
    for conf in /etc/containers/containers.conf "$HOME/.config/containers/containers.conf"; do
      if [ -f "$conf" ]; then
        if grep -q "CODER_AGENT_URL" "$conf"; then
          sudo sed -i 's|.*CODER_AGENT_URL=.*|  "CODER_AGENT_URL=${local.coder_server_url}",|' "$conf"
        elif grep -q "env = \[" "$conf"; then
          sudo sed -i '/env = \[/a \ \ "CODER_AGENT_URL=${local.coder_server_url}",' "$conf"
        elif grep -q "\[containers\]" "$conf"; then
          sudo sed -i '/\[containers\]/a env = [\n  "CODER_AGENT_URL=${local.coder_server_url}",\n]' "$conf"
        fi
      fi
    done

    # Trigger local rootless-in-rootless Podman engine socket activation if the platform supports it
    if [ -f "/usr/local/bin/init-local-podman.sh" ]; then
      echo "Local Podman helper script discovered. Starting system engine..."
      /usr/local/bin/init-local-podman.sh
    fi

    # If desktop environment is enabled, write KasmVNC config to the user's home config
    if [ "$${INSTALL_DE}" = "true" ]; then
      echo "Writing KasmVNC config to $HOME/.vnc/kasmvnc.yaml"
      mkdir -p "$HOME/.vnc"
      cat > "$HOME/.vnc/kasmvnc.yaml" <<'YAML'
network:
  protocol: http
  interface: 127.0.0.1
  websocket_port: 6800
  ssl:
    require_ssl: false
    pem_certificate:
    pem_key:
  udp:
    public_ip: 127.0.0.1

desktop:
  gpu:
    hw3d: true
    drinode: /dev/dri/renderD128
YAML
    fi

    export MISE_DATA_DIR="/opt/mise/data"
    export MISE_CACHE_DIR="/opt/mise/cache"
    export PATH="/opt/mise/data/shims:$HOME/.local/bin:$PATH"
    export CODER_AGENT_URL="${local.coder_server_url}"

    # Now start the Coder agent (which will connect and then run startup_script)
    exec bash -c '${replace(replace(replace(coder_agent.main[count.index].init_script, "${trimsuffix(data.coder_workspace.me.access_url, "/")}/", local.coder_server_url), trimsuffix(data.coder_workspace.me.access_url, "/"), trimsuffix(local.coder_server_url, "/")), "/https?:\\/\\/(localhost|127\\.0\\.0\\.1):[0-9]+/", trimsuffix(local.coder_server_url, "/"))}'
  EOT
  ]

  env = [
    "CODER_AGENT_TOKEN=${coder_agent.main[count.index].token}",
    "CODER_AGENT_URL=${local.coder_server_url}",
    "INSTALL_DE=${data.coder_parameter.install_de.value}",
    "MISE_DATA_DIR=/opt/mise/data",
    "MISE_CACHE_DIR=/opt/mise/cache"
  ]


  volumes {
    container_path  = "/home/coder"
    volume_name     = docker_volume.home_volume.name
    selinux_relabel = data.coder_parameter.enable_devcontainer.value == "true" ? "z" : "Z"
  }

  volumes {
    container_path  = "/workspaces"
    volume_name     = docker_volume.workspaces_volume.name
    selinux_relabel = data.coder_parameter.enable_devcontainer.value == "true" ? "z" : "Z"
  }

  # Mount shared Mise tools and plugins across workspaces
  volumes {
    volume_name     = "shared_mise_data"
    container_path  = "/opt/mise/data"
    selinux_relabel = "z"
  }

  # Mount shared Mise download cache across workspaces
  volumes {
    volume_name     = "shared_mise_cache"
    container_path  = "/opt/mise/cache"
    selinux_relabel = "z"
  }

  # Mount the workspace-specific Podman cache named volume directly into Podman's local rootless storage path
  # This isolates image cache storage uniquely per workspace while enabling full read-write speed.
  dynamic "volumes" {
    for_each = data.coder_parameter.enable_devcontainer.value == "true" ? [1] : []
    content {
      volume_name     = docker_volume.podman_cache.name
      container_path  = "/home/coder/.local/share/containers"
      read_only       = false
      selinux_relabel = "z"
    }
  }

  dynamic "volumes" {
    for_each = data.coder_parameter.enable_devcontainer.value == "true" ? [1] : []
    content {
      container_path  = "/var/lib/containers"
      volume_name     = docker_volume.podman_storage.name
      selinux_relabel = "z"
    }
  }

  dynamic "devices" {
    for_each = local.device_list
    content {
      host_path      = devices.value
      container_path = devices.value
      permissions    = "rwm"
    }
  }

  restart = "unless-stopped"

  # Depend on firewall sidecar so network namespace exists
  depends_on = [
    docker_container.firewall
  ]

  labels {
    label = "coder.owner"
    value = data.coder_workspace_owner.me.name
  }
  labels {
    label = "coder.owner_id"
    value = data.coder_workspace_owner.me.id
  }
  labels {
    label = "coder.workspace_id"
    value = data.coder_workspace.me.id
  }
  labels {
    label = "coder.workspace_name"
    value = data.coder_workspace.me.name
  }
}

resource "coder_devcontainer" "devcontainer" {
  count            = (data.coder_workspace.me.start_count > 0 && data.coder_parameter.enable_devcontainer.value == "true") ? data.coder_workspace.me.start_count : 0
  agent_id         = coder_agent.main[count.index].id
  workspace_folder = local.workdir
}

module "code-server-subagent" {
  count      = (data.coder_workspace.me.start_count > 0 && data.coder_parameter.enable_devcontainer.value == "true") ? 1 : 0
  source     = "registry.coder.com/coder/code-server/coder"
  version    = "~> 1.0"
  folder     = local.workdir
  extensions = ["catppuccin.catppuccin-vsc-icons", "github.vscode-pull-request-github", "catppuccin.catppuccin-vsc"]

  open_in = "tab"
  slug    = "code-server-devcontainer"
  port    = "13331"

  settings = {
    "git.autofetch" : true,
    "git.enableSmartCommit" : true,
    "git.confirmSync" : false,
    "workbench.iconTheme" : "catppuccin-mocha",
    "workbench.colorTheme" : "Catppuccin Mocha"
  }

  subdomain = true
  agent_id  = coder_devcontainer.devcontainer[count.index].subagent_id
  order     = 1
}
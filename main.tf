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

variable "proxy_ip" {
  type        = string
  description = "The IP address of the proxy server."
  default     = "192.168.18.9"
}

variable "proxy_port" {
  type        = string
  description = "The port of the proxy server."
  default     = "1055"
}

locals {
  username = data.coder_workspace_owner.me.name

  # Unique name for containers and resources
  resource_name = "coder-${local.username}-${lower(data.coder_workspace.me.name)}"

  # Calculate the working directory based on git clone settings
  folder_name = data.coder_parameter.enable_git_clone.value == "true" ? replace(basename(try(data.coder_parameter.repo_url[0].value, "")), "/\\.git$/", "") : try(data.coder_parameter.manual_folder_name[0].value, "")
  workdir     = "/home/coder/${local.folder_name}"

  # Whether GPU device mounts should be enabled (true when install_de is selected)
  enable_gpu = data.coder_parameter.install_de.value == "true" ? true : (data.coder_parameter.enable_gpu.value == "true")

  # Select container image dynamically across the 4 workspace combinations
  container_image = (
    data.coder_parameter.install_de.value == "true" && data.coder_parameter.enable_devcontainer.value == "true" ? try(docker_image.workspace_desktop_podman[0].image_id, "") : (
      data.coder_parameter.install_de.value == "true" && data.coder_parameter.enable_devcontainer.value == "false" ? try(docker_image.workspace_desktop[0].image_id, "") : (
        data.coder_parameter.enable_devcontainer.value == "true" && data.coder_parameter.install_de.value == "false" ? try(docker_image.workspace_podman[0].image_id, "") : docker_image.workspace.image_id
      )
    )
  )

  # Compile standard hardware devices to mount
  base_devices = local.enable_gpu ? ["/dev/dri/card0", "/dev/dri/renderD128"] : []

  # Include fuse device for nested container execution if local engine is configured
  device_list = data.coder_parameter.enable_devcontainer.value == "true" ? concat(local.base_devices, ["/dev/fuse"]) : local.base_devices
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

data "coder_parameter" "enable_gpu" {
  type         = "bool"
  name         = "enable_gpu"
  display_name = "Enable GPU Acceleration"
  description  = "Mount host GPU devices /dev/dri/card0 and /dev/dri/renderD128 into the workspace container for hardware acceleration."
  # Force-enable and make read-only when Desktop Environment is selected
  default      = data.coder_parameter.install_de.value == "true" ? "true" : "false"
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
  description  = "Enter the name of the folder to create in your home directory."
  default      = "my-workspace"
}

provider "docker" {
  # Defaulting to null if the variable is an empty string lets us have an optional variable without having to set our own default
  host     = "ssh://workspaces@host.containers.internal:22"
  ssh_opts = ["-o", "StrictHostKeyChecking=no"]
}

data "coder_provisioner" "me" {}
data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}
data "coder_task" "me" {}

data "coder_external_auth" "github" {
  id = "github"
}

resource "coder_ai_task" "task" {
  count  = data.coder_workspace.me.start_count
  app_id = module.copilot[count.index].task_app_id
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

    (
      echo "[Coder Agent] Starting background permissions alignment check..."
      for i in {1..120}; do
        if [ -d "${local.workdir}" ]; then
          # Settle down for 3 seconds to let active cloning complete writing
          sleep 3
          echo "[Coder Agent] Target workspace found at ${local.workdir}. Restoring clean POSIX boundaries..."
          
          # Remove execute permission from general files to make them Git-safe (666)
          find "${local.workdir}" -path '*/.git' -prune -o -type f -exec chmod 666 {} + || true
          
          # Make directories fully accessible and traversable (777)
          find "${local.workdir}" -path '*/.git' -prune -o -type d -exec chmod 777 {} + || true
          
          echo "[Coder Agent] Permission alignments finalized successfully."
          break
        fi
        sleep 1
      done
    ) &
  EOT

  connection_timeout = 120

  env = {
    GIT_AUTHOR_NAME     = coalesce(data.coder_workspace_owner.me.full_name, data.coder_workspace_owner.me.name)
    GIT_AUTHOR_EMAIL    = "${data.coder_workspace_owner.me.email}"
    GIT_COMMITTER_NAME  = coalesce(data.coder_workspace_owner.me.full_name, data.coder_workspace_owner.me.name)
    GIT_COMMITTER_EMAIL = "${data.coder_workspace_owner.me.email}"
    DOCKER_HOST         = data.coder_parameter.enable_devcontainer.value == "true" ? "unix:///var/run/docker.sock" : "unix:///run/user/1000/podman/podman.sock"
    NODE_EXTRA_CA_CERTS = "$HOME/.local/share/ca-certificates/ca-bundle.crt"
    SSL_CERT_FILE       = "$HOME/.local/share/ca-certificates/ca-bundle.crt"
    REQUESTS_CA_BUNDLE  = "$HOME/.local/share/ca-certificates/ca-bundle.crt"
    CURL_CA_BUNDLE      = "$HOME/.local/share/ca-certificates/ca-bundle.crt"
    DISPLAY             = ":1"
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
    display_name = "Home Disk (Host)"
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
    "git.autofetch": true,
    "git.enableSmartCommit": true,
    "git.confirmSync": false,
    "workbench.iconTheme": "catppuccin-mocha",
    "workbench.colorTheme": "Catppuccin Mocha"
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
  version  = "~> 1.0"
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

module "copilot" {
  source   = "registry.coder.com/coder-labs/copilot/coder"
  version  = "0.3.0"
  count    = data.coder_workspace.me.start_count
  agent_id = coder_agent.main[count.index].id
  workdir  = local.workdir

  copilot_version = "1.0.13"

  copilot_config = jsonencode({
    banner = "never"
    theme  = "dark"
  })

  ai_prompt = data.coder_task.me.prompt

  pre_install_script = <<-EOT
    if [ "${data.coder_parameter.install_de.value}" = "true" ]; then
      npm install -g @playwright/cli@latest
      playwright-cli install --skills
    fi
  EOT
}

module "git-clone" {
  count    = (data.coder_workspace.me.start_count > 0 && data.coder_parameter.enable_git_clone.value == "true") ? 1 : 0
  source   = "registry.coder.com/coder/git-clone/coder"
  version  = "~> 1.0"
  agent_id = coder_agent.main[0].id
  url      = data.coder_parameter.repo_url[0].value
  base_dir = "/home/coder"
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

# 1. Base CLI Workspace (Non-Podman)
data "docker_registry_image" "workspace" {
  name = "ghcr.io/sairam-suresh/workspace:latest"
}

resource "docker_image" "workspace" {
  name          = data.docker_registry_image.workspace.name
  pull_triggers = [data.docker_registry_image.workspace.sha256_digest]
  keep_locally  = true
}

# 2. CLI Workspace with Nested local Podman Engine
data "docker_registry_image" "workspace_podman" {
  count = data.coder_parameter.enable_devcontainer.value == "true" && data.coder_parameter.install_de.value == "false" ? 1 : 0
  name  = "ghcr.io/sairam-suresh/workspace-podman:latest"
}

resource "docker_image" "workspace_podman" {
  count         = data.coder_parameter.enable_devcontainer.value == "true" && data.coder_parameter.install_de.value == "false" ? 1 : 0
  name          = data.docker_registry_image.workspace_podman[0].name
  pull_triggers = [data.docker_registry_image.workspace_podman[0].sha256_digest]
  keep_locally  = true
}

# 3. GUI Desktop Workspace (Non-Podman)
data "docker_registry_image" "workspace_desktop" {
  count = data.coder_parameter.install_de.value == "true" && data.coder_parameter.enable_devcontainer.value == "false" ? 1 : 0
  name  = "ghcr.io/sairam-suresh/workspace-desktop:latest"
}

resource "docker_image" "workspace_desktop" {
  count         = data.coder_parameter.install_de.value == "true" && data.coder_parameter.enable_devcontainer.value == "false" ? 1 : 0
  name          = data.docker_registry_image.workspace_desktop[0].name
  pull_triggers = [data.docker_registry_image.workspace_desktop[0].sha256_digest]
  keep_locally  = true
}

# 4. GUI Desktop Workspace with Nested local Podman Engine
data "docker_registry_image" "workspace_desktop_podman" {
  count = data.coder_parameter.install_de.value == "true" && data.coder_parameter.enable_devcontainer.value == "true" ? 1 : 0
  name  = "ghcr.io/sairam-suresh/workspace-desktop-podman:latest"
}

resource "docker_image" "workspace_desktop_podman" {
  count         = data.coder_parameter.install_de.value == "true" && data.coder_parameter.enable_devcontainer.value == "true" ? 1 : 0
  name          = data.docker_registry_image.workspace_desktop_podman[0].name
  pull_triggers = [data.docker_registry_image.workspace_desktop_podman[0].sha256_digest]
  keep_locally  = true
}

resource "docker_image" "firewall" {
  name         = "coder-firewall:local"
  keep_locally = true

  build {
    context            = "${path.module}/images/firewall"
    dockerfile         = "Dockerfile"
    tag                = ["coder-firewall:local"]
    use_legacy_builder = true
  }

  triggers = {
    dockerfile_hash = filesha256("${path.module}/images/firewall/Dockerfile")
    entrypoint_hash = filesha256("${path.module}/images/firewall/entrypoint.sh")
  }
}

# The Sidecar Firewall Container (owns the pasta network stack)
resource "docker_container" "firewall" {
  count = data.coder_workspace.me.start_count
  image = docker_image.firewall.image_id
  name  = "${local.resource_name}-firewall"

  network_mode = "pasta"

  capabilities {
    add = ["NET_ADMIN"]
  }

  env = [
    "PROXY_IP=${var.proxy_ip}",
    "PROXY_PORT=${var.proxy_port}"
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

  # Scale privilege configuration safely only when local nested containers are active
  privileged  = false
  userns_mode = "host"
  user        = "0:0"

  security_opts = data.coder_parameter.enable_devcontainer.value == "true" ? [
    "label:disable",
    "seccomp=unconfined",
    "systempaths=unconfined"
  ] : []

  capabilities {
    add = data.coder_parameter.enable_devcontainer.value == "true" ? ["SYS_ADMIN", "SYS_PTRACE", "MKNOD"] : []
  }

  entrypoint = ["bash", "-c"]
  command = [<<-EOT
    set -e
    echo "Aligning home directory permissions..."
    chown -R 1000:1000 "$HOME" || true

    # Wait until the homelab endpoint responds with HTTP 200 via the
    # Tailscale SOCKS5 proxy. Continue only after it returns 200.
    echo "Waiting for http://healthcheck.service.internal/ to return HTTP 200..."
    until curl --socks5-hostname ${var.proxy_ip}:${var.proxy_port} -sS -I --max-time 5 -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' http://healthcheck.service.internal/ 2>/dev/null | head -n1 | grep -qE 'HTTP/[^ ]+ 200'; do
      echo "Waiting for http://healthcheck.service.internal/ to return 200..."
      sleep 1
    done
    echo "http://healthcheck.service.internal/ returned 200; continuing."

    apt update

    echo "Downloading homelab certificates..."

    # Create user-writable certificate directory
    CERT_DIR="$HOME/.local/share/ca-certificates"
    mkdir -p "$CERT_DIR"

    # Download root certificate
    if curl --socks5-hostname ${var.proxy_ip}:${var.proxy_port} -fsSL -o "$CERT_DIR/homelab-root.crt" http://stepca.service.internal/roots.pem; then
      echo "Successfully downloaded root certificate"
    else
      echo "Warning: Failed to download root certificate"
    fi

    # Download intermediate certificate
    if curl --socks5-hostname ${var.proxy_ip}:${var.proxy_port} -fsSL -o "$CERT_DIR/homelab-intermed.crt" http://stepca.service.internal/intermediates.pem; then
      echo "Successfully downloaded intermediate certificate"
    else
      echo "Warning: Failed to download intermediate certificate"
    fi

    # Create a combined certificate bundle for applications that need a single file
    cat "$CERT_DIR/homelab-root.crt" "$CERT_DIR/homelab-intermed.crt" > "$CERT_DIR/ca-bundle.crt" 2>/dev/null || true

    if [ -f "$CERT_DIR/homelab-root.crt" ]; then
      echo "Importing certificates into Debian system-wide trust store..."
      mkdir -p /usr/local/share/ca-certificates/homelab
      cp "$CERT_DIR/homelab-root.crt" /usr/local/share/ca-certificates/homelab/root.crt 2>/dev/null || true
      cp "$CERT_DIR/homelab-intermed.crt" /usr/local/share/ca-certificates/homelab/intermediate.crt 2>/dev/null || true
      /usr/sbin/update-ca-certificates --fresh >/dev/null
      echo "System trust store rebuilt successfully."
    fi

    appended=0
    system_bundles=( \
      "/etc/ssl/certs/ca-certificates.crt" \
      "/etc/pki/tls/certs/ca-bundle.crt" \
      "/etc/ssl/cert.pem" \
      "/etc/ssl/certs/ca-bundle.crt" \
      "/etc/ssl/ca-bundle.pem" \
      "/etc/ssl/ca-bundle.crt" \
      "/usr/local/share/ca-certificates/ca-certificates.crt" \
    )
    for f in "$${system_bundles[@]}"; do
      if [ -f "$f" ]; then
        echo "Appending system trust store $f to $CERT_DIR/ca-bundle.crt"
        cat "$f" >> "$CERT_DIR/ca-bundle.crt" 2>/dev/null || true
        appended=1
      fi
    done

    # If we didn't find a packaged bundle, append individual cert files from /etc/ssl/certs
    if [ "$appended" -eq 0 ] && [ -d /etc/ssl/certs ]; then
      echo "Appending certificates from /etc/ssl/certs to $CERT_DIR/ca-bundle.crt"
      find /etc/ssl/certs -type f \( -name "*.crt" -o -name "*.pem" \) -print0 | while IFS= read -r -d '' certfile; do
        cat "$certfile" >> "$CERT_DIR/ca-bundle.crt" 2>/dev/null || true
      done
    fi

    # Export certificate paths for all user processes
    export SSL_CERT_FILE="$CERT_DIR/ca-bundle.crt"
    export REQUESTS_CA_BUNDLE="$CERT_DIR/ca-bundle.crt"
    export CURL_CA_BUNDLE="$CERT_DIR/ca-bundle.crt"
    export NODE_EXTRA_CA_CERTS="$CERT_DIR/ca-bundle.crt"

    echo "Certificates configured at $CERT_DIR/ca-bundle.crt"

    # Trigger local rootful-in-rootless Podman engine socket activation if the platform supports it
    if [ -f "/usr/local/bin/init-local-podman.sh" ]; then
      echo "Aligning internal podman storage permissions..."
      chown -R 0:0 /var/lib/containers || true  # Direct root execution

      echo "Local Podman helper script discovered. Starting system engine..."
      /usr/local/bin/init-local-podman.sh
      
      export DOCKER_HOST="unix:///var/run/docker.sock"
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
      chown -R 1000:1000 "$HOME/.vnc" || true
    fi

    export PATH="$HOME/.local/bin:$PATH"
    chown -R 1000:1000 "$HOME" || true

    # Drop down to the coder user while preserving the environment variables we've built
    echo "Dropping privileges to coder user..."
    exec /usr/sbin/runuser -m -u coder -- bash -c '${coder_agent.main[count.index].init_script}'
  EOT
  ]

  env = [
    "CODER_AGENT_TOKEN=${coder_agent.main[count.index].token}",
    "HTTPS_PROXY=http://${var.proxy_ip}:${var.proxy_port}/",
    "HTTP_PROXY=http://${var.proxy_ip}:${var.proxy_port}/",
    "http_proxy=http://${var.proxy_ip}:${var.proxy_port}/",
    "https_proxy=http://${var.proxy_ip}:${var.proxy_port}/",
    "NO_PROXY=localhost,127.0.0.1,::1",
    "DOCKER_HOST=${data.coder_parameter.enable_devcontainer.value == "true" ? "unix:///var/run/docker.sock" : "unix:///run/user/1000/podman/podman.sock"}",
    "CONTAINER_HOST=${data.coder_parameter.enable_devcontainer.value == "true" ? "unix:///var/run/docker.sock" : "unix:///run/user/1000/podman/podman.sock"}",
    "INSTALL_DE=${data.coder_parameter.install_de.value}"
  ]

  volumes {
    container_path = "/home/coder"
    volume_name    = docker_volume.home_volume.name
    selinux_relabel = data.coder_parameter.enable_devcontainer.value == "true" ? "z" : "Z"
  }

  dynamic "volumes" {
    for_each = data.coder_parameter.enable_devcontainer.value == "true" ? [1] : []
    content {
      container_path = "/var/lib/containers"
      volume_name    = docker_volume.podman_storage.name
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

  depends_on = [docker_container.firewall]

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
  folder     = "/workspaces/${local.folder_name}"
  extensions = ["catppuccin.catppuccin-vsc-icons", "github.vscode-pull-request-github", "catppuccin.catppuccin-vsc"]

  open_in = "tab"
  slug    = "code-server-devcontainer"
  port    = "13331"

  settings = {
    "git.autofetch": true,
    "git.enableSmartCommit": true,
    "git.confirmSync": false,
    "workbench.iconTheme": "catppuccin-mocha",
    "workbench.colorTheme": "Catppuccin Mocha"
  }

  subdomain = true
  agent_id  = coder_devcontainer.devcontainer[count.index].subagent_id
  order     = 1
}
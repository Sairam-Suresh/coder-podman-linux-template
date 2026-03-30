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

locals {
  username = data.coder_workspace_owner.me.name
  # Unique name for containers and resources
  resource_name = "coder-${local.username}-${lower(data.coder_workspace.me.name)}"
  workspace_hash_int = parseint(substr(md5(data.coder_workspace.me.id), 0, 7), 16)
  ts_port = 40000 + (local.workspace_hash_int % 300)
  
  # Calculate the working directory based on git clone settings
  folder_name = data.coder_parameter.enable_git_clone.value == "true" ? replace(basename(try(data.coder_parameter.repo_url[0].value, "")), "/\\.git$/", "") : try(data.coder_parameter.manual_folder_name[0].value, "")
  workdir     = "/home/coder/${local.folder_name}"
  
  # Whether GPU device mounts should be enabled (true when install_de is selected)
  enable_gpu = data.coder_parameter.install_de.value == "true" ? true : (data.coder_parameter.enable_gpu.value == "true")

  # Select container image based on desktop environment parameter
  container_image = data.coder_parameter.install_de.value == "true" ? docker_image.workspace_desktop[0].image_id : docker_image.workspace.image_id
}

variable "docker_socket" {
  default     = ""
  description = "(Optional) Docker socket URI"
  type        = string
}

variable "tailscale_auth_key" {
  type        = string
  description = "Tailscale auth key injected at apply time (for example via tfvars or TF_VAR_tailscale_auth_key)."
  sensitive   = true
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
  description  = "Installs Rootless Podman to support Devcontainers."
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
  mutable      = data.coder_parameter.install_de.value == "true" ? false : true
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
  host = var.docker_socket != "" ? var.docker_socket : null
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
  arch           = data.coder_provisioner.me.arch
  os             = "linux"
  count          = data.coder_workspace.me.start_count
  dir            = local.workdir
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

    # Add any additional startup commands here
  EOT

  connection_timeout = 120

  # These environment variables allow you to make Git commits right away after creating a
  # workspace. Note that they take precedence over configuration defined in ~/.gitconfig!
  # You can remove this block if you'd prefer to configure Git manually or using
  # dotfiles. (see docs/dotfiles.md)
  env = {
    GIT_AUTHOR_NAME     = coalesce(data.coder_workspace_owner.me.full_name, data.coder_workspace_owner.me.name)
    GIT_AUTHOR_EMAIL    = "${data.coder_workspace_owner.me.email}"
    GIT_COMMITTER_NAME  = coalesce(data.coder_workspace_owner.me.full_name, data.coder_workspace_owner.me.name)
    GIT_COMMITTER_EMAIL = "${data.coder_workspace_owner.me.email}"
    DOCKER_HOST         = "unix:///run/user/1000/podman/podman.sock"
    # Certificate-related environment variables (using user-writable location for rootless)
    NODE_EXTRA_CA_CERTS = "$HOME/.local/share/ca-certificates/ca-bundle.crt"
    SSL_CERT_FILE       = "$HOME/.local/share/ca-certificates/ca-bundle.crt"
    REQUESTS_CA_BUNDLE  = "$HOME/.local/share/ca-certificates/ca-bundle.crt"
    CURL_CA_BUNDLE      = "$HOME/.local/share/ca-certificates/ca-bundle.crt"
    DISPLAY             = ":1"
  }

  # The following metadata blocks are optional. They are used to display
  # information about your workspace in the dashboard. You can remove them
  # if you don't want to display any information.
  # For basic resources, you can use the `coder stat` command.
  # If you need more control, you can write your own script.
  metadata {
    display_name = "CPU Usage"
    key          = "0_cpu_usage"
    script       = "coder stat cpu"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "RAM Usage"
    key          = "1_ram_usage"
    script       = "coder stat mem"
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
    # get load avg scaled by number of cores
    script   = <<EOT
      echo "`cat /proc/loadavg | awk '{ print $1 }'` `nproc`" | awk '{ printf "%0.2f", $1/$2 }'
    EOT
    interval = 60
    timeout  = 1
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

# See https://registry.coder.com/modules/coder/code-server
module "code-server" {
  count  = data.coder_workspace.me.start_count
  source = "registry.coder.com/coder/code-server/coder"

  # This ensures that the latest non-breaking version of the module gets downloaded, you can also pin the module version to prevent breaking changes in production.
  version = "~> 1.0"

  folder = local.workdir

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

# See https://registry.coder.com/modules/coder/jetbrains-gateway
module "jetbrains_gateway" {
  count  = data.coder_workspace.me.start_count
  source = "registry.coder.com/coder/jetbrains-gateway/coder"

  # JetBrains IDEs to make available for the user to select
  jetbrains_ides = ["IU", "PS", "WS", "PY", "CL", "GO", "RM", "RD", "RR"]
  default        = "IU"

  # Default folder to open when starting a JetBrains IDE
  folder = local.workdir

  # This ensures that the latest non-breaking version of the module gets downloaded, you can also pin the module version to prevent breaking changes in production.
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

  ai_prompt = data.coder_task.me.prompt

  pre_install_script = <<-EOT
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
  name = "coder-${data.coder_workspace.me.id}-home"
  # Protect the volume from being deleted due to changes in attributes.
  lifecycle {
    ignore_changes = all
  }
  # Add labels in Docker to keep track of orphan resources.
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
  # This field becomes outdated if the workspace is renamed but can
  # be useful for debugging or cleaning out dangling volumes.
  labels {
    label = "coder.workspace_name_at_creation"
    value = data.coder_workspace.me.name
  }
}

# Persistent volume for Tailscale state
resource "docker_volume" "tailscale_state" {
  name = "coder-${data.coder_workspace.me.id}-tailscale"
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

# Persistent volume for bind-mounting the rootless podman socket between the podman and workspace containers
resource "docker_volume" "podman_socket" {
  name = "coder-${data.coder_workspace.me.id}-podman-socket"
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

# Build local Podman-in-Podman image (allows custom entrypoint)
resource "docker_image" "PinP" {
  name = "pinp:local"
  keep_locally = true

  build {
    context    = "${path.module}/images/pinp"
    dockerfile = "Dockerfile"
    tag        = ["pinp:local"]
  }

  triggers = {
    dockerfile_hash  = filesha256("${path.module}/images/pinp/Dockerfile")
    entrypoint_hash  = filesha256("${path.module}/images/pinp/entrypoint.sh")
  }
}

# Build the DNS2Socks image if it doesn't exist (persistent across workspace deletions)
resource "docker_image" "dns2socks" {
  name = "dns2socks:local"
  keep_locally = true  # Don't delete on workspace destruction
  
  build {
    context    = "${path.module}/images/dns2socks"
    dockerfile = "Dockerfile"
    tag        = ["dns2socks:local"]
  }

  # Only rebuild if files change
  triggers = {
    dockerfile_hash  = filesha256("${path.module}/images/dns2socks/Dockerfile")
    entrypoint_hash  = filesha256("${path.module}/images/dns2socks/entrypoint.sh")
  }
}

# Build the workspace (no desktop) image if it doesn't exist (persistent across workspace deletions)
resource "docker_image" "workspace" {
  name = "workspace:local"
  keep_locally = true  # Don't delete on workspace destruction
  
  build {
    context    = "${path.module}/images/workspace"
    dockerfile = "Dockerfile"
    tag        = ["workspace:local"]
  }

  # Only rebuild if files change
  triggers = {
    dockerfile_hash  = filesha256("${path.module}/images/workspace/Dockerfile")
  }
}

# Desktop variant built on top of the `workspace` image. Built after `workspace` is available.
resource "docker_image" "workspace_desktop" {
  count = data.coder_parameter.install_de.value == "true" ? 1 : 0
  name = "workspace_desktop:local"
  keep_locally = true
  depends_on = [docker_image.workspace]

  build {
    context    = "${path.module}/images/workspace-desktop"
    dockerfile = "Dockerfile"
    tag        = ["workspace_desktop:local"]
  }

  # Only rebuild if files change
  triggers = {
    dockerfile_hash      = filesha256("${path.module}/images/workspace-desktop/Dockerfile")
    workspace_image_id   = docker_image.workspace.image_id
  }
}

# Tailscale sidecar container with userspace networking mode
resource "docker_container" "tailscale" {
  count = data.coder_workspace.me.start_count
  image = "tailscale/tailscale:latest"
  name  = "${local.resource_name}-tailscale"
  
  hostname = data.coder_workspace.me.name
  
  # Userspace networking mode configuration
  env = [
    "TS_AUTHKEY=${var.tailscale_auth_key}",
    "TS_STATE_DIR=/var/lib/tailscale",
    "TS_SOCKET=/var/run/tailscale/tailscaled.sock",
    "TS_USERSPACE=true",
    "TS_SOCKS5_SERVER=:1055",
    "TS_OUTBOUND_HTTP_PROXY_LISTEN=:1055",
    "TS_TAILSCALED_EXTRA_ARGS=--port=${local.ts_port}"
  ]

  volumes {
    container_path = "/var/lib/tailscale"
    volume_name    = docker_volume.tailscale_state.name
    read_only      = false
  }

  # Use Pasta networking backend
  network_mode = "pasta"

  # Configure DNS to use only localhost (DNS2Socks will be listening on port 53)
  dns = ["127.0.0.1"]

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

# DNS2Socks container for DNS resolution via Tailscale SOCKS5 proxy
resource "docker_container" "dns2socks" {
  count = data.coder_workspace.me.start_count
  image = docker_image.dns2socks.image_id
  name  = "${local.resource_name}-dns2socks"
  
  hostname = "${data.coder_workspace.me.name}-dns"

  env = [
    "LISTEN_ADDR=127.0.0.1:53",
    "DNS_REMOTE_SERVER=100.87.51.78:53",  # Tailscale MagicDNS
    "SOCKS5_SETTINGS=socks5://127.0.0.1:1055",
    "VERBOSITY=info",
    "CACHE_RECORDS=true",
    "FORCE_TCP=true"    
  ]

  # Share the network namespace with the Tailscale container
  network_mode = "container:${docker_container.tailscale[count.index].name}"

  # Wait for Tailscale and the podman volume initializer to be ready
  depends_on = [docker_container.tailscale]

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
  count = data.coder_workspace.me.start_count
  image = local.container_image
  # Uses lower() to avoid Docker restriction on container names.
  name = local.resource_name
  # Hostname makes the shell more user friendly: coder@my-workspace:~$
  hostname = "${data.coder_workspace.me.name}"
  
  # Custom entrypoint that waits for Tailscale and trusts certificates BEFORE starting the agent
  entrypoint = ["bash", "-c"]
  command = [<<-EOT
    set -e

    # Wait until the homelab endpoint responds with HTTP 200 via the
    # Tailscale SOCKS5 proxy. Continue only after it returns 200.
    echo "Waiting for https://homelab.tail4ef781.ts.net/ to return HTTP 200..."
    until curl --socks5-hostname 127.0.0.1:1055 -sS -I --max-time 5 -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' https://homelab.tail4ef781.ts.net/ 2>/dev/null | head -n1 | grep -qE 'HTTP/[^ ]+ 200'; do
      echo "Waiting for homelab.tail4ef781.ts.net to return 200..."
      sleep 1
    done
    echo "homelab.tail4ef781.ts.net returned 200; continuing."

    sudo apt update

    echo "Downloading homelab certificates..."
    
    # Create user-writable certificate directory
    CERT_DIR="$HOME/.local/share/ca-certificates"
    mkdir -p "$CERT_DIR"
    
    # Download root certificate (using SOCKS5 proxy via curl)
    if curl --socks5-hostname 127.0.0.1:1055 -fsSL -o "$CERT_DIR/homelab-root.crt" https://homelab.tail4ef781.ts.net/stepca/roots.pem; then
      echo "Successfully downloaded root certificate"
    else
      echo "Warning: Failed to download root certificate"
    fi
    
    # Download intermediate certificate
    if curl --socks5-hostname 127.0.0.1:1055 -fsSL -o "$CERT_DIR/homelab-intermed.crt" https://homelab.tail4ef781.ts.net/stepca/intermediates.pem; then
      echo "Successfully downloaded intermediate certificate"
    else
      echo "Warning: Failed to download intermediate certificate"
    fi
    
    # Create a combined certificate bundle for applications that need a single file
    cat "$CERT_DIR/homelab-root.crt" "$CERT_DIR/homelab-intermed.crt" > "$CERT_DIR/ca-bundle.crt" 2>/dev/null || true
    
    # Export certificate paths for all processes
    export SSL_CERT_FILE="$CERT_DIR/ca-bundle.crt"
    export REQUESTS_CA_BUNDLE="$CERT_DIR/ca-bundle.crt"
    export CURL_CA_BUNDLE="$CERT_DIR/ca-bundle.crt"
    export NODE_EXTRA_CA_CERTS="$CERT_DIR/ca-bundle.crt"
    
    echo "Certificates configured at $CERT_DIR/ca-bundle.crt"

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

    export PATH="$HOME/.local/bin:$PATH"

    # Now start the Coder agent (which will connect and then run startup_script)
    exec bash -c '${coder_agent.main[count.index].init_script}'
  EOT
  ]
  
  env = [
    "CODER_AGENT_TOKEN=${coder_agent.main[count.index].token}",
    "HTTPS_PROXY=http://localhost:1055/",
    "DOCKER_HOST=unix:///run/user/1000/podman/podman.sock",
    "CONTAINER_HOST=unix:///run/user/1000/podman/podman.sock",
    "INSTALL_DE=${data.coder_parameter.install_de.value}"
  ]

  # Share the network namespace with the Tailscale container
  network_mode = "container:${docker_container.tailscale[count.index].name}"
  
  # DNS is configured on the Tailscale container (network owner)
  
  volumes {
    container_path = "/home/coder"
    volume_name    = docker_volume.home_volume.name
    read_only      = false
  }

  volumes {
    container_path = "/run/user/1000/podman"
    volume_name    = docker_volume.podman_socket.name
    read_only      = false
  }

  dynamic "devices" {
    for_each = local.enable_gpu ? ["/dev/dri/card0", "/dev/dri/renderD128"] : []
    content {
      host_path      = devices.value
      container_path = devices.value
      permissions    = "rwm"
    }
  }

  depends_on = [docker_container.dns2socks]

  restart = "unless-stopped"

  # Add labels in Docker to keep track of orphan resources.
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

# The optional PinP Podman Container which will enable Devcontainer support among others
resource "docker_container" "PinP" {
  count = (data.coder_workspace.me.start_count > 0 && data.coder_parameter.enable_devcontainer.value == "true") ? data.coder_workspace.me.start_count : 0
  image = docker_image.PinP.image_id
  name  = "${local.resource_name}-podman"
  
  hostname = "${data.coder_workspace.me.name}-podman"
  devices {
    host_path      = "/dev/fuse"
    container_path = "/dev/fuse"
    permissions    = "rwm"
  }

  security_opts = [
    "label:disable",
    # "seccomp=unconfined",
  ]

  # Allow PinP to perform operations that require additional privileges (e.g. mounting)
  # capabilities {
  #   add = ["SYS_ADMIN"]
  # }

  # Share the network namespace with the Tailscale container
  network_mode = "container:${docker_container.tailscale[count.index].name}"

  # Wait for Tailscale to be ready
  depends_on = [docker_container.tailscale]

  restart = "unless-stopped"

  volumes {
    container_path = "/home/coder"
    volume_name    = docker_volume.home_volume.name
    read_only      = false
  }

  volumes {
    container_path = "/tmp/podman/"
    volume_name    = docker_volume.podman_socket.name
    read_only      = false
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

resource "coder_devcontainer" "devcontainer" {
  count = (data.coder_workspace.me.start_count > 0 && data.coder_parameter.enable_devcontainer.value == "true") ? data.coder_workspace.me.start_count : 0
  agent_id = coder_agent.main[count.index].id
  workspace_folder = local.workdir
}
---
display_name: Docker Containers
description: Provision Docker containers as Coder workspaces
maintainer_github: sairam-suresh
verified: false
tags: [docker, container]
---

# Remote Development on Docker Containers

Provision Docker containers as [Coder workspaces](https://coder.com/docs/workspaces) with this example template.

<!-- TODO: Add screenshot -->

## Prerequisites

### Infrastructure

The VM you run Coder on must have a running Docker socket and the `coder` user must be added to the Docker group:

```sh
# Add coder user to Docker group
sudo adduser coder docker

# Restart Coder server
sudo systemctl restart coder

# Test Docker
sudo -u coder docker ps
```

## Architecture

This template provisions the following resources:

- Docker image (built by Docker socket and kept locally)
- Docker container pod (ephemeral)
- Docker volume (`/workspaces`) - Dedicated persistent storage for project and git repository data
- Ephemeral home directory (`/home/coder`) - Directly populated from the container image so tools, dotfiles, and system packages are automatically updated upon image rebuild

### Workspace Directory Structure

Repositories and custom folders are placed in `/workspaces/<folder-name>` owned by the `coder` user (`1000:1000`).

- **Image Updates**: Because project storage is cleanly decoupled into `/workspaces`, any changes, updates, or tools in the upstream container image's home directory are immediately applied on workspace rebuild.

> **Note**
> This template is designed to be a starting point! Edit the Terraform to extend the template to support your use case.

### Editing the image

Edit the `Dockerfile` and run `coder templates push` to update workspaces.
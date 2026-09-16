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
- Docker volume (`/home/coder`) - User home directory volume preserving extension logins, auth credentials, and personal settings across restarts

### Workspace Directory Structure

Repositories and custom folders are placed in `/workspaces/<folder-name>` owned by the `coder` user (`1000:1000`).

- **Project Storage**: All source code, projects, and git repositories live cleanly in `/workspaces`.
- **User Environment**: `/home/coder` preserves all tool authentications (such as Antigravity, GitHub, and VS Code extension states), dotfiles, and shell history across restarts.

> **Note**
> This template is designed to be a starting point! Edit the Terraform to extend the template to support your use case.

### Editing the image

Edit the `Dockerfile` and run `coder templates push` to update workspaces.
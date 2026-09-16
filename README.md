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
- Docker volume (`/home/coder`) - User home directory volume (can be removed in the future for seamless image updates)

### Workspace Directory Structure & Migration

Repositories and custom folders are placed in `/workspaces/<folder-name>` owned by the `coder` user (`1000:1000`).

- **Automatic Migration**: On startup, existing workspaces with projects in `/home/coder/<folder-name>` or git repositories directly in `~` are automatically moved to `/workspaces/<folder-name>`, and a backward-compatible symlink is created in `~` to ensure uninterrupted paths.
- **Future Image Updates**: By separating project storage into `/workspaces`, the `/home/coder` volume mount can safely be removed in the future so that changes and tools in the base image's home directory are always up to date.

> **Note**
> This template is designed to be a starting point! Edit the Terraform to extend the template to support your use case.

### Editing the image

Edit the `Dockerfile` and run `coder templates push` to update workspaces.
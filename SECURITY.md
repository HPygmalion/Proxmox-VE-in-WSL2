# Security Policy

## Supported Versions

Only the latest `main` branch is supported. This project is experimental.

## Reporting a Vulnerability

Open a private GitHub security advisory or contact the repository owner. Do not open public issues for exploitable vulnerabilities.

## Installation Risks

This project modifies WSL, installs system packages, and disables default service conditions for `lxcfs`. Users should inspect `scripts/Install-PVE.ps1` and `scripts/bootstrap-pve.sh` before running. Never pipe remote scripts directly into a privileged shell without reviewing them.

Do not publish WSL export files that contain passwords, certificates, private keys, or personal data.

# Security Policy

## Scope

This repository holds scripts and compose files that people run on their own servers, often as root. That includes the `.sh` installers and helpers, `glances.ps1`, and the `.yaml` compose stacks.

Please report anything in these files that could put someone's system at risk, for example:

- Command injection, unsafe `eval`, or piping untrusted input to a shell
- Downloads over plain HTTP, or downloads with no integrity check
- Secrets, tokens, or credentials committed to the repo
- Insecure defaults in compose files: default passwords, services exposed to `0.0.0.0` that shouldn't be, or excessive privileges such as `privileged: true` or a mounted Docker socket without a reason
- Files that change permissions or ownership more broadly than they need to

Vulnerabilities in the upstream projects these files install (Docker, Paperless-ngx, Headscale, the *arr apps, and so on) are out of scope. Report those to the upstream project.

## Supported Versions

Only the latest version on the `main` branch is supported. Fixes are not backported.

## Reporting a Vulnerability

**Please do not open a public issue, pull request, or Discord post about a security problem.**

Report it privately through GitHub's private vulnerability reporting:

👉 **[Report a vulnerability](https://github.com/serversathome/ServersatHome/security/advisories/new)**

Please include:

- The affected file and line(s)
- What the problem is and how it could be exploited
- Steps to reproduce, if you have them
- A suggested fix, if you have one

## What to Expect

This is a one-person project, so responses are best-effort:

- **Acknowledgement:** usually within 7 days
- **Fix or mitigation:** as soon as practical, depending on severity
- **Credit:** you'll be credited in the fix or advisory unless you'd rather stay anonymous

Thank you for helping keep the Servers@Home community safe!

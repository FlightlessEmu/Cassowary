# Security Policy

## Supported Versions

Only the latest commit on `main` receives security fixes.

## Reporting a Vulnerability

**Please do not open a public GitHub issue for security vulnerabilities.**

Report vulnerabilities privately using GitHub's private vulnerability reporting. This keeps the details confidential until a fix is available.

Include as much of the following as you can:

- A description of the vulnerability and its potential impact
- Steps to reproduce or a proof-of-concept
- Affected commit(s)
- Any suggested fix, if you have one

## Scope

Cassowary is an iOS/iPadOS app (plus Catalyst and tvOS). The primary attack surface relevant to security reports:

- **ROM/save file parsing** — malformed files that could cause unexpected behaviour
- **Core plugins** — bundled emulation cores that process untrusted input (ROM data)
- **Local network sharing** — the phone-to-TV transfer path

Out of scope: vulnerabilities in upstream emulation cores (report those to the respective upstream projects), or issues requiring physical access to the device.

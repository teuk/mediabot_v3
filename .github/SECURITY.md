# Security Policy

## Supported versions

Security fixes are primarily provided for the current stable release and the active development branch.

| Version        | Supported             |
| -------------- | --------------------- |
| 3.1 stable     | Yes                   |
| 3.2-dev        | Yes, development code |
| Older versions | No                    |

Users of older releases should upgrade before reporting a security problem whenever possible.

## Reporting a vulnerability

Please do not report security vulnerabilities through:

* public GitHub Issues;
* GitHub Discussions;
* Pull Requests;
* public IRC channels;
* the `#i/o` community channel.

Use GitHub's **private vulnerability reporting** feature instead:

1. Open the **Security** tab of the Mediabot v3 repository.
2. Select **Report a vulnerability**.
3. Provide the requested information privately.

Repository:

https://github.com/teuk/mediabot_v3

## Information to include

Please provide as much of the following information as possible:

* the affected Mediabot version;
* the affected file, module or feature;
* the operating system and Perl version;
* a clear description of the vulnerability;
* the conditions required to reproduce it;
* step-by-step reproduction instructions;
* the potential security impact;
* sanitized logs or proof-of-concept material;
* any suggested mitigation or fix.

Do not include real passwords, API keys, IRC credentials, database credentials, authentication tokens, cookies, private keys or personal data.

Replace sensitive values with clearly marked placeholders.

## Coordinated disclosure

Please allow reasonable time for the problem to be investigated and corrected before publishing technical details.

Security reports will be reviewed privately. When a vulnerability is confirmed, the project may:

* prepare and test a fix;
* publish a corrected release;
* update affected documentation;
* publish a GitHub Security Advisory;
* credit the reporter, unless anonymity is requested.

Do not publicly disclose an unresolved vulnerability before a fix or mitigation is available.

## Scope

Security reports may include issues involving:

* authentication or authorization;
* command execution;
* Partyline administration;
* plugin and script execution;
* database access;
* unsafe handling of external input;
* URL and media processing;
* exposed credentials or secrets;
* insecure default configuration;
* unintended disclosure of private information;
* network operations without appropriate validation or protection.

General bugs, installation problems and feature requests are not security vulnerabilities.

Use:

* **GitHub Issues** for reproducible non-security bugs;
* **GitHub Discussions** for installation and usage questions;
* `#i/o` on EpiKnet for live community discussion.

## Security recommendations for users

Mediabot administrators should:

* run Mediabot under a dedicated system account;
* restrict access to configuration files;
* protect database and IRC credentials;
* disable unused administrative features;
* keep Perl modules and system packages updated;
* review plugin and script code before enabling it;
* avoid exposing Partyline or administrative ports publicly;
* use firewall rules appropriate for their installation;
* keep regular backups of configuration and database data;
* review logs without publishing sensitive information.

## Contact and community support

The public IRC support channel is:

* **Network:** EpiKnet
* **Server:** `irc.epiknet.org`
* **Port:** `6697`
* **Encryption:** SSL/TLS
* **Channel:** `#i/o`

This channel is suitable for general discussion and troubleshooting only.

Do not disclose vulnerabilities, credentials or private infrastructure details there.

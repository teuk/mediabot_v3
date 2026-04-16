# Mediabot v3

Mediabot is a multi-purpose IRC bot written in Perl.

It is designed for real-world IRC operations and long-term use, with support for channel administration, user and hostmask management, database-backed commands, runtime administration, utility features, analytics, media helpers, URL title handling, and a dedicated TCP admin interface called **Partyline**.

---

## Release status

- **Stable release:** `3.1`
- **Current development line:** `3.2-dev`

Mediabot now follows a simple versioning rule:

- **odd minor versions** = **stable releases**
- **even minor versions** = **development / beta lines**

Examples:
- `3.1` = stable release
- `3.2-dev` = development line
- `3.3` = next stable release

This makes it immediately clear whether a version is intended for:
- deployment
- testing
- active development

---

## Which version should I use?

## Stable release (`3.1`)
Choose the stable release if you want:
- the recommended version for deployment
- the documented installation path
- a release tarball-based install
- a cleaner, validated baseline

This is the right choice for most users.

## Development version (`3.2-dev`)
Choose the development version if you want:
- the latest work in progress
- Git-based development access
- changes that may not yet be fully documented or finalized
- the current development branch after the 3.1 release

This is the right choice for contributors and testers.

---

## Installation paths

## Stable release install

Use the release tarball for the stable version.

### `.tar.gz`
```bash
wget https://teuk.org/downloads/mediabot/mediabot_v3-3.1.tar.gz
tar xzf mediabot_v3-3.1.tar.gz
cd mediabot_v3-3.1
./configure
```

### `.tar.xz`
```bash
wget https://teuk.org/downloads/mediabot/mediabot_v3-3.1.tar.xz
tar xJf mediabot_v3-3.1.tar.xz
cd mediabot_v3-3.1
./configure
```

## Development install (`3.2-dev`)

Use Git for the development version.

```bash
git clone https://github.com/teuk/mediabot_v3.git
cd mediabot_v3
./configure
```

---

## Validated baseline

The 3.1 release cycle included a full validation pass on a **fresh Debian 13** environment.

That work helped identify and fix issues that a long-lived development machine can easily hide, including:
- install script edge cases
- schema mismatches
- missing or brittle Perl dependency handling
- runtime restart/jump path issues
- test framework inconsistencies
- admin/runtime edge cases

This was a major step toward making Mediabot a cleaner and more deliberate release.

---

## Key features

Depending on configuration and enabled features, Mediabot can provide:

- IRC channel administration and moderation
- bot user and hostmask management
- managed channel registration and channel settings
- database-backed public commands
- analytics and activity/statistics helpers
- URL title handling
- YouTube / TMDB / media helpers
- timers and runtime administration
- Partyline TCP admin interface
- utility and conversational commands
- radio-oriented helpers where configured

---

## Important runtime notes

## Chromium
Mediabot may use **Chromium** at runtime for some modern URL-title handling cases where a simple static HTTP fetch is not enough.

If you want full expected 3.1 URL-title behavior, install Chromium.

On Debian 13, for example:

```bash
sudo apt update
sudo apt install -y chromium
```

## Hailo
The dependency path for **Hailo** may require a fallback install path during setup.

This is handled by the project install scripts, but it is worth knowing if you are validating a fresh system or reviewing dependency logs.

---

## Main entry points

After installation:

### Configure
```bash
./configure
```

### Start in foreground
```bash
./start
```

### Start in background
```bash
./daemon
```

### Stop
```bash
./stop
```

---

## Documentation

The GitHub wiki is the main documentation hub.

Recommended reading order:

1. Installation
2. Configuration
3. Public commands
4. Private and admin commands
5. Partyline
6. Troubleshooting
7. Testing
8. Release and upgrade notes

Wiki:
- `https://github.com/teuk/mediabot_v3/wiki`

---

## Partyline

Mediabot includes a dedicated TCP admin interface called **Partyline**.

It allows authenticated operators to:
- inspect bot state
- send messages
- join or part channels
- reload runtime state
- restart the bot
- terminate the bot

This interface is documented separately in the wiki and should be treated as an administrative surface.

---

## Fresh install and release philosophy

The goal of the 3.1 cycle was not only to keep adding features, but to make the project:

- installable on a fresh system
- more predictable at runtime
- easier to test
- easier to document
- easier to release cleanly

That is why 3.1 matters.

It is not just another snapshot: it is a proper stable release target.

---

## Stable release vs development tree

A stable release should be:
- downloadable
- documented
- testable
- understandable without guessing

A development tree should be:
- the place where active work continues
- clearly identified as development
- used by contributors and testers

This is why Mediabot now distinguishes clearly between:
- **stable tarball**
- **development Git tree**

---

## Recommended post-install validation

After installation, at minimum verify:

- the bot parses cleanly
- required Perl modules are visible
- DB connection works
- startup works
- expected channels join
- auth path works
- rehash works
- restart works
- Partyline works if enabled

The project also includes a live testing path for deeper validation.

See the wiki page:
- `Testing`

---

## Verify downloads

You can verify the release archives with the published SHA256 checksums.

### Download checksum file
```bash
wget https://teuk.org/downloads/mediabot/SHA256SUMS
```

### Verify the `.tar.gz` archive
```bash
sha256sum -c SHA256SUMS --ignore-missing
```

If you downloaded only one archive, `--ignore-missing` avoids errors for files that are not present locally.

---

## Project links

- Repository: `https://github.com/teuk/mediabot_v3`
- Wiki: `https://github.com/teuk/mediabot_v3/wiki`
- Stable downloads:
  - `https://teuk.org/downloads/mediabot/mediabot_v3-3.1.tar.gz`
  - `https://teuk.org/downloads/mediabot/mediabot_v3-3.1.tar.xz`
  - `https://teuk.org/downloads/mediabot/SHA256SUMS`

---

## Current release direction

- **3.1** is the stable release
- **3.2-dev** is the active development line

That means:
- users should prefer the **3.1 tarball**
- contributors and testers should follow **3.2-dev** in Git

---

## License

See:

- `LICENSE.md`

---

## Next step

If you are here to install Mediabot, start with the stable release tarball and then read the wiki:

- `https://github.com/teuk/mediabot_v3/wiki`

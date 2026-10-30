![Mediabot 3.7 — IRC, Perl, plugins and community](https://raw.githubusercontent.com/teuk/mediabot_v3/3.7/docs/mediabot-3.7-github-social-preview.png)

## The next chapter of the Grimoire 📖🪄

Mediabot 3.7 brings the 3.6 development cycle together: a Perl IRC companion
with community memory, per-channel controls, richer media previews and a
substantial plugin platform.

- **Perl plugins with explicit capabilities and channel policy.** Owned jobs,
  events, bounded failures and persistent operator settings demonstrate a
  supervised extension model. API v3 remains **experimental and opt-in**.
- **Le mot le plus long:** an asynchronous dictionary-backed multiplayer game.
  Submit words directly in chat, beat the round record, win immediately at
  the dictionary maximum and keep total/weekly scores with leaderboards.
- **French Trivia alongside Open Trivia DB English**, with a separate local
  French catalog and its own attribution and data license.
- **MixCloud show and creator-profile previews**, a dedicated opt-in Reddit
  preview, and fixes across music, URL and feed handling.
- **Private diagnostics and scoped mbweb views**, conversation profiles,
  community memory tools and a documented plugin workshop.
- **Reliability work throughout the bot:** Partyline UTF-8, confirmed database
  outcomes, plugin persistence, HTTP redirect budgets, mute cleanup and
  channel identity handling.

## Download and verify

Use the project-built `.tar.gz` or `.tar.xz` asset below, together with the
SHA-256 and SHA-512 manifests. Both contain the same `mediabot_v3-3.7/` tree.
GitHub's automatically generated source archives are separate from these
validated release artifacts.

For a fresh Debian 13 installation, follow the
[README](https://github.com/teuk/mediabot_v3/blob/3.7/README.md).
For an existing database, follow the authoritative migration order; never
import the fresh schema over instance data. Preserve configuration, runtime
state and a database backup before an installed-instance update.

The longest-word dictionary is optional and separate: **DICT.DICT**, with
read-only runtime access. Its original dump is not bundled or automatically
imported. Optional features remain disabled until deliberately configured.

## Qualification and scope

The release commit must pass both the normal CI and Debian 13 installation
gate before these assets become public. The Debian gate covers fresh MariaDB,
upgrades from the real 3.3 and 3.5 sources, logical restoration and deterministic
reapplication. The complete Perl/mbweb tests, security audit and generated
inventory are separate checks; no static test-count badge replaces them.

[Full notes](https://github.com/teuk/mediabot_v3/blob/3.7/docs/RELEASE_NOTES_3.7.md)
and the [operator acceptance record](https://github.com/teuk/mediabot_v3/blob/3.7/docs/RELEASE_ACCEPTANCE_3.7.md)
retain the documented operational follow-up. Publishing this source release
does not deploy a production instance or enable a plugin.

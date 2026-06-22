# Contributing to Mediabot v3

Thank you for considering a contribution to Mediabot v3.

Contributions of all sizes are welcome. You do not need to be an expert in Perl or IRC development to help.

Useful contributions include:

* bug reports and reproductions;
* documentation corrections;
* installation feedback;
* tests;
* plugins and scripting examples;
* improvements to existing commands;
* new IRC commands;
* translations;
* monitoring and metrics improvements;
* testing on additional IRC networks and Debian versions.

## Before starting

Please check the existing:

* [Issues](https://github.com/teuk/mediabot_v3/issues);
* [Discussions](https://github.com/teuk/mediabot_v3/discussions);
* [Wiki](https://github.com/teuk/mediabot_v3/wiki).

Use:

* **Issues** for reproducible bugs and concrete feature requests;
* **Discussions** for support questions, early ideas and general proposals;
* **`#i/o` on EpiKnet** for live community discussion.

IRC connection details:

* **Server:** `irc.epiknet.org`
* **Port:** `6697`
* **Encryption:** SSL/TLS
* **Channel:** `#i/o`

For significant changes, please open an Issue or Discussion before writing the code. This helps avoid duplicated work and makes it possible to agree on the expected behavior first.

## Development branch

The default development branch is `master`.

Create a separate branch for each contribution:

```bash
git checkout master
git pull --rebase
git checkout -b fix/short-description
```

Examples:

```text
fix/url-title-timeout
feature/new-partyline-command
docs/plugin-tutorial
test/public-command-dispatch
```

Keep each branch focused on one bug, feature or documentation topic.

## Setting up Mediabot

Follow the installation instructions in the README and Wiki.

Use a development or test installation. Do not test unreviewed changes directly on an important production bot or production database.

Never commit:

* real configuration files;
* database passwords;
* IRC passwords;
* API keys;
* authentication tokens;
* cookies;
* private certificates or keys;
* personal data;
* production logs containing sensitive information.

Use sample values and sanitized logs in Issues, tests and documentation.

## Coding guidelines

Please follow the style already used in the files you modify.

Contributions should:

* remain focused and reasonably small;
* preserve existing behavior unless a change has been discussed;
* avoid unrelated formatting or refactoring;
* include clear error handling;
* avoid blocking the main IRC event loop;
* keep configuration changes backward-compatible when possible;
* update documentation when behavior or configuration changes;
* add or update tests when practical.

Do not remove existing behavior merely because it appears unused. Mediabot has a long history and some behavior may still be required by existing installations.

## Database changes

Do not change the database schema without discussing it first in an Issue or Discussion.

Database changes require particular care because existing Mediabot installations may contain years of production data.

A database-related contribution should explain:

* why the schema change is necessary;
* how existing installations will be migrated;
* whether the migration is reversible;
* what happens when the new code runs against an older schema;
* how the change was tested with existing data.

Never include real database dumps or production data in a contribution.

## Plugins and scripts

Plugin and scripting contributions are welcome.

A plugin contribution should include:

* a clear purpose;
* configuration documentation;
* safe default behavior;
* an example of use;
* validation of external input;
* appropriate timeout and failure handling;
* tests or a reproducible manual test procedure.

Examples should not contain real credentials, private hosts or production channel information.

## Testing

Before opening a Pull Request, run the syntax checks and tests relevant to your change.

At minimum, check the modified Perl files:

```bash
perl -I. -c mediabot.pl
perl -I. -c path/to/modified/module.pm
```

Run the tests related to the modified feature.

When practical, run the complete test suite:

```bash
prove -lr t
```

If a test cannot be run in your environment, explain that clearly in the Pull Request.

Include the exact commands used and their results in the Pull Request description.

Do not claim that a test passed if it was not actually executed.

## Documentation contributions

Documentation corrections are valuable and welcome.

They may include:

* spelling and grammar corrections;
* clearer installation instructions;
* command examples;
* troubleshooting procedures;
* plugin examples;
* screenshots;
* explanations for new users.

Documentation should use generic examples and must not expose private infrastructure, credentials or personal information.

## Commit messages

Use short and descriptive commit messages written in English.

Examples:

```text
Fix timeout handling in URL title lookup
Add tests for Partyline authentication
Document EpiKnet IRC support channel
Improve Debian installation troubleshooting
```

Avoid vague messages such as:

```text
Update
Fix stuff
Changes
Test
```

## Opening a Pull Request

A Pull Request should contain:

* a clear summary of the change;
* the problem it solves;
* any compatibility impact;
* configuration or documentation changes;
* the tests that were executed;
* relevant sanitized logs or screenshots;
* a link to the related Issue or Discussion when applicable.

Keep Pull Requests focused. Unrelated changes should be submitted separately.

The maintainer may request adjustments before merging. This is normal and helps protect existing Mediabot installations from regressions.

## Pull Request checklist

Before submitting, verify that:

* [ ] the change is focused on one topic;
* [ ] no password, token, cookie or private information is included;
* [ ] modified Perl files pass syntax checks;
* [ ] relevant tests pass;
* [ ] existing behavior is preserved unless explicitly discussed;
* [ ] configuration changes are documented;
* [ ] user-visible changes are documented;
* [ ] database changes were discussed beforehand;
* [ ] the Pull Request explains exactly how the change was tested.

## Reporting security problems

Do not publish security vulnerabilities, exposed credentials or private infrastructure details in a public Issue, Discussion or IRC channel.

Use GitHub's private vulnerability reporting feature and see `.github/SECURITY.md` for the complete security reporting procedure.

## License

By submitting a contribution, you agree that it may be distributed under the same license as Mediabot v3.

Thank you for helping improve Mediabot.

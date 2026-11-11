package Mediabot::Partyline::PluginAdmin;

use strict;
use warnings;
use utf8;
use Exporter 'import';
our @EXPORT_OK = qw(_plugin_info_text _plugin_config_display_value);

# Partyline plugin administration. No bot, SQL, transport runtime or global
# service lookup: the adapter supplies a manager, writer and lazy providers for
# session level, autoload and metrics. Permission checks remain here; lifecycle
# and capability enforcement remain owned by PluginManager.

# ---------------------------------------------------------------------------
# Plugin v2 partyline rendering helpers.
# Keep every manifest/config value on one bounded line, and never expose
# likely credentials through the read-only .plugins info view.
sub _plugin_info_text {
    my ($value, $max) = @_;

    return '' unless defined $value && !ref($value);
    my $text = "$value";
    $text =~ s/[\x00-\x1f\x7f]+/ /g;
    $text =~ s/\s+/ /g;
    $text =~ s/^\s+|\s+$//g;

    $max = 200 unless defined $max && $max =~ /\A[0-9]+\z/;
    $text = substr($text, 0, $max - 3) . '...'
        if $max >= 4 && length($text) > $max;
    return $text;
}

sub _plugin_config_display_value {
    my ($key, $value) = @_;

    my $name = defined($key) && !ref($key) ? uc("$key") : '';
    return '[redacted]'
        if $name =~ /(?:\A|_)(?:PASS(?:WORD)?|SECRET|TOKEN|KEY|APIKEY|PRIVATEKEY|ACCESSKEY|CREDENTIALS?|AUTH)(?:\z|_)/;

    return _plugin_info_text($value, 63);
}

# ---------------------------------------------------------------------------
# .plugins [loaded|config] - read-only PluginManager visibility
sub run {
    my ($stream, $arg, %services) = @_;
    my $pm = $services{manager};
    unless ($pm) {
        $stream->write("PluginManager: not initialized\r\n");
        return;
    }
    $arg //= '';
    $arg =~ s/^\s+|\s+$//g;
    my $mode = lc($arg || 'summary');

    # mb588-B1: cycle de vie a chaud — la partyline devient le poste de
    # pilotage de l'arc plugins v2. Les actions destructives (load/unload/
    # reload) exigent Owner (level 0) ; enable/disable exigent Master ou
    # mieux (level <= 1), comme .schedule. Chaque refus est explique, chaque
    # erreur de chargement est montree en clair (le die du PluginManager
    # porte deja la raison precise : manifest rejete, collision, methode
    # manquante...).
    my ($verb, @rest) = split /\s+/, $arg;
    $verb = lc($verb // '');
    if ($verb eq 'discoverv3') {
        my @packages = eval { $pm->discover_v3_packages };
        if ($@) {
            (my $err = $@) =~ s/\s+\z//;
            $stream->write("API v3 discovery failed: "
                . _plugin_info_text($err, 180) . "\r\n");
            return;
        }
        $stream->write("API v3 packages:\r\n");
        for my $package (@packages) {
            $stream->write("  $package->{name} version=$package->{version} default=off caps="
                . join(',', @{ $package->{capabilities} || [] }) . "\r\n");
        }
        $stream->write("  (none)\r\n") unless @packages;
        return;
    }
    # Keep the frozen v2 lifecycle gate explicit: historical tests and tools
    # use this exact list as the boundary between read-only inspection and
    # mutable plugin operations.  API v3 extends that boundary alongside it
    # instead of rewriting the legacy contract.
    my $legacy_lifecycle_verb =
        $verb =~ /\A(?:load|loadscript|unload|reload|enable|disable|cleardata)\z/;
    my $v3_lifecycle_verb =
        $verb =~ /\A(?:loadv3|policy|resetpolicy|quarantine|unquarantine|clearv3data)\z/;
    if ($legacy_lifecycle_verb || $v3_lifecycle_verb) {
        my $level = $services{level}->();
        my $need_owner = $v3_lifecycle_verb
            || ($verb =~ /\A(?:load|loadscript|unload|reload|cleardata)\z/)
            ? 1 : 0;
        if ($need_owner && !(defined $level && $level == 0)) {
            $stream->write("Access denied: .plugins $verb requires Owner level.\r\n");
            return;
        }

        if ($verb eq 'loadv3') {
            my ($package, $grant_text) = @rest;
            unless (defined $package && length $package) {
                $stream->write("Usage: .plugins loadv3 <package> [capability,...]\r\n");
                return;
            }
            my @grants = defined($grant_text) && $grant_text ne '-'
                ? grep { length } split /,/, $grant_text : ();
            my $entry = eval {
                $pm->load_package_v3_persistent(
                    $package, grants => \@grants);
            };
            if (!$entry) {
                (my $err = $@ || 'unknown error') =~ s/\s+\z//;
                $stream->write("API v3 load failed: "
                    . _plugin_info_text($err, 180) . "\r\n");
                return;
            }
            $stream->write("Loaded API v3 package '$entry->{name}' disabled; configure one channel, then enable it.\r\n");
            return;
        }

        if ($verb eq 'policy') {
            my ($target, $channel, $policy_mode, @pairs) = @rest;
            unless (defined($target) && defined($channel)
                    && defined($policy_mode)) {
                $stream->write("Usage: .plugins policy <name> <#channel> <off|observe|on> [key=value ...]\r\n");
                return;
            }
            my %config;
            for my $pair (@pairs) {
                unless ($pair =~ /\A([a-z][a-z0-9_]{0,47})=(.*)\z/) {
                    $stream->write("Invalid config token '$pair' (expected key=value).\r\n");
                    return;
                }
                $config{$1} = $2;
            }
            my $policy = eval {
                $pm->set_v3_channel_policy_persistent($target, $channel,
                    mode => lc($policy_mode),
                    (@pairs ? (config => \%config) : ()));
            };
            if (!$policy) {
                (my $err = $@ || 'unknown error') =~ s/\s+\z//;
                $stream->write("API v3 policy failed: "
                    . _plugin_info_text($err, 180) . "\r\n");
                return;
            }
            $stream->write("API v3 policy '$target' $policy->{channel}: $policy->{mode}.\r\n");
            return;
        }

        if ($verb eq 'resetpolicy') {
            my ($target, $channel) = @rest;
            unless (defined($target) && defined($channel)) {
                $stream->write("Usage: .plugins resetpolicy <name> <#channel>\r\n");
                return;
            }
            my $removed = eval {
                $pm->reset_v3_channel_policy_persistent($target, $channel);
            };
            if ($@) {
                (my $err = $@) =~ s/\s+\z//;
                $stream->write("API v3 reset failed: "
                    . _plugin_info_text($err, 180) . "\r\n");
                return;
            }
            $stream->write($removed
                ? "API v3 policy '$target' $channel removed.\r\n"
                : "API v3 policy '$target' $channel was already absent.\r\n");
            return;
        }

        if ($verb eq 'quarantine' || $verb eq 'unquarantine') {
            my ($target, $kind, $resource, $channel, @extra) = @rest;
            unless (defined($target) && defined($kind)
                    && defined($resource) && defined($channel) && !@extra) {
                $stream->write("Usage: .plugins $verb <name> <command|event|http_callback|job> <resource> <#channel>\r\n");
                return;
            }
            if ($verb eq 'quarantine') {
                my $result = eval {
                    $pm->set_v3_quarantine(
                        $target, lc($kind), $resource, $channel);
                };
                unless ($result) {
                    my $error = $@ || 'quarantine unavailable';
                    $stream->write("API v3 quarantine failed: "
                        . _plugin_info_text($error, 180) . "\r\n");
                    return;
                }
                my $state = $result->{created} ? 'added' : 'already present';
                $stream->write("API v3 quarantine '$target':"
                    . " $result->{kind} $result->{resource}"
                    . " $result->{channel} $state.\r\n");
                return;
            }

            my $removed = eval {
                $pm->reset_v3_quarantine(
                    $target, lc($kind), $resource, $channel);
            };
            if ($@) {
                $stream->write("API v3 unquarantine failed: "
                    . _plugin_info_text($@, 180) . "\r\n");
                return;
            }
            $stream->write($removed
                ? "API v3 quarantine '$target': $kind $resource $channel released.\r\n"
                : "API v3 quarantine '$target': $kind $resource $channel was already absent.\r\n");
            return;
        }

        if ($verb eq 'clearv3data') {
            my ($target, @extra) = @rest;
            unless (defined($target) && length($target) && !@extra) {
                $stream->write("Usage: .plugins clearv3data <package>\r\n");
                return;
            }
            my ($ok, $removed, $clear_err) =
                $pm->clear_v3_plugin_data($target);
            unless ($ok) {
                $stream->write("Could not clear API v3 data for '$target': "
                    . _plugin_info_text($clear_err, 160) . "\r\n");
                return;
            }
            unless ($removed) {
                $stream->write("No stored API v3 data for package '$target'.\r\n");
                return;
            }
            $stream->write("Stored API v3 data for package '$target' cleared.\r\n");
            return;
        }
        if (!$need_owner && !(defined $level && $level <= 1)) {
            $stream->write("Access denied: .plugins $verb requires Master or Owner level.\r\n");
            return;
        }

        # mb601-B1: purge de l'etat persistant d'un plugin (Owner). Le
        # plugin peut rester charge : son prochain store repartira de zero.
        if ($verb eq 'cleardata') {
            my ($target) = @rest;
            unless (defined $target && length $target) {
                $stream->write("Usage: .plugins cleardata <name>\r\n");
                return;
            }
            my ($ok, $removed, $clear_err) = $pm->clear_plugin_data($target);
            unless ($ok) {
                $stream->write("Could not clear data for '$target': "
                    . _plugin_info_text($clear_err, 160) . "\r\n");
                return;
            }
            unless ($removed) {
                $stream->write("No stored data for plugin '$target'.\r\n");
                return;
            }
            $stream->write("Stored data for plugin '$target' cleared.\r\n");
            return;
        }

        # mb590-B1: chargement d'un plugin SCRIPT v2 (sidecar JSON) — meme
        # gate Owner, memes messages en clair, meme cycle de vie ensuite.
        if ($verb eq 'loadscript') {
            my ($path, $custom) = @rest;
            unless (defined $path && length $path) {
                $stream->write("Usage: .plugins loadscript <relative/script.(pl|py|tcl)> [name]\r\n");
                return;
            }
            my $entry = eval {
                $pm->load_script_v2($path,
                    (defined $custom && length $custom) ? (name => $custom) : ());
            };
            if (!$entry) {
                (my $err = $@ || 'unknown error') =~ s/\s+\z//;
                $stream->write("Load failed: $err\r\n");
                return;
            }
            my @cmds = @{ $entry->{mounted_commands} || [] };
            $stream->write("Loaded script plugin '$entry->{name}' ("
                . ($entry->{metadata}{script_path})
                . (@cmds ? ", commands: " . join(',', @cmds) : "")
                . ")\r\n");
            return;
        }

        if ($verb eq 'load') {
            my ($module, $custom) = @rest;
            unless (defined $module && length $module) {
                $stream->write("Usage: .plugins load <Perl::Module> [name]\r\n");
                return;
            }
            my $entry = eval {
                $pm->load_perl_module($module,
                    (defined $custom && length $custom) ? (name => $custom) : ());
            };
            if (!$entry) {
                (my $err = $@ || 'unknown error') =~ s/\s+\z//;
                $stream->write("Load failed: $err\r\n");
                return;
            }
            my @cmds = @{ $entry->{mounted_commands} || [] };
            $stream->write("Loaded plugin '$entry->{name}' (api="
                . ($entry->{metadata}{api} // 1)
                . (@cmds ? ", commands: " . join(',', @cmds) : "")
                . ")\r\n");
            return;
        }

        my ($target) = @rest;
        unless (defined $target && length $target) {
            $stream->write("Usage: .plugins $verb <name>\r\n");
            return;
        }
        unless ($pm->is_registered($target)) {
            $stream->write("Unknown plugin '$target' — see .plugins loaded\r\n");
            return;
        }

        if ($verb eq 'unload') {
            my $plug = $pm->plugin($target);
            my $api = ref($plug->{metadata}) eq 'HASH'
                ? ($plug->{metadata}{api} // 1) : 1;
            my $ok = eval {
                $api == 3
                    ? $pm->unregister_plugin_persistent($target)
                    : $pm->unregister_plugin($target);
                1;
            };
            unless ($ok) {
                my $err = $@ || 'unknown error';
                $stream->write("Unload failed: "
                    . _plugin_info_text($err, 180) . "\r\n");
                return;
            }
            $stream->write("Unloaded plugin '$target' (commands unmounted).\r\n");
            return;
        }
        if ($verb eq 'enable' || $verb eq 'disable') {
            my $plug = $pm->plugin($target);
            my $api = ref($plug->{metadata}) eq 'HASH'
                ? ($plug->{metadata}{api} // 1) : 1;
            my $ok = eval {
                if ($api == 3) {
                    $pm->set_v3_enabled_persistent(
                        $target, $verb eq 'enable' ? 1 : 0);
                }
                else {
                    $verb eq 'enable'
                        ? $pm->enable($target) : $pm->disable($target);
                }
                1;
            };
            unless ($ok) {
                my $err = $@ || 'unknown error';
                $stream->write("Lifecycle change failed: "
                    . _plugin_info_text($err, 180) . "\r\n");
                return;
            }
            $stream->write("Plugin '$target' is now ${verb}d"
                . ($verb eq 'disable' ? " (mounted commands stay silent)" : "")
                . ".\r\n");
            return;
        }
        # reload : le VRAI rechargement — delete %INC puis load replace. Si le
        # nouveau code echoue (require/manifest/register), le die tombe AVANT
        # register_plugin : l'instance precedente reste enregistree et active.
        my $plug = $pm->plugin($target);
        if ($plug && ($plug->{metadata}{api} // 0) == 3) {
            my @grants = @{ $plug->{metadata}{granted_capabilities} || [] };
            my @policies = $pm->v3_channel_policies($target);
            my %policy_map = map {
                $_->{channel} => {
                    mode => $_->{mode}, config => { %{ $_->{config} || {} } },
                }
            } @policies;
            my $was_enabled = $plug->{enabled} ? 1 : 0;
            my $unloaded = eval {
                $pm->unregister_plugin_persistent($target); 1;
            };
            unless ($unloaded) {
                my $err = $@ || 'unload failed';
                $stream->write("API v3 reload failed before replacement: "
                    . _plugin_info_text($err, 160) . "\r\n");
                return;
            }
            my $entry = eval {
                $pm->load_package_v3_persistent($target,
                    grants => \@grants,
                    channel_policies => \%policy_map);
            };
            if (!$entry) {
                (my $err = $@ || 'unknown error') =~ s/\s+\z//;
                $stream->write("API v3 reload failed; saved built-in handlers are active: "
                    . _plugin_info_text($err, 160) . "\r\n");
                return;
            }
            if ($was_enabled) {
                my $enabled = eval {
                    $pm->set_v3_enabled_persistent($target, 1); 1;
                };
                unless ($enabled) {
                    my $err = $@ || 'activation failed';
                    eval { $pm->unregister_plugin_persistent($target) };
                    $err =~ s/\s+\z//;
                    $stream->write("API v3 reload activation failed; saved built-in handlers are active: "
                        . _plugin_info_text($err, 150) . "\r\n");
                    return;
                }
            }
            $stream->write("Reloaded API v3 package '$target' (version "
                . ($entry->{version} // '-') . ").\r\n");
            return;
        }
        # mb590-B1: le reload d'un plugin SCRIPT relit le sidecar JSON et
        # remonte ses commandes (pas de %INC en jeu) — meme rollback : un
        # sidecar devenu invalide laisse l'instance precedente active.
        if ($plug && ($plug->{metadata}{kind} // '') eq 'script') {
            my $spath = $plug->{metadata}{script_path};
            my $sentry = eval { $pm->load_script_v2($spath, name => $target, replace => 1) };
            if (!$sentry) {
                (my $err = $@ || 'unknown error') =~ s/\s+\z//;
                $stream->write("Reload failed (previous instance still active): $err\r\n");
                return;
            }
            $stream->write("Reloaded script plugin '$target' (version "
                . ($sentry->{version} // '-') . ").\r\n");
            return;
        }
        my $module = $plug ? $plug->{module} : undef;
        unless (defined $module && length $module) {
            $stream->write("Reload failed: plugin '$target' has no module recorded.\r\n");
            return;
        }
        my $file = $module; $file =~ s{::}{/}g; $file .= '.pm';
        delete $INC{$file};
        my $entry = eval { $pm->load_perl_module($module, name => $target, replace => 1) };
        if (!$entry) {
            (my $err = $@ || 'unknown error') =~ s/\s+\z//;
            $stream->write("Reload failed (previous instance still active): $err\r\n");
            return;
        }
        $stream->write("Reloaded plugin '$target' (version "
            . ($entry->{version} // '-') . ").\r\n");
        return;
    }

    # Read-only Partyline visibility for the active PluginManager state. This
    # command does not load, unload, enable, or disable anything.
    my $autoload = eval { $services{autoload} ? $services{autoload}->() : 0 } ? 'enabled' : 'disabled';
    my @all      = eval { $pm->list } ? $pm->list : ();
    my @enabled  = eval { $pm->list(enabled => 1) } ? $pm->list(enabled => 1) : ();
    my @disabled = eval { $pm->list(enabled => 0) } ? $pm->list(enabled => 0) : ();

    # MB750-MB752/MB764: these views are deliberately read-only. They expose the
    # core's decision, capability intersection, bounded failure history and
    # manual quarantine state, plus one bounded installed/loaded portfolio;
    # never configuration values or service objects.
    if ($mode eq 'overviewv3') {
        my $report = eval { $pm->v3_portfolio_report };
        unless ($report) {
            my $error = $@ || 'portfolio unavailable';
            $stream->write("API v3 overview failed: "
                . _plugin_info_text($error, 180) . "\r\n");
            return;
        }
        my $summary = $report->{summary};
        $stream->write("API v3 overview: discovered=$summary->{discovered}"
            . " loaded=$summary->{loaded} enabled=$summary->{enabled}"
            . " active=$summary->{active} ready=$summary->{ready}"
            . " limited=$summary->{limited}"
            . " active_channels=$summary->{active_channels}.\r\n");
        for my $package (@{ $report->{packages} || [] }) {
            my $policies = $package->{policies};
            my $source = $package->{installed} ? 'installed' : 'missing';
            $stream->write("  $package->{name} version=$package->{version}"
                . " source=$source lifecycle=$package->{lifecycle}"
                . " status=$package->{status} reason=$package->{reason}"
                . " policies=on:$policies->{on},observe:$policies->{observe},off:$policies->{off}\r\n");
        }
        if (($summary->{truncated} // 0) > 0) {
            $stream->write("  ... $summary->{truncated} additional package(s) omitted.\r\n");
        }
        return;
    }

    if ($mode =~ /\Adoctor\s+(\S+)\z/) {
        my $target = $1;
        my $report = eval { $pm->v3_diagnostic_report($target) };
        unless ($report) {
            my $error = $@ || 'diagnostic unavailable';
            $stream->write("API v3 doctor failed: "
                . _plugin_info_text($error, 180) . "\r\n");
            return;
        }
        my $permissions = $report->{permissions};
        my $policies = $report->{policies};
        my $runtime = $report->{runtime};
        my $failures = $report->{failures};
        my $quarantine = $report->{quarantine};
        my $missing = @{ $permissions->{missing} || [] }
            ? join(',', @{ $permissions->{missing} }) : 'none';
        $stream->write("Plugin doctor '$report->{plugin}': "
            . "$report->{status} ($report->{reason}).\r\n");
        $stream->write("  lifecycle: $report->{lifecycle}\r\n");
        $stream->write("  permissions: $permissions->{status} missing=$missing\r\n");
        $stream->write("  policies: total=$policies->{total} active=$policies->{active}"
            . " on=$policies->{on} observe=$policies->{observe} off=$policies->{off}\r\n");
        $stream->write("  runtime: commands=$runtime->{mounted}{commands}/$runtime->{declared}{commands}"
            . " events=$runtime->{mounted}{events}/$runtime->{declared}{events}"
            . " jobs=$runtime->{mounted}{jobs}/$runtime->{declared}{jobs}"
            . " saved_handlers=$runtime->{saved_handlers}\r\n");
        $stream->write("  failures: total=$failures->{total} recent=$failures->{recent}"
            . " resources=$failures->{affected_resources}"
            . " active_streaks=$failures->{active_streaks}"
            . " last=$failures->{last_failure_at}\r\n");
        $stream->write("  quarantine: total=$quarantine->{total}/$quarantine->{max_entries}\r\n");
        return;
    }

    if ($mode =~ /\Afailures\s+(\S+)\z/) {
        my $target = $1;
        my $report = eval { $pm->v3_failure_report($target) };
        unless ($report) {
            my $error = $@ || 'failure history unavailable';
            $stream->write("API v3 failure history failed: "
                . _plugin_info_text($error, 180) . "\r\n");
            return;
        }
        my $active = ref($report->{active_streaks}) eq 'ARRAY'
            ? scalar(@{ $report->{active_streaks} }) : 0;
        $stream->write("Plugin failures '$report->{plugin}':"
            . " total=$report->{total_failures}"
            . " recent=$report->{recent_count}/$report->{max_recent}"
            . " resources=$report->{affected_resources}/$report->{max_resources}"
            . " active_streaks=$active.\r\n");
        my @recent = ref($report->{recent}) eq 'ARRAY'
            ? reverse @{ $report->{recent} } : ();
        splice(@recent, 5) if @recent > 5;
        unless (@recent) {
            $stream->write("  latest: none\r\n");
            return;
        }
        for my $failure (@recent) {
            my $channel = length($failure->{channel} // '')
                ? $failure->{channel} : '-';
            $stream->write("  $failure->{kind} $failure->{resource}"
                . " channel=$channel at=$failure->{occurred_at}"
                . " fingerprint=$failure->{fingerprint}"
                . " streak=$failure->{streak}\r\n");
        }
        return;
    }

    if ($mode =~ /\Aquarantines\s+(\S+)\z/) {
        my $target = $1;
        my $report = eval { $pm->v3_quarantine_report($target) };
        unless ($report) {
            my $error = $@ || 'quarantine report unavailable';
            $stream->write("API v3 quarantine report failed: "
                . _plugin_info_text($error, 180) . "\r\n");
            return;
        }
        $stream->write("Plugin quarantines '$report->{plugin}':"
            . " total=$report->{total}/$report->{max_entries}.\r\n");
        my @entries = ref($report->{entries}) eq 'ARRAY'
            ? reverse @{ $report->{entries} } : ();
        splice(@entries, 10) if @entries > 10;
        unless (@entries) {
            $stream->write("  active: none\r\n");
            return;
        }
        for my $entry (@entries) {
            $stream->write("  $entry->{kind} $entry->{resource}"
                . " channel=$entry->{channel}"
                . " since=$entry->{quarantined_at}\r\n");
        }
        return;
    }

    if ($mode =~ /\Apermissions\s+(\S+)\z/) {
        my $target = $1;
        my $report = eval { $pm->v3_permissions_report($target) };
        unless ($report) {
            my $error = $@ || 'permissions unavailable';
            $stream->write("API v3 permissions failed: "
                . _plugin_info_text($error, 180) . "\r\n");
            return;
        }
        for my $field (qw(requested granted effective missing)) {
            my $value = @{ $report->{$field} || [] }
                ? join(',', @{ $report->{$field} }) : 'none';
            $report->{$field} = $value;
        }
        $stream->write("Plugin permissions '$report->{plugin}': $report->{status}.\r\n");
        $stream->write("  requested: $report->{requested}\r\n");
        $stream->write("  granted: $report->{granted}\r\n");
        $stream->write("  effective: $report->{effective}\r\n");
        $stream->write("  missing: $report->{missing}\r\n");
        return;
    }

    if ($mode =~ /\Awhy\s+(\S+)\s+(\S+)\z/) {
        my ($target, $channel) = ($1, $2);
        my $report = eval { $pm->v3_channel_explanation($target, $channel) };
        unless ($report) {
            my $error = $@ || 'decision unavailable';
            $stream->write("API v3 decision failed: "
                . _plugin_info_text($error, 180) . "\r\n");
            return;
        }
        my $configured = $report->{configured} ? 'yes' : 'no';
        my $runs = $report->{plugin_runs} ? 'yes' : 'no';
        my $output = $report->{output_allowed} ? 'yes' : 'no';
        my $fallback = !$report->{saved_handlers} ? 'none'
            : $report->{fallback_visible} ? 'visible' : 'suppressed';
        $stream->write("Plugin decision '$report->{plugin}' $report->{channel}: "
            . "$report->{decision} ($report->{reason}).\r\n");
        $stream->write("  lifecycle: $report->{lifecycle}\r\n");
        $stream->write("  policy: $report->{policy_mode} configured=$configured\r\n");
        $stream->write("  plugin: runs=$runs output=$output\r\n");
        $stream->write("  migration fallback: $fallback\r\n");
        return;
    }

    if ($mode eq 'config') {
        $stream->write("Plugin config:\r\n");
        $stream->write("  autoload: $autoload\r\n");

        if ($services{autoload} && !$services{autoload}->()) {
            $stream->write("  boot loading: skipped unless plugins.AUTOLOAD=1 (or compatible key)\r\n");
        }
        else {
            $stream->write("  boot loading: enabled by configuration gate\r\n");
        }

        $stream->write("  autoload keys: plugins.AUTOLOAD, plugins.autoload, plugins.ENABLED_AUTOLOAD, PLUGIN_AUTOLOAD, PLUGINS_AUTOLOAD\r\n");
        $stream->write("  plugin list keys: plugins.ENABLED, plugins.enabled, plugins.PLUGINS, plugins.plugins, PLUGINS_ENABLED, PLUGIN_ENABLED, PLUGINS\r\n");
        $stream->write("  sidecar list keys: plugins.SCRIPTS, plugins.scripts, PLUGINS_SCRIPTS, PLUGIN_SCRIPTS\r\n");
        $stream->write("  module safety: Perl module names only, no paths\r\n");
        $stream->write("  sidecar safety: relative paths below plugins/scripts; .pl/.py/.tcl + manifest JSON\r\n");
        return;
    }

    # mb598-B1: .plugins info <name> — la fiche complete d'un plugin, mode
    # LECTURE (aucune gate au-dela de la session authentifiee, comme
    # loaded/config) : identite, manifest detaille (commandes avec niveau et
    # help, events), etat, et les compteurs d'invocation Prometheus quand
    # l'exporteur est actif. Le parseur de verbes gated reste intact.
    if ($mode =~ /\Ainfo\s+(\S+)\z/) {
        my $target = $1;
        my $entry = $pm->plugin($target);
        unless ($entry) {
            $stream->write("Unknown plugin '$target' — see .plugins loaded\r\n");
            return;
        }
        my $state = $entry->{enabled} ? 'enabled' : 'disabled';
        my $kind  = $entry->{metadata}{kind} // 'module';
        my $api   = $entry->{metadata}{api}  // 1;
        $stream->write("Plugin '$entry->{name}' [$state] kind=$kind api=$api"
            . " version=" . ($entry->{version} // '-') . "\r\n");
        $stream->write("  source: " . ($kind eq 'script'
            ? ($entry->{metadata}{script_path} // '?')
            : ($entry->{module} // '?')) . "\r\n");
        if (defined $entry->{description} && length $entry->{description}) {
            $stream->write("  description: "
                . _plugin_info_text($entry->{description}, 200) . "\r\n");
        }
        my $manifest = $entry->{manifest};
        my $metrics  = eval { $services{metrics}->() };
        if ($manifest && ref($manifest->{commands}) eq 'HASH'
            && %{ $manifest->{commands} }) {
            $stream->write("  commands:\r\n");
            for my $cmd (sort keys %{ $manifest->{commands} }) {
                my $spec  = $manifest->{commands}{$cmd};
                my $level = defined $spec->{level} && $spec->{level} ne '0'
                    ? $spec->{level} : 'public';
                my $count = $metrics
                    ? eval { $metrics->get('mediabot_plugin_command_total',
                        { plugin => $entry->{name}, command => $cmd }) }
                    : undef;
                $stream->write(sprintf("    %-14s level=%-8s calls=%s  %s\r\n",
                    $cmd, $level, $count // 0,
                    _plugin_info_text($spec->{help}, 200)));
            }
        }
        else {
            $stream->write("  commands: none\r\n");
        }
        # mb601-B1: etat persistant sur disque, taille reelle du fichier.
        {
            my ($storage) = eval { $pm->plugin_data_info($entry->{name}) };
            if (ref($storage) eq 'HASH') {
                $stream->write("  storage: " . ($storage->{size} // 0)
                    . " bytes (" . _plugin_info_text($storage->{path}, 200) . ")\r\n");
            }
        }
        # mb600-B1: config effective (defaults sidecar + surcharges conf).
        if (ref($entry->{plugin_config}) eq 'HASH' && %{ $entry->{plugin_config} }) {
            for my $ckey (sort keys %{ $entry->{plugin_config} }) {
                my $cval = _plugin_config_display_value(
                    $ckey, $entry->{plugin_config}{$ckey});
                $stream->write("  config: $ckey=$cval\r\n");
            }
        }
        if ($manifest && ref($manifest->{events}) eq 'ARRAY'
            && @{ $manifest->{events} }) {
            for my $ev (@{ $manifest->{events} }) {
                my $count = $metrics
                    ? eval { $metrics->get('mediabot_plugin_event_total',
                        { plugin => $entry->{name}, event => $ev }) }
                    : undef;
                $stream->write("  event: $ev routed=" . ($count // 0) . "\r\n");
            }
        }
        else {
            $stream->write("  events: none\r\n");
        }
        if ($api == 3) {
            my @caps = @{ $entry->{metadata}{effective_capabilities} || [] };
            $stream->write("  capabilities: "
                . (@caps ? join(',', @caps) : 'none') . "\r\n");
            my @policies = $pm->v3_channel_policies($entry->{name});
            if (@policies) {
                for my $policy (@policies) {
                    $stream->write("  policy: $policy->{channel} mode=$policy->{mode}\r\n");
                }
            }
            else {
                $stream->write("  policies: none\r\n");
            }
        }
        return;
    }

    if ($mode ne 'summary' && $mode ne 'loaded') {
        $stream->write("Usage: .plugins [loaded|config|info <name>"
            . "|load <Module> [name]|loadscript <path> [name]|unload <name>|reload <name>"
            . "|enable <name>|disable <name>|cleardata <name>|discoverv3"
            . "|loadv3 <package> [caps]|policy <name> <channel> <mode> [key=value ...]"
            . "|resetpolicy <name> <channel>"
            . "|clearv3data <package>"
            . "|quarantine <name> <kind> <resource> <channel>"
            . "|unquarantine <name> <kind> <resource> <channel>|doctor <name>"
            . "|failures <name>|quarantines <name>"
            . "|permissions <name>|why <name> <channel>|overviewv3]\r\n");
        return;
    }

    $stream->write("PluginManager:\r\n");
    $stream->write("  autoload: $autoload\r\n");
    $stream->write("  registered: " . scalar(@all) . "\r\n");
    $stream->write("  enabled: " . scalar(@enabled) . "\r\n");
    $stream->write("  disabled: " . scalar(@disabled) . "\r\n");

    if (!@all) {
        $stream->write("  plugins: none loaded\r\n");
        return;
    }

    $stream->write("Loaded plugins:\r\n");
    for my $entry (@all) {
        next unless ref($entry) eq 'HASH';

        my $name    = $entry->{name}    // '(unknown)';
        my $module  = $entry->{module}  // '-';
        my $version = defined $entry->{version} ? $entry->{version} : '-';
        my $state   = $entry->{enabled} ? 'enabled' : 'disabled';
        my $desc    = $entry->{description} // '';

        my $api  = $entry->{metadata}{api} // 1;
        my @cmds = @{ $entry->{mounted_commands} || [] };
        $stream->write("  - $name [$state] api=$api module=$module version=$version");
        $stream->write(" commands=" . join(',', @cmds)) if @cmds;
        $stream->write(" - $desc") if length $desc;
        $stream->write("\r\n");
    }

    return;
}


1;

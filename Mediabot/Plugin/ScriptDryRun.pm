package Mediabot::Plugin::ScriptDryRun;

use strict;
use warnings;
use utf8;
use Time::HiRes qw(time);

our $VERSION = '0.001';

# ---------------------------------------------------------------------------
# Mediabot::Plugin::ScriptDryRun
# ---------------------------------------------------------------------------
# Trusted in-process bridge from EventBus to external Perl/Python/Tcl scripts.
#
# The historical ScriptDryRun name is retained for configuration and partyline
# compatibility, but the plugin now supports two explicit modes:
#   - dry-run: execute the script and validate/plan its returned actions only;
#   - apply: execute the script and pass validated actions to ScriptActionRunner.
# IRC reply/notice output additionally requires ALLOW_IRC=yes, and apply mode is
# scoped by COMMANDS/ROUTES when APPLY_REQUIRE_SCOPE is enabled (the default).
# ---------------------------------------------------------------------------

# mb537-B1: lecture des clés de conf du plugin, partagée entre register() et
# refresh_from_conf(). Une seule source de vérité pour les noms/alias — toute
# nouvelle clé ajoutée ici est relue au rechargement à chaud sans code
# supplémentaire (et le contrat mb532 la forcera dans la référence partyline).
sub _collect_conf_raw {
    my ($bot) = @_;
    my $conf = $bot ? $bot->{conf} : undef;

    return (
        script_path => _conf_get_first(
            $conf,
            'plugins.ScriptDryRun.SCRIPT',
            'plugins.ScriptDryRun.script',
            'plugins.script_dryrun.SCRIPT',
            'plugins.script_dryrun.script',
            'SCRIPT_DRYRUN_SCRIPT',
            'SCRIPT_DRYRUN_PATH',
        ),
        command_filter_raw => _conf_get_first(
            $conf,
            'plugins.ScriptDryRun.COMMANDS',
            'plugins.ScriptDryRun.commands',
            'plugins.script_dryrun.COMMANDS',
            'plugins.script_dryrun.commands',
            'SCRIPT_DRYRUN_COMMANDS',
        ),
        command_routes_raw => _conf_get_first(
            $conf,
            'plugins.ScriptDryRun.ROUTES',
            'plugins.ScriptDryRun.routes',
            'plugins.script_dryrun.ROUTES',
            'plugins.script_dryrun.routes',
            'SCRIPT_DRYRUN_ROUTES',
        ),
        action_mode_raw => _conf_get_first(
            $conf,
            'plugins.ScriptDryRun.ACTION_MODE',
            'plugins.ScriptDryRun.action_mode',
            'plugins.script_dryrun.ACTION_MODE',
            'plugins.script_dryrun.action_mode',
            'SCRIPT_DRYRUN_ACTION_MODE',
        ),
        allow_irc_raw => _conf_get_first(
            $conf,
            'plugins.ScriptDryRun.ALLOW_IRC',
            'plugins.ScriptDryRun.allow_irc',
            'plugins.script_dryrun.ALLOW_IRC',
            'plugins.script_dryrun.allow_irc',
            'SCRIPT_DRYRUN_ALLOW_IRC',
        ),
        apply_require_scope_raw => _conf_get_first(
            $conf,
            'plugins.ScriptDryRun.APPLY_REQUIRE_SCOPE',
            'plugins.ScriptDryRun.apply_require_scope',
            'plugins.script_dryrun.APPLY_REQUIRE_SCOPE',
            'plugins.script_dryrun.apply_require_scope',
            'SCRIPT_DRYRUN_APPLY_REQUIRE_SCOPE',
        ),
        # mb529-B1: routage opt-in des evenements de canal vers des scripts.
        # Format identique a ROUTES (event=script), whitelist stricte,
        # PAS de fallback SCRIPT pour les evenements.
        event_routes_raw => _conf_get_first(
            $conf,
            'plugins.ScriptDryRun.EVENTS',
            'plugins.ScriptDryRun.events',
            'plugins.script_dryrun.EVENTS',
            'plugins.script_dryrun.events',
            'SCRIPT_DRYRUN_EVENTS',
        ),
        event_cooldown_raw => _conf_get_first(
            $conf,
            'plugins.ScriptDryRun.EVENT_COOLDOWN',
            'plugins.ScriptDryRun.event_cooldown',
            'plugins.script_dryrun.EVENT_COOLDOWN',
            'plugins.script_dryrun.event_cooldown',
            'SCRIPT_DRYRUN_EVENT_COOLDOWN',
        ),
    );
}

sub register {
    my ($class, $bot, %opts) = @_;

    my $self = bless {
        bot             => $bot,
        manager         => $opts{manager},
        plugin_name     => $opts{name} || __PACKAGE__,
        _collect_conf_raw($bot),
        action_mode => 'dry-run',
        allow_irc   => 0,
        apply_require_scope => 0,
        command_filter => undef,
        command_routes => undef,
        observed_public => 0,
        skipped_public  => 0,
        filtered_public => 0,
        # mb529-B1: compteurs et etat du chemin evenements de canal.
        observed_events      => 0,
        skipped_events       => 0,
        event_cooldown_skips => 0,
        event_routes    => undef,
        event_cooldown  => 10,
        event_last_run  => {},
        event_listener_entries => [],
        route_configs   => {},
        last_result     => undef,
        last_error      => undef,
        # mb525-B1: timers IO::Async actifs, indexes par nom de timer. Permet
        # l'annulation propre au dechargement/remplacement du plugin.
        active_timers   => {},
    }, $class;

    # mb261-B1: SCRIPT is a single script path, not a list-like option.
    # Config loaders can still hand us ARRAY refs; normalize to the first
    # meaningful scalar value here so we never pass ARRAY(...)/HASH(...) to
    # ScriptRunner path validation or route fallback.
    $self->{script_path} = _first_config_scalar($self->{script_path});

    # mb182-B1: optional command allow-list for the ScriptDryRun bridge.
    # Empty or missing filter keeps the previous behavior: observe all commands.
    $self->_derive_conf_state;

    # mb540-B1: declarer les series du bridge (idempotent, no-op sans Metrics).
    $self->_declare_bridge_metrics;
    # mb543-B1: publier immediatement le zero initial du gauge. Une metrique
    # declaree sans echantillon reste invisible a Prometheus jusqu'au premier
    # run, ce qui rendrait le panneau Grafana ambigu apres un demarrage calme.
    $self->_note_pending_timers_metric;

    if ($bot && $bot->can('events') && $bot->events) {
        # mb242-B2: keep the EventBus listener entry so a replaced plugin
        # instance can unregister its own observer without removing the new
        # replacement listener. This keeps PluginManager replace reloads from
        # accumulating duplicate ScriptDryRun observers.
        $self->{listener_entry} = $bot->events->on(
            public_command_observed => sub {
                my ($ctx) = @_;
                return $self->observe_public_command($ctx);
            },
            name   => 'script-dryrun-public-command-observer',
            plugin => __PACKAGE__,
        );

        $self->_subscribe_event_listeners;
    }

    return $self;
}

sub unregister {
    my ($self, %opts) = @_;

    # mb525-B1: un plugin decharge ou remplace ne doit laisser derriere lui
    # aucun timer arme; sinon un rappel differe executerait un script au nom
    # d'une instance morte (et le slot pending resterait occupe a jamais).
    $self->cancel_script_timers;

    # mb529-B1: retirer aussi les observateurs d'evenements de canal, sinon un
    # remplacement de plugin accumulerait des listeners morts (mb537: factorise
    # avec la resouscription du refresh a chaud).
    my $bot = $self->{bot};
    $self->_unsubscribe_event_listeners;

    my $entry = $self->{listener_entry};
    return 0 unless ref($entry) eq 'HASH';

    return 0 unless $bot && $bot->can('events') && $bot->events && $bot->events->can('off');

    my $removed = eval { $bot->events->off(public_command_observed => $entry) } || 0;
    delete $self->{listener_entry} if $removed;

    return $removed;
}

sub plugin_enabled {
    my ($self) = @_;

    # mb245-B1: a loaded EventBus listener must still honour PluginManager's
    # enabled flag.  PluginManager::disable() only flips manager metadata; it
    # does not rebuild EventBus subscriptions.  Without this guard, a disabled
    # ScriptDryRun plugin could keep intercepting public commands through its
    # existing listener.  If the plugin is not manager-registered (direct unit
    # construction), keep the historical fail-open behaviour.
    my $manager = $self->{manager};
    return 1 unless $manager && eval { $manager->can('is_enabled') };

    my $name = $self->{plugin_name} || __PACKAGE__;
    my $registered = eval { $manager->can('plugin') ? $manager->plugin($name) : undef };
    return 1 unless $registered;

    my $enabled = eval { $manager->is_enabled($name) };
    return 1 if $@;

    return $enabled ? 1 : 0;
}

sub _conf_get_first {
    my ($conf, @keys) = @_;

    return undef unless $conf;

    for my $key (@keys) {
        next unless defined $key && length $key;

        my $value;
        my $ok = eval {
            if (ref($conf) eq 'HASH') {
                $value = $conf->{$key};
            }
            elsif ($conf->can('get')) {
                $value = $conf->get($key);
            }
            1;
        };

        next unless $ok;
        return $value if _conf_value_has_meaningful_scalar($value);
    }

    return undef;
}

sub _conf_value_has_meaningful_scalar {
    my ($value) = @_;

    # mb264-B1: config fallback selection must not rely on Perl ref
    # stringification. An empty ARRAY ref or a HASH ref in the first key must
    # not mask a later legacy/alias key that contains the real value. Keep
    # ARRAY support for Config::Simple list-like values, but require at least
    # one meaningful flattened scalar before accepting the candidate key.
    for my $candidate (_flatten_config_values($value)) {
        next unless defined $candidate;
        next if ref($candidate);

        my $v = "$candidate";
        $v =~ s/^\s+|\s+$//g;
        return 1 if length $v;
    }

    return 0;
}

sub _truthy {
    my ($value) = @_;

    # mb195-B1: Config::Simple can return ARRAY refs for boolean plugin
    # settings too. Never stringify ARRAY refs into "ARRAY(0x...)" here.
    for my $candidate (_flatten_config_values($value)) {
        next unless defined $candidate;

        my $v = lc "$candidate";
        $v =~ s/^\s+|\s+$//g;
        next unless length $v;

        return 1 if $v =~ /\A(?:1|yes|true|on|enabled|enable)\z/;
        return 0 if $v =~ /\A(?:0|no|false|off|disabled|disable)\z/;
    }

    return 0;
}

# A3 (mb225): like _truthy, but distinguishes "not configured at all" (return
# the supplied default) from an explicit true/false. Used so a safety gate can
# default to enabled while still honoring an explicit opt-out.
sub _truthy_with_default {
    my ($value, $default) = @_;

    for my $candidate (_flatten_config_values($value)) {
        next unless defined $candidate;

        my $v = lc "$candidate";
        $v =~ s/^\s+|\s+$//g;
        next unless length $v;

        return 1 if $v =~ /\A(?:1|yes|true|on|enabled|enable)\z/;
        return 0 if $v =~ /\A(?:0|no|false|off|disabled|disable)\z/;
    }

    return $default ? 1 : 0;
}


sub _first_config_scalar {
    my ($value) = @_;

    # mb261-B2: only plain scalar config values can become SCRIPT paths.
    # COMMANDS/ROUTES are list-like and keep ARRAY support elsewhere, but SCRIPT
    # must never be left as an ARRAY/HASH ref that later stringifies into
    # ARRAY(0x...) or HASH(0x...) at the ScriptRunner boundary.
    for my $candidate (_flatten_config_values($value)) {
        next unless defined $candidate;
        next if ref($candidate);

        my $v = "$candidate";
        $v =~ s/^\s+|\s+$//g;
        next unless length $v;

        return $v;
    }

    return undef;
}

sub _normalize_action_mode {
    my ($value) = @_;

    # mb195-B2: ACTION_MODE can also be delivered as an ARRAY ref when coming
    # from sectioned Config::Simple data. Use the first meaningful flattened
    # value and keep the historical dry-run default on anything unknown.
    for my $candidate (_flatten_config_values($value)) {
        next unless defined $candidate;

        my $v = lc "$candidate";
        $v =~ s/^\s+|\s+$//g;
        $v =~ s/_/-/g;
        next unless length $v;

        return 'apply'   if $v eq 'apply';
        return 'dry-run' if $v eq 'dry-run' || $v eq 'dryrun' || $v eq 'dry';
    }

    return 'dry-run';
}


sub _flatten_config_values {
    my ($value) = @_;

    return () unless defined $value;

    # mb194-B1: Config::Simple can return ARRAY refs for comma-separated
    # values. ScriptDryRun uses COMMANDS and ROUTES heavily, so flatten arrays
    # before any split/parsing step.
    my @queue = ($value);
    my @out;

    while (@queue) {
        my $entry = shift @queue;
        next unless defined $entry;

        if (ref($entry) eq 'ARRAY') {
            unshift @queue, @$entry;
            next;
        }

        # mb261-B3: skip non-ARRAY refs instead of stringifying HASH(...) or
        # blessed config objects into COMMANDS/ROUTES/booleans/SCRIPT helpers.
        next if ref($entry);

        push @out, $entry;
    }

    return @out;
}

sub _split_list {
    my ($raw) = @_;

    my @items;
    for my $value (_flatten_config_values($raw)) {
        for my $part (split /[,\s]+/, "$value") {
            $part =~ s/^\s+|\s+$//g;
            next unless length $part;
            push @items, $part;
        }
    }

    return @items;
}


sub _normalize_command_name {
    my ($command) = @_;

    return '' unless defined $command;

    # mb268-B1: command names are protocol/control values, not arbitrary JSON or
    # Perl structures.  Do not stringify ARRAY/HASH/blessed refs into values such
    # as ARRAY(0x...) and then let a fallback SCRIPT observe/apply them as if they
    # were real IRC commands.
    # mb281-B1: keep the command token single-line and single-token before it can
    # drive ScriptDryRun routing, logging, ownership, or the JSON payload sent to
    # external Perl/Python/Tcl scripts. Real IRC commands are separated from args
    # before this point, so embedded whitespace/control bytes are malformed.
    return '' if ref($command);

    my $raw = "$command";
    return '' if $raw =~ /[\r\n\0]/;

    my $value = lc $raw;
    $value =~ s/^\s+|\s+$//g;
    $value =~ s/^[.!]+//;

    return '' unless length $value;
    return '' if $value =~ /\s/;

    return $value;
}

sub _make_command_filter {
    my ($raw) = @_;

    my %filter;
    for my $command (_split_list($raw)) {
        my $normalized = _normalize_command_name($command);
        next unless length $normalized;
        $filter{$normalized} = 1;
    }

    return \%filter;
}


sub _make_command_routes {
    my ($raw) = @_;

    my %routes;

    # mb195-B3: ROUTES may arrive as an ARRAY ref with Config::Simple when the
    # value contains commas. Parse each flattened value instead of stringifying
    # the ARRAY ref into "ARRAY(0x...)".
    for my $value (_flatten_config_values($raw)) {
        next unless defined $value;

        for my $entry (split /[,\n;]+/, "$value") {
            $entry =~ s/^\s+|\s+$//g;
            next unless length $entry;

            my ($command, $script) = split /\s*=\s*/, $entry, 2;
            next unless defined $command && defined $script;

            my $normalized = _normalize_command_name($command);
            $script =~ s/^\s+|\s+$//g;

            next unless length $normalized && length $script;
            $routes{$normalized} = $script;
        }
    }

    return \%routes;
}


sub _ctx_value {
    my ($ctx, @names) = @_;

    return undef unless $ctx;

    for my $name (@names) {
        next unless defined $name && length $name;

        my $value;

        if (ref($ctx) eq 'HASH') {
            $value = $ctx->{$name};
            return $value if defined $value;
        }

        my $hash_ok = eval {
            $value = $ctx->{$name};
            1;
        };
        return $value if $hash_ok && defined $value;

        my $method_ok = eval { $ctx->can($name) };
        if ($method_ok) {
            my $method_value = eval { $ctx->$name() };
            return $method_value if defined $method_value;
        }
    }

    return undef;
}

sub _ctx_mark_scriptdryrun_handled {
    my ($ctx, $result, $error) = @_;

    return unless $ctx;

    my $ok = eval {
        $ctx->{scriptdryrun_handled} = 1;
        $ctx->{scriptdryrun_result}  = $result if defined $result;
        $ctx->{scriptdryrun_error}   = $error  if defined $error && length "$error";
        1;
    };

    return $ok ? 1 : 0;
}

# mb196-B1: lightweight ScriptDryRun runtime logging.
# This is intentionally defensive: logging must never break command dispatch.
sub _log_bot {
    my ($self, $level, $message) = @_;

    return unless defined $message && length "$message";
    $level = 4 unless defined $level && $level =~ /\A\d+\z/;

    my $bot = $self->{bot};
    return unless $bot;

    my $logger = eval { $bot->{logger} };
    if ($logger && eval { $logger->can('log') }) {
        eval { $logger->log($level, $message); 1 };
        return;
    }
}

sub _count_arrayref {
    my ($value) = @_;
    return 0 unless ref($value) eq 'ARRAY';
    return scalar @$value;
}


sub _elapsed_ms {
    my ($started_at) = @_;

    return 0 unless defined $started_at;

    my $elapsed = int(((time() - $started_at) * 1000) + 0.5);
    return $elapsed < 0 ? 0 : $elapsed;
}

# mb202-B1: centralize runtime logging with elapsed_ms so live debugging can
# distinguish command routing delays, script runtime, and action application.
sub _log_script_result {
    my ($self, $command, $started_at, $script_result) = @_;

    my $elapsed = _elapsed_ms($started_at);
    $self->_log_bot(4, "PUBLIC(scriptdryrun): script_result command=$command elapsed_ms=$elapsed " . _script_result_summary($script_result));
}

sub _log_action_plan {
    my ($self, $command, $started_at, $action_plan) = @_;

    my $elapsed = _elapsed_ms($started_at);
    $self->_log_bot(4, "PUBLIC(scriptdryrun): action_plan command=$command elapsed_ms=$elapsed " . _action_plan_summary($action_plan));
}

sub _script_result_summary {
    my ($result) = @_;

    return 'result=<not-a-hash>' unless ref($result) eq 'HASH';

    my $ok      = $result->{ok}      ? 1 : 0;
    my $timeout = $result->{timeout} ? 1 : 0;
    my $exit    = defined $result->{exit_code} ? $result->{exit_code} : '-';
    my $stderr  = defined $result->{stderr} && length $result->{stderr} ? $result->{stderr} : '';
    $stderr =~ s/[\r\n]+/ /g;
    $stderr = substr($stderr, 0, 180) if length($stderr) > 180;

    my $response = ref($result->{response}) eq 'HASH' ? $result->{response} : {};
    my $actions  = _count_arrayref($response->{actions});
    my $errors   = _count_arrayref($response->{errors});

    return "ok=$ok timeout=$timeout exit=$exit actions=$actions errors=$errors stderr=$stderr";
}

sub _action_plan_summary {
    my ($plan) = @_;

    return 'plan=<not-a-hash>' unless ref($plan) eq 'HASH';

    my $ok           = $plan->{ok}         ? 1 : 0;
    my $applied_ok   = $plan->{applied_ok} ? 1 : 0;
    my $planned      = _count_arrayref($plan->{planned});
    my $applied      = _count_arrayref($plan->{applied});
    my $errors       = _count_arrayref($plan->{errors});
    my $apply_errors = _count_arrayref($plan->{apply_errors});

    return "ok=$ok applied_ok=$applied_ok planned=$planned applied=$applied errors=$errors apply_errors=$apply_errors";
}


sub _ctx_command {
    my ($ctx) = @_;

    # mb269-B1: command/cmd are scalar protocol fields.  A malformed ref in
    # the preferred key must not mask a scalar fallback key, and must never be
    # stringified into ARRAY(...)/HASH(...) before command filtering/routing.
    for my $name (qw(command cmd)) {
        my $value = _ctx_value($ctx, $name);
        return "$value" if defined $value && !ref($value) && length "$value";
    }

    my $cmd_obj = _ctx_value($ctx, 'command_obj');
    if ($cmd_obj) {
        for my $method (qw(name command cmd)) {
            next unless eval { $cmd_obj->can($method) };
            my $value = eval { $cmd_obj->$method() };
            return "$value" if defined $value && !ref($value) && length "$value";
        }

        my $hash_value = eval { $cmd_obj->{name} };
        return "$hash_value" if defined $hash_value && !ref($hash_value) && length "$hash_value";
    }

    return undef;
}

sub _ctx_scalar_value {
    my ($ctx, @names) = @_;

    # mb269-B2: public-command envelope fields sent to external scripts must be
    # scalar text values.  Ignore refs and continue to fallback aliases instead
    # of JSON-encoding nested Perl structures or dying on blessed objects.
    for my $name (@names) {
        my $value = _ctx_value($ctx, $name);
        return "$value" if defined $value && !ref($value) && length "$value";
    }

    return undef;
}

sub _sanitize_ctx_args {
    my ($args) = @_;

    return [] unless ref($args) eq 'ARRAY';

    my @clean;
    for my $arg (@$args) {
        next unless defined $arg;
        next if ref($arg);
        push @clean, "$arg";
    }

    return \@clean;
}

sub _ctx_args {
    my ($ctx) = @_;

    # mb269-B3: command arguments are an array of scalar strings in the external
    # script JSON envelope.  Keep valid scalars, drop ARRAY/HASH/blessed refs,
    # and let command_obj/hash fallbacks work when the first source is malformed.
    my $args = _ctx_value($ctx, 'args');
    return _sanitize_ctx_args($args) if ref($args) eq 'ARRAY';

    my $cmd_obj = _ctx_value($ctx, 'command_obj');
    if ($cmd_obj) {
        for my $method (qw(args argv)) {
            next unless eval { $cmd_obj->can($method) };
            my $value = eval { $cmd_obj->$method() };
            return _sanitize_ctx_args($value) if ref($value) eq 'ARRAY';
        }

        my $hash_value = eval { $cmd_obj->{args} };
        return _sanitize_ctx_args($hash_value) if ref($hash_value) eq 'ARRAY';
    }

    return [];
}

sub observe_public_command {
    my ($self, $ctx) = @_;

    $self->{observed_public}++;

    my $bot = $self->{bot};

    unless ($self->plugin_enabled) {
        $self->{skipped_public}++;
        $self->{last_error} = 'ScriptDryRun plugin is disabled';
        return undef;
    }

    unless ($bot && $bot->can('run_script_actions_dry')) {
        $self->{last_error} = 'bot cannot run script actions dry';
        return undef;
    }

    my $raw_command = _ctx_command($ctx);

    # mb284-B1: command_allowed(), script_for_command(), and _command_is_scoped()
    # already classify commands through _normalize_command_name().  Use that same
    # canonical token for the rest of the observer flow too, so external
    # Perl/Python/Tcl scripts receive the command that was actually authorized
    # instead of raw context text such as "  !PyHello  ".
    my $command = _normalize_command_name($raw_command);
    unless ($self->command_allowed($command)) {
        my $name = length($command) ? $command : '<empty>';
        $self->{filtered_public}++;
        $self->{skipped_public}++;
        $self->{last_error} = "command '$name' not allowed by ScriptDryRun filter";
        return undef;
    }

    # mb263-B1: observe_public_command must pass the current command to
    # apply_scope_warning().  MB262 correctly made the guard command-aware,
    # but the runtime call site still invoked it without arguments, causing
    # valid scoped apply commands to be rejected in the real observer path.
    if (my $scope_warning = $self->apply_scope_warning($command)) {
        $self->{skipped_public}++;
        $self->{last_error} = $scope_warning;
        return undef;
    }

    my $script_path = $self->script_for_command($command);
    unless ($script_path) {
        my $name = defined($command) && length("$command") ? "$command" : '<empty>';
        $self->{skipped_public}++;
        $self->{last_error} = "no script configured for command '$name'";
        return undef;
    }

    # mb238-B1: do not mark a public command as handled in apply mode until
    # the apply runtime is actually available.  Without this guard, a bad boot
    # order or a partially initialized bot could swallow a routed script command
    # before ScriptRunner/ScriptActionRunner were ready, preventing the legacy
    # dispatcher from seeing the command and leaving the user with silence.
    if ($self->action_mode eq 'apply') {
        unless ($bot->can('script_runner') && $bot->script_runner && $bot->script_runner->can('run_script')) {
            $self->{skipped_public}++;
            $self->{last_error} = 'script runner is not initialized';
            return undef;
        }

        unless ($bot->can('script_action_runner') && $bot->script_action_runner && $bot->script_action_runner->can('apply_actions')) {
            $self->{skipped_public}++;
            $self->{last_error} = 'script action runner cannot apply actions';
            return undef;
        }
    }

    # mb196-B1: log before running the external script. If the script blocks or
    # times out, this line appears immediately and gives us the accepted route.
    $self->_log_bot(4, "PUBLIC(scriptdryrun): accepted command=$command script=$script_path mode=" . $self->action_mode . " allow_irc=" . $self->allow_irc);

    # mb194-B1 + A2 (mb225) + mb226-B1: ScriptDryRun runs the resolved script,
    # but OWNERSHIP (suppressing the legacy dispatcher) must stay consistent
    # with whether the run has side effects:
    #   - dry-run mode: only OWN explicitly scoped commands (ROUTES/COMMANDS).
    #     An unscoped bare-SCRIPT command still runs for observation but does
    #     not suppress the legacy "command not found" path (R1 footgun fix).
    #   - apply mode: if we are about to APPLY a script's IRC/log actions, we
    #     MUST also own the command. Otherwise an unscoped command would have
    #     its fallback script applied AND be dispatched by the legacy handler —
    #     a double execution (duplicate IRC). mb226-B1 closes that: in apply
    #     mode, running implies owning.
    my $owns_command = $self->_command_is_scoped($command)
        || ($self->action_mode eq 'apply');
    _ctx_mark_scriptdryrun_handled($ctx, undef, undef) if $owns_command;

    my %data = (
        channel => _ctx_scalar_value($ctx, 'channel', 'target'),
        target  => _ctx_scalar_value($ctx, 'target', 'channel'),
        nick    => _ctx_scalar_value($ctx, 'nick', 'sender'),
        command => $command,
        args    => _ctx_args($ctx),
    );
    # mb531-B1: config par route (clé CONFIG_<route>), injectée uniquement si
    # configurée; les scripts lisent data.config.<clé> avec leur propre défaut.
    my $route_config = $self->route_config($command);
    $data{config} = $route_config if %$route_config;

    my $result;
    my $run_started_at;
    my $apply_started_at;

    if ($self->action_mode eq 'apply') {
        $run_started_at = time();
        my $script_result = $bot->script_runner->run_script(
            $script_path,
            'public_command',
            %data,
        );

        $self->_log_script_result($command, $run_started_at, $script_result);

        my $context = {
            event   => 'public_command',
            channel => $data{channel},
            target  => $data{target},
            nick    => $data{nick},
            command => $data{command},
            args    => $data{args},
        };

        $apply_started_at = time();
        my $action_plan = $bot->script_action_runner->apply_actions(
            $script_result,
            $context,
            apply       => 1,
            allow_irc   => $self->allow_irc,
            # mb525-B1: brancher l'ordonnanceur de timers. La politique
            # (plafond, doublon, profondeur) reste dans ScriptActionRunner;
            # ce plugin ne fait qu'armer le timer IO::Async et re-executer
            # le MEME script avec event "timer" a l'expiration.
            timer_depth    => 0,
            schedule_timer => sub {
                return $self->_schedule_script_timer($script_path, \%data, @_);
            },
        );

        $self->_log_action_plan($command, (defined $apply_started_at ? $apply_started_at : $run_started_at), $action_plan);

        $result = {
            ok            => ($script_result->{ok} && $action_plan->{applied_ok}) ? 1 : 0,
            dry_run       => 0,
            action_mode   => 'apply',
            allow_irc     => $self->allow_irc,
            script_result => $script_result,
            action_plan   => $action_plan,
        };
    }
    else {
        $run_started_at = time();
        $result = $bot->run_script_actions_dry(
            $script_path,
            'public_command',
            %data,
        );
        $result->{action_mode} = 'dry-run' if ref($result) eq 'HASH';
        $result->{allow_irc}   = $self->allow_irc if ref($result) eq 'HASH';

        my $script_result = ref($result) eq 'HASH' ? $result->{script_result} : undef;
        my $action_plan   = ref($result) eq 'HASH' ? $result->{action_plan}   : undef;
        $self->_log_script_result($command, $run_started_at, $script_result);
        $self->_log_action_plan($command, (defined $apply_started_at ? $apply_started_at : $run_started_at), $action_plan);
    }

    $self->{last_result} = $result;
    $self->{last_error}  = undef;
    $self->_note_run_metric('command', $result);
    $self->_note_pending_timers_metric;
    _ctx_mark_scriptdryrun_handled($ctx, $result, undef) if $owns_command;

    return $result;
}

# ---------------------------------------------------------------------------
# mb525-B1: application des actions timer.
#
# Semantique: quand un script (Perl/Python/Tcl) retourne une action
#   { type: "timer", name: "...", delay: N }
# en ACTION_MODE=apply, le bridge arme un IO::Async::Timer::Countdown de N
# secondes. A l'expiration, le MEME script est re-execute avec l'evenement
# "timer" (donnees d'origine + timer_name/timer_delay) et ses actions
# reply/notice/log repassent par les MEMES portes: apply, ALLOW_IRC, garde de
# scope canal mb524. Le rappel est execute avec timer_depth => 1, donc un
# script declenche par un timer ne peut jamais replanifier de timer.
# ---------------------------------------------------------------------------

sub _script_timer_loop {
    my ($self) = @_;

    my $bot = $self->{bot};
    return undef unless $bot;

    my $loop = eval { $bot->can('getLoop') ? $bot->getLoop : undef };
    return $loop if $loop;

    return eval { $bot->{loop} };
}

sub active_script_timer_count {
    my ($self) = @_;
    return scalar keys %{ $self->{active_timers} || {} };
}

sub _schedule_script_timer {
    my ($self, $script_path, $data, $planned, $context) = @_;

    return (0, 'planned timer is not a hash') unless ref($planned) eq 'HASH';

    my $name  = $planned->{name};
    my $delay = $planned->{delay};
    return (0, 'planned timer is missing name or delay')
        unless defined $name && length $name && defined $delay;

    my $loop = $self->_script_timer_loop;
    return (0, 'bot loop is unavailable') unless $loop;

    my $io_async_ok = eval { require IO::Async::Timer::Countdown; 1 };
    return (0, 'IO::Async timer support is unavailable') unless $io_async_ok;

    # Copie defensive des donnees d'origine: le contexte du rappel differe ne
    # doit pas pouvoir etre mute par la suite du traitement de la commande.
    my %snapshot = %{ ref($data) eq 'HASH' ? $data : {} };
    $snapshot{args} = [ @{ ref($snapshot{args}) eq 'ARRAY' ? $snapshot{args} : [] } ];

    my %planned_copy = ( name => "$name", delay => $delay );

    my $timer;
    my $armed = eval {
        $timer = IO::Async::Timer::Countdown->new(
            delay     => $delay,
            on_expire => sub {
                my ($expired) = @_;

                # Nettoyage AVANT le rappel: le slot doit etre libre pendant
                # l'execution differee (etat coherent, pas de fuite si le
                # rappel meurt).
                delete $self->{active_timers}{ $planned_copy{name} };
                eval { $loop->remove($expired); 1 };
                eval {
                    my $bot = $self->{bot};
                    my $runner = $bot && $bot->can('script_action_runner')
                        ? $bot->script_action_runner
                        : undef;
                    $runner->release_timer($planned_copy{name}) if $runner;
                    1;
                };
                # mb543-B1: le slot est deja libere ici. Mettre le gauge a jour
                # avant le rappel garantit sa justesse meme si le rappel est
                # saute (plugin desactive, mode dry-run, runner absent) ou meurt.
                $self->_note_pending_timers_metric;

                my $fired_ok = eval {
                    $self->_fire_script_timer($script_path, \%planned_copy, \%snapshot);
                    1;
                };
                unless ($fired_ok) {
                    my $err = $@ || 'unknown error';
                    $err =~ s/[\r\n]+/ /g;
                    $self->_log_bot(1, "PUBLIC(scriptdryrun): timer callback failed name=$planned_copy{name} error=$err");
                }

                return;
            },
        );

        $loop->add($timer);
        $timer->start;
        1;
    };

    unless ($armed) {
        my $err = $@ || 'failed to arm timer';
        $err =~ s/[\r\n]+/ /g;
        if ($timer) {
            eval { $timer->stop;         1 };
            eval { $loop->remove($timer); 1 };
        }
        return (0, $err);
    }

    $self->{active_timers}{"$name"} = {
        # mb527-B1: garder les metadonnees du timer avec l'objet IO::Async,
        # pour la visibilite partyline (.scriptdryrun timers) et l'annulation
        # ciblee. L'objet timer lui-meme n'est jamais expose hors du plugin.
        timer      => $timer,
        name       => "$name",
        delay      => $delay,
        armed_at   => time(),
        expires_at => time() + $delay,
        channel    => $snapshot{channel},
        nick       => $snapshot{nick},
        command    => $snapshot{command},
        script     => $script_path,
    };
    $self->_log_bot(4, "PUBLIC(scriptdryrun): timer armed name=$name delay=$delay script=$script_path");

    $self->_bridge_metric('inc', 'mediabot_scriptbridge_timers_total', { outcome => 'armed' });
    $self->_note_pending_timers_metric;

    return (1, undef);
}

sub _fire_script_timer {
    my ($self, $script_path, $planned, $data) = @_;

    my $bot   = $self->{bot};
    my $label = 'timer:' . $planned->{name};

    # Les portes du chemin apply s'appliquent aussi au rappel differe: un
    # plugin desactive, repasse en dry-run ou dont les runners ont disparu
    # entre l'armement et l'expiration ne doit rien executer.
    unless ($self->plugin_enabled) {
        $self->_log_bot(4, "PUBLIC(scriptdryrun): timer skipped ($label): plugin is disabled");
        return undef;
    }

    unless ($self->action_mode eq 'apply') {
        $self->_log_bot(4, "PUBLIC(scriptdryrun): timer skipped ($label): action mode is no longer apply");
        return undef;
    }

    unless ($bot && $bot->can('script_runner') && $bot->script_runner
        && $bot->script_runner->can('run_script')) {
        $self->_log_bot(1, "PUBLIC(scriptdryrun): timer skipped ($label): script runner is not initialized");
        return undef;
    }

    unless ($bot->can('script_action_runner') && $bot->script_action_runner
        && $bot->script_action_runner->can('apply_actions')) {
        $self->_log_bot(1, "PUBLIC(scriptdryrun): timer skipped ($label): script action runner cannot apply actions");
        return undef;
    }

    my $run_started_at = time();
    my $script_result  = $bot->script_runner->run_script(
        $script_path,
        'timer',
        %$data,
        timer_name  => $planned->{name},
        timer_delay => $planned->{delay},
    );

    $self->_log_script_result($label, $run_started_at, $script_result);

    my $context = {
        event      => 'timer',
        channel    => $data->{channel},
        target     => $data->{target},
        nick       => $data->{nick},
        command    => $data->{command},
        args       => $data->{args},
        timer_name => $planned->{name},
    };

    my $apply_started_at = time();
    my $action_plan = $bot->script_action_runner->apply_actions(
        $script_result,
        $context,
        apply       => 1,
        allow_irc   => $self->allow_irc,
        # Pas de schedule_timer ici ET timer_depth => 1: double verrou contre
        # les chaines de timers auto-entretenues.
        timer_depth => 1,
    );

    $self->_log_action_plan($label, $apply_started_at, $action_plan);

    my $result = {
        ok            => ($script_result->{ok} && $action_plan->{applied_ok}) ? 1 : 0,
        dry_run       => 0,
        action_mode   => 'apply',
        allow_irc     => $self->allow_irc,
        event         => 'timer',
        timer_name    => $planned->{name},
        script_result => $script_result,
        action_plan   => $action_plan,
    };

    $self->{last_result} = $result;
    $self->_note_run_metric('timer', $result);
    $self->_bridge_metric('inc', 'mediabot_scriptbridge_timers_total', { outcome => 'delivered' });
    $self->_note_pending_timers_metric;

    return $result;
}

# mb527-B1: instantane en LECTURE SEULE des timers en attente, pour la
# partyline. Retourne des copies triees par nom; ni l'objet timer IO::Async ni
# le hash interne ne sont exposes. Le champ remaining est recalcule a chaque
# appel.
sub script_timer_list {
    my ($self) = @_;

    my $timers = $self->{active_timers};
    return () unless ref($timers) eq 'HASH' && %$timers;

    my $now = time();
    my @list;

    for my $name (sort keys %$timers) {
        my $rec = $timers->{$name};
        next unless ref($rec) eq 'HASH';

        my $remaining = (defined $rec->{expires_at} ? $rec->{expires_at} : $now) - $now;
        $remaining = 0 if $remaining < 0;

        push @list, {
            name      => $rec->{name},
            delay     => $rec->{delay},
            remaining => int($remaining + 0.5),
            channel   => $rec->{channel},
            nick      => $rec->{nick},
            command   => $rec->{command},
            script    => $rec->{script},
        };
    }

    return @list;
}

# mb527-B1: annulation ciblee d'un timer arme. N'execute jamais rien: stoppe
# le timer, le retire de la boucle et libere le slot pending du runner.
sub cancel_script_timer {
    my ($self, $name) = @_;

    return 0 unless defined $name && !ref($name) && length $name;

    my $timers = $self->{active_timers};
    return 0 unless ref($timers) eq 'HASH' && exists $timers->{$name};

    my $rec = delete $timers->{$name};
    # Tolerance: un record mb527 est un HASH { timer => ... }; un eventuel
    # ancien format (objet timer nu) reste annulable.
    my $timer = ref($rec) eq 'HASH' ? $rec->{timer} : $rec;

    my $loop = $self->_script_timer_loop;
    my $bot  = $self->{bot};
    my $runner = eval {
        $bot && $bot->can('script_action_runner') ? $bot->script_action_runner : undef;
    };

    eval { $timer->stop; 1 } if $timer;
    eval { $loop->remove($timer); 1 } if $timer && $loop;
    eval { $runner->release_timer($name); 1 } if $runner;

    $self->_log_bot(4, "PUBLIC(scriptdryrun): timer cancelled name=$name");
    $self->_bridge_metric('inc', 'mediabot_scriptbridge_timers_total', { outcome => 'cancelled' });
    $self->_note_pending_timers_metric;

    return 1;
}

sub cancel_script_timers {
    my ($self) = @_;

    my $timers = $self->{active_timers};
    return 0 unless ref($timers) eq 'HASH' && %$timers;

    my $cancelled = 0;
    for my $name (sort keys %$timers) {
        $cancelled += $self->cancel_script_timer($name);
    }

    return $cancelled;
}

# ---------------------------------------------------------------------------
# mb529-B1: evenements de canal (join/part/topic) routes vers des scripts.
#
# Opt-in strict: un evenement ne tourne QUE s'il a une route EVENTS dediee
# (pas de fallback SCRIPT). Le pipeline reutilise les portes existantes:
# ACTION_MODE (dry-run/apply), ALLOW_IRC, garde de scope canal mb524 (le
# contexte porte le canal de l'evenement), timers mb525 disponibles en apply.
# Une route d'evenement est un scope explicite par definition, donc
# APPLY_REQUIRE_SCOPE n'ajoute pas de porte supplementaire ici.
#
# Garde-fous specifiques aux evenements:
#   - is_self: le bot n'execute jamais de script pour ses propres
#     join/part/topic;
#   - cooldown par (evenement, canal): au plus une execution par fenetre
#     (EVENT_COOLDOWN, defaut 10s, borne 1..3600) — les rafales de
#     join/part (netsplits) ne peuvent pas transformer le bridge en
#     fork-bomb. Les evenements en exces sont comptes puis ignores.
# ---------------------------------------------------------------------------

sub _is_supported_channel_event {
    my ($event) = @_;
    return 0 unless defined $event && !ref($event);
    return ($event eq 'join' || $event eq 'part' || $event eq 'topic' || $event eq 'kick') ? 1 : 0;
}

sub _bounded_positive_int {
    my ($value, $default, $min, $max) = @_;

    my $number = $default;
    if (defined $value && !ref($value)) {
        my $raw = "$value";
        $raw =~ s/^\s+|\s+$//g;
        $number = int($raw) if $raw =~ /\A[0-9]+\z/;
    }

    $number = $min if $number < $min;
    $number = $max if $number > $max;
    return $number;
}

sub event_routes {
    my ($self) = @_;
    return ref($self->{event_routes}) eq 'HASH' ? $self->{event_routes} : {};
}

sub event_routes_enabled {
    my ($self) = @_;
    return scalar(keys %{ $self->event_routes }) ? 1 : 0;
}

sub event_route_list {
    my ($self) = @_;
    return sort keys %{ $self->event_routes };
}

sub event_cooldown {
    my ($self) = @_;
    return $self->{event_cooldown} || 10;
}

sub observed_events       { $_[0]->{observed_events}       || 0 }
sub skipped_events        { $_[0]->{skipped_events}        || 0 }
sub event_cooldown_skips  { $_[0]->{event_cooldown_skips}  || 0 }

sub observe_channel_event {
    my ($self, $event, $ctx) = @_;

    $self->{observed_events}++;

    my $bot = $self->{bot};
    # mb540-B1: label event sur des valeurs sures uniquement (cardinalite
    # bornee par la whitelist; tout le reste est agrege sous invalid).
    my $event_label = _is_supported_channel_event($event) ? $event : 'invalid';
    my $note_event = sub {
        my ($outcome) = @_;
        $self->_bridge_metric('inc', 'mediabot_scriptbridge_events_total',
            { event => $event_label, outcome => $outcome });
    };

    unless (_is_supported_channel_event($event)) {
        $self->{skipped_events}++;
        $self->{last_error} = 'unsupported channel event';
        $note_event->('other');
        return undef;
    }

    unless ($self->plugin_enabled) {
        $self->{skipped_events}++;
        $self->{last_error} = 'ScriptDryRun plugin is disabled';
        $note_event->('other');
        return undef;
    }

    my $script_path = $self->event_routes->{$event};
    unless (defined $script_path && length "$script_path") {
        $self->{skipped_events}++;
        $self->{last_error} = "no script routed for event '$event'";
        $note_event->('unrouted');
        return undef;
    }

    my $channel = _ctx_scalar_value($ctx, 'channel', 'target');
    my $nick    = _ctx_scalar_value($ctx, 'nick', 'sender');
    my $is_self = 0;
    if (ref($ctx) eq 'HASH') {
        $is_self = $ctx->{is_self} ? 1 : 0;
    }

    if ($is_self) {
        $self->{skipped_events}++;
        $self->{last_error} = "self $event event is never routed to scripts";
        $note_event->('self');
        return undef;
    }

    unless (defined $channel && length "$channel") {
        $self->{skipped_events}++;
        $self->{last_error} = "channel event '$event' without a channel";
        $note_event->('other');
        return undef;
    }

    # Anti-tempete: cooldown par (evenement, canal).
    my $now = time();
    my $chan_key = lc "$channel";
    my $last_run = $self->{event_last_run}{$event}{$chan_key} || 0;
    if (($now - $last_run) < $self->event_cooldown) {
        $self->{skipped_events}++;
        $self->{event_cooldown_skips}++;
        $self->{last_error} = "event '$event' on $channel is cooling down";
        $note_event->('cooldown');
        return undef;
    }

    if ($self->action_mode eq 'apply') {
        unless ($bot && $bot->can('script_runner') && $bot->script_runner && $bot->script_runner->can('run_script')) {
            $self->{skipped_events}++;
            $self->{last_error} = 'script runner is not initialized';
            $note_event->('other');
            return undef;
        }
        unless ($bot->can('script_action_runner') && $bot->script_action_runner && $bot->script_action_runner->can('apply_actions')) {
            $self->{skipped_events}++;
            $self->{last_error} = 'script action runner cannot apply actions';
            $note_event->('other');
            return undef;
        }
    }
    else {
        unless ($bot && $bot->can('run_script_actions_dry')) {
            $self->{skipped_events}++;
            $self->{last_error} = 'bot cannot run script actions dry';
            $note_event->('other');
            return undef;
        }
    }

    # Le cooldown demarre a l'ACCEPTATION (pas au succes): un script qui
    # echoue en boucle ne doit pas etre relance a chaque join d'une rafale.
    $self->{event_last_run}{$event}{$chan_key} = $now;
    $note_event->('accepted');

    $self->_log_bot(4, "PUBLIC(scriptdryrun): accepted event=$event channel=$channel script=$script_path mode=" . $self->action_mode . " allow_irc=" . $self->allow_irc);

    my %data = (
        channel => $channel,
        target  => $channel,
        nick    => $nick,
        args    => [],
    );
    for my $extra (qw(ident host message topic kicked)) {
        my $value = _ctx_scalar_value($ctx, $extra);
        $data{$extra} = $value if defined $value && length "$value";
    }
    # mb531-B1: config par route d'evenement (clé CONFIG_<event>), meme
    # mecanique que pour les commandes.
    my $route_config = $self->route_config($event);
    $data{config} = $route_config if %$route_config;

    my $result;
    my $label = "event:$event";

    if ($self->action_mode eq 'apply') {
        my $run_started_at = time();
        my $script_result  = $bot->script_runner->run_script($script_path, $event, %data);
        $self->_log_script_result($label, $run_started_at, $script_result);

        my $context = {
            event   => $event,
            channel => $data{channel},
            target  => $data{target},
            nick    => $data{nick},
            args    => $data{args},
        };

        my $apply_started_at = time();
        my $action_plan = $bot->script_action_runner->apply_actions(
            $script_result,
            $context,
            apply       => 1,
            allow_irc   => $self->allow_irc,
            timer_depth => 0,
            schedule_timer => sub {
                return $self->_schedule_script_timer($script_path, \%data, @_);
            },
        );
        $self->_log_action_plan($label, $apply_started_at, $action_plan);

        $result = {
            ok            => ($script_result->{ok} && $action_plan->{applied_ok}) ? 1 : 0,
            dry_run       => 0,
            action_mode   => 'apply',
            allow_irc     => $self->allow_irc,
            event         => $event,
            script_result => $script_result,
            action_plan   => $action_plan,
        };
    }
    else {
        my $run_started_at = time();
        $result = $bot->run_script_actions_dry($script_path, $event, %data);
        if (ref($result) eq 'HASH') {
            $result->{action_mode} = 'dry-run';
            $result->{allow_irc}   = $self->allow_irc;
            $result->{event}       = $event;
        }
        my $script_result = ref($result) eq 'HASH' ? $result->{script_result} : undef;
        my $action_plan   = ref($result) eq 'HASH' ? $result->{action_plan}   : undef;
        $self->_log_script_result($label, $run_started_at, $script_result);
        $self->_log_action_plan($label, $run_started_at, $action_plan);
    }

    $self->{last_result} = $result;
    $self->{last_error}  = undef;
    $self->_note_run_metric('event', $result);
    $self->_note_pending_timers_metric;

    return $result;
}

# ---------------------------------------------------------------------------
# mb531-B1: configuration par route (commandes ET evenements).
#
# Cle de conf: CONFIG_<route> dans le bloc plugin, une par route, valeur au
# format "cle=valeur; cle2=valeur2" (separateur ';' pour autoriser les
# virgules dans les valeurs; Config::Simple ayant deja splitte sur les
# virgules, les fragments sont rejoints avant parsing). Regles fail-closed:
#   - cles limitees a [A-Za-z0-9_.-]{1,64};
#   - valeurs scalaires de 512 caracteres max (paire REJETEE au-dela, avec
#     log: tronquer silencieusement de la config est vicieux);
#   - au plus 20 cles par route (tri deterministe, excedent ignore + log).
# La map validee est injectee dans l'enveloppe JSON sous data.config,
# uniquement quand elle est non vide; elle voyage avec les rappels timer via
# le snapshot mb525.
# ---------------------------------------------------------------------------

use constant ROUTE_CONFIG_MAX_KEYS      => 20;
use constant ROUTE_CONFIG_MAX_VALUE_LEN => 512;

sub _parse_route_config {
    my ($self, $route, $raw) = @_;

    my $joined = join ',', grep { defined } _flatten_config_values($raw);
    return {} unless length $joined;

    my %config;
    my $kept = 0;

    for my $pair (split /;/, $joined) {
        $pair =~ s/^\s+|\s+$//g;
        next unless length $pair;

        my ($key, $value) = split /\s*=\s*/, $pair, 2;
        $key   = defined $key   ? $key   : '';
        $value = defined $value ? $value : '';
        $key =~ s/^\s+|\s+$//g;

        unless ($key =~ /\A[A-Za-z0-9_.-]{1,64}\z/) {
            $self->_log_bot(2, "PUBLIC(scriptdryrun): CONFIG_$route: rejected invalid key");
            next;
        }
        if (length($value) > ROUTE_CONFIG_MAX_VALUE_LEN) {
            $self->_log_bot(2, "PUBLIC(scriptdryrun): CONFIG_$route: rejected oversized value for key '$key'");
            next;
        }
        if ($kept >= ROUTE_CONFIG_MAX_KEYS) {
            $self->_log_bot(2, "PUBLIC(scriptdryrun): CONFIG_$route: too many keys, ignoring '$key'");
            next;
        }

        $config{$key} = $value;
        $kept++;
    }

    return \%config;
}

sub _load_route_configs {
    my ($self) = @_;

    my $conf = $self->{bot} ? $self->{bot}{conf} : undef;
    my %configs;

    my %route_names = (
        %{ $self->{command_routes} || {} },
        %{ $self->{event_routes}   || {} },
    );

    for my $name (sort keys %route_names) {
        my $raw = _conf_get_first(
            $conf,
            "plugins.ScriptDryRun.CONFIG_$name",
            "plugins.ScriptDryRun.config_$name",
            "plugins.script_dryrun.CONFIG_$name",
            "plugins.script_dryrun.config_$name",
            'SCRIPT_DRYRUN_CONFIG_' . uc($name),
        );
        next unless defined $raw;

        my $parsed = $self->_parse_route_config($name, $raw);
        $configs{$name} = $parsed if %$parsed;
    }

    $self->{route_configs} = \%configs;
    return \%configs;
}

# Copie defensive: un script ou un appelant ne doit pas pouvoir muter la
# config stockee via la reference injectee dans l'enveloppe.
sub route_config {
    my ($self, $name) = @_;

    return {} unless defined $name && !ref($name) && length $name;
    my $stored = ref($self->{route_configs}) eq 'HASH' ? $self->{route_configs}{$name} : undef;
    return {} unless ref($stored) eq 'HASH';
    return { %$stored };
}

sub configured_routes {
    my ($self) = @_;
    return () unless ref($self->{route_configs}) eq 'HASH';
    return sort keys %{ $self->{route_configs} };
}

# mb536-B1: instantane en LECTURE SEULE des fenetres de cooldown, pour la
# partyline (.scriptdryrun events). Une entree par (evenement, canal) deja
# declenche: anciennete du dernier declenchement et temps restant de la
# fenetre (0 = re-declenchable). Copies triees, rien de mutable n'est expose.
sub event_cooldown_state {
    my ($self) = @_;

    my $last_run = $self->{event_last_run};
    return () unless ref($last_run) eq 'HASH' && %$last_run;

    my $now      = time();
    my $cooldown = $self->event_cooldown;
    my @state;

    for my $event (sort keys %$last_run) {
        my $channels = $last_run->{$event};
        next unless ref($channels) eq 'HASH';
        for my $channel (sort keys %$channels) {
            my $stamp = $channels->{$channel} || 0;
            next unless $stamp > 0;
            my $ago = $now - $stamp;
            $ago = 0 if $ago < 0;
            my $remaining = $cooldown - $ago;
            $remaining = 0 if $remaining < 0;
            push @state, {
                event        => $event,
                channel      => $channel,
                last_run_ago => int($ago + 0.5),
                remaining    => int($remaining + 0.5),
            };
        }
    }

    return @state;
}

# mb536-B1: purge manuelle des fenetres de cooldown (deblocage ops apres un
# test, un netsplit...). Ne touche ni aux routes ni aux compteurs; n'execute
# jamais rien — la prochaine occurrence d'un evenement route redevient
# simplement eligible immediatement.
sub clear_event_cooldowns {
    my ($self) = @_;

    my $last_run = $self->{event_last_run};
    my $cleared = 0;
    if (ref($last_run) eq 'HASH') {
        for my $event (keys %$last_run) {
            next unless ref($last_run->{$event}) eq 'HASH';
            $cleared += scalar keys %{ $last_run->{$event} };
        }
    }
    $self->{event_last_run} = {};

    $self->_log_bot(4, "PUBLIC(scriptdryrun): event cooldown windows cleared count=$cleared");
    return $cleared;
}

# mb537-B1: derivation de l'etat depuis les valeurs *_raw, partagee entre
# register() et refresh_from_conf(). Ne touche ni aux compteurs, ni aux
# timers actifs (leur snapshot mb525 fige leur config), ni aux fenetres de
# cooldown (clearevents existe pour ca), ni aux listeners (geres a part).
sub _derive_conf_state {
    my ($self) = @_;

    $self->{command_filter} = _make_command_filter($self->{command_filter_raw});

    # Optional command-to-script route map. One trusted bridge instance can
    # dispatch different commands to different Perl/Python/Tcl scripts while
    # keeping the same path, protocol, scope and action-application guards.
    $self->{command_routes} = _make_command_routes($self->{command_routes_raw});

    # mb187-B1: explicit action mode gate. Default is dry-run. Real application
    # is only possible with ACTION_MODE=apply, and IRC output still requires
    # ALLOW_IRC to be truthy.
    $self->{action_mode} = _normalize_action_mode($self->{action_mode_raw});
    $self->{allow_irc}   = _truthy($self->{allow_irc_raw});

    # mb189-B1 + A3 (mb225): optional extra safety gate, ENABLED BY DEFAULT.
    # When enabled, ACTION_MODE=apply is refused unless COMMANDS or ROUTES
    # restrict the public-command scope. An operator can still opt out
    # explicitly with APPLY_REQUIRE_SCOPE=no.
    $self->{apply_require_scope} = _truthy_with_default($self->{apply_require_scope_raw}, 1);

    # mb529-B1: routes d'evenements. Reutilise le parseur ROUTES puis filtre
    # sur la whitelist; toute entree inconnue est ignoree (et loggee) plutot
    # que d'ouvrir silencieusement un chemin d'execution non prevu.
    my $raw_event_routes = _make_command_routes($self->{event_routes_raw});
    my %event_routes;
    for my $event (keys %{ $raw_event_routes || {} }) {
        if (_is_supported_channel_event($event)) {
            $event_routes{$event} = $raw_event_routes->{$event};
        }
        else {
            $self->_log_bot(2, "PUBLIC(scriptdryrun): ignoring unsupported EVENTS entry '$event' (supported: join, part, topic, kick)");
        }
    }
    $self->{event_routes} = \%event_routes;

    # mb529-B1: anti-tempete. Les join/part arrivent en rafale (netsplits);
    # au plus UNE execution par evenement par canal par fenetre de cooldown.
    $self->{event_cooldown} = _bounded_positive_int($self->{event_cooldown_raw}, 10, 1, 3600);

    # mb531-B1: config par route, chargee une fois les deux cartes de routes
    # connues (commandes + evenements).
    $self->_load_route_configs;

    return 1;
}

# mb537-B1: abonnement aux SEULS evenements routes (regle mb529). Les entries
# sont conservees pour un retrait propre (regle mb242) — a l'unregister comme
# lors d'une resouscription apres refresh_from_conf().
sub _subscribe_event_listeners {
    my ($self) = @_;

    my $bot = $self->{bot};
    return 0 unless $bot && $bot->can('events') && $bot->events;

    for my $event (sort keys %{ $self->{event_routes} || {} }) {
        my $bus_event = "channel_${event}_observed";
        my $entry = $bot->events->on(
            $bus_event => sub {
                my ($ctx) = @_;
                return $self->observe_channel_event($event, $ctx);
            },
            name   => "script-dryrun-${event}-observer",
            plugin => __PACKAGE__,
        );
        push @{ $self->{event_listener_entries} }, [ $bus_event, $entry ];
    }

    return 1;
}

sub _unsubscribe_event_listeners {
    my ($self) = @_;

    my $bot = $self->{bot};
    return 0 unless $bot && $bot->can('events') && $bot->events && $bot->events->can('off');

    for my $pair (@{ $self->{event_listener_entries} || [] }) {
        next unless ref($pair) eq 'ARRAY' && ref($pair->[1]) eq 'HASH';
        eval { $bot->events->off($pair->[0] => $pair->[1]); 1 };
    }
    $self->{event_listener_entries} = [];

    return 1;
}

# mb537-B1: rechargement a chaud de l'etat de conf du plugin, SANS reload du
# plugin. A utiliser apres .reloadconf ou .rehash (qui rechargent le
# fichier dans $bot->{conf} mais ne touchent pas aux plugins). Relit toutes
# les cles via _collect_conf_raw, re-derive l'etat, resouscrit les listeners
# d'evenements si les routes ont change, et retourne la liste triee des
# champs modifies. Compteurs, timers armes (snapshot mb525) et fenetres de
# cooldown sont volontairement conserves.
sub refresh_from_conf {
    my ($self) = @_;

    my $fingerprint = sub {
        my %fp;
        $fp{script_path} = defined $self->{script_path} ? "$self->{script_path}" : '';
        $fp{action_mode} = $self->{action_mode} || '';
        $fp{allow_irc}   = $self->{allow_irc} ? 1 : 0;
        $fp{apply_require_scope} = $self->{apply_require_scope} ? 1 : 0;
        $fp{event_cooldown} = $self->{event_cooldown} || 0;
        my $filter = $self->{command_filter};
        $fp{command_filter} = ref($filter) eq 'HASH' ? join(',', sort keys %$filter) : '';
        for my $pair ([ command_routes => 'command_routes' ],
                      [ event_routes   => 'event_routes' ]) {
            my ($label, $key) = @$pair;
            my $map = $self->{$key};
            $fp{$label} = ref($map) eq 'HASH'
                ? join(',', map { "$_=" . ($map->{$_} // '') } sort keys %$map)
                : '';
        }
        my $configs = $self->{route_configs};
        $fp{route_configs} = '';
        if (ref($configs) eq 'HASH') {
            $fp{route_configs} = join('|', map {
                my $route = $_;
                my $c = $configs->{$route};
                "$route:" . join(';', map { "$_=" . ($c->{$_} // '') } sort keys %{ ref($c) eq 'HASH' ? $c : {} });
            } sort keys %$configs);
        }
        return \%fp;
    };

    my $before = $fingerprint->();

    my %fresh = _collect_conf_raw($self->{bot});
    @{$self}{keys %fresh} = values %fresh;

    # mb539-B1: register() already normalizes SCRIPT because Config::Simple
    # may return an ARRAY ref for a single-path option. Hot reload must apply
    # the same rule before the fallback path can reach ScriptRunner.
    $self->{script_path} = _first_config_scalar($self->{script_path});

    $self->_derive_conf_state;

    my $after = $fingerprint->();

    my @changed = sort grep { ($before->{$_} // '') ne ($after->{$_} // '') } keys %$after;

    if (($before->{event_routes} // '') ne ($after->{event_routes} // '')) {
        $self->_unsubscribe_event_listeners;
        $self->_subscribe_event_listeners;
    }

    $self->_log_bot(3, 'PUBLIC(scriptdryrun): conf refreshed'
        . (@changed ? ' changed=' . join(',', @changed) : ' (no changes)'));

    return @changed;
}

# ---------------------------------------------------------------------------
# mb540-B1: metriques Prometheus du bridge (best-effort). Quatre series sous
# le prefixe mediabot_scriptbridge_*; toutes les emissions passent par
# _bridge_metric, qui ne fait RIEN si le bot n'a pas de Metrics actif — le
# bridge ne depend jamais de l'observabilite pour fonctionner. Aucune cle de
# conf nouvelle: l'activation suit le systeme de metriques global du bot.
# ---------------------------------------------------------------------------

sub _bridge_metric {
    my ($self, $method, @args) = @_;

    my $metrics = $self->{bot} ? $self->{bot}{metrics} : undef;
    return 0 unless $metrics && eval { $metrics->can($method) };
    eval { $metrics->$method(@args); 1 } or return 0;
    return 1;
}

sub _declare_bridge_metrics {
    my ($self) = @_;

    $self->_bridge_metric('declare', 'mediabot_scriptbridge_runs_total', 'counter',
        'External script bridge runs by origin (command/event/timer) and result');
    $self->_bridge_metric('declare', 'mediabot_scriptbridge_events_total', 'counter',
        'Channel events seen by the script bridge, by event and outcome');
    $self->_bridge_metric('declare', 'mediabot_scriptbridge_timers_total', 'counter',
        'Script bridge timers by lifecycle outcome (armed/delivered/cancelled)');
    $self->_bridge_metric('declare', 'mediabot_scriptbridge_pending_timers', 'gauge',
        'Currently armed script bridge timers');

    return 1;
}

sub _note_run_metric {
    my ($self, $origin, $result) = @_;

    my $ok = ref($result) eq 'HASH' && $result->{ok} ? 'ok' : 'error';
    $self->_bridge_metric('inc', 'mediabot_scriptbridge_runs_total',
        { origin => $origin, result => $ok });
    return 1;
}

sub _note_pending_timers_metric {
    my ($self) = @_;

    my $bot = $self->{bot};
    my $count = 0;
    if ($bot && $bot->can('script_action_runner') && $bot->script_action_runner
        && $bot->script_action_runner->can('pending_timer_count')) {
        $count = $bot->script_action_runner->pending_timer_count || 0;
    }
    $self->_bridge_metric('set', 'mediabot_scriptbridge_pending_timers', $count);
    return 1;
}

sub action_mode_raw {
    my ($self) = @_;
    return $self->{action_mode_raw};
}

sub action_mode {
    my ($self) = @_;
    return $self->{action_mode} || 'dry-run';
}

sub allow_irc {
    my ($self) = @_;
    return $self->{allow_irc} ? 1 : 0;
}


sub apply_require_scope {
    my ($self) = @_;
    return $self->{apply_require_scope} ? 1 : 0;
}

sub apply_scope_is_restricted {
    my ($self) = @_;
    return ($self->command_filter_enabled || $self->command_routes_enabled) ? 1 : 0;
}

sub apply_scope_warning {
    my ($self, $command) = @_;

    return undef unless $self->action_mode eq 'apply';
    return undef unless $self->apply_require_scope;

    # mb262-B1: APPLY_REQUIRE_SCOPE must protect the CURRENT command, not only
    # the global plugin configuration.  A config such as ROUTES=foo=... plus a
    # fallback SCRIPT is globally "restricted", but command "bar" is still not
    # explicitly scoped.  In apply mode that fallback would apply script actions
    # for an unscoped command.  Reject it unless the operator explicitly opts out
    # with APPLY_REQUIRE_SCOPE=no.
    return undef if defined($command) && $self->_command_is_scoped($command);

    return 'ACTION_MODE=apply requires COMMANDS or ROUTES matching the current command when APPLY_REQUIRE_SCOPE is enabled';
}


sub command_routes_raw {
    my ($self) = @_;
    return $self->{command_routes_raw};
}

sub command_routes {
    my ($self) = @_;
    return $self->{command_routes} || {};
}

sub command_route_list {
    my ($self) = @_;
    return sort keys %{ $self->command_routes };
}

sub command_routes_enabled {
    my ($self) = @_;
    return scalar(keys %{ $self->command_routes }) ? 1 : 0;
}

sub script_for_command {
    my ($self, $command) = @_;

    my $normalized = _normalize_command_name($command);
    my $routes = $self->command_routes;

    return $routes->{$normalized} if length($normalized) && exists $routes->{$normalized};
    return $self->{script_path};
}


sub command_filter_raw {
    my ($self) = @_;
    return $self->{command_filter_raw};
}

sub command_filter {
    my ($self) = @_;
    return $self->{command_filter} || {};
}

sub command_filter_list {
    my ($self) = @_;
    return sort keys %{ $self->command_filter };
}

sub command_filter_enabled {
    my ($self) = @_;
    return scalar(keys %{ $self->command_filter }) ? 1 : 0;
}

sub command_allowed {
    my ($self, $command) = @_;

    my $filter = $self->command_filter;
    my $routes = $self->command_routes;

    my $normalized = _normalize_command_name($command);
    return 0 unless length $normalized;

    # mb184-F1: routes-only mode must not allow every command.
    # If COMMANDS exists, it is an allow-list.
    # If ROUTES exists without SCRIPT fallback, routed commands only are allowed.
    # If SCRIPT fallback exists and no COMMANDS filter exists, every command can
    # fall back to SCRIPT unless a route overrides it.
    return 1 if $routes->{$normalized};
    return 1 if $filter->{$normalized};

    if (scalar keys %$filter) {
        return 0;
    }

    if (scalar keys %$routes) {
        return defined($self->{script_path}) && length("$self->{script_path}") ? 1 : 0;
    }

    return defined($self->{script_path}) && length("$self->{script_path}") ? 1 : 0;
}

# A2 (mb225): true only when the command is explicitly scoped (routed or in the
# COMMANDS allow-list). Used to decide whether ScriptDryRun OWNS the public
# command (i.e. suppresses the legacy dispatcher). A bare SCRIPT fallback alone
# never owns a command.
sub _command_is_scoped {
    my ($self, $command) = @_;

    my $normalized = _normalize_command_name($command);
    return 0 unless length $normalized;

    return 1 if $self->command_routes->{$normalized};
    return 1 if $self->command_filter->{$normalized};
    return 0;
}


sub script_path {
    my ($self) = @_;
    return $self->{script_path};
}

sub observed_public {
    my ($self) = @_;
    return $self->{observed_public} || 0;
}

sub skipped_public {
    my ($self) = @_;
    return $self->{skipped_public} || 0;
}

sub filtered_public {
    my ($self) = @_;
    return $self->{filtered_public} || 0;
}


sub last_result {
    my ($self) = @_;
    return $self->{last_result};
}

sub last_error {
    my ($self) = @_;
    return $self->{last_error};
}

1;

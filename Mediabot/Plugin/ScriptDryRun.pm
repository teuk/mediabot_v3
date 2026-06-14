package Mediabot::Plugin::ScriptDryRun;

use strict;
use warnings;
use utf8;
use Time::HiRes qw(time);

our $VERSION = '0.001';

# ---------------------------------------------------------------------------
# Mediabot::Plugin::ScriptDryRun
# ---------------------------------------------------------------------------
# mb179-B1: trusted in-process Perl bridge from EventBus to ScriptRunner.
#
# This plugin listens to public_command_observed and calls
# $bot->run_script_actions_dry(...). It deliberately never applies actions.
# It is an integration bridge and a safety proof, not an IRC feature yet.
# ---------------------------------------------------------------------------

sub register {
    my ($class, $bot, %opts) = @_;

    my $self = bless {
        bot             => $bot,
        manager         => $opts{manager},
        script_path     => _conf_get_first(
            $bot ? $bot->{conf} : undef,
            'plugins.ScriptDryRun.SCRIPT',
            'plugins.ScriptDryRun.script',
            'plugins.script_dryrun.SCRIPT',
            'plugins.script_dryrun.script',
            'SCRIPT_DRYRUN_SCRIPT',
            'SCRIPT_DRYRUN_PATH',
        ),
        command_filter_raw => _conf_get_first(
            $bot ? $bot->{conf} : undef,
            'plugins.ScriptDryRun.COMMANDS',
            'plugins.ScriptDryRun.commands',
            'plugins.script_dryrun.COMMANDS',
            'plugins.script_dryrun.commands',
            'SCRIPT_DRYRUN_COMMANDS',
        ),
        command_routes_raw => _conf_get_first(
            $bot ? $bot->{conf} : undef,
            'plugins.ScriptDryRun.ROUTES',
            'plugins.ScriptDryRun.routes',
            'plugins.script_dryrun.ROUTES',
            'plugins.script_dryrun.routes',
            'SCRIPT_DRYRUN_ROUTES',
        ),
        action_mode_raw => _conf_get_first(
            $bot ? $bot->{conf} : undef,
            'plugins.ScriptDryRun.ACTION_MODE',
            'plugins.ScriptDryRun.action_mode',
            'plugins.script_dryrun.ACTION_MODE',
            'plugins.script_dryrun.action_mode',
            'SCRIPT_DRYRUN_ACTION_MODE',
        ),
        allow_irc_raw => _conf_get_first(
            $bot ? $bot->{conf} : undef,
            'plugins.ScriptDryRun.ALLOW_IRC',
            'plugins.ScriptDryRun.allow_irc',
            'plugins.script_dryrun.ALLOW_IRC',
            'plugins.script_dryrun.allow_irc',
            'SCRIPT_DRYRUN_ALLOW_IRC',
        ),
        apply_require_scope_raw => _conf_get_first(
            $bot ? $bot->{conf} : undef,
            'plugins.ScriptDryRun.APPLY_REQUIRE_SCOPE',
            'plugins.ScriptDryRun.apply_require_scope',
            'plugins.script_dryrun.APPLY_REQUIRE_SCOPE',
            'plugins.script_dryrun.apply_require_scope',
            'SCRIPT_DRYRUN_APPLY_REQUIRE_SCOPE',
        ),
        action_mode => 'dry-run',
        allow_irc   => 0,
        apply_require_scope => 0,
        command_filter => undef,
        command_routes => undef,
        observed_public => 0,
        skipped_public  => 0,
        filtered_public => 0,
        last_result     => undef,
        last_error      => undef,
    }, $class;

    # mb182-B1: optional command allow-list for the ScriptDryRun bridge.
    # Empty or missing filter keeps the previous behavior: observe all commands.
    $self->{command_filter} = _make_command_filter($self->{command_filter_raw});

    # mb184-B1: optional command-to-script route map. This lets one trusted
    # ScriptDryRun plugin dispatch different commands to different Perl/Python/Tcl
    # scripts while keeping the same dry-run safety boundary.
    $self->{command_routes} = _make_command_routes($self->{command_routes_raw});

    # mb187-B1: explicit action mode gate. Default is dry-run. Real application
    # is only possible with ACTION_MODE=apply, and IRC output still requires
    # ALLOW_IRC to be truthy.
    $self->{action_mode} = _normalize_action_mode($self->{action_mode_raw});
    $self->{allow_irc}   = _truthy($self->{allow_irc_raw});

    # mb189-B1: optional extra safety gate. When enabled, ACTION_MODE=apply is
    # refused unless COMMANDS or ROUTES restrict the public-command scope.
    $self->{apply_require_scope} = _truthy($self->{apply_require_scope_raw});

    if ($bot && $bot->can('events') && $bot->events) {
        $bot->events->on(
            public_command_observed => sub {
                my ($ctx) = @_;
                return $self->observe_public_command($ctx);
            },
            name   => 'script-dryrun-public-command-observer',
            plugin => __PACKAGE__,
        );
    }

    return $self;
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
        return $value if defined $value && length "$value";
    }

    return undef;
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

    my $value = lc "$command";
    $value =~ s/^\s+|\s+$//g;
    $value =~ s/^[.!]+//;

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

    my $command = _ctx_value($ctx, 'command', 'cmd');
    return $command if defined $command && length "$command";

    my $cmd_obj = _ctx_value($ctx, 'command_obj');
    if ($cmd_obj) {
        for my $method (qw(name command cmd)) {
            next unless eval { $cmd_obj->can($method) };
            my $value = eval { $cmd_obj->$method() };
            return $value if defined $value && length "$value";
        }

        my $hash_value = eval { $cmd_obj->{name} };
        return $hash_value if defined $hash_value && length "$hash_value";
    }

    return undef;
}

sub _ctx_args {
    my ($ctx) = @_;

    my $args = _ctx_value($ctx, 'args');
    return $args if ref($args) eq 'ARRAY';

    my $cmd_obj = _ctx_value($ctx, 'command_obj');
    if ($cmd_obj) {
        for my $method (qw(args argv)) {
            next unless eval { $cmd_obj->can($method) };
            my $value = eval { $cmd_obj->$method() };
            return $value if ref($value) eq 'ARRAY';
        }

        my $hash_value = eval { $cmd_obj->{args} };
        return $hash_value if ref($hash_value) eq 'ARRAY';
    }

    return [];
}

sub observe_public_command {
    my ($self, $ctx) = @_;

    $self->{observed_public}++;

    my $bot = $self->{bot};

    unless ($bot && $bot->can('run_script_actions_dry')) {
        $self->{last_error} = 'bot cannot run script actions dry';
        return undef;
    }

    my $command = _ctx_command($ctx);
    unless ($self->command_allowed($command)) {
        my $name = defined($command) && length("$command") ? "$command" : '<empty>';
        $self->{filtered_public}++;
        $self->{skipped_public}++;
        $self->{last_error} = "command '$name' not allowed by ScriptDryRun filter";
        return undef;
    }

    if (my $scope_warning = $self->apply_scope_warning) {
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

    # mb196-B1: log before running the external script. If the script blocks or
    # times out, this line appears immediately and gives us the accepted route.
    $self->_log_bot(4, "PUBLIC(scriptdryrun): accepted command=$command script=$script_path mode=" . $self->action_mode . " allow_irc=" . $self->allow_irc);

    # mb194-B1: once ScriptDryRun accepts a command through COMMANDS/ROUTES and
    # finds a script for it, it owns that public command. This prevents the
    # legacy DB/fallback path from logging "Public command ... not found" after a
    # dry-run or apply-mode script command such as "m pyhello".
    _ctx_mark_scriptdryrun_handled($ctx, undef, undef);

    my %data = (
        channel => _ctx_value($ctx, 'channel', 'target'),
        target  => _ctx_value($ctx, 'target', 'channel'),
        nick    => _ctx_value($ctx, 'nick', 'sender'),
        command => $command,
        args    => _ctx_args($ctx),
    );

    my $result;
    my $run_started_at;
    my $apply_started_at;

    if ($self->action_mode eq 'apply') {
        unless ($bot->can('script_runner') && $bot->script_runner && $bot->script_runner->can('run_script')) {
            $self->{last_error} = 'script runner is not initialized';
            return undef;
        }

        unless ($bot->can('script_action_runner') && $bot->script_action_runner && $bot->script_action_runner->can('apply_actions')) {
            $self->{last_error} = 'script action runner cannot apply actions';
            return undef;
        }

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
            apply     => 1,
            allow_irc => $self->allow_irc,
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
    _ctx_mark_scriptdryrun_handled($ctx, $result, undef);

    return $result;
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
    my ($self) = @_;

    return undef unless $self->action_mode eq 'apply';
    return undef unless $self->apply_require_scope;
    return undef if $self->apply_scope_is_restricted;

    return 'ACTION_MODE=apply requires COMMANDS or ROUTES when APPLY_REQUIRE_SCOPE is enabled';
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

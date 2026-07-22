package Mediabot;
 
use strict;
use warnings;
# mb315-C1: 'use diagnostics' retiré. Pragma de debug coûteux en prod (charge
# tout perldiag, verbeux sur chaque warning) ; t/test_commands.pl le désactivait
# déjà explicitement après chargement. strict + warnings ci-dessus suffisent.
use Mediabot::Auth;
use Mediabot::User;
use Mediabot::Channel;
use Mediabot::Conf;
use Mediabot::Log;
use Mediabot::Context;
use Mediabot::Command;
use Mediabot::CommandRegistry;
use Mediabot::EventBus;
use Mediabot::PluginManager;
use Mediabot::ScriptRunner;
use Mediabot::ScriptActionRunner;
use Mediabot::Hailo;
use Mediabot::Quotes;
use Mediabot::LoginCommands;
use Mediabot::Helpers;
use Mediabot::ProcessLock;
use Mediabot::ChannelCommands;
use Mediabot::UserCommands;
use Mediabot::External;
use Mediabot::DCC qw(validate_dcc_active_target);
use Mediabot::DBCommands;
use Mediabot::AdminCommands;
use Time::HiRes qw(usleep);
use Config::Simple;
use Date::Parse;
use DBI;
# mb315-C2: 'use Switch' retiré. Aucun bloc switch/case dans le module ; Switch
# est un source-filter déprécié (risque de parsing) chargé pour rien.
use IO::Async::Timer::Periodic;
use IO::Async::Timer::Countdown;
use String::IRC;
use POSIX qw(setsid strftime);
use DateTime;
use DateTime::TimeZone;
use utf8;
use HTML::Tree;
use URL::Encode qw(url_encode_utf8 url_encode url_decode_utf8);
use HTML::Entities '%entity2char';
# Let's comment this out for now (in case noone reads the README)
#use MP3::Tag;
use File::Basename;
use Encode;
# mb315-C3: 'use Moose' retiré. L'objet Mediabot est construit par bless manuel
# (sub new) ; aucun keyword Moose (has/extends/with/before/after/around/meta) ni
# méthode Moose::Object n'est utilisé. blessed/confess ne sont pas appelés ici, et
# croak vient de Carp (importé plus bas). Retire l'arbre de deps Moose et accélère
# le démarrage du bot.
use Hailo;
use Socket;
use JSON::MaybeXS;
use Try::Tiny;
use URI::Escape qw(uri_escape_utf8 uri_escape);
use List::Util qw/min/;
use Carp qw(croak);
use IO::Socket::SSL;
use HTTP::Tiny;


# --- Top of Mediabot.pm (near other 'my' / 'our' declarations)
my $ALREADY_EXITING = 0;  # re-entrance guard for clean_and_exit

# Constructor for Mediabot object
sub new {
    my ($class, $args) = @_;

        my $self = bless {
        config_file             => $args->{config_file}      // undef,
        requested_server        => $args->{server}           // undef,
        server                  => $args->{server}           // undef,
        server_hostname         => undef,
        server_port             => undef,
        server_source           => undef,
        network_name            => undef,
        dbh                     => $args->{dbh}              // undef,
        conf                    => $args->{conf}             // undef,
        channels                => {},
        channel_nicklist_timers => {},
        command_registry        => Mediabot::CommandRegistry->new(),
        event_bus               => Mediabot::EventBus->new(),
        plugin_manager          => undef,
        script_runner           => undef,
        script_action_runner    => undef,
        WHOIS_VARS              => {},
    }, $class;

    # mb169-B1: create PluginManager after bless so it can hold a safe reference
    # to the Mediabot object. It loads no plugin by default.
    $self->{plugin_manager} = Mediabot::PluginManager->new(bot => $self);

    # External script runtime: validates and executes trusted Perl/Python/Tcl
    # scripts through the bounded mediabot-script-v1 JSON protocol.
    $self->{script_runner} = Mediabot::ScriptRunner->new(bot => $self);

    # Action layer: validates/plans every script response and can apply the
    # explicitly gated reply/notice/log actions used by ScriptDryRun apply mode.
    $self->{script_action_runner} = Mediabot::ScriptActionRunner->new(bot => $self);

    # mb166-B1: seed the first low-risk built-in commands into the registry.
    # The old dispatch tables are still kept as fallback.
    $self->_register_builtin_public_core_commands();

    # Minimal logging setup
    require Mediabot::Log;
    $self->{logger} = Mediabot::Log->new(
        debug_level => 0,
        logfile     => undef
    );

    return $self;
}







sub _flatten_local_config_values {
    my ($value) = @_;

    return () unless defined $value;

    # mb282-B1: boot-time plugin autoload config follows the same scalar/list
    # contract as PluginManager and ScriptDryRun config. Config::Simple can hand
    # section values back as ARRAY refs; keep ARRAY support, but never stringify
    # HASH/blessed refs into HASH(...)/Object(...) pseudo values.
    my @queue = ($value);
    my @out;

    while (@queue) {
        my $entry = shift @queue;
        next unless defined $entry;

        if (ref($entry) eq 'ARRAY') {
            unshift @queue, @$entry;
            next;
        }

        next if ref($entry);
        push @out, $entry;
    }

    return @out;
}

sub _local_conf_value_has_meaningful_scalar {
    my ($value) = @_;

    for my $candidate (_flatten_local_config_values($value)) {
        next unless defined $candidate;

        my $v = "$candidate";
        $v =~ s/^\s+|\s+$//g;
        return 1 if length $v;
    }

    return 0;
}

sub _conf_get_first_local {
    my ($self, @keys) = @_;

    my $conf = $self->{conf};
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
        return $value if _local_conf_value_has_meaningful_scalar($value);
    }

    return undef;
}

sub _truthy_config_value {
    my ($value) = @_;

    for my $candidate (_flatten_local_config_values($value)) {
        next unless defined $candidate;

        my $v = lc "$candidate";
        $v =~ s/^\s+|\s+$//g;
        next unless length $v;

        return 1 if $v =~ /\A(?:1|yes|true|on|enabled|enable)\z/;
        return 0 if $v =~ /\A(?:0|no|false|off|disabled|disable)\z/;
    }

    return 0;
}

# Controlled boot-time plugin loading gate.
# mb172-B1: plugins are loaded at boot only when explicitly enabled in config.
sub plugin_autoload_enabled {
    my ($self) = @_;

    my $value = $self->_conf_get_first_local(
        'plugins.AUTOLOAD',
        'plugins.autoload',
        'plugins.ENABLED_AUTOLOAD',
        'PLUGIN_AUTOLOAD',
        'PLUGINS_AUTOLOAD',
    );

    return _truthy_config_value($value);
}

sub load_configured_plugins_if_enabled {
    my ($self, %opts) = @_;

    unless ($self->plugin_autoload_enabled) {
        return {
            skipped => 1,
            reason  => 'plugin autoload disabled',
            loaded  => [],
            errors  => [],
            invalid => [],
        };
    }

    my $report = $self->load_configured_plugins(%opts);
    $report->{skipped} = 0 if ref($report) eq 'HASH';

    return $report;
}

sub log_plugin_load_report {
    my ($self, $report) = @_;

    return unless ref($report) eq 'HASH';

    if ($report->{skipped}) {
        $self->{logger}->log(3, "Plugin autoload skipped: " . ($report->{reason} || 'disabled'))
            if $self->{logger};
        return 1;
    }

    my $loaded = ref($report->{loaded}) eq 'ARRAY' ? scalar @{ $report->{loaded} } : 0;
    $self->{logger}->log(1, "Plugin autoload: loaded $loaded plugin(s)")
        if $self->{logger};

    if (ref($report->{invalid}) eq 'ARRAY') {
        for my $invalid (@{ $report->{invalid} }) {
            $self->{logger}->log(1, "Plugin autoload: invalid module name '$invalid'")
                if $self->{logger};
        }
    }

    if (ref($report->{errors}) eq 'ARRAY') {
        for my $err (@{ $report->{errors} }) {
            next unless ref($err) eq 'HASH';
            my $module = $err->{module} || 'unknown';
            my $msg    = $err->{error}  || 'unknown error';
            $self->{logger}->log(1, "Plugin autoload: failed to load $module: $msg")
                if $self->{logger};
        }
    }

    return 1;
}


# Explicit plugin loading entry point for future boot integration.
# mb170-B1 does not call this automatically from the constructor.
sub load_configured_plugins {
    my ($self, %opts) = @_;

    my $manager = $self->plugin_manager;
    return {
        loaded  => [],
        errors  => [ { error => 'plugin manager is not initialized' } ],
        invalid => [],
    } unless $manager && $manager->can('load_configured_plugins');

    return $manager->load_configured_plugins($self->{conf}, %opts);
}





# Run an external script through ScriptRunner, then validate its returned actions
# through ScriptActionRunner without applying any real side effect.
sub run_script_actions_dry {
    my ($self, $script_path, $event, %data) = @_;

    my $script_runner = $self->script_runner;
    my $action_runner = $self->script_action_runner;

    return {
        ok      => 0,
        dry_run => 1,
        error   => 'script runner is not initialized',
    } unless $script_runner && $script_runner->can('run_script');

    return {
        ok      => 0,
        dry_run => 1,
        error   => 'script action runner is not initialized',
    } unless $action_runner && $action_runner->can('apply_actions_dry');

    # mb178-B1: full dry-run pipeline only. External script execution is allowed
    # through ScriptRunner, but the resulting actions are only validated/planned.
    # No IRC message, DB write, timer creation or runtime mutation is applied here.
    my $script_result = $script_runner->run_script($script_path, $event, %data);
    my $context = {
        event   => $event,
        channel => $data{channel},
        target  => $data{target},
        nick    => $data{nick},
        command => $data{command},
        args    => $data{args},
    };

    my $action_plan = $action_runner->apply_actions_dry($script_result, $context);

    return {
        ok            => ($script_result->{ok} && $action_plan->{ok}) ? 1 : 0,
        dry_run       => 1,
        script_result => $script_result,
        action_plan   => $action_plan,
    };
}


# Return the active script action validator/applier.
sub script_action_runner {
    my ($self) = @_;
    return $self->{script_action_runner};
}

# Short alias for script action runner access.
sub script_actions {
    my ($self) = @_;
    return $self->{script_action_runner};
}


# Return the active external Perl/Python/Tcl script runtime.
sub script_runner {
    my ($self) = @_;
    return $self->{script_runner};
}

# Short alias for script runner access.
sub scripts {
    my ($self) = @_;
    return $self->{script_runner};
}


# Return the active plugin manager.
sub plugin_manager {
    my ($self) = @_;
    return $self->{plugin_manager};
}

# Short alias for plugin manager access.
sub plugins {
    my ($self) = @_;
    return $self->{plugin_manager};
}


# Return the active internal event bus used by hooks and plugins.
sub event_bus {
    my ($self) = @_;
    return $self->{event_bus};
}

# Short alias for event bus access.
sub events {
    my ($self) = @_;
    return $self->{event_bus};
}



# Emit an internal event through EventBus and log listener errors without
# changing the caller's normal control flow.
sub emit_event_report {
    my ($self, $event, @args) = @_;

    my $bus = $self->event_bus;
    return {
        event  => $event,
        ran    => 0,
        errors => [],
    } unless $bus && $bus->can('emit_report');

    my $report = eval { $bus->emit_report($event, @args) };
    if (!$report) {
        my $err = $@ || 'unknown EventBus error';
        $err =~ s/\s+/ /g;
        $self->{logger}->log(1, "EventBus '$event' failed: $err")
            if $self->{logger};
        return {
            event  => $event,
            ran    => 0,
            errors => [ { event => $event, error => $err } ],
        };
    }

    if (ref($report) eq 'HASH' && ref($report->{errors}) eq 'ARRAY' && @{ $report->{errors} }) {
        for my $e (@{ $report->{errors} }) {
            next unless ref($e) eq 'HASH';
            my $who = $e->{name} || $e->{plugin} || 'anonymous-listener';
            my $err = $e->{error} || 'unknown listener error';
            $self->{logger}->log(1, "EventBus '$event' listener '$who' failed: $err")
                if $self->{logger};
        }
    }

    return $report;
}

# mb529-B1: single core entry point for observed channel lifecycle events.
# Called (eval-guarded) from the mediabot.pl JOIN/PART/TOPIC handlers; builds a
# small scalar-only context and emits channel_<type>_observed on the EventBus.
# Listener errors are isolated by emit_event_report; with no listeners this is
# a no-op, so the historical IRC handlers keep their exact behavior.
# mb535-B1: kick ajoute — canal + auteur (nick) + victime (kicked) + raison.
my %OBSERVABLE_CHANNEL_EVENTS = map { $_ => 1 } qw(join part topic kick);

sub observe_channel_event {
    my ($self, $type, %data) = @_;

    return undef unless defined $type && !ref($type) && $OBSERVABLE_CHANNEL_EVENTS{$type};

    my $ctx = { event_type => $type };
    for my $key (qw(channel nick ident host message topic kicked is_self)) {
        my $value = $data{$key};
        next unless defined $value && !ref($value);
        $ctx->{$key} = "$value";
    }
    $ctx->{is_self} = $ctx->{is_self} ? 1 : 0;

    return $self->emit_event_report("channel_${type}_observed", $ctx);
}

# mb543-B1: network-wide stats from the LUSERS numerics. Called (eval-guarded)
# by the thin on_message_251/252/254/265/266 handlers in mediabot.pl; parses
# defensively and updates the mediabot_network_* gauges best-effort. Returns a
# hashref of what was updated (empty on unknown/garbage input) so the logic is
# unit-testable without an IRC connection.
sub update_network_metrics_from_numeric {
    my ($self, $numeric, $args, $text) = @_;

    $numeric = defined $numeric && !ref($numeric) ? "$numeric" : '';
    $args    = ref($args) eq 'ARRAY' ? $args : [];
    $text    = defined $text && !ref($text) ? "$text" : '';

    my %updated;
    my $set = sub {
        my ($name, $value) = @_;
        return unless defined $value && "$value" =~ /\A[0-9]+\z/;
        $updated{$name} = int($value);
        # mb544-B1: cache coeur — source de verite pour la partyline et les
        # logs, disponible meme sans le systeme Metrics.
        my $short = $name;
        $short =~ s/^mediabot_network_//;
        $self->{network_stats}{$short} = int($value);
        $self->{network_stats}{updated_at} = time();
        if ($self->{metrics} && eval { $self->{metrics}->can('set') }) {
            eval { $self->{metrics}->set($name, int($value)); 1 };
        }
    };

    if ($numeric eq '251') {
        # ":There are 7 users and 3 invisible on 2 servers"
        if ($text =~ /There are\s+([0-9]+)\s+users\s+and\s+([0-9]+)\s+invisible/i) {
            $set->('mediabot_network_users', $1 + $2);
        }
        if ($text =~ /on\s+([0-9]+)\s+servers?/i) {
            $set->('mediabot_network_servers', $1);
        }
    }
    elsif ($numeric eq '252') {
        my ($count) = grep { defined && /\A[0-9]+\z/ } @$args;
        $set->('mediabot_network_operators', $count);
    }
    elsif ($numeric eq '254') {
        my ($count) = grep { defined && /\A[0-9]+\z/ } @$args;
        $set->('mediabot_network_channels', $count);
    }
    elsif ($numeric eq '266') {
        # Preferred source for users: global current/max, either as numeric
        # args (current, max) or in the trailing text.
        my @nums = grep { defined && /\A[0-9]+\z/ } @$args;
        if (@nums >= 2) {
            $set->('mediabot_network_users',     $nums[0]);
            $set->('mediabot_network_users_max', $nums[1]);
        }
        elsif ($text =~ /global users[:\s]+([0-9]+)[,\s]+max[:\s]+([0-9]+)/i) {
            $set->('mediabot_network_users',     $1);
            $set->('mediabot_network_users_max', $2);
        }
    }

    # mb544-B1: les details du LUSERS en debug 3 — une ligne par numeric
    # ayant extrait quelque chose, avec les paires cle=valeur.
    if (%updated && $self->{logger}) {
        my $detail = join ' ', map {
            my $short = $_; $short =~ s/^mediabot_network_//;
            "$short=$updated{$_}";
        } sort keys %updated;
        $self->{logger}->log(3, "LUSERS $numeric: $detail");
    }

    return \%updated;
}

# mb544-B1: instantane du cache reseau (copie) pour la partyline et les
# integrations; updated_at = epoch de la derniere valeur recue.
sub network_stats {
    my ($self) = @_;
    my $stats = $self->{network_stats};
    return {} unless ref($stats) eq 'HASH';
    return { %$stats };
}

# mb544-B1: requete LUSERS immediate (commande operateur), sans throttle mais
# alignant le compteur pour que le refresh periodique reparte proprement.
sub request_lusers_now {
    my ($self) = @_;

    return 0 unless $self->{irc} && eval { $self->{irc}->is_connected };
    eval { $self->{irc}->send_message('LUSERS', undef); 1 } or return 0;
    # mb553-B1: only a successful send makes the cached network snapshot
    # eligible to age behind a new throttle window.
    $self->{network_lusers_last_request} = time();
    $self->{logger}->log(3, 'LUSERS refresh requested (partyline)') if $self->{logger};
    return 1;
}

# mb550-B1: event-loop stall detector. The periodic tick calls this with its
# expected interval; any drift beyond STALL_THRESHOLD means the loop was
# blocked (synchronous SQL, DNS, disk...) — log it loudly, count it, and keep
# the last stall for operator views. Catches freezes that never touch the
# PRIVMSG path. First call only arms the reference point.
use constant LOOP_STALL_THRESHOLD => 2;

sub note_tick_for_stall_detection {
    my ($self, $expected_interval) = @_;

    $expected_interval = 5
        unless defined $expected_interval && "$expected_interval" =~ /\A[0-9]+(?:\.[0-9]+)?\z/
            && $expected_interval > 0;

    my $now  = Time::HiRes::time();
    my $last = $self->{loop_last_tick_at};
    $self->{loop_last_tick_at} = $now;
    return 0 unless defined $last;

    my $drift = ($now - $last) - $expected_interval;
    return 0 if $drift <= LOOP_STALL_THRESHOLD;

    my $stall = sprintf('%.2f', $drift);
    $self->{loop_last_stall} = { at => int($now), seconds => 0 + $stall };
    $self->{logger}->log(1, "event loop stalled ~${stall}s (tick expected every ${expected_interval}s) — a synchronous operation blocked the bot")
        if $self->{logger};
    if ($self->{metrics} && eval { $self->{metrics}->can('inc') }) {
        eval { $self->{metrics}->inc('mediabot_loop_stalls_total'); 1 };
    }
    return 0 + $stall;
}

# mb550-B1: read-only copy of the last detected stall (for .status and tests).
sub last_loop_stall {
    my ($self) = @_;
    my $stall = $self->{loop_last_stall};
    return ref($stall) eq 'HASH' ? { %$stall } : undef;
}

# mb543-B1: periodic LUSERS refresh so the network gauges stay current after
# the connection burst. Called from the main tick (eval-guarded); throttled by
# main.LUSERS_REFRESH (seconds, default 300, bounded 60..3600, 0 disables).
sub maybe_request_lusers {
    my ($self) = @_;

    my $raw = eval { $self->{conf} ? $self->{conf}->get('main.LUSERS_REFRESH') : undef };
    my $interval = 300;
    if (defined $raw && !ref($raw) && "$raw" =~ /\A[0-9]+\z/) {
        $interval = int($raw);
    }
    return 0 if $interval == 0;
    $interval = 60   if $interval < 60;
    $interval = 3600 if $interval > 3600;

    return 0 unless $self->{irc} && eval { $self->{irc}->is_connected };

    my $now  = time();
    my $last = $self->{network_lusers_last_request} || 0;
    return 0 if ($now - $last) < $interval;

    eval { $self->{irc}->send_message('LUSERS', undef); 1 } or return 0;
    # mb553-B1: a connection race must leave the previous timestamp untouched
    # so the next tick can retry instead of serving stale data for a full window.
    $self->{network_lusers_last_request} = $now;
    $self->{logger}->log(3, 'LUSERS refresh requested') if $self->{logger};
    return 1;
}


# Register the first small batch of built-in public commands in the new
# CommandRegistry. mb166-B1 deliberately starts with low-risk core/help commands
# and keeps the historical dispatch table as fallback.
sub _register_builtin_public_core_commands {
    my ($self) = @_;

    return 1 if $self->{_builtin_public_core_commands_registered};

    my $registry = $self->commands;
    return 0 unless $registry;

    $registry->register_command(
        name        => 'version',
        source      => 'public',
        category    => 'core',
        description => 'Show Mediabot version information',
        handler     => sub {
            my ($ctx) = @_;
            versionCheck($ctx);
        },
    );

    $registry->register_command(
        name        => 'uptime',
        source      => 'public',
        category    => 'core',
        description => 'Show Mediabot uptime',
        handler     => sub {
            my ($ctx) = @_;
            mbUptime_ctx($ctx);
        },
    );

    $registry->register_command(
        name        => 'help',
        source      => 'public',
        category    => 'core',
        description => 'Show command help',
        handler     => sub {
            my ($ctx) = @_;
            mbHelp_ctx($ctx);
        },
    );

    $registry->register_command(
        name        => 'commands',
        source      => 'public',
        category    => 'core',
        description => 'List available commands',
        handler     => sub {
            my ($ctx) = @_;
            $ctx->{args} = [ 'commands' ];
            mbHelp_ctx($ctx);
        },
    );

    $self->{_builtin_public_core_commands_registered} = 1;
    return 1;
}


# Return the active command registry used by built-ins and plugin dispatch.
sub command_registry {
    my ($self) = @_;
    return $self->{command_registry};
}

# Short alias for command registry access.
sub commands {
    my ($self) = @_;
    return $self->{command_registry};
}



# Log info with timestamp
sub my_log_info {
    my ($self, $msg) = @_;
    my $ts = POSIX::strftime("[%d/%m/%Y %H:%M:%S]", localtime);
    print STDOUT "$ts [INFO] $msg\n";
}

# Log error with timestamp
sub my_log_error {
    my ($self, $msg) = @_;
    my $ts = POSIX::strftime("[%d/%m/%Y %H:%M:%S]", localtime);
    print STDERR "$ts [ERROR] $msg\n";
}

# Read the configuration file and populate the $self->{conf} object
sub readConfigFile {
    my ($self, $file) = @_;

    $file //= $self->{config_file}
        or croak "No config file specified (\$self->{config_file} is empty)";

    unless (-e $file) {
        $self->my_log_error("Config file '$file' does not exist");
        return;
    }
    unless (-r $file) {
        $self->my_log_error("Cannot read config file '$file'");
        return;
    }

    $self->my_log_info("Loading configuration from '$file'");

    my $conf;
    eval {
        require Mediabot::Conf;
        $conf = Mediabot::Conf->new(undef, $file);
    };
    if ($@ or not $conf) {
        $self->my_log_error("Failed to load configuration: $@");
        return;
    }

    $self->{conf} = $conf;

    $self->my_log_info("Configuration loaded successfully");
    return 1;
}

sub reload_logger_from_config {
    my ($self) = @_;

    my $conf = $self->{conf};
    unless ($conf) {
        $self->my_log_error("reload_logger_from_config() called without loaded config");
        return;
    }

    my $debug_level = $conf->get('main.MAIN_PROG_DEBUG');
    $debug_level = 0 unless defined $debug_level && $debug_level =~ /^\d+$/;

    my $log_path = $conf->get('main.MAIN_LOG_FILE');
    unless (defined $log_path && $log_path ne '') {
        $self->my_log_error("reload_logger_from_config() MAIN_LOG_FILE is empty");
        return;
    }

    # Reopen raw LOG handle used by some legacy code paths
    eval {
        if (defined $self->{LOG}) {
            my $oldfh = $self->{LOG};
            close $oldfh if defined(fileno($oldfh));
        }
        1;
    };

    open(my $LOG, ">>", $log_path) or do {
        $self->my_log_error("Could not reopen log file '$log_path': $!");
        return;
    };
    select((select($LOG), $| = 1)[0]);
    $self->{LOG} = $LOG;

    # Recreate object logger with fresh config values
    my $new_logger;
    eval {
        require Mediabot::Log;
        $new_logger = Mediabot::Log->new(
            debug_level => $debug_level,
            logfile     => $log_path,
        );
        1;
    } or do {
        my $err = $@ || 'unknown error';
        $self->my_log_error("Failed to recreate logger from config: $err");
        return;
    };
    
    if ($self->{logger} && $self->{logger}->{_console_hooks}) {
        $new_logger->{_console_hooks} = $self->{logger}->{_console_hooks};
    }
    
    $self->{logger} = $new_logger;
    $self->{logger}->log(1, "Logger reloaded from config (debug=$debug_level, logfile=$log_path)");

    return 1;
}

sub rebuild_channel_cache {
    my ($self) = @_;

    $self->{logger}->log(1, "Rebuilding channel cache from database");
    $self->{channels} = {};
    
    # Populate channels from DB
	$self->populateChannels();

	# Start per-channel nicklist refresh timers
	$self->setup_channel_nicklist_timers();

    my $count = scalar keys %{ $self->{channels} };
    $self->{logger}->log(1, "Channel cache rebuilt ($count channel objects)");

    return 1;
}

sub refresh_channel_nicklist {
    my ($self, $channel_name) = @_;
    return unless defined $channel_name && $channel_name ne '';

    unless ($self->{irc}) {
        $self->{logger}->log(4, "refresh_channel_nicklist() skipped for $channel_name: no IRC object");
        return;
    }

    $self->{logger}->log(4, "Refreshing nicklist for $channel_name via NAMES");
    eval {
        $self->{irc}->send_message('NAMES', undef, $channel_name);
        1;
    } or do {
        my $err = $@ || 'unknown error';
        $self->{logger}->log(1, "Failed to refresh nicklist for $channel_name: $err");
    };

    return 1;
}

sub stop_all_channel_nicklist_timers {
    my ($self) = @_;

    my $timers = $self->{channel_nicklist_timers} || {};
    foreach my $channel_name (keys %$timers) {
        my $timer = $timers->{$channel_name};
        next unless $timer;

        eval {
            if ($self->{loop}) {
                $self->{loop}->remove($timer);
            }
            $timer->stop if $timer->can('stop');
            1;
        };
    }

    $self->{channel_nicklist_timers} = {};
    $self->{logger}->log(1, "Stopped all channel nicklist timers");

    return 1;
}

sub stop_channel_nicklist_timer {
    my ($self, $channel_name) = @_;

    return unless defined $channel_name && $channel_name ne '';

    my $timer = $self->{channel_nicklist_timers}{$channel_name};
    return unless $timer;

    eval {
        if ($self->{loop}) {
            $self->{loop}->remove($timer);
        }
        $timer->stop if $timer->can('stop');
        1;
    } or do {
        my $err = $@ || 'unknown error';
        $self->{logger}->log(1, "Failed to stop nicklist timer for $channel_name: $err");
    };

    delete $self->{channel_nicklist_timers}{$channel_name};
    $self->{logger}->log(1, "Stopped nicklist timer for $channel_name");

    return 1;
}

sub setup_channel_nicklist_timers {
    my ($self) = @_;

    my $conf = $self->{conf};
    unless ($conf) {
        $self->{logger}->log(1, "setup_channel_nicklist_timers() called without config");
        return;
    }

    unless ($self->{loop}) {
        $self->{logger}->log(1, "setup_channel_nicklist_timers() called without IO::Async loop");
        return;
    }

    $self->stop_all_channel_nicklist_timers();

    my $interval = $conf->get('main.MAIN_CHANNEL_NICKLIST_REFRESH_INTERVAL');
    $interval = 300 unless defined $interval && $interval =~ /^\d+$/ && $interval > 0;

    foreach my $channel_name (sort keys %{ $self->{channels} || {} }) {
        my $channel_obj = $self->{channels}{lc $channel_name};
        next unless $channel_obj;

        my $timer = IO::Async::Timer::Periodic->new(
            interval => $interval,
            first_interval => $interval,
            on_tick => sub {
                $self->refresh_channel_nicklist($channel_name);
            },
        );

        $self->{loop}->add($timer);
        $timer->start;
        $self->{channel_nicklist_timers}{$channel_name} = $timer;

        $self->{logger}->log(1, "Started nicklist refresh timer for $channel_name (interval=${interval}s)");
    }

    my $count = scalar keys %{ $self->{channel_nicklist_timers} || {} };
    $self->{logger}->log(1, "Nicklist timer setup complete ($count timers)");

    return 1;
}

sub rehash_runtime_state {
    my ($self) = @_;

    if ($self->{metrics}) {
        $self->{metrics}->inc('mediabot_rehash_total');
    }

    my @done;

    unless ($self->readConfigFile()) {
        return;
    }
    push @done, 'config';

    unless ($self->reload_logger_from_config()) {
        return;
    }
    push @done, 'logger';

    # F4: update debug_level at runtime if logger supports it
    my $new_level = $self->{conf}->get('main.MAIN_PROG_DEBUG') // 0;
    if ($self->{logger} && $self->{logger}->can('set_level')) {
        $self->{logger}->set_level(int($new_level));
        $self->{logger}->log(2, "Rehash: debug_level updated to $new_level");
    }

    unless ($self->rebuild_channel_cache()) {
        return;
    }
    push @done, 'channels';

    $self->{logger}->log(1, "Rehash runtime state completed: " . join(', ', @done));
    return 1;
}
# ---------------------------------------------------------------------------
# restart_irc() - reconnect to IRC without killing the process
# The Partyline stays alive. Called from Partyline .restart command.
# ---------------------------------------------------------------------------
sub restart_irc {
    my ($self, %opts) = @_;

    my $reason = $opts{reason} // "Restarting IRC connection";
    my $server = $opts{server} // undef;   # optional jump target

    if ($self->{irc_restart_in_progress}) {
        $self->{logger}->log(1, "restart_irc(): restart already in progress, ignoring duplicate request");
        return 0;
    }

    $self->{irc_restart_in_progress} = 1;

    $self->{logger}->log(1, "restart_irc(): initiating IRC restart ($reason)");

    # Override server if jumping
    if (defined $server && $server ne '') {
        $self->{requested_server} = $server;
        $self->{logger}->log(1, "restart_irc(): will connect to $server after restart");
    }

    # This is NOT a final exit.
    $self->{Quit} = 0;

    if (my $pending = delete $self->{irc_reconnect_timer}) {
        my $loop = $self->can('getLoop') ? $self->getLoop : undef;
        eval {
            $pending->stop if $pending->can('stop');
            $loop->remove($pending) if $loop;
        };
    }

    # Ask for an IRC reconnect through the normal runtime path.
    # We do NOT stop the main loop and we do NOT tear down the Partyline.
    $self->{irc_reconnect_requested} = 1;

    $self->{logger}->log(0,
        "restart_irc(): flags set "
        . "restart_in_progress=" . ($self->{irc_restart_in_progress} // 'undef')
        . " reconnect_requested=" . ($self->{irc_reconnect_requested} // 'undef')
        . " reconnect_in_progress=" . ($self->{irc_reconnect_in_progress} // 'undef')
    );

    # Invalidate connection timestamp so the reconnect grace period does not block us.
    $self->setConnectionTimestamp(0) if $self->can('setConnectionTimestamp');

    # Best-effort QUIT.
    # Do not remove the IRC object from the loop immediately: that can prevent
    # the QUIT from being flushed and also defeats the goal of keeping the process alive cleanly.
    eval {
        if ($self->{irc} && $self->{irc}->is_connected) {
            $self->{irc}->send_message("QUIT", undef, $reason);
            $self->{logger}->log(0, "restart_irc(): QUIT sent (best effort)");
        }
        1;
    } or do {
        my $err = $@ || 'unknown error';
        $self->{logger}->log(1, "restart_irc(): QUIT send failed: $err");
    };

    if ($self->{metrics}) {
        $self->{metrics}->inc('mediabot_restart_total');
    }

    $self->{logger}->log(1, "restart_irc(): reconnect requested - Partyline remains active");

    return 1;
}

# get debug level from configuration
sub getDebugLevel {
	my $self = shift;
	return $self->{conf}->get('main.MAIN_PROG_DEBUG');
}

# Get the log file path from the configuration
sub getLogFile {
	my $self = shift;
	return $self->{conf}->get('main.MAIN_LOG_FILE');
}

# Dump the configuration to STDERR
sub dumpConfig {
    my ($self) = @_;

    my %conf = $self->{conf}->all;
    return unless %conf;

    print STDERR "\e[1m=== Mediabot configuration dump ===\e[0m\n";

    foreach my $key (sort keys %conf) {
        my $val = $conf{$key};

        # Formattage section.clé en deux parties si souhaité
        if ($key =~ /^(.+?)\.(.+)$/) {
            my ($section, $subkey) = ($1, $2);
            printf STDERR "  \e[1;36m[%s]\e[0m \e[1;33m%-18s\e[0m : %s\n", $section, $subkey, _format_val($val);
        } else {
            printf STDERR "  \e[1;34m%-20s\e[0m : %s\n", $key, _format_val($val);
        }
    }

    print STDERR "\n\e[1m===================================\e[0m\n";
}

# Format a single value with color
sub _format_val {
    my ($val) = @_;
    return "\e[31m(undef)\e[0m" unless defined $val;
    return "\e[33m[empty]\e[0m" if $val eq '';
    return "\e[32m$val\e[0m";
}

# Get the main configuration object
sub getMainConfCfg {
    my $self = shift;
    return $self->{conf};
}

# Get pid file path from configuration
sub getPidFile {
	my $self = shift;
	return $self->{conf}->get('main.MAIN_PID_FILE');
}

# MB390-B1: acquire and retain an advisory PID lock for the whole process
# lifetime.  ProcessLock also recognises legacy live PID files that predate the
# lock protocol.
sub acquirePidFile {
    my ($self) = @_;
    return 1 if $self->{pid_file_lock};

    my $lock = Mediabot::ProcessLock->new(
        path => $self->getPidFile(),
        pid  => $$,
    );

    unless ($lock->acquire()) {
        my $error = $lock->error() // 'unknown PID lock error';
        $self->{logger}->log(0, "Failed to acquire PID file: $error");
        return 0;
    }

    $self->{pid_file_lock} = $lock;
    return 1;
}

# Historical public name retained for callers outside the main program.
sub writePidFile {
    my ($self) = @_;
    return $self->acquirePidFile();
}

sub releasePidFile {
    my ($self) = @_;
    my $lock = delete $self->{pid_file_lock};
    return 1 unless $lock;

    unless ($lock->release()) {
        my $error = $lock->error() // 'unknown PID release error';
        $self->{logger}->log(1, "Failed to release PID file: $error")
            if $self->{logger};
        return 0;
    }

    return 1;
}

# Get PID from the PID file
sub getPidFromFile {
    my $self = shift;
    my $pidfile = $self->{conf}->get('main.MAIN_PID_FILE');

    my $fh_pid;
    unless (open $fh_pid, '<', $pidfile) {
        return undef;
    }
    my $line;
    if (defined($line = <$fh_pid>)) {
        chomp($line);
        close $fh_pid;
        return $line;
    }
    else {
        $self->{logger}->log(1, "getPidFromFile() couldn't read PID from $pidfile");
        close $fh_pid;
        return undef;
    }
}

# Initialize the log file for Mediabot
sub init_log {
    my ($self) = @_;

    my $log_path = $self->{conf}->get('main.MAIN_LOG_FILE');
    unless (defined $log_path && $log_path ne '') {
        print STDERR "[ERROR] Log file path not defined in config.\n";
        clean_and_exit($self, 1);
    }

    open(my $LOG, ">>", $log_path) or do {
        print STDERR "[ERROR] Could not open log file '$log_path' for writing: $!\n";
        clean_and_exit($self, 1);
    };

    # Autoflush enabled
    select((select($LOG), $| = 1)[0]);

    # Optional: timestamp or header
    print $LOG "+--------------------------------------------------------------------------------+\n";
    print $LOG "| Mediabot log started at " . scalar(localtime) . "\n";
    print $LOG "+--------------------------------------------------------------------------------+\n";

    # Store filehandle in object
    $self->{LOG} = $LOG;
}


# Populate the channels from the database and create Channel objects
sub populateChannels {
    my ($self) = @_;

    $self->{logger}->log( 3, "populateChannels: Populating channels from database");

    my $sQuery = "SELECT id_channel, name, description, topic, tmdb_lang, `key`, auto_join FROM CHANNEL";
    my $sth = $self->{dbh}->prepare($sQuery);
    unless ($sth && $sth->execute()) {
        $self->{logger}->log( 1, "SQL Error: " . $DBI::errstr . " Query: $sQuery");
        $sth->finish if $sth;
        return;
    }

    my $i = 0;
    while (my $ref = $sth->fetchrow_hashref()) {
        $i++ == 0 and $self->{logger}->log( 0, "Populating channel objects");

        my $channel_obj = Mediabot::Channel->new({
            id          => $ref->{id_channel},
            name        => $ref->{name},
            description => $ref->{description},
            topic       => $ref->{topic},
            tmdb_lang   => $ref->{tmdb_lang},
            key         => $ref->{key},
            dbh         => $self->{dbh},
            irc         => $self->{irc},
            logger      => $self->{logger},
            auto_join   => $ref->{auto_join},
        });

        # mb407-B1: clé CANONIQUE lc — un canal ajouté en live (chanadd, déjà lc)
        # et le même canal rechargé au restart doivent partager LA MÊME clé, et
        # les lookups par nom reçu d'IRC/utilisateur (casse libre, wrappés lc)
        # doivent toujours le trouver. Le nom d'affichage canonique reste dans
        # l'objet (get_name).
        $self->{channels}{ lc($ref->{name}) } = $channel_obj;
    }

    $sth->finish;

    if ($i == 0) {
        $self->{logger}->log( 0, "No channel found in database.");
    }
}

# Clean up resources and exit the program with the given return value
sub clean_and_exit {
    my ($self, $iRetValue) = @_;
    $iRetValue = 0 unless defined $iRetValue;

    # Re-entrance guard without 'state'
    if ($ALREADY_EXITING) { CORE::exit($iRetValue); }
    $ALREADY_EXITING = 1;

    # Log if possible (best-effort)
    eval {
        $self->{logger}->log(1, "Cleaning and exiting...")
            if $self->{logger} && $self->{logger}->can('log');
        1;
    };

    # --- Graceful IRC QUIT via Net::Async::IRC ---
    eval {
        my $irc = $self->{irc};
        if ($irc) {
            my $quit_msg = "Mediabot shutting down";
            if ($self->{conf} && $self->{conf}->can('get')) {
                my $cfg = eval { $self->{conf}->get('main.MAIN_PROG_QUIT_MSG') };
                $quit_msg = $cfg if defined($cfg) && $cfg ne '';
            }
            $irc->can('do_QUIT') ? $irc->do_QUIT( reason => $quit_msg )
                                 : 0;
        }
        1;
    };

    # --- mb120-B2: flush des achievements avant le shutdown ---
    # Le save() est habituellement debounce 10s — sans flush forcé au shutdown,
    # les unlocks récents (< 10s avant le SIGTERM) seraient perdus.
    eval {
        if ($self->{achievements} && $self->{achievements}->can('save')) {
            $self->{achievements}->save(1);   # force = bypass debounce
            $self->{logger}->log(3, "Achievements: final save() before exit")
                if $self->{logger} && $self->{logger}->can('log');
        }
        1;
    };

    # --- DB: safe disconnect ---
    eval {
        if (defined $self->{dbh} && $self->{dbh}) {
            if ($iRetValue != 1146) { } # keep original no-op
            my $dbh = $self->{dbh};
            if (ref($dbh) && eval { $dbh->{Active} }) {
                eval { $dbh->disconnect(); 1 };
            }
        }
        1;
    };

    # --- MB390-B1: release the process-lifetime PID lock and remove only
    # the PID file still owned by this process. ---
    eval {
        $self->releasePidFile() if $self->can('releasePidFile');
        1;
    };

    # --- Raw LOG filehandle: safe close ---
    eval {
        if (defined $self->{LOG}) {
            my $fh = $self->{LOG};
            if (defined(fileno($fh))) {
                eval { local $| = 1; 1; }; # opportunistic flush
                close $fh;
            }
        }
        1;
    };

    # --- Flush object logger if available ---
    eval {
        $self->{logger}->flush()
            if $self->{logger} && $self->{logger}->can('flush');
        1;
    };

    CORE::exit($iRetValue);
}


# Connect to the database
sub dbConnect {
    my ($self) = @_;
    my $conf = $self->{conf};
    my $LOG  = $self->{LOG};

    my $dbname = $conf->get('mysql.MAIN_PROG_DDBNAME');
    my $dbhost = $conf->get('mysql.MAIN_PROG_DBHOST') // 'localhost';
    my $dbport = $conf->get('mysql.MAIN_PROG_DBPORT') // 3306;
    my $dbuser = $conf->get('mysql.MAIN_PROG_DBUSER');
    my $dbpass = $conf->get('mysql.MAIN_PROG_DBPASS');

    my $connectionInfo = "DBI:MariaDB:database=$dbname;host=$dbhost;port=$dbport";

    $self->{logger}->log( 1, "dbConnect() Connecting to Database: $dbname");

    my $dbh;
    unless ($dbh = DBI->connect($connectionInfo, $dbuser, $dbpass, { RaiseError => 0, PrintError => 0 })) {
        $self->{logger}->log( 0, "dbConnect() DBI Error: " . $DBI::errstr);
        $self->{logger}->log( 0, "dbConnect() DBI Native error code: " . ($DBI::err // 'undef'));
        clean_and_exit($self, 3) if defined $DBI::err;
    }

    $dbh->{mariadb_auto_reconnect} = 1;
    $self->{logger}->log( 1, "dbConnect() Connected to $dbname.");

    foreach my $sql (
        "SET NAMES 'utf8'",
        "SET CHARACTER SET utf8",
        "SET COLLATION_CONNECTION = 'utf8_general_ci'"
    ) {
        my $sth = $dbh->prepare($sql);
        unless ($sth && $sth->execute()) {
            $self->{logger}->log( 1, "dbConnect() SQL Error: $DBI::errstr Query: $sql");
        }
        $sth->finish;
    }

    $self->{dbh} = $dbh;
}

# Get the database handle
sub getDbh {
	my $self = shift;
	return $self->{dbh};
}

# Check if the USER table exists in the database
sub dbCheckTables {
    my ($self) = shift;
    my $LOG = $self->{LOG};
    my $dbh = $self->{dbh};

    $self->{logger}->log(4, "Checking database schema");

    unless (defined $dbh) {
 $self->{logger}->log(0, " No DBI handle found (dbh is undef). Aborting DB check.");
        $self->{logger}->log(0, "Check your database credentials in mediabot.conf and ensure the user has proper access.");
        clean_and_exit($self, 1);
    }

    # Check USER table exists
    my $sth = $dbh->prepare("SELECT 1 FROM USER LIMIT 1");
    unless ($sth && $sth->execute) {
        $self->{logger}->log(0, "dbCheckTables() SQL Error: $DBI::errstr ($DBI::err)");
        if (defined($DBI::err) && $DBI::err == 1146) {
            $self->{logger}->log(0, "USER table does not exist. Check your database installation.");
            clean_and_exit($self, 1146);
        }
    }
    else {
        $self->{logger}->log(4, "USER table exists");
    }
    $sth->finish;

    # Check USER_HOSTMASK table exists - required since schema migration
    # If missing, the bot cannot match user hostmasks and auth will be broken.
    my $hm_sth = $dbh->prepare(
        "SELECT 1 FROM INFORMATION_SCHEMA.TABLES " .
        "WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'USER_HOSTMASK' LIMIT 1"
    );
    $hm_sth->execute;
    my $hm_exists = $hm_sth->fetchrow_arrayref;
    $hm_sth->finish;

    unless ($hm_exists) {
        $self->{logger}->log(0, "");
 $self->{logger}->log(0, "" x 65);
        $self->{logger}->log(0, "  DATABASE MIGRATION REQUIRED");
 $self->{logger}->log(0, "" x 65);
        $self->{logger}->log(0, "  The USER_HOSTMASK table is missing.");
        $self->{logger}->log(0, "  Your database schema needs to be migrated before");
        $self->{logger}->log(0, "  the bot can start.");
        $self->{logger}->log(0, "");
        $self->{logger}->log(0, "  Run as root:");
        $self->{logger}->log(0, "    sudo ./install/db_migrate.sh -c mediabot.conf");
 $self->{logger}->log(0, "" x 65);
        $self->{logger}->log(0, "");
        clean_and_exit($self, 1);
    }

    $self->{logger}->log(4, "USER_HOSTMASK table exists - schema OK");

    # Check USER.hostmasks column is gone (renamed to hostmasks_legacy)
    # This is a soft warning only - the bot can still run.
    my $col_sth = $dbh->prepare(
        "SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS " .
        "WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'USER' AND COLUMN_NAME = 'hostmasks' LIMIT 1"
    );
    $col_sth->execute;
    if ($col_sth->fetchrow_arrayref) {
 $self->{logger}->log(0, " USER.hostmasks column still present (not yet renamed to hostmasks_legacy).");
        $self->{logger}->log(0, "  Run sudo ./install/db_migrate.sh -c mediabot.conf to complete migration.");
    }
    $col_sth->finish;
}

# Set the server hostname
sub setServer {
	my ($self, $sServer) = @_;
	$self->{requested_server} = $sServer;
	$self->{server} = $sServer;
}

sub getRequestedServer {
    my ($self) = @_;
    return $self->{requested_server};
}

sub getServerSource {
    my ($self) = @_;
    return $self->{server_source};
}

sub getNetworkName {
    my ($self) = @_;
    return $self->{network_name};
}

sub getServerHostPort {
    my ($self) = @_;
    return ($self->{server_hostname}, $self->{server_port});
}

# Pick a server from the database based on the configured network
sub pickServer {
    my ($self) = @_;
    my $conf = $self->{conf};
    my $dbh  = $self->{dbh};

    $self->{network_name}  = undef;
    $self->{server_source} = undef;

    my $requested_server = $self->{requested_server};

    if (!defined($requested_server) || $requested_server eq "") {
        my $network_name = $conf->get('connection.CONN_SERVER_NETWORK');
        $self->{network_name} = $network_name;

        unless ($network_name) {
            $self->{logger}->log(0, "No CONN_SERVER_NETWORK defined in $self->{config_file}");
            _log_configure_hint($self);
            clean_and_exit($self, 4);
        }

        my $count_query = "
            SELECT COUNT(*) AS server_count
            FROM NETWORK
            JOIN SERVERS ON SERVERS.id_network = NETWORK.id_network
            WHERE NETWORK.network_name = ?
        ";
        my $sth_count = $dbh->prepare($count_query);

        if ($sth_count && $sth_count->execute($network_name)) {
            my $count_ref = $sth_count->fetchrow_hashref();
            $sth_count->finish;

            my $server_count = int($count_ref->{server_count} // 0);

            if ($server_count > 0) {
                my $offset = int(rand($server_count));

                my $sQuery = "
                    SELECT SERVERS.server_hostname
                    FROM NETWORK
                    JOIN SERVERS ON SERVERS.id_network = NETWORK.id_network
                    WHERE NETWORK.network_name = ?
                    ORDER BY SERVERS.id_server
                    LIMIT 1 OFFSET $offset
                ";
                my $sth = $dbh->prepare($sQuery);

                if ($sth && $sth->execute($network_name)) {
                    if (my $ref = $sth->fetchrow_hashref()) {
                        $self->{server} = $ref->{server_hostname};
                        $self->{server_source} = 'network-db';
                    }
                    $sth->finish;
                } else {
                    $self->{logger}->log(0, "Startup select SERVER, SQL Error: " . $DBI::errstr . " Query: " . $sQuery);
                }
            }
        }
        else {
            $self->{logger}->log(0, "Startup count SERVER, SQL Error: " . $DBI::errstr . " Query: " . $count_query);
        }

        unless ($self->{server}) {
            $self->{logger}->log(0, "No server found for network $network_name defined in $self->{config_file}");
            _log_configure_hint($self);
            clean_and_exit($self, 4);
        }

        $self->{logger}->log(1, "Picked $self->{server} from network '$network_name'");
    } else {
        $self->{server} = $requested_server;
        $self->{server_source} = 'requested-server';
        $self->{network_name} = $conf->get('connection.CONN_SERVER_NETWORK');

        $self->{logger}->log(1, "Picked $self->{server} from requested server override");
    }

    # Parse hostname[:port]
    if ($self->{server} =~ /:/) {
        ($self->{server_hostname}, $self->{server_port}) = split(/:/, $self->{server}, 2);
    } else {
        $self->{server_hostname} = $self->{server};
        $self->{server_port} = 6667;
    }

    $self->{logger}->log(
        4,
        "Using host $self->{server_hostname}, port $self->{server_port}, source=$self->{server_source}, network=" .
        (defined $self->{network_name} ? $self->{network_name} : '<undef>')
    );
}

# Log a hint to run ./configure if no server is set
sub _log_configure_hint {
    my ($self) = @_;
    $self->{logger}->log(1, "Run ./configure at first use or ./configure -s to set it properly");
}

# Get server hostname 
sub getServerHostname {
	my $self = shift;
	return $self->{server_hostname};
}

# Get server port
sub getServerPort {
	my $self = shift;
	return $self->{server_port};
}

# Set loop
sub setLoop {
	my ($self,$loop) = @_;
	$self->{loop} = $loop;
}

# Get loop
sub getLoop {
	my $self = shift;
	return $self->{loop};
}

# Refresh channel information from the database and update the Channel objects
sub refresh_channel_hashes {
    my ($self) = @_;

    $self->{logger}->log(4, "Refreshing channel information from database");

    my $sQuery = "SELECT name, description, topic, tmdb_lang, `key` FROM CHANNEL";
    my $sth = $self->{dbh}->prepare($sQuery);
    unless ($sth && $sth->execute()) {
        $self->{logger}->log(1, "SQL Error: " . $DBI::errstr . " Query: $sQuery");
        $sth->finish if $sth;
        return;
    }

    my %db_info;
    while (my $ref = $sth->fetchrow_hashref()) {
        next unless defined $ref->{name};
        # mb482-B1: {channels} is keyed by lc(channel) since mb407.  Refresh
        # must case-fold the DB side as well, otherwise a row stored as
        # "#Glamour" is loaded at boot but reported every minute as missing
        # when the in-memory key is "#glamour".
        $db_info{ lc($ref->{name}) } = $ref;
    }
    $sth->finish;

    foreach my $chan_name (keys %{ $self->{channels} }) {
        my $chan_key = lc($chan_name);
        # mb407 guard: keep lc() visible inside the {channels} lookup itself.
        # $chan_name comes from keys (already canonical), so lc is a no-op here,
        # but the convention forbids a bare {channels}{$var} lookup.
        my $chan_obj = $self->{channels}{lc $chan_name};

        if (exists $db_info{$chan_key}) {
            my $ref = $db_info{$chan_key};

            # fields to update
            $chan_obj->{description} = $ref->{description};
            $chan_obj->{topic}       = $ref->{topic};
            $chan_obj->{tmdb_lang}   = $ref->{tmdb_lang};
            $chan_obj->{key}         = $ref->{key};

            $self->{logger}->log(4, "Refreshed data for $chan_name");
        } else {
            $self->{logger}->log(1, "Channel $chan_name not found in DB during refresh");
        }
    }
}

# Set IRC object
sub setIrc {
	my ($self,$irc) = @_;
	$self->{irc} = $irc;
}

# Get IRC object
sub getIrc {
	my $self = shift;
	return $self->{irc};
}

# Get connection nick
sub getConnectionNick {
	my $self = shift;
	my $conf = $self->{conf};

	my $sConnectionNick = $conf->get('connection.CONN_NICK');
	my $network_type    = $conf->get('connection.CONN_NETWORK_TYPE');
	my $usermode        = $conf->get('connection.CONN_USERMODE');

	if (defined($network_type) && $network_type == 1 && defined($usermode) && $usermode =~ /x/) {
		my @chars = ("A".."Z", "a".."z");
		my $string;
		$string .= $chars[rand @chars] for 1..8;
		$sConnectionNick = $string . (int(rand(100)) + 10);
	}

	$self->{logger}->log( 0, "Connection nick: $sConnectionNick");
	return $sConnectionNick;
}

# Get server password
sub getServerPass {
	my $self = shift;
	my $conf = $self->{conf};
	return $conf->get('connection.CONN_PASS') // "";
}

# Get nick trigger status
sub getNickTrigger {
	my $self = shift;
	my $conf = $self->{conf};
	return $conf->get('main.NICK_TRIGGER') // 0;
}

# Get IRC username from configuration
sub getIrcName {
	my $self = shift;
	my $conf = $self->{conf};
	return $conf->get('connection.CONN_IRCNAME');
}

# Get nick info from a message
sub getMessageNickIdentHost {
	my ($self,$message) = @_;
	my $sNick = $message->prefix;
	$sNick =~ s/!.*$//;
	my $sIdent = $message->prefix;
	$sIdent =~ s/^.*!//;
	$sIdent =~ s/@.*$//;
	my $sHost = $message->prefix;
	$sHost =~ s/^.*@//;
	return ($sNick,$sIdent,$sHost);
}

# DEPRECATED: use $self->{channels}{lc $name}->get_id instead
sub joinChannels {
    my ($self) = @_;

    my @channels = sort {
        (($a->get_name // '') cmp ($b->get_name // ''))
    } grep {
        $_->get_auto_join && (($_->get_description // '') ne 'console')
    } values %{ $self->{channels} // {} };

    if (!@channels) {
        $self->{logger}->log(0, "No channel to auto join");
        return;
    }

    $self->{logger}->log(0, "Auto join channels");

    my $loop = eval { $self->getLoop } // undef;

    # NS3: avoid a JOIN burst after reconnect/netsplit.
    # Keep timer refs so Countdown timers are not garbage-collected.
    for my $old (@{ delete $self->{_join_timers} // [] }) {
        eval { $old->stop if $old->can('stop') };
        eval { $loop->remove($old) if $loop };
    }
    for my $old (@{ delete $self->{_join_who_timers} // [] }) {
        eval { $old->stop if $old->can('stop') };
        eval { $loop->remove($old) if $loop };
    }

    $self->{_join_timers}     = [];
    $self->{_join_who_timers} = [];

    my $join_step = 1.5;
    my $who_delay = 3;

    for my $idx (0 .. $#channels) {
        my $chan = $channels[$idx];
        my $name = $chan->get_name;
        my $key  = $chan->get_key;

        if ($self->{metrics}) {
            $self->{metrics}->set('mediabot_channel_autojoin', 1, { channel => $name });
        }

        my $do_join = sub {
            return unless $self->{irc};

            joinChannel($self, $name, $key);
            $self->{logger}->log(2, "NS3: joining channel $name (throttled)");

            $self->{metrics}->inc('mediabot_netsplit_rejoins_total', { channel => $name })
                if $self->{metrics};

            # NS4: refresh nicklist quickly after JOIN instead of waiting for
            # the periodic nicklist refresh interval.
            if ($loop) {
                my $who_timer;
                $who_timer = IO::Async::Timer::Countdown->new(
                    delay => $who_delay,
                    on_expire => sub {
                        eval {
                            $self->{irc}->send_message('WHO', undef, $name)
                                if $self->{irc} && $self->{irc}->is_connected;
                        };
                        $self->{logger}->log(4, "NS4: WHO requested for $name after JOIN")
                            if $self->{logger};
                        @{ $self->{_join_who_timers} // [] } =
                            grep { $_ != $who_timer } @{ $self->{_join_who_timers} // [] };
                        # mb326-B1: retirer du loop et rompre le cycle closure<->timer.
                        # on_expire ne retirait pas le Countdown firé du loop (il y
                        # restait inerte) et la closure capturait $who_timer ->
                        # double rétention (loop + cycle) jamais libérée. Le nettoyage
                        # NS3 en tête de routine ne les voit plus (auto-retirés du
                        # tableau ci-dessus), d'où accumulation sur un bot long-running.
                        eval { $loop->remove($who_timer) } if $loop;
                        undef $who_timer;
                    },
                );
                push @{ $self->{_join_who_timers} }, $who_timer;
                $loop->add($who_timer);
                $who_timer->start;
            }
        };

        my $delay = $idx * $join_step;

        if ($loop && $delay > 0) {
            my $timer;
            $timer = IO::Async::Timer::Countdown->new(
                delay => $delay,
                on_expire => sub {
                    $do_join->();
                    @{ $self->{_join_timers} // [] } =
                        grep { $_ != $timer } @{ $self->{_join_timers} // [] };
                    # mb326-B1: même correctif que les WHO timers — retirer du loop
                    # et rompre le cycle closure<->timer pour éviter la fuite.
                    eval { $loop->remove($timer) } if $loop;
                    undef $timer;
                },
            );
            push @{ $self->{_join_timers} }, $timer;
            $loop->add($timer);
            $timer->start;

            $self->{logger}->log(2, sprintf("NS3: scheduled JOIN %s in %.1fs", $name, $delay));
        }
        else {
            $do_join->();
        }
    }
}

# mb86-R1: _dispatch_radio — sous-handler centralisé pour toutes les commandes radio
# Évite de dupliquer 17 entrées sub { handler($ctx) } dans la dispatch table.
sub _dispatch_radio {
    my ($ctx, $cmd) = @_;
    my %radio_map = (
        song            => \&song_ctx,
        radiostatus     => \&radioStatus_ctx,
        radiomounts     => \&radioMounts_ctx,
        listeners       => \&displayRadioListeners_ctx,
        nextsong        => \&radioNext_ctx,
        play            => \&radioPlay_ctx,
        radioimport     => \&radioImport_ctx,
        radioimportdir  => \&radioImportDir_ctx,
        radioqueue      => \&radioQueue_ctx,
        radiocheck      => \&radioCheck_ctx,
        radiocache      => \&radioCache_ctx,
        radiocacheprune => \&radioCachePrune_ctx,
        radiodlstatus   => \&radioDlStatus_ctx,
        radiodlcancel   => \&radioDlCancel_ctx,
        radiopush       => \&radioPush_ctx,
        radioskip       => \&radioSkip_ctx,
        radioflush      => \&radioFlush_ctx,
    );
    my $handler = $radio_map{$cmd};
    return $handler->($ctx) if $handler;
}

# Handle public commands
sub mbCommandPublic {
    my ($self, $message, $sChannel, $sNick, $botNickTriggered, $sCommand, @tArgs) = @_;

    # AF4: global per-channel rate limit — all nicks combined
    return if checkChanFlood($self, $sChannel);
    # Per-nick flood protection (AF2: notify, AF3: sliding window)
    return if checkNickFlood($self, $sNick, $sChannel);

    # Normalize command once
    my $cmd = lc $sCommand;

    # DD2: per-command invocation counter
    $self->{metrics}->inc_label('mediabot_command_total', $cmd)
        if $self->{metrics} && $self->{metrics}->can('inc_label');

    # CC1: per-command cooldown for expensive commands
    {
        my $wait = checkCmdCooldown($self, $sChannel, $cmd);
        if ($wait > 0) {
            # IMP11: human-readable wait time
            my $wait_str = $wait >= 60
                ? do { my $m = int($wait/60); my $s = $wait%60;
                       $s ? "${m}m ${s}s" : "${m}m"; }
                : "${wait}s";
            botNotice($self, $sNick,
                "!$cmd is cooling down on $sChannel — wait $wait_str.");
            return;
        }
    }

    # Build Context once for all handlers
    my $ctx = Mediabot::Context->new(
        bot     => $self,
        message => $message,
        nick    => $sNick,
        channel => $sChannel,
        command => $cmd,
        args    => \@tArgs,
    );

    # Attach a Command object to the Context for handlers that want it
    $ctx->{command_obj} = Mediabot::Command->new(
        name    => $cmd,
        args    => \@tArgs,
        raw     => join(" ", $sCommand, @tArgs),
        context => $ctx,
        source  => 'public',
    );

    # mb168-B1: first low-risk EventBus integration point. This only observes
    # public commands after Context/Command construction; with no listeners it
    # is a no-op, and listener failures are reported but never break dispatch.
    $self->emit_event_report('public_command_observed', $ctx);

    my $scriptdryrun_handled = eval { $ctx->{scriptdryrun_handled} } ? 1 : 0;

    if ($self->{metrics} && defined $cmd && length $cmd) {
        $self->{metrics}->inc(
            'mediabot_commands_public_total',
            { command => $cmd }
        );

        if (defined $sChannel && $sChannel =~ /^#/) {
            $self->{metrics}->inc(
                'mediabot_channel_commands_total',
                { channel => $sChannel }
            );

            $self->{metrics}->inc(
                'mediabot_channel_commands_by_name_total',
                { channel => $sChannel, command => $cmd }
            );
        }
    }

    if ($scriptdryrun_handled) {
        $self->{logger}->log(4, "PUBLIC(scriptdryrun): $sNick triggered $sCommand on $sChannel")
            if $self->{logger};
        return;
    }

    # ---------------------------------------------------------------------------
    # Command dispatch table
    # All handlers receive a Mediabot::Context object
    # ---------------------------------------------------------------------------
    my %command_map = (
        die          => sub { mbQuit_ctx($ctx) },
        nick         => sub { mbChangeNick_ctx($ctx) },
        addtimer     => sub { mbAddTimer_ctx($ctx) },
        remtimer     => sub { mbRemTimer_ctx($ctx) },
        timers       => sub { mbTimers_ctx($ctx) },
        msg          => sub { msgCmd_ctx($ctx) },
        say          => sub { sayChannel_ctx($ctx) },
        act          => sub { actChannel_ctx($ctx) },
        cstat        => sub { userCstat_ctx($ctx) },
        status       => sub { mbStatus_ctx($ctx) },
        echo         => sub { mbEcho($ctx) },
        adduser      => sub { addUser_ctx($ctx) },
        useradd      => sub { addUser_ctx($ctx) }, # legacy alias
        deluser      => sub { delUser_ctx($ctx) },
        users        => sub { userStats_ctx($ctx) },
        userinfo     => sub { userInfo_ctx($ctx) },
        addhost      => sub { addUserHost_ctx($ctx) },
        addchan      => sub { addChannel_ctx($ctx) },
        chanset      => sub { channelSet_ctx($ctx) },
        purge        => sub { purgeChannel_ctx($ctx) },
        part         => sub { channelPart_ctx($ctx) },
        join         => sub { channelJoin_ctx($ctx) },
        add          => sub { channelAddUser_ctx($ctx) },
        del          => sub { channelDelUser_ctx($ctx) },
        modinfo      => sub { userModinfo_ctx($ctx) },
        op           => sub { userOpChannel_ctx($ctx) },
        deop         => sub { userDeopChannel_ctx($ctx) },
        invite       => sub { userInviteChannel_ctx($ctx) },
        voice        => sub { userVoiceChannel_ctx($ctx) },
        devoice      => sub { userDevoiceChannel_ctx($ctx) },
        kick         => sub { userKickChannel_ctx($ctx) },
        ban          => sub { channelBan_ctx($ctx) },
        kickban      => sub { channelKickBan_ctx($ctx) },
        kb           => sub { channelKickBan_ctx($ctx) },
        unban        => sub { channelUnban_ctx($ctx) },
        bans         => sub { channelBans_ctx($ctx) },
        showcommands => sub { userShowcommandsChannel_ctx($ctx) },
        chaninfo     => sub { userChannelInfo_ctx($ctx) },
        chanlist     => sub { channelList_ctx($ctx) },
        channels     => sub { channelList_ctx($ctx) },
        channellist  => sub { channelList_ctx($ctx) },
        whoami       => sub { userWhoAmI_ctx($ctx) },
        auth         => sub { userAuthNick_ctx($ctx) },
        verify       => sub { userVerifyNick_ctx($ctx) },
        access       => sub { userAccessChannel_ctx($ctx) },
        addcmd       => sub { mbDbAddCommand_ctx($ctx) },
        remcmd       => sub { mbDbRemCommand_ctx($ctx) },
        modcmd       => sub { mbDbModCommand_ctx($ctx) },
        mvcmd        => sub { mbDbMvCommand_ctx($ctx) },
        chowncmd     => sub { mbChownCommand_ctx($ctx) },
        showcmd      => sub { mbDbShowCommand_ctx($ctx) },
        chanstatlines => sub { channelStatLines_ctx($ctx) },
        whotalk      => sub { whoTalk_ctx($ctx) },
        whotalks     => sub { whoTalk_ctx($ctx) },
        countcmd     => sub { mbCountCommand_ctx($ctx) },
        topcmd       => sub { mbTopCommand_ctx($ctx) },
        popcmd       => sub { mbPopCommand_ctx($ctx) },
        searchcmd    => sub { mbDbSearchCommand_ctx($ctx) },
        lastcmd      => sub { mbLastCommand_ctx($ctx) },
        owncmd       => sub { mbDbOwnersCommand_ctx($ctx) },
        holdcmd      => sub { mbDbHoldCommand_ctx($ctx) },
        addcatcmd    => sub { mbDbAddCategoryCommand_ctx($ctx) },
        chcatcmd     => sub { mbDbChangeCategoryCommand_ctx($ctx) },
        topsay       => sub { userTopSay_ctx($ctx) },
        checkhostchan => sub { mbDbCheckHostnameNickChan_ctx($ctx) },
        checkhost    => sub { mbDbCheckHostnameNick_ctx($ctx) },
        checknick    => sub { mbDbCheckNickHostname_ctx($ctx) },
        greet        => sub { userGreet_ctx($ctx) },
        nicklist     => sub { channelNickList_ctx($ctx) },
        rnick        => sub { randomChannelNick_ctx($ctx) },
        birthdate    => sub { displayBirthDate_ctx($ctx) },
        colors       => sub { mbColors_ctx($ctx) },
        seen         => sub { mbSeen_ctx($ctx) },
        stats        => sub { mbStats_ctx($ctx) },
        top          => sub { mbTop_ctx($ctx) },
        calc         => sub { mbCalc_ctx($ctx) },
        convert      => sub { mbConvert_ctx($ctx) },     # mb479: unit conversion
        '8ball'      => sub { mb8ball_ctx($ctx) },
        remind       => sub {
            my @a = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();
            if (@a && lc($a[0]) eq 'cancel') {
                shift @{ $ctx->args };
                mbRemindCancel_ctx($ctx);
            } else { mbRemind_ctx($ctx) }
        },
        remindlist   => sub { mbRemindList_ctx($ctx) },
        tell         => sub { mbRemind_ctx($ctx) },   # mb474: leave a message, delivered when the target returns
        calclast     => sub { mbCalcLast_ctx($ctx) },
        wordcount    => sub { mbWordCount_ctx($ctx) },
        alias        => sub { mbAlias_ctx($ctx) },
        streak       => sub { mbStreak_ctx($ctx) },
        slap         => sub { mbSlap_ctx($ctx) },
        karma        => sub { mbKarma_ctx($ctx) },
        karmatop     => sub { mbKarmaTop_ctx($ctx) },
        karmareset   => sub { mbKarmaReset_ctx($ctx) },
        karmadiff    => sub { mbKarmaDiff_ctx($ctx) },
        karmgraph    => sub { mbKarmaGraph_ctx($ctx) },
        triviastop   => sub { mbTriviaStop_ctx($ctx) },
        karmawatch   => sub { mbKarmaWatch_ctx($ctx) },
        remindsnooze => sub { mbRemindSnooze_ctx($ctx) },
        karmainfo    => sub { mbKarmaInfo_ctx($ctx) },
        triviareset  => sub { mbTriviaReset_ctx($ctx) },
        triviatop    => sub { mbTriviaTop_ctx($ctx) },
        pollextend   => sub { mbPollExtend_ctx($ctx) },
        karmahist    => sub { mbKarmaHist_ctx($ctx) },
        roll         => sub { mbRoll_ctx($ctx) },
        flip         => sub { mbFlip_ctx($ctx) },
        choose       => sub { mbChoose_ctx($ctx) },
        morse        => sub { mbMorse_ctx($ctx) },
        abbrev       => sub { mbAbbrev_ctx($ctx) },
        compare      => sub { mbCompare_ctx($ctx) },
        heatmap      => sub { mbHeatmap_ctx($ctx) },
        monthstats   => sub { mbMonthStats_ctx($ctx) },
        define       => sub { mbDefine_ctx($ctx) },
        trivia       => sub { mbTrivia_ctx($ctx) },
        triviascore  => sub { mbTriviaScore_ctx($ctx) },
        active       => sub { mbActive_ctx($ctx) },
        when         => sub { mbWhen_ctx($ctx) },
        # mb115: système d'achievements + profil + radar
        achievements => sub { mbAchievements_ctx($ctx) },
        achievs      => sub { mbAchievements_ctx($ctx) },   # alias court
        profil       => sub { mbProfil_ctx($ctx) },
        profile      => sub { mbProfil_ctx($ctx) },          # alias en anglais
        radar        => sub { mbRadar_ctx($ctx) },

        # mb116: dashboard de canal + duel + horoscope
        dashboard    => sub { mbDashboard_ctx($ctx) },
        chanstats    => sub { mbDashboard_ctx($ctx) },        # alias
        duel         => sub { mbDuel_ctx($ctx) },
        horoscope    => sub { mbHoroscope_ctx($ctx) },
        horo         => sub { mbHoroscope_ctx($ctx) },        # alias court

        # mb117: compat + quotegame + mood
        compat       => sub { mbCompat_ctx($ctx) },
        affinity     => sub { mbCompat_ctx($ctx) },           # alias EN
        quotegame    => sub { mbQuotegame_ctx($ctx) },
        qg           => sub { mbQuotegame_ctx($ctx) },        # alias court
        mood         => sub { mbMood_ctx($ctx) },
        milestone    => sub { mbMilestone_ctx($ctx) },
        milestones   => sub { mbMilestone_ctx($ctx) },
        ambiance     => sub { mbMood_ctx($ctx) },             # alias FR

        # mb118: leaderboard + chronos
        # Keep the historical !top command mapped to mbTop_ctx above.
        # Leaderboard aliases are !leaderboard and !lb.
        leaderboard  => sub { mbLeaderboard_ctx($ctx) },
        lb           => sub { mbLeaderboard_ctx($ctx) },      # alias court
        chronos      => sub { mbChronos_ctx($ctx) },
        chrono       => sub { mbChronos_ctx($ctx) },          # alias court
        timeline     => sub { mbChronos_ctx($ctx) },          # alias EN
        features     => sub { mbFeatures_ctx($ctx) },
        capabilities => sub { mbFeatures_ctx($ctx) },
        caps         => sub { mbFeatures_ctx($ctx) },
        observatory  => sub { mbObservatory_ctx($ctx) },
        obs          => sub { mbObservatory_ctx($ctx) },
        recap        => sub { mbRecap_ctx($ctx) },       # mb472: catch-up summary
        onthisday    => sub { mbOnThisDay_ctx($ctx) },    # mb489: history nostalgia
        otd          => sub { mbOnThisDay_ctx($ctx) },
        learn        => sub { mbLearn_ctx($ctx) },        # mb476: factoids
        whatis       => sub { mbWhatis_ctx($ctx) },
        forget       => sub { mbForget_ctx($ctx) },
        factoids     => sub { mbFactoids_ctx($ctx) },
        factoid      => sub { mbFactoid_ctx($ctx) },     # mb478: factoid details
        quotecount   => sub {
            my @a = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();
            mbQuoteCount_ctx($ctx->bot, $ctx->nick, $ctx->channel, $a[0]) },

        topquote     => sub {
            my @a = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();
            mbTopQuote_ctx($ctx->bot, $ctx->nick, $ctx->channel, $a[0]) },
        halloffame   => sub {
            my @a = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();
            mbTopQuote_ctx($ctx->bot, $ctx->nick, $ctx->channel, $a[0]) },

        last         => sub { mbLast_ctx($ctx) },
        poll         => sub { mbPoll_ctx($ctx) },
        vote         => sub { mbVote_ctx($ctx) },
        pollresult   => sub { mbPollResult_ctx($ctx) },
        pollstatus   => sub { mbPollStatus_ctx($ctx) },
        pollvoters   => sub { mbPollVoters_ctx($ctx) },
        unvote       => sub { mbUnvote_ctx($ctx) },
        pollstop     => sub { mbPollStop_ctx($ctx) },
        note         => sub { mbNote_ctx($ctx) },
        notes        => sub { mbNotes_ctx($ctx) },
        date         => sub { displayDate_ctx($ctx) },
        weather      => sub {
            my @a = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();
            if (@a && lc($a[0]) eq 'compare') {
                shift @{ $ctx->args };
                mbWeatherCompare_ctx($ctx);
            } else { displayWeather_ctx($ctx) }
        },
        meteo        => sub { displayWeather_ctx($ctx) },
        addbadword   => sub { channelAddBadword_ctx($ctx) },
        rembadword   => sub { channelRemBadword_ctx($ctx) },
        ignores      => sub { IgnoresList_ctx($ctx) },
        ignore       => sub { addIgnore_ctx($ctx) },
        unignore     => sub { delIgnore_ctx($ctx) },
        yt           => sub {
            my @a = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();
            if (@a && lc($a[0]) eq 'search') {
                shift @{ $ctx->args };
                ytSearch_ctx($ctx);
            } else {
                youtubeSearch_ctx($ctx);
            }
        },
        # mb86-R1: commandes radio regroupées via _dispatch_radio
        song           => sub { _dispatch_radio($ctx, $cmd) },
        radiostatus    => sub { _dispatch_radio($ctx, $cmd) },
        radiomounts    => sub { _dispatch_radio($ctx, $cmd) },
        listeners      => sub { _dispatch_radio($ctx, $cmd) },
        nextsong       => sub { _dispatch_radio($ctx, $cmd) },
        play           => sub { _dispatch_radio($ctx, $cmd) },
        radioimport    => sub { _dispatch_radio($ctx, $cmd) },
        radioimportdir => sub { _dispatch_radio($ctx, $cmd) },
        radioqueue     => sub { _dispatch_radio($ctx, $cmd) },
        radiocheck     => sub { _dispatch_radio($ctx, $cmd) },
        radiocache     => sub { _dispatch_radio($ctx, $cmd) },
        radiocacheprune => sub { _dispatch_radio($ctx, $cmd) },
        radiodlstatus  => sub { _dispatch_radio($ctx, $cmd) },
        radiodlcancel  => sub { _dispatch_radio($ctx, $cmd) },
        radiopush      => sub { _dispatch_radio($ctx, $cmd) },
        radioskip      => sub { _dispatch_radio($ctx, $cmd) },
        radioflush     => sub { _dispatch_radio($ctx, $cmd) },
        addresponder => sub { addResponder_ctx($ctx) },
        delresponder => sub { delResponder_ctx($ctx) },
        lastcom      => sub { lastCom_ctx($ctx) },
        q            => sub { mbQuotes_ctx($ctx) },
        quote        => sub {
            my @a = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();
            if (@a && lc($a[0]) eq 'add') {
                shift @{ $ctx->args };
                mbQuoteAdd($ctx->bot, $ctx->nick, $ctx->channel,
                    join(' ', @{ $ctx->args }));
            } elsif (@a && lc($a[0]) eq 'count') {
                shift @{ $ctx->args };
                my @r = @{ $ctx->args };
                mbQuoteCount_ctx($ctx->bot, $ctx->nick, $ctx->channel, $r[0]);
            } else { mbQuoteByNick($ctx) }
        },
        moduser      => sub { mbModUser_ctx($ctx) },
        antifloodset => sub { setChannelAntiFloodParams_ctx($ctx) },
        leet         => sub { displayLeetString_ctx($ctx) },
        rehash       => sub { mbRehash_ctx($ctx) },
        mp3          => sub { mp3_ctx($ctx) },
        exec         => sub { mbExec_ctx($ctx) },
        qlog         => sub { mbChannelLog_ctx($ctx) },
        hailo_ignore   => sub { hailo_ignore_ctx($ctx) },
        hailo_unignore => sub { hailo_unignore_ctx($ctx) },
        hailo_status   => sub { hailo_status_ctx($ctx) },
        hailo_chatter  => sub { hailo_chatter_ctx($ctx) },
        whereis      => sub { mbWhereis_ctx($ctx) },
        birthday     => sub { userBirthday_ctx($ctx) },
        f            => sub { fortniteStats_ctx($ctx) },
        xlogin       => sub { xLogin_ctx($ctx) },
        tellme       => sub { chatGPT_ctx($ctx) },
        openai       => sub { openai_ctx($ctx) },
        ai           => sub { claude_ctx($ctx) },
        yomomma      => sub { Yomomma_ctx($ctx) },
        resolve      => sub { resolve_ctx($ctx) },
        tmdb         => sub { mbTMDBSearch_ctx($ctx) },
        tmdblangset  => sub { setTMDBLangChannel_ctx($ctx) },
        debug        => sub { debug_ctx($ctx) },
        version      => sub { versionCheck($ctx) },
        uptime       => sub { mbUptime_ctx($ctx) },
        help         => sub { mbHelp_ctx($ctx) },
        commands     => sub {
            $ctx->{args} = [ 'commands' ];
            mbHelp_ctx($ctx);
        },
        spike        => sub { $ctx->reply("https://teuk.org/In_Spike_Memory.jpg") },
        update       => sub { update_ctx($ctx) },
    );

    # A4: track per-command usage in Prometheus
    if ($self->{metrics}) {
        $self->{metrics}->inc('mediabot_commands_by_name_total', { command => $cmd });
    }

    # mb166-B1: first real use of CommandRegistry for a small low-risk core
    # public command group. The legacy %command_map remains immediately below
    # as compatibility fallback for every command not yet migrated.
    if (my $handler = $self->commands->handler_for($cmd, 'public')) {
        $self->{logger}->log(4, "PUBLIC(registry): $sNick triggered $sCommand on $sChannel");
        eval { $handler->($ctx) };
        if ($@) {
            $self->{logger}->log(1, "PUBLIC registry command '$cmd' error: $@");
            $self->{metrics}->inc('mediabot_command_errors_total', { command => $cmd })
                if $self->{metrics};
        }
        return;
    }

    # Dispatch known command through the historical table.
    if (my $handler = $command_map{$cmd}) {
        $self->{logger}->log(4, "PUBLIC: $sNick triggered $sCommand on $sChannel");
        eval { $handler->() };
        if ($@) {
            $self->{logger}->log(1, "PUBLIC command '$cmd' error: $@");
            $self->{metrics}->inc('mediabot_command_errors_total', { command => $cmd })
                if $self->{metrics};
        }
        return;
    }

    # Check database for custom commands
    my $bFound = mbDbCommand($self, $message, $sChannel, $sNick, $sCommand, @tArgs);
    return if $bFound;

    # Bot nick triggered - natural language / Hailo fallback
    if ($botNickTriggered) {
        mbHandleNickTriggered($ctx, join(" ", $sCommand, @tArgs));
    } else {
        $self->{logger}->log(4, "Public command '$sCommand' not found");
        # mb475: "did you mean?" — suggest the closest known public command on a
        # genuine typo, instead of staying silent. Conservative: only for a
        # channel command, only a close single suggestion, and rate-limited.
        _mbSuggestCommand($self, $ctx, $sChannel, $sNick, $sCommand);
    }
}

# Handle help command

# ---------------------------------------------------------------------------
# mb475: "did you mean?" suggestion for a mistyped public command.
#
# _levenshtein($a, $b) — Damerau-Levenshtein edit distance (pure Perl). Unlike
# plain Levenshtein, an adjacent transposition ("hlep" -> "help") costs 1, which
# matches real typing mistakes far better. Bounded by caller to short tokens, so
# the O(len_a*len_b) cost is trivial. Name kept for callers/tests.
# ---------------------------------------------------------------------------
sub _levenshtein {
    my ($a, $b) = @_;
    $a = defined $a ? $a : '';
    $b = defined $b ? $b : '';
    return length($b) if $a eq '';
    return length($a) if $b eq '';

    my @a = split //, $a;
    my @b = split //, $b;
    my ($la, $lb) = (scalar @a, scalar @b);

    # full matrix for Damerau (need row i-2 / col j-2 for transposition)
    my @d;
    for my $i (0 .. $la) { $d[$i][0] = $i }
    for my $j (0 .. $lb) { $d[0][$j] = $j }

    for my $i (1 .. $la) {
        for my $j (1 .. $lb) {
            my $cost = ($a[$i-1] eq $b[$j-1]) ? 0 : 1;
            my $min = $d[$i-1][$j] + 1;                      # deletion
            $min = $d[$i][$j-1] + 1     if $d[$i][$j-1] + 1     < $min; # insertion
            $min = $d[$i-1][$j-1] + $cost if $d[$i-1][$j-1] + $cost < $min; # substitution
            # transposition of two adjacent characters
            if ($i > 1 && $j > 1
                && $a[$i-1] eq $b[$j-2]
                && $a[$i-2] eq $b[$j-1]) {
                my $t = $d[$i-2][$j-2] + 1;
                $min = $t if $t < $min;
            }
            $d[$i][$j] = $min;
        }
    }
    return $d[$la][$lb];
}

# ---------------------------------------------------------------------------
# _mbSuggestCommand($self, $ctx, $channel, $nick, $typed)
# On an unknown PUBLIC command, if a single close known public command exists,
# reply "Unknown command 'x'. Did you mean 'y'?". Conservative by design:
#   - only in a channel (skip private, which is quieter anyway);
#   - the typed token must look like a command word (letters/digits, 2..24);
#   - suggestion distance must be small AND relative to length (avoid absurd
#     matches on very short tokens);
#   - at most one suggestion, no list spam;
#   - per-channel cooldown to avoid becoming a flood vector.
# Returns 1 if a suggestion was sent, 0 otherwise.
# ---------------------------------------------------------------------------
sub _mbSuggestCommand {
    my ($self, $ctx, $channel, $nick, $typed) = @_;

    return 0 unless Mediabot::Helpers::isIrcChannelTarget($channel);
    return 0 unless defined $typed;
    my $t = lc $typed;
    # only plausible command words: letters/digits/_, length 3..24. Two-letter
    # tokens (hi, ok, no, lol-typos) are conversational noise, not command typos,
    # and would produce false suggestions — require at least 3 characters.
    return 0 unless $t =~ /^[a-z0-9_]{3,24}$/;

    # opt-out per channel via chanset (default on for a friendly bot).
    return 0 unless eval {
        Mediabot::Helpers::chanset_enabled($self, $channel, 'DidYouMean', default => 1)
    } // 1;

    # per-channel cooldown (default 15s), bounded memory.
    my $now = time();
    my $cooldown = int(eval { $self->{conf}->get('main.DIDYOUMEAN_COOLDOWN_S') } // 15);
    $cooldown = 15 if $cooldown < 0;
    $self->{_didyoumean_cd} ||= {};
    if ($cooldown > 0) {
        my $last = $self->{_didyoumean_cd}{lc $channel};
        return 0 if defined $last && ($now - $last) < $cooldown;
    }

    # candidate set = known PUBLIC commands (help metadata is the source of truth)
    my %help = eval { _mbHelpInternalCommands() };
    return 0 unless %help;
    my @public = grep { ($help{$_}{level} // '') eq 'public' } keys %help;
    return 0 unless @public;

    # find the closest command by edit distance.
    my ($best, $best_d);
    for my $cmd (@public) {
        # cheap length prefilter: skip candidates whose length differs a lot.
        next if abs(length($cmd) - length($t)) > 2;
        my $d = _levenshtein($t, $cmd);
        if (!defined $best_d || $d < $best_d) {
            $best_d = $d;
            $best   = $cmd;
        }
    }
    return 0 unless defined $best;

    # acceptance: distance <= 2 AND not more than ~1/3 of the length, so that
    # short tokens need an almost-exact match (e.g. don't map "hi" -> "help").
    my $max_d = length($t) <= 4 ? 1 : 2;
    return 0 if $best_d > $max_d;
    return 0 if $best_d == 0;   # exact match shouldn't reach here, but be safe

    $self->{_didyoumean_cd}{lc $channel} = $now;
    # bound memory
    if (scalar(keys %{ $self->{_didyoumean_cd} }) > 256) {
        for my $k (keys %{ $self->{_didyoumean_cd} }) {
            delete $self->{_didyoumean_cd}{$k}
                if ($now - $self->{_didyoumean_cd}{$k}) > 3600;
        }
    }

    my $cc = eval { $self->{conf}->get('main.MAIN_PROG_CMD_CHAR') } // '!';
    botPrivmsg($self, $channel,
        "$nick: unknown command '$cc$typed'. Did you mean $cc$best?");
    $self->{metrics}->inc('mediabot_didyoumean_total', { channel => $channel })
        if $self->{metrics};
    return 1;
}


# ---------------------------------------------------------------------------
# mbUptime_ctx — !uptime
# ---------------------------------------------------------------------------
sub mbUptime_ctx {
    my ($ctx) = @_;
    my $self    = $ctx->bot;
    my $start = getProcessStartTimestamp($self);

    my $uptime_secs = time() - $start;
    $uptime_secs = 0 if $uptime_secs < 0;
    my $d = int($uptime_secs / 86400);
    my $h = int(($uptime_secs % 86400) / 3600);
    my $m = int(($uptime_secs % 3600) / 60);
    my $s = $uptime_secs % 60;

    my $uptime_str = '';
    $uptime_str .= "${d}d " if $d;
    $uptime_str .= "${h}h " if $h;
    $uptime_str .= "${m}m " if $m;
    $uptime_str .= "${s}s";
    $uptime_str =~ s/\s+$//;

    my $nick = eval { $self->{irc}->nick_folded } // 'mediabotv3';

    # F23: enrich with RAM and load average
    my ($rss_kb, $load) = (0, '');
    if (open my $fh, '<', '/proc/self/status') {
        while (<$fh>) { if (/^VmRSS:\s+(\d+)/) { $rss_kb = $1; last; } }
        close $fh;
    }
    if (open my $fh2, '<', '/proc/loadavg') {
        my $line = <$fh2>; close $fh2;
        my @la = split /\s+/, ($line // '');
        $load = "$la[0] $la[1] $la[2]" if @la >= 3;
    }
    my $mem_str  = $rss_kb ? sprintf('%.1f MB', $rss_kb/1024) : '?';
    my $load_str = $load || '?';
    # F54: add Claude request counter from Prometheus metrics
    my $claude_str = '';
    if ($self->{metrics}) {
        my $reqs = eval { $self->{metrics}->get('mediabot_claude_requests_total') } // 0;
        $claude_str = " | AI $reqs req(s)" if $reqs;
    }
    # LL1: compute since string before botPrivmsg
    my @_st = localtime($start);
    my $since_str = sprintf(' (since %02d:%02d)', $_st[2], $_st[1]);
    $ctx->reply(
        "$nick: up $uptime_str$since_str | RAM $mem_str | load $load_str$claude_str"
    );
}

sub _mbHelpInternalCommands {
    my %help;

    my $raw = <<'MEDIABOT_INTERNAL_HELP';
access|access [#channel]|public|Show your access level on a channel.
act|act #channel <text>|operator+|Send an IRC action to a channel through the bot.
add|add #channel <nick> <level>|channel admin|Add or update a user access level on a channel.
addbadword|addbadword #channel <word>|channel admin|Add a badword filter entry for a channel.
addcatcmd|addcatcmd <category>|authorized|Create a PUBLIC_COMMANDS category.
addchan|addchan #channel|admin|Add a channel to the bot configuration.
addcmd|addcmd <category> <command> <action>|authorized|Create a dynamic command stored in PUBLIC_COMMANDS.
addhost|addhost <nick> <hostmask>|admin|Add a hostmask to a known user.
addresponder|addresponder <trigger> <response>|admin|Add an automatic responder.
addtimer|addtimer <name> <seconds> <command>|admin|Add a bot timer.
adduser|adduser <handle> [-n] <hostmask> [level]|admin|Create a bot user.
useradd|useradd <handle> [-n] <hostmask> [level]|admin|Legacy alias for adduser.
antifloodset|antifloodset #channel <key> <value>|channel admin|Adjust anti-flood settings for a channel.
auth|auth|public|Check or refresh your authentication status.
ban|ban #channel <mask|nick> [duration]|operator+|Ban a mask or nick on a channel.
bans|bans #channel|operator+|List known bans for a channel.
birthdate|birthdate [nick]|public|Display a stored user birthdate.
birthday|birthday [nick]|public|Display birthday information.
chaninfo|chaninfo #channel|public|Show information about a bot channel.
chanlist|chanlist|public|List channels known by the bot.
channels|channels|public|Alias for chanlist.
channellist|channellist|public|Alias for chanlist.
chanset|chanset #channel <setting> <value>|channel admin|Change a channel setting.
chanstatlines|chanstatlines #channel|public|Show channel line/statistics information.
chcatcmd|chcatcmd <command> <category>|authorized|Move a dynamic command to another category.
checkhost|checkhost <hostmask>|admin|Search users matching a hostmask.
checkhostchan|checkhostchan #channel <hostmask>|admin|Search channel users matching a hostmask.
checknick|checknick <nick>|admin|Search known hostmasks for a nick.
chowncmd|chowncmd <command> <nick>|authorized|Change the owner of a dynamic PUBLIC_COMMANDS command.
colors|colors|public|Display IRC color information.
countcmd|countcmd|authorized|Count dynamic PUBLIC_COMMANDS entries.
cstat|cstat #channel|public|Show channel statistics.
date|date [timezone|user]|public|Display the current date/time for a timezone or user.
debug|debug <level>|master|Change or display debug verbosity.
del|del #channel <nick>|channel admin|Remove a user from channel access.
delresponder|delresponder <trigger>|admin|Remove an automatic responder.
deluser|deluser <nick>|admin|Delete a bot user.
deop|deop #channel [nick]|operator+|Remove operator status on a channel.
devoice|devoice #channel [nick]|operator+|Remove voice status on a channel.
die|die [reason]|master|Ask the bot to quit.
dump|dump|master|Dump internal debug information.
echo|echo <text>|admin|Echo text for debugging.
exec|exec <command>|master|Execute a shell command. Dangerous and admin-only.
f|f <player>|public|Display Fortnite stats when configured.
greet|greet [text]|public|Show or set a greeting.
hailo_chatter|hailo_chatter [on|off]|admin|Control Hailo chatter behavior.
hailo_ignore|hailo_ignore <nick>|admin|Ignore a nick for Hailo learning or replies.
hailo_status|hailo_status|admin|Show Hailo status.
hailo_unignore|hailo_unignore <nick>|admin|Remove a nick from the Hailo ignore list.
help|help [#channel|command|docs|search <term>|level <level>]|public|Show command lists, search internal help, or documentation pointers.
commands|commands|public|Alias for help commands.
holdcmd|holdcmd <command> [on|off]|authorized|Put a dynamic command on hold or restore it.
ident|ident <login> <password>|private|Legacy/private authentication helper.
ignore|ignore <nick|mask>|admin|Add an ignore entry.
ignores|ignores|admin|List ignore entries.
invite|invite #channel <nick>|operator+|Invite a nick to a channel.
join|join #channel|admin|Make the bot join a channel.
kb|kb #channel <nick> [reason]|operator+|Alias for kickban.
kick|kick #channel <nick> [reason]|operator+|Kick a user from a channel.
kickban|kickban #channel <nick> [reason]|operator+|Kick and ban a user from a channel.
lastcmd|lastcmd [limit]|authorized|Show recently used dynamic commands.
lastcom|lastcom [nick]|public|Show recent command usage.
leet|leet <text>|public|Convert text to leetspeak.
listeners|listeners|public|Show Icecast listener counts.
login|login <user> <password>|private|Authenticate with the bot.
logout|logout|private|Logout from the bot.
meteo|meteo [city]|public|Alias for weather.
modcmd|modcmd <command> <new action>|authorized|Modify a dynamic PUBLIC_COMMANDS command.
modinfo|modinfo <nick>|admin|Show moderation information about a user.
moduser|moduser <nick> <field> <value>|admin|Modify a bot user.
mp3|mp3 <query>|public|Search or display MP3/radio related information.
play|play <query>|public|Queue a cached/downloaded radio track via Liquidsoap. Master-only during rollout.
radioqueue|radioqueue|public|Show the Liquidsoap Mediabot request queue. Master-only.
radiocheck|radiocheck|public|Check local radio cache, yt-dlp, cookies, Liquidsoap, and Icecast configuration. Master-only.
radiocache|radiocache|public|Show MP3 cache database/file consistency summary. Master-only.
radiocacheprune|radiocacheprune [confirm]|public|Dry-run or delete MP3 cache rows whose files are missing. Master-only.
radiodlstatus|radiodlstatus|public|Show current non-blocking yt-dlp download status. Master-only.
radiodlcancel|radiodlcancel|public|Cancel the current non-blocking yt-dlp download. Master-only.
radiopush|radiopush <absolute-mp3-path>|public|Push a local MP3 file into the Liquidsoap Mediabot queue. Master-only.
radioimport|radioimport <absolute-mp3-path> [artist - title]|public|Index a local MP3 file into the radio cache. Master-only.
radioimportdir|radioimportdir [directory]|public|Index all readable MP3 files from a local directory into the radio cache. Master-only.
radioskip|radioskip|public|Skip the current Liquidsoap queue item. Master-only.
radioflush|radioflush|public|Flush the Liquidsoap queue and skip. Master-only.
msg|msg <nick|#channel> <text>|admin|Send a message through the bot.
mvcmd|mvcmd <old> <new>|authorized|Rename a dynamic PUBLIC_COMMANDS command.
nextsong|nextsong|public|Display next-song information when a scheduler is wired.
nick|nick <newnick>|admin|Change the bot nickname.
nicklist|nicklist #channel|public|List nicks currently known on a channel.
op|op #channel [nick]|operator+|Give operator status on a channel.
owncmd|owncmd [nick]|authorized|List dynamic commands owned by a user.
part|part #channel [reason]|admin|Make the bot leave a channel.
pass|pass <newpass>|pass <oldpass> <newpass>|private|Set first password, or change existing password with old password verification.
popcmd|popcmd|authorized|Show popular dynamic commands.
purge|purge #channel|admin|Purge or reset channel runtime information.
q|q [nick|search]|public|Display a quote.
qlog|qlog #channel <query>|admin|Search channel logs.
radiomounts|radiomounts|public|List Icecast mounts.
radiostatus|radiostatus|public|Show Icecast status.
register|register <owner> <password>|private|Register the first owner account.
rehash|rehash|master|Reload bot configuration.
rembadword|rembadword #channel <word>|channel admin|Remove a badword filter entry.
remcmd|remcmd <command>|authorized|Remove a dynamic PUBLIC_COMMANDS command.
remtimer|remtimer <name>|admin|Remove a bot timer.
resolve|resolve <host|ip>|public|Resolve a hostname or IP address.
rnick|rnick #channel|public|Pick a random nick from a channel.
say|say #channel <text>|admin|Send a channel message through the bot.
searchcmd|searchcmd <keyword> [limit]|public|Search dynamic PUBLIC_COMMANDS entries.
seen|seen <nick>|public|Show when a nick was last seen.
showcmd|showcmd <command>|public|Display a dynamic PUBLIC_COMMANDS command.
showcommands|showcommands [#channel]|public|List commands available for your level on a channel.
song|song|public|Show the current Icecast song or stream title.
status|status|admin|Show bot runtime status.
tellme|tellme <prompt>|public|Ask the configured ChatGPT/OpenAI integration.
openai|openai help|owner|Show and change safe OpenAI/tellme runtime settings.
timers|timers|admin|List bot timers.
tmdb|tmdb <movie or show>|public|Search TMDB when configured.
tmdblangset|tmdblangset #channel <lang>|channel admin|Set TMDB language for a channel.
topic|topic #channel <topic>|private/admin|Change the topic of a channel.
topcmd|topcmd|authorized|Show most used dynamic commands.
topsay|topsay [#channel]|public|Show top talkers.
unban|unban #channel <mask|id>|operator+|Remove a ban from a channel.
unignore|unignore <nick|mask>|admin|Remove an ignore entry.
update|update|master|Disabled IRC update command. Use the deploy script manually.
uptime|uptime|public|Show bot uptime.
userinfo|userinfo <nick>|admin|Show information about a user.
users|users|admin|List or count known users.
verify|verify|public|Verify your authentication or account state.
version|version|public|Show bot version.
voice|voice #channel [nick]|operator+|Give voice on a channel.
weather|weather [city]|public|Display weather information.
whereis|whereis <nick>|public|Locate a nick or channel when known.
whoami|whoami|public|Show who the bot thinks you are.
whotalk|whotalk #channel|public|Show channel talk statistics.
whotalks|whotalks #channel|public|Alias for whotalk.
xlogin|xlogin <account>|public|Authenticate or check X login integration when configured.
yomomma|yomomma|public|Return a yomomma joke.
yt|yt <query>|public|Search YouTube when configured.

# --- Wave IV-V commands added 2025-2026 ---
# Fun / random
8ball|8ball <question>|public|Ask the Magic 8-ball a yes/no question.
choose|choose <a> | <b>|public|Random pick. Weight opt:N. Deduplicates (empty result → error).
flip|flip|public|Flip a coin (heads or tails).
morse|morse <text>|public|Encode text in Morse code.
roll|roll [NdN]|public|Roll dice. Defaults to 1d6. Supports NdN format (e.g. 2d6, 1d20).
slap|slap [nick]|public|Slap a nick with a random object via CTCP ACTION.

# Analytics / stats
abbrev|abbrev <text>|public|Generate an acronym from the initials of each word.
active|active [period]|public|List nicks active in the last N hours or days (e.g. 24h, 7d).
calclast|calclast [1-3]|public|Show your most recent !calc results (session memory).
calc|calc <expression>|public|Evaluate a safe calculator expression.
convert|convert <value> <from> <to>|public|Convert units: length, mass, temperature, volume, speed, data (e.g. convert 100 km mi).
stats|stats [nick]|public|Show channel/user statistics.
top|top [limit]|public|Show top channel activity statistics.
compare|compare <nick1> <nick2>|public|Compare message counts between two nicks on the channel.
heatmap|heatmap [nick]|public|Show hourly activity chart as ASCII bars.
monthstats|monthstats [nick]|public|Show activity count per month for the last 12 months.
streak|streak [nick]|public|Show consecutive days of activity on the channel.
when|when <nick>|public|Show when a nick first appeared on the channel.
wordcount|wordcount [nick]|public|Count distinct words spoken by a nick on the channel.

# Karma
karma|karma [+/-/++/--] [nick]|public|Show karma or vote: !karma + <nick> / !karma - <nick>. Requires nick on channel.
karmawatch|karmawatch [nick]|public|Watch a nick's karma. Get notified on any vote (max 5 watches). Toggle on/off.
karmainfo|karmainfo <nick>|public|Detailed karma stats: received, given, top voter.
karmgraph|karmgraph [nick]|public|ASCII sparkline of karma changes over the last 7 days.
karmadiff|karmadiff [nick]|public|Show karma delta for nick in the last 24h.
karmareset|karmareset <nick>|master|Reset a nick's karma to 0 on this channel.
karmatop|karmatop [n]|public|Show the top N karma scores (default 5). Use 'karmatop bottom [n]' for lowest scores.
karmahist|karmahist [nick]|public|Show the last 5 karma changes on the channel (optionally filtered by nick).

# Reminders
remind|remind [!] <nick> <msg>|public|Set reminder. Subcommands: list, cancel <id>|all, show.
tell|tell <nick> <msg>|public|Leave a message for a nick, delivered when they next join or speak here.
remindsnooze|remindsnooze <id> <delay>|public|Snooze a reminder by 30m, 2h, 1d etc.
remindlist|public|List your pending reminders with remaining time and urgent flag.

# Quotes
quotecount|quotecount [nick]|public|Count quotes by author on the channel.
topquote|topquote [n]|public|Channel hall of fame: the most-recalled quotes (default 5, max 10). Alias: halloffame
halloffame|halloffame [n]|public|Alias for topquote.
quote|quote [nick] | quote add <text> | quote count [nick]|public|Quote alias: fetch by nick, add a quote, or count quotes.

# Notes (in-memory, reset on restart)
note|note <msg>|public|Save a note (max 200 chars, max 10). !notes to list/del/search/export.
notes|notes [del <n>]|public|List or delete personal notes.

# Polls
poll|poll [secs] [weighted] <q> | opt1[:N] | opt2|public|Start a poll. 'weighted' enables weighted options (opt:N).
pollextend|pollextend <secs>|public|Extend the current poll timer by N seconds (10-600).
pollresult|pollresult|public|Show current or last poll results.
pollvoters|pollvoters|master|Show who voted for what in the current poll.
pollstatus|public|Show the current poll status without closing it.
pollstop|pollstop|master|Close the active poll.
unvote|unvote|public|Cancel your vote in the current poll.
vote|vote <n>|public|Vote in the current poll. Shows live tally after each vote (U3).

# Social / channel memory
achievements|achievements [nick|list|all|top]|public|Show achievements for yourself, a nick, the catalogue or the top unlocks.
achievs|achievs [nick|list|all|top]|public|Alias for achievements.
profil|profil [nick]|public|Show a compact channel profile for a nick.
profile|profile [nick]|public|Alias for profil.
radar|radar [Nd]|public|Show current or historical channel activity radar.
dashboard|dashboard|public|Show a compact dashboard for the current channel.
chanstats|chanstats|public|Alias for dashboard.
leaderboard|leaderboard [msgs|karma|trivia|duels|achievs] [24h|7d|30d]|public|Show channel rankings, optionally limited to recent msgs/karma.
lb|lb [msgs|karma|trivia|duels|achievs] [24h|7d|30d]|public|Alias for leaderboard.
chronos|chronos [short|full]|public|Show a compact or full narrative timeline of the current channel.
chrono|chrono [short|full]|public|Alias for chronos.
timeline|timeline [short|full]|public|Alias for chronos.
features|features|public|Show active channel capabilities and important chansets.
capabilities|capabilities|public|Alias for features.
caps|caps|public|Alias for features.
observatory|observatory|public|Show a compact live channel and bot status view.
obs|obs|public|Alias for observatory.
recap|recap [30m\|2h] [ai]|public|Summarize what you missed on this channel (stats, or AI summary with 'ai').
onthisday|onthisday [MM-DD]|public|Resurface what happened on this channel on a calendar day (today, or a given MM-DD) in past years. Alias: otd
otd|otd|public|Alias for onthisday.
learn|learn <keyword> = <value>|public|Store a shared channel fact. Recall with whatis.
whatis|whatis <keyword>|public|Recall a shared channel fact stored with learn. Shortcut: ?keyword
forget|forget <keyword>|public|Delete a channel fact (author or channel op only).
factoids|factoids [pattern\|top]|public|List channel facts (glob pattern), or 'top' for the most recalled.
factoid|factoid <keyword>|public|Show details of a fact: author, dates, recall count.
mood|mood|public|Read the channel mood: sentiment, energy, who's driving it, and today's peak hour.
milestone|milestone|public|Show channel milestones: total messages, next round milestone, progress and ETA. Alias: milestones
milestones|milestones|public|Alias for milestone.
ambiance|ambiance|public|Alias for mood.

# Games / playful commands
duel|duel <nick>|public|Challenge a present nick to a d20 duel. Gated by chanset +Games.
horoscope|horoscope [nick]|public|Show a deterministic daily IRC horoscope. Public use is gated by +Games.
horo|horo [nick]|public|Alias for horoscope.
compat|compat <nick1> [nick2]|public|Compare IRC affinity between two nicks. Gated by +Games.
affinity|affinity <nick1> [nick2]|public|Alias for compat.
quotegame|quotegame [stop|top]|public|Guess who said a stored quote. Uses a proactive 60s timer. Gated by +Games.
qg|qg [stop|top]|public|Alias for quotegame.

# Trivia
triviareset|triviareset <nick>|master|Reset a nick's trivia score in DB.
triviatop|triviatop [n]|public|Show top trivia scores from DB (hall of fame, max 15).
triviastop|triviastop|master|Stop the active trivia game on this channel.
trivia|trivia [cat] [start N]|public|Trivia. 'categories' to list. Named cats: science, history, music, film, tv...
triviascore|triviascore|public|Show trivia scores for the current channel session.

# Dictionary / external
define|define <word>|public|Look up a word definition from Wiktionary.

# AI
ai|ai <prompt>|public|Ask Claude. Subcommands: summary [periode] [N] [Nl] [public] [nick] (details: ai summary help), pin, relay, forget, models, stats, reset, history, ai persona.

# Misc
spike|spike|public|Show Spike memorial image.
last|last <nick>|public|Show the last message posted by a nick on this channel.
alias|alias <alias> <command>|owner|Create or manage IRC command aliases (alias list, alias del <alias>).
MEDIABOT_INTERNAL_HELP

    for my $line (split /\n/, $raw) {
        next if $line =~ /^\s*$/;
        next if $line =~ /^\s*#/;   # mb485: skip heredoc comments (were parsed as ghost commands)

        # Format is:
        #   command|syntax|level|description
        #
        # The syntax itself may contain pipes, for example:
        #   ban #channel <mask|nick> [duration]
        #   date [timezone|user]
        #
        # So we parse from both ends instead of blindly using split(..., 4).
        my @fields = split /\|/, $line;
        my $cmd    = shift @fields;
        my $desc   = pop @fields;
        my $level  = pop @fields;
        my $syntax = join('|', @fields);

        next unless defined $cmd && length $cmd;

        my $key = lc $cmd;
        next if exists $help{$key};

        $help{$key} = {
            syntax => defined($syntax) && length($syntax) ? $syntax : $cmd,
            level  => defined($level)  && length($level)  ? $level  : 'unknown',
            desc   => defined($desc)   && length($desc)   ? $desc   : 'No description available yet.',
        };
    }

    return %help;
}

sub _mbHelpPublicCommandExists {
    my ($self, $cmd) = @_;

    return 0 unless defined $cmd && $cmd ne '';
    return 0 unless $self && $self->{dbh};

    my $sth = eval {
        $self->{dbh}->prepare(
            'SELECT 1 FROM PUBLIC_COMMANDS WHERE command = ? LIMIT 1'
        );
    };

    return 0 unless $sth;

    my $ok = eval {
        $sth->execute($cmd);
        1;
    };

    unless ($ok) {
        eval { $sth->finish };
        return 0;
    }

    my ($exists) = $sth->fetchrow_array;
    $sth->finish;

    return $exists ? 1 : 0;
}

sub _mbHelpSendInternalCommand {
    my ($ctx, $cmd, $entry) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;

    botNotice($self, $nick, "Internal command: $cmd");
    botNotice($self, $nick, "Syntax: " . ($entry->{syntax} // $cmd));
    botNotice($self, $nick, "Level: " . ($entry->{level} // 'unknown'));
    botNotice($self, $nick, "Description: " . ($entry->{desc} // 'No description available yet.'));

    return 1;
}

sub _mbHelpSendChunkedList {
    my ($self, $nick, $prefix, @items) = @_;

    return unless @items;

    my $max_len = 360;
    my $line = $prefix;

    for my $item (@items) {
        my $piece = ($line eq $prefix) ? $item : ", $item";

        if (length($line) + length($piece) > $max_len) {
            botNotice($self, $nick, $line);
            $line = $prefix . $item;
        } else {
            $line .= $piece;
        }
    }

    botNotice($self, $nick, $line) if $line ne $prefix;

    return 1;
}


sub _mbHelpBuildChunkedList {
    my ($prefix, @items) = @_;

    return () unless @items;

    my $max_len = 360;
    my @lines;
    my $line = $prefix;

    for my $item (@items) {
        my $piece = ($line eq $prefix) ? $item : ", $item";

        if (length($line) + length($piece) > $max_len) {
            # mb462-B1: ne pas pousser une ligne réduite au seul préfixe quand un
            # item dépasse à lui seul la limite (sinon une ligne vide de contenu
            # est émise avant celle de l'item). Latent avec les noms de commandes
            # courts actuels ; correct pour tout réemploi avec des items longs.
            push @lines, $line if $line ne $prefix;
            $line = $prefix . $item;
        } else {
            $line .= $piece;
        }
    }

    push @lines, $line if $line ne $prefix;

    return @lines;
}

sub _mbHelpSendNoticeQueue {
    my ($self, $nick, @lines) = @_;
    return queueBotNotices($self, $nick, @lines);
}

sub _mbHelpSendSearchResults {
    my ($ctx, $term) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;

    $term //= '';
    $term =~ s/^\s+|\s+\z//g;

    unless ($term ne '') {
        botNotice($self, $nick, "Syntax: help search <term>");
        return 1;
    }

    my %internal = _mbHelpInternalCommands();
    my @matches;

    for my $cmd (sort keys %internal) {
        my $entry = $internal{$cmd} || {};

        my $haystack = join(
            ' ',
            $cmd,
            $entry->{syntax} // '',
            $entry->{level}  // '',
            $entry->{desc}   // '',
        );

        next unless lc($haystack) =~ /\Q@{[lc($term)]}\E/;

        push @matches, $cmd;
    }

    unless (@matches) {
        botNotice($self, $nick, "No internal command help matched '$term'.");
        botNotice($self, $nick, "Try: searchcmd $term");
        return 1;
    }

    botNotice($self, $nick, "Internal help matches for '$term':");
    _mbHelpSendChunkedList($self, $nick, "Matches: ", @matches[0 .. (@matches > 25 ? 24 : $#matches)]);

    if (@matches > 25) {
        botNotice($self, $nick, "Showing 25 of " . scalar(@matches) . " matches. Use a narrower term.");
    }

    botNotice($self, $nick, "Use: help <command> for syntax and explanation.");

    return 1;
}

sub _mbHelpSendLevelResults {
    my ($ctx, $level_query) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;

    $level_query //= '';
    $level_query =~ s/^\s+|\s+\z//g;

    unless ($level_query ne '') {
        botNotice($self, $nick, "Syntax: help level <public|private|admin|owner|master|authorized|operator>");
        return 1;
    }

    my %internal = _mbHelpInternalCommands();
    my @matches;

    for my $cmd (sort keys %internal) {
        my $level = lc($internal{$cmd}->{level} // '');

        next unless $level =~ /\Q@{[lc($level_query)]}\E/;

        push @matches, $cmd;
    }

    unless (@matches) {
        botNotice($self, $nick, "No internal command help matched level '$level_query'.");
        return 1;
    }

    botNotice($self, $nick, "Internal commands for level '$level_query':");
    _mbHelpSendChunkedList($self, $nick, "Commands: ", @matches);

    return 1;
}


sub _mbHelpExplicitCategory {
    # mb485: explicit command -> category map. Consulted BEFORE the heuristic
    # regexes so commands land in the right place regardless of wording. Only
    # list commands the heuristic would misclassify or that deserve a precise
    # home; everything else falls through to the heuristic below.
    return (
        # factoids family (was scattered across channel/moderation/general)
        learn    => 'factoids',
        whatis   => 'factoids',
        forget   => 'factoids',
        factoids => 'factoids',
        factoid  => 'factoids',
        # channel memory / catch-up
        recap    => 'social',
        onthisday => 'social',
        otd      => 'social',
        # messaging (tell was landing in admin via "delivered"/"nick")
        tell     => 'general',
        # tools
        convert  => 'stats',
        # quotes hall of fame (mb503: were mistakenly in category-aliases map)
        topquote    => 'ai_fun',
        halloffame  => 'ai_fun',
        # public commands the heuristic wrongly put in 'admin'
        remind      => 'general',
        slap        => 'ai_fun',
        heatmap     => 'stats',
        milestone   => 'stats',
        milestones  => 'stats',
        karmadiff   => 'stats',
        karmawatch  => 'stats',
        karmgraph   => 'stats',
        lastcom     => 'stats',
        monthstats  => 'stats',
        pollstatus  => 'general',
    );
}

sub _mbHelpCategoryForCommand {
    my ($cmd, $entry) = @_;

    # mb485: explicit map wins over heuristics.
    my %explicit = _mbHelpExplicitCategory();
    return $explicit{$cmd} if exists $explicit{$cmd};

    my $level  = lc($entry->{level}  // '');
    my $syntax = lc($entry->{syntax} // '');
    my $desc   = lc($entry->{desc}   // '');
    my $hay    = "$cmd $syntax $level $desc";

    return 'social' if $cmd =~ /^(?:achievements|achievs|profil|profile|radar|dashboard|chanstats|leaderboard|lb|chronos|chrono|timeline|features|capabilities|caps|observatory|obs|mood|ambiance)$/;
    return 'games' if $cmd =~ /^(?:duel|horoscope|horo|compat|affinity|quotegame|qg)$/;
    return 'settings' if $cmd =~ /^(?:chanset)$/;

    return 'radio' if $hay =~ /\b(?:radio|song|mp3|icecast|liquidsoap|listener|yt|youtube|tmdb|play|queue)\b/;
    return 'dynamic' if $hay =~ /\b(?:cmd|public_commands|category|timer|responder)\b/
        || $cmd =~ /cmd$/ || $cmd =~ /^(?:addcmd|modcmd|remcmd|showcmd|showcommands|searchcmd|topcmd|popcmd|lastcmd|countcmd|owncmd|chowncmd|mvcmd|holdcmd|addcatcmd|chcatcmd|addtimer|remtimer|timers|addresponder|delresponder)$/;
    return 'moderation' if $hay =~ /\b(?:ban|kick|ignore|voice|op|deop|devoice|invite|topic|mode)\b/;
    return 'channel' if $hay =~ /\b(?:channel|chan|access|chanset|owner)\b/
        || $cmd =~ /^(?:add|del|access|chan|channels|chanlist|channellist|chaninfo|chanset|addchan|part|join|purge|nicklist)$/;
    return 'auth' if $hay =~ /\b(?:login|logout|password|pass|auth|register|verify|hostmask|whoami|ident|xlogin|user)\b/;
    return 'stats' if $hay =~ /\b(?:stats|stat|seen|top|log|lines|talk|date|weather|meteo|resolve|whereis)\b/;
    return 'ai_fun' if $hay =~ /\b(?:hailo|openai|chatgpt|claude|tellme|quote|joke|dice|leet|yomomma|greet|birthday|birthdate|q)\b/;
    return 'admin' if $level =~ /\b(?:admin|master|owner|authorized)\b/
        || $hay =~ /\b(?:debug|exec|rehash|die|dump|update|status|version|nick)\b/;

    return 'general';
}

sub _mbHelpCategoryLabels {
    return (
        general    => 'General/status',
        auth       => 'Auth/users',
        channel    => 'Channels/access',
        moderation => 'Moderation',
        dynamic    => 'Dynamic commands',
        radio      => 'Radio/media',
        stats      => 'Stats/logs/tools',
        social     => 'Social/channel memory',
        factoids   => 'Factoids (learn/whatis)',
        games      => 'Games/playful commands',
        settings   => 'Chansets/settings',
        ai_fun     => 'AI/fun/quotes',
        admin      => 'Admin/ops',
    );
}

sub _mbHelpCategoryAliases {
    return (
        general    => 'general',
        status     => 'general',
        auth       => 'auth',
        users      => 'auth',
        user       => 'auth',
        channel    => 'channel',
        channels   => 'channel',
        access     => 'channel',
        moderation => 'moderation',
        mod        => 'moderation',
        dynamic    => 'dynamic',
        commands   => 'dynamic',
        cmd        => 'dynamic',
        radio      => 'radio',
        media      => 'radio',
        stats      => 'stats',
        logs       => 'stats',
        tools      => 'stats',
        social     => 'social',
        memory     => 'social',
        factoid    => 'factoids',
        factoids   => 'factoids',
        facts      => 'factoids',
        learn      => 'factoids',
        profile    => 'social',
        profiles   => 'social',
        games      => 'games',
        game       => 'games',
        playful    => 'games',
        chanset    => 'settings',
        chansets   => 'settings',
        settings   => 'settings',
        flags      => 'settings',
        ai         => 'ai_fun',
        fun        => 'ai_fun',
        quotes     => 'ai_fun',
        admin      => 'admin',
        ops        => 'admin',
    );
}

sub _mbHelpBuildCategories {
    my %internal = _mbHelpInternalCommands();

    my %cats;
    for my $cmd (sort keys %internal) {
        my $cat = _mbHelpCategoryForCommand($cmd, $internal{$cmd});
        push @{ $cats{$cat} }, $cmd;
    }

    return %cats;
}

sub _mbHelpCategoryIndexLines {
    # mb486: build the category index as a list of lines (reused by both the
    # "help commands" index and the bare "help" welcome screen).
    my %cats   = _mbHelpBuildCategories();
    my %labels = _mbHelpCategoryLabels();

    my @order = qw(general auth channel moderation dynamic radio stats social factoids games settings ai_fun admin);

    my @lines;
    for my $cat (@order) {
        my $count = scalar @{ $cats{$cat} || [] };
        next unless $count;
        push @lines, sprintf("  %-10s - %s (%d command%s)",
            $cat,
            $labels{$cat} || $cat,
            $count,
            $count == 1 ? '' : 's',
        );
    }
    return @lines;
}

sub _mbHelpSendCategoryIndex {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;

    my @lines;
    push @lines, "Internal command categories:";
    push @lines, _mbHelpCategoryIndexLines();
    push @lines, "Use: help commands <category>  Example: help commands radio";
    push @lines, "Other filters: help search <term> / help level <level> / help <command>";

    return _mbHelpSendNoticeQueue($self, $nick, @lines);
}

sub _mbHelpCategoryIndexCompact {
    # mb488: dense one-token-per-category index ("name(count)"), chunked so the
    # whole set fits in a couple of lines. Used by the welcome screen, which must
    # stay under the notice-queue cap so the navigation section is never cut off.
    my %cats = _mbHelpBuildCategories();
    my @order = qw(general auth channel moderation dynamic radio stats social factoids games settings ai_fun admin);
    my @tokens;
    for my $cat (@order) {
        my $count = scalar @{ $cats{$cat} || [] };
        next unless $count;
        push @tokens, "$cat($count)";
    }
    return _mbHelpBuildChunkedList("", @tokens);
}

sub _mbHelpSendWelcome {
    # mb486/mb488: the bare "help" entry point. Surfaces the whole internal help
    # structure (categories + navigation) at once. Kept COMPACT (<= the notice
    # queue cap) so the navigation lines are never truncated away (mb488 fix).
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;

    my $cc = eval { $self->{conf}->get('main.MAIN_PROG_CMD_CHAR') };
    $cc = '!' unless defined $cc && $cc ne '';

    # Read the local VERSION file directly — cheap and offline. getVersion()
    # may reach out for a remote comparison, which must not sit in the help path.
    my $version = '';
    if (open(my $vfh, '<', 'VERSION')) {
        local $/;
        my $v = <$vfh>;
        close $vfh;
        $v =~ s/^\s+|\s+$//g if defined $v;
        $version = $v if defined $v && $v ne '';
    }
    my $banner  = "Mediabot help" . ($version ne '' ? " ($version)" : '');

    my @lines;
    push @lines, $banner;
    push @lines, "Categories (name = command count):";
    push @lines, _mbHelpCategoryIndexCompact();
    push @lines, "Navigate:";
    push @lines, "  ${cc}help <category>      list a category   (e.g. ${cc}help radio)";
    push @lines, "  ${cc}help <command>       syntax + details  (e.g. ${cc}help convert)";
    push @lines, "  ${cc}help search <term>   find commands by keyword";
    push @lines, "  ${cc}help level <role>    commands for an access level";
    push @lines, "  ${cc}help chansets        channel behaviour flags   /   ${cc}help #channel  custom cmds";
    push @lines, "Docs: https://github.com/teuk/mediabot_v3/wiki";

    return _mbHelpSendNoticeQueue($self, $nick, @lines);
}

sub _mbHelpSendCategoryCommands {
    my ($ctx, $category) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;

    $category //= '';
    $category =~ s/^\s+|\s+$//g;
    $category = lc $category;
    $category =~ s/[\s-]+/_/g;

    my %aliases = _mbHelpCategoryAliases();
    $category = $aliases{$category} if exists $aliases{$category};

    my %cats = _mbHelpBuildCategories();
    my %labels = _mbHelpCategoryLabels();

    unless ($category ne '' && exists $cats{$category}) {
        botNotice($self, $nick, "Unknown help category '$category'. Use: help commands");
        return 1;
    }

    my @cmds = @{ $cats{$category} || [] };

    my @lines;
    push @lines, "Internal commands category: " . ($labels{$category} || $category);

    # mb487: for a small category, show a one-line "name - short description"
    # per command (far more useful than a bare list). For a large category,
    # keep the compact chunked list to avoid flooding. Threshold chosen so the
    # biggest detailed category stays well under a dozen NOTICE lines.
    my $DETAILED_MAX = 12;

    if (@cmds && @cmds <= $DETAILED_MAX) {
        my %internal = _mbHelpInternalCommands();
        my $w = 0;
        for my $c (@cmds) { $w = length($c) if length($c) > $w; }
        for my $c (@cmds) {
            my $desc = $internal{$c}{desc} // '';
            $desc =~ s/\s+/ /g;
            $desc =~ s/^\s+|\s+$//g;
            # keep each line comfortably within IRC limits
            $desc = Mediabot::Helpers::truncate_utf8($desc, 90, '...') if length($desc) > 90;
            push @lines, $desc ne ''
                ? sprintf("  %-*s - %s", $w, $c, $desc)
                : sprintf("  %s", $c);
        }
    }
    else {
        push @lines, _mbHelpBuildChunkedList("Commands: ", @cmds);
    }

    push @lines, "Use: help <command> for full syntax/details.";

    return _mbHelpSendNoticeQueue($self, $nick, @lines);
}


sub _mbHelpSendInternalList {
    my ($ctx, $category) = @_;

    $category //= '';
    $category =~ s/^\s+|\s+$//g;

    if ($category ne '') {
        return _mbHelpSendCategoryCommands($ctx, $category);
    }

    return _mbHelpSendCategoryIndex($ctx);
}


sub _mbHelpSendChansetsTopic {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;

    my @lines = (
        "Chansets / channel behavior flags:",
        "  Syntax: chanset #channel +Name / chanset #channel -Name",
        "  +AchievementAnnounce : publicly announce achievement unlocks. Without it, achievements still unlock silently.",
        "  +Games               : allow playful public commands: duel, horoscope, compat, quotegame.",
        "  +UrlTitle            : enable URL title fetching.",
        "  +Youtube             : enable YouTube URL details.",
        "  +YoutubeSearch       : enable YouTube search commands.",
        "  +RandomQuote         : enable random quote behavior.",
        "  +Claude              : enable Claude-related behavior if configured.",
        "  +NoColors            : strip colors from bot output where supported.",
        "  +AntiFlood           : enable channel anti-flood checks.",
        "  +ChannelReport       : receive automatic daily/weekly channel reports (on by default; -ChannelReport to silence).",
        "  +DidYouMean          : suggest the closest command on a typo (on by default; -DidYouMean to silence).",
        "  +Factoids            : allow shared learn/whatis channel facts (on by default; -Factoids to silence).",
        "  +OnThisDay           : allow the onthisday/otd channel history feature (on by default; -OnThisDay to silence).",
        "  +OnThisDayDigest     : post a daily 'on this day' recap to the channel (OFF by default; +OnThisDayDigest to enable).",
        "Use: help commands settings  /  help chansets  /  help chanset",
    );

    return _mbHelpSendNoticeQueue($self, $nick, @lines);
}


sub mbHelp_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;
    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    my $first = defined $args[0] ? $args[0] : '';

    if ($first =~ /^(?:wiki|doc|docs|documentation)$/i) {
        botNotice($self, $nick, "Mediabot documentation: https://github.com/teuk/mediabot_v3/wiki");
        return 1;
    }

    if ($first =~ /^(?:internal|internals|commands)$/i) {
        my $category = join(' ', @args[1 .. $#args]);
        return _mbHelpSendInternalList($ctx, $category);
    }

    # mb123: direct themed help shortcuts for the new social/game layer.
    if ($first =~ /^(?:social|memory|profiles?)$/i) {
        return _mbHelpSendInternalList($ctx, 'social');
    }

    if ($first =~ /^(?:games?|playful)$/i) {
        return _mbHelpSendInternalList($ctx, 'games');
    }

    if ($first =~ /^(?:chansets?|settings|flags)$/i) {
        return _mbHelpSendChansetsTopic($ctx);
    }

    # mb490: command/category collision rule must be real, not only simulated
    # in tests. "help stats" is an actual command and must show command help;
    # "help logs/tools" remain convenient aliases for the stats category.
    if ($first =~ /^(?:logs|tools)$/i) {
        return _mbHelpSendInternalList($ctx, 'stats');
    }

    if ($first =~ /^(?:search|find|grep)$/i) {
        my $term = join(' ', @args[1 .. $#args]);
        return _mbHelpSendSearchResults($ctx, $term);
    }

    if ($first =~ /^(?:level|role)$/i) {
        my $level_query = join(' ', @args[1 .. $#args]);
        return _mbHelpSendLevelResults($ctx, $level_query);
    }

    # mb488: "help <category>" (e.g. help general, help radio, help factoids)
    # lists that category — the names shown by the category index. A command of
    # the same name still wins (help stats -> the stats command), so we only
    # route to a category when $first names a category AND is NOT a command.
    if ($first ne '' && !isIrcChannelTarget($first) && @args == 1) {
        my $key = lc $first;
        $key =~ s/[\s-]+/_/g;
        my %cats    = _mbHelpBuildCategories();
        my %aliases = _mbHelpCategoryAliases();
        my $canon   = exists $aliases{$key} ? $aliases{$key} : $key;
        my %internal = _mbHelpInternalCommands();
        if (exists $cats{$canon} && !exists $internal{$key}) {
            return _mbHelpSendCategoryCommands($ctx, $canon);
        }
    }

    if ($first ne '' && !isIrcChannelTarget($first)) {
        my $cmd = lc $first;
        my %internal = _mbHelpInternalCommands();

        if (my $entry = $internal{$cmd}) {
            return _mbHelpSendInternalCommand($ctx, $cmd, $entry);
        }

        if (_mbHelpPublicCommandExists($self, $cmd)) {
            return mbDbShowCommand_ctx($ctx);
        }

        botNotice($self, $nick, "No internal help or PUBLIC_COMMANDS entry found for '$cmd'.");
        botNotice($self, $nick, "Try: searchcmd $cmd");
        botNotice($self, $nick, "Try: showcommands #channel");
        botNotice($self, $nick, "Documentation: https://github.com/teuk/mediabot_v3/wiki");
        return 1;
    }

    my $channel = $ctx->channel // '';

    # mb486: an explicit "help #channel" still lists that channel's dynamic
    # PUBLIC_COMMANDS. A bare "help" (no argument) now shows the welcome screen
    # — categories + navigation — instead of a dead-end syntax line (in private)
    # or silently dumping the channel's custom commands (on a channel).
    if (isIrcChannelTarget($first)) {
        return userShowcommandsChannel_ctx($ctx);
    }

    return _mbHelpSendWelcome($ctx);
}

# Handle bot nick triggered messages - natural patterns + Hailo fallback
sub mbHandleNickTriggered {
    my ($ctx, $what) = @_;

    my $self     = $ctx->bot;
    my $sNick    = $ctx->nick;
    my $sChannel = $ctx->channel;

    if ($what =~ /how\s+old\s+(are|r)\s+(you|u)/i) {
        displayBirthDate_ctx($ctx);
    }
    elsif ($what =~ /who.*(your daddy|is your daddy)/i) {
        my $owner = getChannelOwner($self, $sChannel);
        my $reply = defined $owner && $owner ne ""
            ? "Well I'm registered to $owner on $sChannel, but Te[u]K's my daddy"
            : "I have no clue of who is $sChannel\'s owner, but Te[u]K's my daddy";
        botPrivmsg($self, $sChannel, $reply);
    }
    elsif ($what =~ /^(thx|thanx|thank you|thanks)$/i) {
        botPrivmsg($self, $sChannel, "you're welcome $sNick");
    }
    elsif ($what =~ /who.*StatiK/i) {
        botPrivmsg($self, $sChannel, "StatiK is my big brother $sNick, he's awesome !");
    }
    else {
        # 🧠 Hailo fallback
        my $id_chanset_list = getIdChansetList($self, "Hailo");
        my $id_channel_set  = getIdChannelSet($self, $sChannel, $id_chanset_list);

        unless (
            is_hailo_excluded_nick($self, $sNick)
            || $what =~ /^[!]/
            || $what =~ /^@{[$self->{conf}->get('main.MAIN_PROG_CMD_CHAR')]}/
        ) {
            # mb361-B1: Hailo initialization is allowed to fail without taking
            # IRC message handling down or incrementing the timeout metric.
            my $hailo = get_hailo_runtime($self);
            return unless $hailo;

            my $sCurrentNick = $self->{irc}->nick_folded;
            $what =~ s/\Q$sCurrentNick\E//g;

            $what = decode("UTF-8", $what, sub { decode("iso-8859-2", chr(shift)) });

            # AA5+AA6: timeout + metrics around Hailo brain call
            $self->{metrics}->inc('mediabot_hailo_learn_reply_total') if $self->{metrics};
            my $sAnswer = eval {
                local $SIG{ALRM} = sub { die "Hailo timeout\n" };
                alarm(5);
                my $r = $hailo->learn_reply($what);
                alarm(0);
                $r;
            };
            alarm(0);  # ensure alarm is cleared even on exception
            if ($@) {
                $self->{logger}->log(1, "AA5: Hailo learn_reply timeout or error: $@");
                $self->{metrics}->inc('mediabot_hailo_timeout_total') if $self->{metrics};
            } elsif (defined $sAnswer && $sAnswer ne '' && $sAnswer !~ /^\Q$what\E\s*\.$/i) {
                $self->{logger}->log(4, "learn_reply $what from $sNick : $sAnswer");
                botPrivmsg($self, $sChannel, $sAnswer);
            }
        }
    }
}


# Handle private commands (same as public but with channel = nick)
sub mbCommandPrivate {
    my ($self, $message, $sNick, $sCommand, @tArgs) = @_;

    # Antiflood note:
    # AF4/checkChanFlood is intentionally public-channel only.
    # Private commands have no channel context here and include login/admin
    # workflows that should not be silently blocked by a channel flood guard.

    # Normalize command - q and Q are the same
    $sCommand = lc $sCommand;

    # DD5: log private command dispatch at DEBUG3
    $self->{logger}->log(3, "mbCommandPrivate: !$sCommand from $sNick")
        if $self->{logger} && $sCommand ne 'q';

    # CC1: per-command cooldown for expensive commands
    {
        my $wait = checkCmdCooldown($self, undef, $sCommand);
        if ($wait > 0) {
            # IMP11
            my $wait_str2 = $wait >= 60
                ? do { my $m = int($wait/60); my $s = $wait%60;
                       $s ? "${m}m ${s}s" : "${m}m"; }
                : "${wait}s";
            botNotice($self, $sNick,
                "!$sCommand is cooling down — wait $wait_str2.");
            return;
        }
    }

    # Build Context once, used by all handlers
    my $ctx = Mediabot::Context->new(
        bot     => $self,
        message => $message,
        nick    => $sNick,
        channel => $sNick,   # private context: reply target is the nick
        command => $sCommand,
        args    => \@tArgs,
    );

    # Attach a Command object to the Context for handlers that want it
    $ctx->{command_obj} = Mediabot::Command->new(
        name    => $sCommand,
        args    => \@tArgs,
        raw     => join(" ", $sCommand, @tArgs),
        context => $ctx,
        source  => 'private',
    );

    if ($self->{metrics} && defined $sCommand && length $sCommand) {
        $self->{metrics}->inc(
            'mediabot_commands_private_total',
            { command => $sCommand }
        );
    }

    # ---------------------------------------------------------------------------
    # Command dispatch table
    # All handlers receive a Mediabot::Context object.
    # Legacy handlers (pass, ident, topic, update, play, radiopub, debug) still
    # receive the old signature ($self, $message, $sNick, $sChannel, @tArgs)
    # and are wrapped in closures for forward compatibility.
    # ---------------------------------------------------------------------------
    my %command_table = (

        # --- Legacy handlers (not yet migrated to Context) ---
        pass        => sub { userPass_ctx($ctx) },
        ident       => sub { userIdent_ctx($ctx) },
        topic       => sub { userTopicChannel_ctx($ctx) },
        update      => sub { update_ctx($ctx) },
        debug       => sub { debug_ctx($ctx) },

        # --- Context-based handlers ---
        status      => sub { mbStatus_ctx($ctx) },
        radiostatus => sub { radioStatus_ctx($ctx) },
        radiomounts => sub { radioMounts_ctx($ctx) },
        echo        => sub { mbEcho($ctx) },
        die         => sub { mbQuit_ctx($ctx) },
        nick        => sub { mbChangeNick_ctx($ctx) },
        addtimer    => sub { mbAddTimer_ctx($ctx) },
        remtimer    => sub { mbRemTimer_ctx($ctx) },
        timers      => sub { mbTimers_ctx($ctx) },
        register    => sub { mbRegister_ctx($ctx) },
        msg         => sub { msgCmd_ctx($ctx) },
        dump        => sub { dumpCmd_ctx($ctx) },
        say         => sub { sayChannel_ctx($ctx) },
        act         => sub { actChannel_ctx($ctx) },
        song        => sub { song_ctx($ctx) },
        play        => sub { radioPlay_ctx($ctx) },
        radioimport => sub { radioImport_ctx($ctx) },
        commands    => sub {
            $ctx->{args} = [ 'commands' ];
            mbHelp_ctx($ctx);
        },
        radioqueue  => sub { radioQueue_ctx($ctx) },
        radiopush   => sub { radioPush_ctx($ctx) },
        radioskip   => sub { radioSkip_ctx($ctx) },
        radioflush  => sub { radioFlush_ctx($ctx) },
        adduser     => sub { addUser_ctx($ctx) },
        useradd     => sub { addUser_ctx($ctx) }, # legacy alias
        deluser     => sub { delUser_ctx($ctx) },
        users       => sub { userStats_ctx($ctx) },
        cstat       => sub { userCstat_ctx($ctx) },
        login       => sub { userLogin_ctx($ctx) },
        logout      => sub { userLogout_ctx($ctx) },
        userinfo    => sub { userInfo_ctx($ctx) },
        addhost     => sub { addUserHost_ctx($ctx) },
        addchan     => sub { addChannel_ctx($ctx) },
        chanset     => sub { channelSet_ctx($ctx) },
        purge       => sub { purgeChannel_ctx($ctx) },
        part        => sub { channelPart_ctx($ctx) },
        join        => sub { channelJoin_ctx($ctx) },
        add         => sub { channelAddUser_ctx($ctx) },
        del         => sub { channelDelUser_ctx($ctx) },
        modinfo     => sub { userModinfo_ctx($ctx) },
        op          => sub { userOpChannel_ctx($ctx) },
        deop        => sub { userDeopChannel_ctx($ctx) },
        invite      => sub { userInviteChannel_ctx($ctx) },
        voice       => sub { userVoiceChannel_ctx($ctx) },
        devoice     => sub { userDevoiceChannel_ctx($ctx) },
        kick        => sub { userKickChannel_ctx($ctx) },
        showcommands => sub { userShowcommandsChannel_ctx($ctx) },
        chaninfo    => sub { userChannelInfo_ctx($ctx) },
        chanlist    => sub { channelList_ctx($ctx) },
        channels    => sub { channelList_ctx($ctx) },
        channellist => sub { channelList_ctx($ctx) },
        whoami      => sub { userWhoAmI_ctx($ctx) },
        auth        => sub { userAuthNick_ctx($ctx) },
        verify      => sub { userVerifyNick_ctx($ctx) },
        access      => sub { userAccessChannel_ctx($ctx) },
        addcmd      => sub { mbDbAddCommand_ctx($ctx) },
        remcmd      => sub { mbDbRemCommand_ctx($ctx) },
        modcmd      => sub { mbDbModCommand_ctx($ctx) },
        mvcmd       => sub { mbDbMvCommand_ctx($ctx) },
        chowncmd    => sub { mbChownCommand_ctx($ctx) },
        showcmd     => sub { mbDbShowCommand_ctx($ctx) },
        chanstatlines => sub { channelStatLines_ctx($ctx) },
        whotalk     => sub { whoTalk_ctx($ctx) },
        whotalks    => sub { whoTalk_ctx($ctx) },
        countcmd    => sub { mbCountCommand_ctx($ctx) },
        topcmd      => sub { mbTopCommand_ctx($ctx) },
        popcmd      => sub { mbPopCommand_ctx($ctx) },
        searchcmd   => sub { mbDbSearchCommand_ctx($ctx) },
        lastcmd     => sub { mbLastCommand_ctx($ctx) },
        owncmd      => sub { mbDbOwnersCommand_ctx($ctx) },
        holdcmd     => sub { mbDbHoldCommand_ctx($ctx) },
        addcatcmd   => sub { mbDbAddCategoryCommand_ctx($ctx) },
        chcatcmd    => sub { mbDbChangeCategoryCommand_ctx($ctx) },
        topsay      => sub { userTopSay_ctx($ctx) },
        checkhostchan => sub { mbDbCheckHostnameNickChan_ctx($ctx) },
        checkhost   => sub { mbDbCheckHostnameNick_ctx($ctx) },
        checknick   => sub { mbDbCheckNickHostname_ctx($ctx) },
        greet       => sub { userGreet_ctx($ctx) },
        nicklist    => sub { channelNickList_ctx($ctx) },
        rnick       => sub { randomChannelNick_ctx($ctx) },
        birthdate   => sub { displayBirthDate_ctx($ctx) },
        ignores     => sub { IgnoresList_ctx($ctx) },
        ignore      => sub { addIgnore_ctx($ctx) },
        unignore    => sub { delIgnore_ctx($ctx) },
        lastcom     => sub { lastCom_ctx($ctx) },
        moduser     => sub { mbModUser_ctx($ctx) },
        antifloodset => sub { setChannelAntiFloodParams_ctx($ctx) },
        rehash      => sub { mbRehash_ctx($ctx) },
        ai           => sub { claude_ctx($ctx) },  # P4: !ai in private (no chanset gate)
    );

    if (my $handler = $command_table{$sCommand}) {
        $self->{logger}->log(4, "PRIVATE: $sNick triggered $sCommand");
        return $handler->();
    }

    $self->{logger}->log(4, $message->prefix . " Private command '$sCommand' not found");
    return undef;
}

# Set connection timestamp (used for uptime calculation)
sub setConnectionTimestamp {
	my ($self,$iConnectionTimestamp) = @_;
	$self->{iConnectionTimestamp} = $iConnectionTimestamp;
}

# Get connection timestamp
sub getConnectionTimestamp {
	my $self = shift;
	return $self->{iConnectionTimestamp};
}

# Set quit flag (used to signal shutdown)
sub setQuit {
	my ($self,$iQuit) = @_;
	$self->{Quit} = $iQuit;
}

# Get quit flag
sub getQuit {
	my $self = shift;
	return $self->{Quit};
}


# ---------------------------------------------------------------------------
# process_expired_channel_bans()
#
# Called periodically by the main event loop.
#
# For each active CHANNEL_BAN whose expires_at is in the past:
#   - resolve channel id -> channel name
#   - send MODE #channel -b mask
#   - mark the ban inactive in DB
#
# This method is deliberately conservative:
#   - if the IRC object is not ready, it does nothing
#   - if a channel cannot be resolved, it logs and skips
#   - if MODE -b fails, it keeps the ban active for a later retry
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# purge_channel_log() — delete CHANNEL_LOG entries older than N days
# ---------------------------------------------------------------------------
sub purge_channel_log {
    my ($self) = @_;
    my $days = int(eval { $self->{conf}->get('main.CHANNEL_LOG_RETENTION_DAYS') } // 90);
    return if $days <= 0;
    my $dbh = $self->{db} ? $self->{db}->ensure_connected() : $self->{dbh};
    my $sth = $dbh->prepare(
        "DELETE FROM CHANNEL_LOG WHERE ts < DATE_SUB(NOW(), INTERVAL ? DAY)"
    ) or return;
    eval { $sth->execute($days) };
    if ($@) { $self->{logger}->log(1, "purge_channel_log: $@"); return; }
    my $rows = $sth->rows // 0;
    $sth->finish;

    if ($rows) {
        my $msg = "purge_channel_log: $rows row(s) deleted (>${days}d)";
        $self->{logger}->log(2, $msg);
        noticeConsoleChan($self, $msg);
    }

    return $rows;
}

# ---------------------------------------------------------------------------
# post_onthisday_digest() — mb496
# Daily "on this day" digest: once a day, proactively post the onthisday recap
# to every joined channel that opted IN via the OnThisDayDigest chanset. This
# turns the reactive !onthisday (mb489) into a channel ritual that sparks
# conversation on its own. Shares _onthisday_lines() with the command, so the
# two never drift. Opt-IN (default off): a spontaneous post is more intrusive
# than a command, so channels must ask for it.
# Read-only against CHANNEL_LOG; silent on channels with no history that day.
# ---------------------------------------------------------------------------
sub post_onthisday_digest {
    my ($self) = @_;
    my $dbh = $self->{db} ? eval { $self->{db}->ensure_connected() } : $self->{dbh};
    $dbh ||= $self->{dbh};
    return unless $dbh;

    my $posted = 0;
    for my $chan_obj (values %{ $self->{channels} // {} }) {
        next unless $chan_obj;

        # canonical channel name for display + chanset lookup
        my $channel = eval { $chan_obj->get_name };
        next unless defined $channel && $channel =~ /^[#&]/;

        # opt-IN only
        next unless eval {
            Mediabot::Helpers::chanset_enabled($self, $channel, 'OnThisDayDigest', default => 0)
        };

        my $id_channel = eval { $chan_obj->get_id };
        next unless defined $id_channel;

        my @lines = Mediabot::UserCommands::_onthisday_lines($self, $id_channel, $channel);
        next unless @lines;   # nothing on this calendar day: stay quiet

        # Post to the channel (bounded), with a small header so it reads as a
        # daily feature rather than an answer to someone.
        Mediabot::Helpers::botPrivmsg($self, $channel, "\x02On this day\x02 — a look back at $channel:");
        my $sent = 0;
        for my $line (@lines) {
            last if $sent >= 8;   # hard cap, _onthisday_lines already bounds itself
            Mediabot::Helpers::botPrivmsg($self, $channel, $line);
            $sent++;
        }
        $posted++;
        $self->{logger}->log(3, "post_onthisday_digest: posted to $channel ($sent line(s))")
            if $self->{logger};
    }

    $self->{logger}->log(3, "post_onthisday_digest: done, $posted channel(s)")
        if $self->{logger} && $posted;
    return $posted;
}
# ---------------------------------------------------------------------------
sub purge_user_seen {
    my ($self) = @_;
    my $days = int(eval { $self->{conf}->get('main.USER_SEEN_RETENTION_DAYS') } // 180);
    return if $days <= 0;
    my $dbh = $self->{db} ? $self->{db}->ensure_connected() : $self->{dbh};
    my $sth = $dbh->prepare(
        "DELETE FROM USER_SEEN WHERE seen_at < DATE_SUB(NOW(), INTERVAL ? DAY)"
    ) or return;
    eval { $sth->execute($days) };
    if ($@) { $self->{logger}->log(1, "purge_user_seen: $@"); return; }
    my $rows = $sth->rows // 0;
    $sth->finish;

    if ($rows) {
        my $msg = "purge_user_seen: $rows stale nick(s) purged (>${days}d)";
        $self->{logger}->log(2, $msg);
        noticeConsoleChan($self, $msg);
    }

    return $rows;
}

sub process_expired_channel_bans {
    my ($self) = @_;

    return 0 unless $self->{channel_ban};
    return 0 unless $self->{irc};

    my @expired = eval { $self->{channel_ban}->expired_bans };
    if ($@) {
        my $err = $@;
        $err =~ s/\s+/ /g;
        $self->{logger}->log(1, "channelban: failed to fetch expired bans: $err");
        return 0;
    }

    return 0 unless @expired;

    my $done = 0;

    BAN:
    for my $ban (@expired) {
        my $id_channel = $ban->{id_channel};
        my $mask       = $ban->{mask};
        my $id_ban     = $ban->{id_channel_ban};

        unless ($id_channel && $mask && $id_ban) {
            $self->{logger}->log(1, "channelban: invalid expired ban row, skipping");
            next BAN;
        }

        my $channel_name = '';

        for my $name (sort keys %{ $self->{channels} || {} }) {
            my $ch = $self->{channels}{lc $name} || next;
            my $ch_id = eval { $ch->get_id };
            if (defined $ch_id && $ch_id == $id_channel) {
                $channel_name = eval { $ch->get_name } || $name;
                last;
            }
        }

        unless ($channel_name) {
            $self->{logger}->log(1, "channelban: expired ban #$id_ban references unknown channel id=$id_channel");
            next BAN;
        }

        $self->{logger}->log(2, "channelban: expiring ban #$id_ban on $channel_name mask=$mask");

        # Verify the bot is actually present in the channel before sending MODE -b.
        # If not, skip the IRC command but still mark the ban removed in DB so it
        # does not pile up — the IRC ban either expired naturally or the bot was
        # absent when it was set.
        my $bot_nick = eval { $self->{irc}->nick_folded } // '';
        my @chan_nicks = $self->gethChannelsNicksOnChan($channel_name);
        my $bot_on_chan = grep { lc($_) eq lc($bot_nick) } @chan_nicks;

        my $mode_ok;
        if ($bot_on_chan) {
            $mode_ok = eval {
                $self->{irc}->send_message("MODE", undef, ($channel_name, "-b", $mask));
                1;
            };

            unless ($mode_ok) {
                my $err = $@ || 'unknown error';
                $err =~ s/\s+/ /g;
                $self->{logger}->log(1, "channelban: MODE -b failed for expired ban #$id_ban on $channel_name $mask: $err");
                next BAN;
            }
        }
        else {
 $self->{logger}->log(2, "channelban: bot not on $channel_name -- skipping MODE -b for expired ban #$id_ban, marking removed in DB");
            $mode_ok = 1;   # proceed to DB cleanup
        }

        my ($rows, $err) = eval {
            $self->{channel_ban}->mark_removed(
                id_channel      => $id_channel,
                selector        => $id_ban,
                removed_by      => undef,
                removed_by_nick => 'system',
                remove_reason   => 'expired',
            );
        };

        if ($@) {
            my $e = $@;
            $e =~ s/\s+/ /g;
            $self->{logger}->log(1, "channelban: DB mark_removed failed for expired ban #$id_ban: $e");
            next BAN;
        }

        if ($err) {
            $self->{logger}->log(1, "channelban: DB mark_removed error for expired ban #$id_ban: $err");
            next BAN;
        }

        $done++;
        if ($self->{metrics}) {
            $self->{metrics}->inc('mediabot_channel_bans_expired_total');
        }
        $self->{logger}->log(2, "channelban: expired ban #$id_ban removed from $channel_name ($mask)");
    }

    return $done;
}


# ---------------------------------------------------------------------------
# _fetch_user_for_dcc($nick)
#
# Shared DB lookup for DCC CHAT validation.
# Returns hashref {id_user, nickname, level, description} or undef.
# ---------------------------------------------------------------------------
sub _fetch_user_for_dcc {
    my ($self, $nick) = @_;

    my $sth = $self->{dbh}->prepare(q{
        SELECT u.id_user, u.nickname, ul.level, ul.description
        FROM USER u
        JOIN USER_LEVEL ul ON ul.id_user_level = u.id_user_level
        WHERE u.nickname = ?
        LIMIT 1
    });

    unless ($sth && $sth->execute($nick)) {
 $self->{logger}->log(1, "DCC: DB error for nick '$nick' " . ($DBI::errstr // 'unknown'));
        $sth->finish if $sth;
        return undef;
    }

    my $row = $sth->fetchrow_hashref;
    $sth->finish;
    return $row;
}

# ---------------------------------------------------------------------------
# _handle_ctcp_chat_request($message, $nick)
#
# Called when a simple Eggdrop-style CTCP CHAT request is received:
#   /ctcp <botnick> CHAT
#
# The requester must be a known Mediabot user with global level <= 1
# before we offer a DCC CHAT Partyline session.
# ---------------------------------------------------------------------------
sub _handle_ctcp_chat_request {
    my ($self, $message, $nick) = @_;

    my $logger = $self->{logger};
    my $dbh    = $self->{dbh};

    unless ($self->{partyline} && $self->{partyline}->can('offer_dcc_chat')) {
        $logger->log(1, "CTCP CHAT from $nick: Partyline not available - ignored");
        return;
    }

    my $row = $self->_fetch_user_for_dcc($nick);

    unless ($row) {
        $logger->log(2, "CTCP CHAT from $nick: unknown user or DB error - ignored");
        return;
    }

    unless (defined($row->{level}) && $row->{level} <= 1) {
        $logger->log(2, sprintf(
            "CTCP CHAT from %s: insufficient level (%s=%d) - ignored",
            $nick, $row->{description} // '?', $row->{level} // -1
        ));
        return;
    }

    $logger->log(2, sprintf(
        "CTCP CHAT from %s (level=%s): offering DCC CHAT",
        $nick, $row->{description}
    ));

    $self->{partyline}->offer_dcc_chat($nick);
}

# ---------------------------------------------------------------------------
# _handle_dcc_chat_request($message, $nick, $ip_int, $port)
#
# Called when a CTCP DCC CHAT request is received as a private PRIVMSG.
# Validates the requesting user (must be known in DB with level <= 1),
# then delegates the actual TCP connection to Partyline->accept_dcc_chat().
# ---------------------------------------------------------------------------

sub _dcc_token_hint {
    my ($token) = @_;

    return 'none' unless defined $token && $token ne '';

    my $s = "$token";
    return 'redacted' if length($s) <= 4;

    my $prefix = substr($s, 0, 2);
    my $suffix = substr($s, -2);

    return $prefix . '...' . $suffix;
}


sub _handle_dcc_chat_request {
    my ($self, $message, $nick, $ip_int, $port, $token) = @_;

    my $logger = $self->{logger};
    my $dbh    = $self->{dbh};

    # ── Detect passive DCC CHAT (ip=0 port=0 token=opaque-safe-id) ───────────────────────
    # mb142-B2: token alphanumerique accepte, pas seulement numerique
    my $is_passive = (defined $ip_int && $ip_int == 0
                   && defined $port   && $port   == 0
                   && defined $token  && length($token) > 0
                   && $token =~ /^[A-Za-z0-9._-]+$/);

    # MB332-B1: an active DCC request controls an outbound connection made by
    # the bot. Validate both the 32-bit address and the destination class before
    # looking up the user or delegating to Partyline. Passive DCC keeps its
    # historical token-based flow and does not provide an outbound target here.
    my ($active_target_ok, $active_ip, $active_target_reason) = (1, undef, 'passive');
    unless ($is_passive) {
        ($active_target_ok, $active_ip, $active_target_reason)
            = validate_dcc_active_target($ip_int, $port);

        unless ($active_target_ok) {
            my $safe_ip = defined($active_ip) ? $active_ip : 'invalid';
            my $safe_port = defined($port) ? $port : 'undef';
            $logger->log(
                1,
                "DCC CHAT from $nick: rejected active target "
                . "$safe_ip:$safe_port reason=$active_target_reason"
            );
            return;
        }
    }

    # ── Partyline must be available ──────────────────────────────────────────
    unless ($self->{partyline} && $self->{partyline}->can('accept_dcc_chat')) {
        $logger->log(1, "DCC CHAT from $nick: Partyline not available - ignored");
        return;
    }

    # ── Look up user in DB - must exist and have level <= 1 ─────────────────
    my $row = $self->_fetch_user_for_dcc($nick);

    unless ($row) {
        $logger->log(2, "DCC CHAT from $nick: unknown user or DB error - ignored");
        return;
    }

    unless (defined($row->{level}) && $row->{level} <= 1) {
        $logger->log(2, sprintf(
            "DCC CHAT from %s: insufficient level (%s=%d) - ignored",
            $nick, $row->{description} // '?', $row->{level} // -1
        ));
        return;
    }

    # ── Delegate to Partyline ────────────────────────────────────────────────
    if ($is_passive) {
        my $token_hint = _dcc_token_hint($token);
        $logger->log(2, sprintf(
            "DCC CHAT from %s (level=%s): passive mode - token=%s",
            $nick, $row->{description}, $token_hint
        ));
        $self->{partyline}->accept_dcc_chat_passive($nick, $token);
    }
    else {
        $logger->log(2, sprintf(
            "DCC CHAT from %s (level=%s): active mode - target=%s:%d",
            $nick, $row->{description}, $active_ip, $port
        ));
        $self->{partyline}->accept_dcc_chat($nick, $ip_int, $port);
    }
}

1;

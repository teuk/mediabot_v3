package Mediabot::Partyline::Commands;

# =============================================================================
# Mediabot::Partyline::Commands
# =============================================================================
# MB678-IV-A: Partyline plugin/ScriptDryRun command extraction.
#
# The historical Mediabot::Partyline method surface remains available via
# import so existing callers and tests keep the same API while the commands
# progressively leave the parent module.
# =============================================================================

use strict;
use warnings;
use utf8;
use Exporter 'import';
use Encode qw(encode);
use Mediabot::Helpers ();
use Mediabot::External ();

our @EXPORT_OK = qw(
    _cmd_scriptdryrun
    _plugin_info_text
    _plugin_config_display_value
    _cmd_plugins
    _cmd_help
    _cmd_console
    _cmd_motd
    _send_motd
    _cmd_whom
    _cmd_match
    _cmd_boot
    _cmd_whois
    _cmd_log
    _cmd_timers
    _format_duration
    _seconds_to_human
    _cmd_schedule
    _cmd_status
    _cmd_metrics
    _cmd_channels
    _cmd_bcast
    _cmd_whochan
    _cmd_top
    _cmd_remind
    _cmd_seen
    _cmd_purgereminders
    _cmd_karma
    _cmd_karmahist
    _reload_configuration_file
    _cmd_reloadconf
    _cmd_reload
    _cmd_lusers
    _cmd_stats
    _cmd_join
    _cmd_part
    _cmd_nick
    _cmd_raw
    _cmd_rehash
    _cmd_restart
    _cmd_ai
    _cmd_persona
    _cmd_quota
    _cmd_ping
    _cmd_uptime
    _cmd_dccstat
    _cmd_stat
    _cmd_dbstats
    _cmd_bans
    _cmd_ban
    _cmd_unban
    _cmd_topic
    _cmd_kick
    _cmd_unmute
    _cmd_floodset
    _cmd_cmdcooldown
    _cmd_netsplit
    _cmd_floodstatus
    _cmd_flushcooldown
    _cmd_history
    _cmd_say
    _cmd_who
    _cmd_chanlog
    _cmd_nickinfo
    _cmd_who_chan
    _cmd_kv
    _cmd_achievementprofile
);

# ---------------------------------------------------------------------------
# .scriptdryrun [status|last|config|timers|canceltimers|events|clearevents|reload] - ScriptDryRun plugin visibility
sub _cmd_scriptdryrun {
    my ($self, $stream, $id, $arg) = @_;

    $arg //= '';
    $arg =~ s/^\s+|\s+$//g;
    my $mode = lc($arg || 'status');

    my $bot = $self->{bot};
    unless ($bot && $bot->can('plugin_manager') && $bot->plugin_manager) {
        $stream->write("ScriptDryRun: PluginManager not initialized\r\n");
        return;
    }

    my $pm = $bot->plugin_manager;
    my $plugin = eval { $pm->object_for('Mediabot::Plugin::ScriptDryRun') };

    # mb180-B1: read-only partyline visibility for the ScriptDryRun bridge.
    # This command never loads plugins, executes scripts, applies actions,
    # sends IRC messages, creates timers or touches the database.
    # mb527-B1: timers/canceltimers extend this with pending-timer visibility
    # and explicit cancellation. Cancellation only STOPS armed timers and
    # frees their pending slots; it never creates or executes anything.
    if ($mode eq 'config') {
        $stream->write("ScriptDryRun config:\r\n");
        $stream->write("  plugin module: Mediabot::Plugin::ScriptDryRun\r\n");
        $stream->write("  script path keys:\r\n");
        $stream->write("    plugins.ScriptDryRun.SCRIPT\r\n");
        $stream->write("    plugins.ScriptDryRun.script\r\n");
        $stream->write("    plugins.script_dryrun.SCRIPT\r\n");
        $stream->write("    plugins.script_dryrun.script\r\n");
        $stream->write("    SCRIPT_DRYRUN_SCRIPT\r\n");
        $stream->write("    SCRIPT_DRYRUN_PATH\r\n");
        $stream->write("  command filter keys:\r\n");
        $stream->write("    plugins.ScriptDryRun.COMMANDS\r\n");
        $stream->write("    plugins.ScriptDryRun.commands\r\n");
        $stream->write("    plugins.script_dryrun.COMMANDS\r\n");
        $stream->write("    plugins.script_dryrun.commands\r\n");
        $stream->write("    SCRIPT_DRYRUN_COMMANDS\r\n");
        $stream->write("  command route keys:\r\n");
        $stream->write("    plugins.ScriptDryRun.ROUTES\r\n");
        $stream->write("    plugins.ScriptDryRun.routes\r\n");
        $stream->write("    plugins.script_dryrun.ROUTES\r\n");
        $stream->write("    plugins.script_dryrun.routes\r\n");
        $stream->write("    SCRIPT_DRYRUN_ROUTES\r\n");
        $stream->write("  route format: command=script, other=script2\r\n");
        $stream->write("  command filter: optional explicit allow-list\r\n");
        $stream->write("  command routes: mapped commands are explicitly scoped and authorized\r\n");
        $stream->write("  SCRIPT fallback: used only when no route matches; keep scoped in apply mode\r\n");
        $stream->write("  action mode keys:\r\n");
        $stream->write("    plugins.ScriptDryRun.ACTION_MODE\r\n");
        $stream->write("    plugins.ScriptDryRun.action_mode\r\n");
        $stream->write("    plugins.script_dryrun.ACTION_MODE\r\n");
        $stream->write("    plugins.script_dryrun.action_mode\r\n");
        $stream->write("    SCRIPT_DRYRUN_ACTION_MODE\r\n");
        $stream->write("  allowed IRC keys:\r\n");
        $stream->write("    plugins.ScriptDryRun.ALLOW_IRC\r\n");
        $stream->write("    plugins.ScriptDryRun.allow_irc\r\n");
        $stream->write("    plugins.script_dryrun.ALLOW_IRC\r\n");
        $stream->write("    plugins.script_dryrun.allow_irc\r\n");
        $stream->write("    SCRIPT_DRYRUN_ALLOW_IRC\r\n");
        $stream->write("  apply scope guard keys:\r\n");
        $stream->write("    plugins.ScriptDryRun.APPLY_REQUIRE_SCOPE\r\n");
        $stream->write("    plugins.ScriptDryRun.apply_require_scope\r\n");
        $stream->write("    plugins.script_dryrun.APPLY_REQUIRE_SCOPE\r\n");
        $stream->write("    plugins.script_dryrun.apply_require_scope\r\n");
        $stream->write("    SCRIPT_DRYRUN_APPLY_REQUIRE_SCOPE\r\n");
        # mb532-B1: la reference partyline doit couvrir TOUTES les cles du
        # plugin; EVENTS/EVENT_COOLDOWN (mb529) et CONFIG_<route> (mb531)
        # manquaient depuis leur introduction.
        $stream->write("  ban gate keys:\r\n");
        $stream->write("    plugins.ScriptDryRun.ALLOW_BAN\r\n");
        $stream->write("    plugins.ScriptDryRun.allow_ban\r\n");
        $stream->write("    plugins.script_dryrun.ALLOW_BAN\r\n");
        $stream->write("    plugins.script_dryrun.allow_ban\r\n");
        $stream->write("    SCRIPT_DRYRUN_ALLOW_BAN\r\n");
        $stream->write("  ban gate: ban/unban actions (MODE +b/-b, originating channel, full nick!user\@host mask) require apply + ALLOW_IRC + ALLOW_BAN (default: no); +b never targets the bot's own literal nick, while -b remains available as a repair path\r\n");
        $stream->write("  kick gate keys:\r\n");
        $stream->write("    plugins.ScriptDryRun.ALLOW_KICK\r\n");
        $stream->write("    plugins.ScriptDryRun.allow_kick\r\n");
        $stream->write("    plugins.script_dryrun.ALLOW_KICK\r\n");
        $stream->write("    plugins.script_dryrun.allow_kick\r\n");
        $stream->write("    SCRIPT_DRYRUN_ALLOW_KICK\r\n");
        $stream->write("  kick gate: kick actions require apply + ALLOW_IRC + ALLOW_KICK (default: no); the bot never kicks itself\r\n");
        $stream->write("  topic gate keys:\r\n");
        $stream->write("    plugins.ScriptDryRun.ALLOW_TOPIC\r\n");
        $stream->write("    plugins.ScriptDryRun.allow_topic\r\n");
        $stream->write("    plugins.script_dryrun.ALLOW_TOPIC\r\n");
        $stream->write("    plugins.script_dryrun.allow_topic\r\n");
        $stream->write("    SCRIPT_DRYRUN_ALLOW_TOPIC\r\n");
        $stream->write("  topic gate: topic actions require apply + ALLOW_IRC + ALLOW_TOPIC (default: no)\r\n");
        $stream->write("  event route keys:\r\n");
        $stream->write("    plugins.ScriptDryRun.EVENTS\r\n");
        $stream->write("    plugins.ScriptDryRun.events\r\n");
        $stream->write("    plugins.script_dryrun.EVENTS\r\n");
        $stream->write("    plugins.script_dryrun.events\r\n");
        $stream->write("    SCRIPT_DRYRUN_EVENTS\r\n");
        $stream->write("  event cooldown keys:\r\n");
        $stream->write("    plugins.ScriptDryRun.EVENT_COOLDOWN\r\n");
        $stream->write("    plugins.ScriptDryRun.event_cooldown\r\n");
        $stream->write("    plugins.script_dryrun.EVENT_COOLDOWN\r\n");
        $stream->write("    plugins.script_dryrun.event_cooldown\r\n");
        $stream->write("    SCRIPT_DRYRUN_EVENT_COOLDOWN\r\n");
        $stream->write("  per-route config keys:\r\n");
        $stream->write("    plugins.ScriptDryRun.CONFIG_<route>\r\n");
        $stream->write("    plugins.script_dryrun.CONFIG_<route>\r\n");
        $stream->write("    SCRIPT_DRYRUN_CONFIG_<ROUTE>\r\n");
        $stream->write("  event route format: join=script, topic=script2 (join/part/topic/kick only, no SCRIPT fallback)\r\n");
        $stream->write("  event cooldown: one run per event per channel per window (1-3600s, default 10)\r\n");
        $stream->write("  per-route config format: key=value; key2=value2 (keys [A-Za-z0-9_.-] max 64, values max 512, 20 keys/route)\r\n");
        $stream->write("  per-route config delivery: injected as data.config only when non-empty\r\n");
        $stream->write("  action modes: dry-run, apply\r\n");
        $stream->write("  IRC output requires: ACTION_MODE=apply and ALLOW_IRC=yes\r\n");
        $stream->write("  apply scope guard: when enabled, ACTION_MODE=apply requires COMMANDS or ROUTES\r\n");
        return;
    }

    if ($mode eq 'reload') {
        unless ($plugin) {
            $stream->write("ScriptDryRun: not loaded\r\n");
            $stream->write("  hint: load Mediabot::Plugin::ScriptDryRun explicitly or enable plugin autoload\r\n");
            return;
        }

        # mb537-B1: rechargement a chaud de l'etat de conf du plugin, a
        # utiliser apres .reloadconf/.rehash. Ne recharge PAS le fichier de
        # conf lui-meme (c'est le role de .reloadconf) et n'execute jamais
        # rien; compteurs, timers armes et fenetres de cooldown conserves.
        unless ($plugin->can('refresh_from_conf')) {
            $stream->write("ScriptDryRun: loaded plugin does not support conf refresh\r\n");
            return;
        }

        my @changed = eval { $plugin->refresh_from_conf };
        if ($@) {
            my $err = $@;
            $err =~ s/[\r\n]+/ /g;
            $stream->write("ScriptDryRun conf refresh failed: $err\r\n");
            return;
        }

        if (@changed) {
            $stream->write("ScriptDryRun conf refreshed (changed: " . join(', ', @changed) . ")\r\n");
            $stream->write("  note: armed timers keep the config snapshot they were armed with\r\n");
        }
        else {
            $stream->write("ScriptDryRun conf refreshed (no changes)\r\n");
        }
        return;
    }

    if ($mode eq 'events' || $mode eq 'clearevents') {
        unless ($plugin) {
            $stream->write("ScriptDryRun: not loaded\r\n");
            $stream->write("  hint: load Mediabot::Plugin::ScriptDryRun explicitly or enable plugin autoload\r\n");
            return;
        }

        if ($mode eq 'clearevents') {
            # mb536-B1: purge des fenetres de cooldown uniquement — routes,
            # compteurs et timers intacts; rien n'est execute.
            my $cleared = eval {
                $plugin->can('clear_event_cooldowns') ? $plugin->clear_event_cooldowns : 0;
            } || 0;
            $stream->write("ScriptDryRun event cooldown windows cleared: $cleared\r\n");
            return;
        }

        # mb536-B1: pendant de `timers` pour les evenements — routes,
        # compteurs, et l'etat des fenetres de cooldown par (evenement, canal)
        # qui etait jusqu'ici invisible pour l'operateur.
        my $routes_on = eval { $plugin->can('event_routes_enabled') ? $plugin->event_routes_enabled : 0 } ? 1 : 0;
        $stream->write("ScriptDryRun events:\r\n");
        unless ($routes_on) {
            $stream->write("  event_routes: disabled\r\n");
            return;
        }

        my $event_map = eval { $plugin->can('event_routes') ? $plugin->event_routes : {} };
        $event_map = {} unless ref($event_map) eq 'HASH';
        my @event_pairs = map { $_ . '=' . ($event_map->{$_} // '') } sort keys %$event_map;
        my $cooldown = eval { $plugin->can('event_cooldown') ? $plugin->event_cooldown : 10 } || 10;
        my $observed = eval { $plugin->can('observed_events') ? $plugin->observed_events : 0 } || 0;
        my $skipped  = eval { $plugin->can('skipped_events') ? $plugin->skipped_events : 0 } || 0;
        my $cd_skips = eval { $plugin->can('event_cooldown_skips') ? $plugin->event_cooldown_skips : 0 } || 0;

        $stream->write("  event_map: " . (@event_pairs ? join(',', @event_pairs) : 'none') . "\r\n");
        $stream->write("  event_cooldown: ${cooldown}s\r\n");
        $stream->write("  observed_events: $observed\r\n");
        $stream->write("  skipped_events: $skipped (cooldown: $cd_skips)\r\n");

        my @windows = eval {
            $plugin->can('event_cooldown_state') ? $plugin->event_cooldown_state : ();
        };
        @windows = () unless @windows && ref($windows[0]) eq 'HASH';

        unless (@windows) {
            $stream->write("  windows: none\r\n");
            return;
        }

        # Fenetres actives d'abord (remaining decroissant), puis expirees.
        @windows = sort {
            ($b->{remaining} || 0) <=> ($a->{remaining} || 0)
                || ($a->{event} || '') cmp ($b->{event} || '')
                || ($a->{channel} || '') cmp ($b->{channel} || '')
        } @windows;

        my $shown = 0;
        for my $w (@windows) {
            last if $shown >= 20;
            my %safe;
            for my $field (qw(event channel last_run_ago remaining)) {
                my $value = $w->{$field};
                $value = '' unless defined $value && !ref($value);
                $value =~ s/[\r\n]+/ /g;
                $safe{$field} = length($value) ? $value : '-';
            }
            my $status = ($safe{remaining} ne '-' && $safe{remaining} > 0)
                ? "cooling ($safe{remaining}s left)"
                : 'ready';
            $stream->write("  $safe{event} $safe{channel}: last=$safe{last_run_ago}s ago, $status\r\n");
            $shown++;
        }
        if (@windows > $shown) {
            my $more = @windows - $shown;
            $stream->write("  ... and $more more window(s)\r\n");
        }

        return;
    }

    if ($mode eq 'timers' || $mode eq 'canceltimers') {
        unless ($plugin) {
            $stream->write("ScriptDryRun: not loaded\r\n");
            $stream->write("  hint: load Mediabot::Plugin::ScriptDryRun explicitly or enable plugin autoload\r\n");
            return;
        }

        if ($mode eq 'canceltimers') {
            my $cancelled = eval {
                $plugin->can('cancel_script_timers') ? $plugin->cancel_script_timers : 0;
            } || 0;
            $stream->write("ScriptDryRun timers cancelled: $cancelled\r\n");
            return;
        }

        # mb527-B1: instantane en lecture seule des timers armes par les
        # scripts. Le plafond et le compteur de slots viennent du runner pour
        # exposer toute incoherence entre les deux couches.
        my @timers = eval {
            $plugin->can('script_timer_list') ? $plugin->script_timer_list : ();
        };
        @timers = () unless @timers && ref($timers[0]) eq 'HASH';

        my $runner = eval {
            $bot->can('script_action_runner') ? $bot->script_action_runner : undef;
        };
        my $cap = eval {
            $runner && $runner->can('max_pending_timers') ? $runner->max_pending_timers : undef;
        };
        my $runner_pending = eval {
            $runner && $runner->can('pending_timer_count') ? $runner->pending_timer_count : undef;
        };

        my $pending = scalar @timers;
        $stream->write("ScriptDryRun timers:\r\n");
        $stream->write("  pending: $pending" . (defined $cap ? " (cap $cap)" : '') . "\r\n");
        if (defined $runner_pending && $runner_pending != $pending) {
            $stream->write("  runner_pending: $runner_pending (mismatch)\r\n");
        }

        for my $t (@timers) {
            my %safe;
            for my $field (qw(name delay remaining channel nick command script)) {
                my $value = $t->{$field};
                $value = '' unless defined $value && !ref($value);
                $value =~ s/[\r\n]+/ /g;
                $safe{$field} = length($value) ? $value : '-';
            }
            $stream->write("  $safe{name}: remaining=$safe{remaining}s delay=$safe{delay}s"
                . " channel=$safe{channel} nick=$safe{nick} command=$safe{command}"
                . " script=$safe{script}\r\n");
        }

        return;
    }

    if ($mode ne 'status' && $mode ne 'last') {
        $stream->write("Usage: .scriptdryrun [status|last|config|timers|canceltimers|events|clearevents|reload]\r\n");
        return;
    }

    unless ($plugin) {
        $stream->write("ScriptDryRun: not loaded\r\n");
        $stream->write("  hint: load Mediabot::Plugin::ScriptDryRun explicitly or enable plugin autoload\r\n");
        return;
    }

    my $script_path = eval { $plugin->script_path };
    my $observed    = eval { $plugin->observed_public } || 0;
    my $skipped     = eval { $plugin->skipped_public } || 0;
    my $filtered    = eval { $plugin->can('filtered_public') ? $plugin->filtered_public : 0 } || 0;
    my $filter_on   = eval { $plugin->can('command_filter_enabled') ? $plugin->command_filter_enabled : 0 } ? 1 : 0;
    my @filter_list = eval { $plugin->can('command_filter_list') ? $plugin->command_filter_list : () };
    my $routes_on   = eval { $plugin->can('command_routes_enabled') ? $plugin->command_routes_enabled : 0 } ? 1 : 0;
    my @route_list  = eval { $plugin->can('command_route_list') ? $plugin->command_route_list : () };
    my $route_map   = eval { $plugin->can('command_routes') ? $plugin->command_routes : {} };
    $route_map = {} unless ref($route_map) eq 'HASH';
    my $action_mode = eval { $plugin->can('action_mode') ? $plugin->action_mode : 'dry-run' } || 'dry-run';
    my $allow_irc   = eval { $plugin->can('allow_irc') ? $plugin->allow_irc : 0 } ? 1 : 0;
    my $scope_guard = eval { $plugin->can('apply_require_scope') ? $plugin->apply_require_scope : 0 } ? 1 : 0;
    my $scope_restricted = eval { $plugin->can('apply_scope_is_restricted') ? $plugin->apply_scope_is_restricted : 0 } ? 1 : 0;
    my $scope_warning = eval { $plugin->can('apply_scope_warning') ? $plugin->apply_scope_warning : undef };
    my $last_error  = eval { $plugin->last_error };
    my $last_result = eval { $plugin->last_result };

    $stream->write("ScriptDryRun:\r\n");
    $stream->write("  loaded: yes\r\n");
    $stream->write("  script: " . (defined($script_path) && length("$script_path") ? $script_path : 'not configured') . "\r\n");
    $stream->write("  observed_public: $observed\r\n");
    $stream->write("  skipped_public: $skipped\r\n");
    $stream->write("  filtered_public: $filtered\r\n");
    # mb183-B1: include ScriptDryRun command filter visibility in read-only partyline status.
    $stream->write("  command_filter: " . ($filter_on ? 'enabled' : 'disabled') . "\r\n");
    if ($filter_on) {
        my $filter_text = @filter_list ? join(',', @filter_list) : 'none';
        $stream->write("  allowed_commands: $filter_text\r\n");
    }
    # mb185-B1: include ScriptDryRun command route visibility in read-only partyline status.
    $stream->write("  command_routes: " . ($routes_on ? 'enabled' : 'disabled') . "\r\n");
    if ($routes_on) {
        my @route_pairs = map { $_ . '=' . ($route_map->{$_} // '') } @route_list;
        my $route_text = @route_pairs ? join(',', @route_pairs) : 'none';
        $stream->write("  route_map: $route_text\r\n");
    }
    # mb188-B1: expose ScriptDryRun ACTION_MODE / ALLOW_IRC state in read-only partyline status.
    $stream->write("  action_mode: $action_mode\r\n");
    $stream->write("  allow_irc: " . ($allow_irc ? 'yes' : 'no') . "\r\n");
    my $allow_topic_545 = eval { $plugin->can('allow_topic') ? $plugin->allow_topic : 0 } ? 1 : 0;
    $stream->write("  allow_topic: " . ($allow_topic_545 ? 'yes' : 'no') . "\r\n");
    my $allow_kick_553 = eval { $plugin->can('allow_kick') ? $plugin->allow_kick : 0 } ? 1 : 0;
    $stream->write("  allow_kick: " . ($allow_kick_553 ? 'yes' : 'no') . "\r\n");
    # mb531-B1: expose per-route configuration presence.
    my @cfg_routes = eval { $plugin->can('configured_routes') ? $plugin->configured_routes : () };
    $stream->write("  config_routes: " . (@cfg_routes ? join(',', @cfg_routes) : 'none') . "\r\n");
    # mb529-B1: expose channel-event routing state (join/part/topic bridge).
    my $event_routes_on = eval { $plugin->can('event_routes_enabled') ? $plugin->event_routes_enabled : 0 } ? 1 : 0;
    $stream->write("  event_routes: " . ($event_routes_on ? 'enabled' : 'disabled') . "\r\n");
    if ($event_routes_on) {
        my $event_map = eval { $plugin->can('event_routes') ? $plugin->event_routes : {} };
        $event_map = {} unless ref($event_map) eq 'HASH';
        my @event_pairs = map { $_ . '=' . ($event_map->{$_} // '') } sort keys %$event_map;
        $stream->write("  event_map: " . (@event_pairs ? join(',', @event_pairs) : 'none') . "\r\n");
        my $cooldown = eval { $plugin->can('event_cooldown') ? $plugin->event_cooldown : 10 } || 10;
        my $observed_events = eval { $plugin->can('observed_events') ? $plugin->observed_events : 0 } || 0;
        my $skipped_events  = eval { $plugin->can('skipped_events') ? $plugin->skipped_events : 0 } || 0;
        my $cooldown_skips  = eval { $plugin->can('event_cooldown_skips') ? $plugin->event_cooldown_skips : 0 } || 0;
        $stream->write("  event_cooldown: ${cooldown}s\r\n");
        $stream->write("  observed_events: $observed_events\r\n");
        $stream->write("  skipped_events: $skipped_events (cooldown: $cooldown_skips)\r\n");
    }
    # mb190-B1: expose ScriptDryRun apply-scope guard state without executing scripts.
    $stream->write("  apply_require_scope: " . ($scope_guard ? 'yes' : 'no') . "\r\n");
    $stream->write("  apply_scope_restricted: " . ($scope_restricted ? 'yes' : 'no') . "\r\n");
    if (defined $scope_warning && length "$scope_warning") {
        $scope_warning =~ s/[\r\n]+/ /g;
        $stream->write("  apply_scope_warning: $scope_warning\r\n");
    }

    if (defined $last_error && length "$last_error") {
        $last_error =~ s/[\r\n]+/ /g;
        $stream->write("  last_error: $last_error\r\n");
    }

    unless ($last_result && ref($last_result) eq 'HASH') {
        $stream->write("  last_result: none\r\n");
        return;
    }

    my $script_result = $last_result->{script_result} || {};
    my $action_plan   = $last_result->{action_plan}   || {};

    $stream->write("  last_result_ok: " . ($last_result->{ok} ? 'yes' : 'no') . "\r\n");
    $stream->write("  dry_run: " . ($last_result->{dry_run} ? 'yes' : 'no') . "\r\n");
    # mb532-B1: depuis mb525/mb529 un run peut venir d'une commande, d'un
    # evenement de canal ou d'un rappel timer; l'operateur doit le voir.
    my $origin = 'command';
    if (defined $last_result->{timer_name} && length "$last_result->{timer_name}") {
        $origin = 'timer:' . $last_result->{timer_name};
    }
    elsif (defined $last_result->{event} && length "$last_result->{event}"
        && $last_result->{event} ne 'public_command') {
        $origin = 'event:' . $last_result->{event};
    }
    $origin =~ s/[\r\n]+/ /g;
    $stream->write("  origin: $origin\r\n");

    if ($mode eq 'status') {
        my $planned = ref($action_plan->{planned}) eq 'ARRAY' ? scalar @{ $action_plan->{planned} } : 0;
        my $errors  = ref($action_plan->{errors})  eq 'ARRAY' ? scalar @{ $action_plan->{errors} }  : 0;
        my $applied = ref($action_plan->{applied}) eq 'ARRAY' ? scalar @{ $action_plan->{applied} } : 0;
        my $apply_errors = ref($action_plan->{apply_errors}) eq 'ARRAY' ? scalar @{ $action_plan->{apply_errors} } : 0;
        my $has_apply_result = exists $action_plan->{applied_ok} || $applied || $apply_errors;

        $stream->write("  script_ok: " . ($script_result->{ok} ? 'yes' : 'no') . "\r\n");
        $stream->write("  action_plan_ok: " . ($action_plan->{ok} ? 'yes' : 'no') . "\r\n");
        $stream->write("  planned_actions: $planned\r\n");
        $stream->write("  action_errors: $errors\r\n");
        # mb191-B1: expose ScriptActionRunner apply results in read-only partyline status.
        if ($has_apply_result) {
            $stream->write("  applied_ok: " . ($action_plan->{applied_ok} ? 'yes' : 'no') . "\r\n");
            $stream->write("  applied_actions: $applied\r\n");
            $stream->write("  apply_errors: $apply_errors\r\n");
        }
        return;
    }

    my $timeout = $script_result->{timeout} ? 'yes' : 'no';
    my $exit = defined($script_result->{exit_code}) ? $script_result->{exit_code} : 'n/a';
    my $planned = ref($action_plan->{planned}) eq 'ARRAY' ? $action_plan->{planned} : [];
    my $errors  = ref($action_plan->{errors})  eq 'ARRAY' ? $action_plan->{errors}  : [];
    my $applied = ref($action_plan->{applied}) eq 'ARRAY' ? $action_plan->{applied} : [];
    my $apply_errors = ref($action_plan->{apply_errors}) eq 'ARRAY' ? $action_plan->{apply_errors} : [];
    my $has_apply_result = exists $action_plan->{applied_ok} || @$applied || @$apply_errors;

    $stream->write("  script_ok: " . ($script_result->{ok} ? 'yes' : 'no') . "\r\n");
    $stream->write("  script_timeout: $timeout\r\n");
    $stream->write("  script_exit_code: $exit\r\n");
    $stream->write("  command_filter: " . ($filter_on ? 'enabled' : 'disabled') . "\r\n");
    if ($filter_on) {
        my $filter_text = @filter_list ? join(',', @filter_list) : 'none';
        $stream->write("  allowed_commands: $filter_text\r\n");
    }
    $stream->write("  command_routes: " . ($routes_on ? 'enabled' : 'disabled') . "\r\n");
    if ($routes_on) {
        my @route_pairs = map { $_ . '=' . ($route_map->{$_} // '') } @route_list;
        my $route_text = @route_pairs ? join(',', @route_pairs) : 'none';
        $stream->write("  route_map: $route_text\r\n");
    }
    $stream->write("  action_mode: $action_mode\r\n");
    $stream->write("  allow_irc: " . ($allow_irc ? 'yes' : 'no') . "\r\n");
    my $allow_topic_545b = eval { $plugin->can('allow_topic') ? $plugin->allow_topic : 0 } ? 1 : 0;
    $stream->write("  allow_topic: " . ($allow_topic_545b ? 'yes' : 'no') . "\r\n");
    my $allow_kick_553b = eval { $plugin->can('allow_kick') ? $plugin->allow_kick : 0 } ? 1 : 0;
    $stream->write("  allow_kick: " . ($allow_kick_553b ? 'yes' : 'no') . "\r\n");
    $stream->write("  apply_require_scope: " . ($scope_guard ? 'yes' : 'no') . "\r\n");
    $stream->write("  apply_scope_restricted: " . ($scope_restricted ? 'yes' : 'no') . "\r\n");
    if (defined $scope_warning && length "$scope_warning") {
        $scope_warning =~ s/[\r\n]+/ /g;
        $stream->write("  apply_scope_warning: $scope_warning\r\n");
    }
    $stream->write("  planned_actions:\r\n");

    if (!@$planned) {
        $stream->write("    none\r\n");
    }
    else {
        my $idx = 0;
        for my $action (@$planned) {
            $idx++;
            my $type = defined($action->{type}) ? $action->{type} : '?';
            my $target = defined($action->{target}) ? $action->{target} : '';
            my $text = defined($action->{text}) ? $action->{text} : '';
            $text =~ s/[\r\n]+/ /g;
            $text = Mediabot::Helpers::truncate_utf8($text, 160);  # mb429-R1
            $stream->write("    $idx. type=$type target=$target text=$text\r\n");
        }
    }

    $stream->write("  action_errors:\r\n");
    if (!@$errors) {
        $stream->write("    none\r\n");
    }
    else {
        for my $err (@$errors) {
            my $index = defined($err->{index}) ? $err->{index} : '?';
            my $msg = defined($err->{error}) ? $err->{error} : 'unknown error';
            $msg =~ s/[\r\n]+/ /g;
            $stream->write("    index=$index error=$msg\r\n");
        }
    }

    if ($has_apply_result) {
        $stream->write("  applied_ok: " . ($action_plan->{applied_ok} ? 'yes' : 'no') . "\r\n");

        $stream->write("  applied_actions:\r\n");
        if (!@$applied) {
            $stream->write("    none\r\n");
        }
        else {
            for my $item (@$applied) {
                my $index = defined($item->{index}) ? $item->{index} : '?';
                my $type = defined($item->{type}) ? $item->{type} : '?';
                my $target = defined($item->{target}) ? $item->{target} : '';
                $target =~ s/[\r\n]+/ /g;
                $stream->write("    index=$index type=$type target=$target\r\n");
            }
        }

        $stream->write("  apply_errors:\r\n");
        if (!@$apply_errors) {
            $stream->write("    none\r\n");
        }
        else {
            for my $err (@$apply_errors) {
                my $index = defined($err->{index}) ? $err->{index} : '?';
                my $type = defined($err->{type}) ? $err->{type} : '?';
                my $msg = defined($err->{error}) ? $err->{error} : 'unknown error';
                $msg =~ s/[\r\n]+/ /g;
                $stream->write("    index=$index type=$type error=$msg\r\n");
            }
        }
    }

    return;
}


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
sub _cmd_plugins {
    my ($self, $stream, $id, $arg) = @_;

    $arg //= '';
    $arg =~ s/^\s+|\s+$//g;
    my $mode = lc($arg || 'summary');

    my $bot = $self->{bot};
    unless ($bot && $bot->can('plugin_manager') && $bot->plugin_manager) {
        $stream->write("PluginManager: not initialized\r\n");
        return;
    }

    my $pm = $bot->plugin_manager;

    # mb588-B1: cycle de vie a chaud — la partyline devient le poste de
    # pilotage de l'arc plugins v2. Les actions destructives (load/unload/
    # reload) exigent Owner (level 0) ; enable/disable exigent Master ou
    # mieux (level <= 1), comme .schedule. Chaque refus est explique, chaque
    # erreur de chargement est montree en clair (le die du PluginManager
    # porte deja la raison precise : manifest rejete, collision, methode
    # manquante...).
    my ($verb, @rest) = split /\s+/, $arg;
    $verb = lc($verb // '');
    if ($verb =~ /\A(?:load|loadscript|unload|reload|enable|disable|cleardata)\z/) {
        my $level = $self->{users}{$id}{level};
        my $need_owner = ($verb =~ /\A(?:load|loadscript|unload|reload|cleardata)\z/) ? 1 : 0;
        if ($need_owner && !(defined $level && $level == 0)) {
            $stream->write("Access denied: .plugins $verb requires Owner level.\r\n");
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
            $pm->unregister_plugin($target);
            $stream->write("Unloaded plugin '$target' (commands unmounted).\r\n");
            return;
        }
        if ($verb eq 'enable' || $verb eq 'disable') {
            $verb eq 'enable' ? $pm->enable($target) : $pm->disable($target);
            $stream->write("Plugin '$target' is now ${verb}d"
                . ($verb eq 'disable' ? " (mounted commands stay silent)" : "")
                . ".\r\n");
            return;
        }
        # reload : le VRAI rechargement — delete %INC puis load replace. Si le
        # nouveau code echoue (require/manifest/register), le die tombe AVANT
        # register_plugin : l'instance precedente reste enregistree et active.
        my $plug = $pm->plugin($target);
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
    my $autoload = eval { $bot->can('plugin_autoload_enabled') ? $bot->plugin_autoload_enabled : 0 } ? 'enabled' : 'disabled';
    my @all      = eval { $pm->list } ? $pm->list : ();
    my @enabled  = eval { $pm->list(enabled => 1) } ? $pm->list(enabled => 1) : ();
    my @disabled = eval { $pm->list(enabled => 0) } ? $pm->list(enabled => 0) : ();

    if ($mode eq 'config') {
        $stream->write("Plugin config:\r\n");
        $stream->write("  autoload: $autoload\r\n");

        if ($bot && $bot->can('plugin_autoload_enabled') && !$bot->plugin_autoload_enabled) {
            $stream->write("  boot loading: skipped unless plugins.AUTOLOAD=1 (or compatible key)\r\n");
        }
        else {
            $stream->write("  boot loading: enabled by configuration gate\r\n");
        }

        $stream->write("  autoload keys: plugins.AUTOLOAD, plugins.autoload, plugins.ENABLED_AUTOLOAD, PLUGIN_AUTOLOAD, PLUGINS_AUTOLOAD\r\n");
        $stream->write("  plugin list keys: plugins.ENABLED, plugins.enabled, plugins.PLUGINS, plugins.plugins, PLUGINS_ENABLED, PLUGIN_ENABLED, PLUGINS\r\n");
        $stream->write("  module safety: Perl module names only, no paths\r\n");
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
        my $metrics  = eval { $bot->{metrics} };
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
        return;
    }

    if ($mode ne 'summary' && $mode ne 'loaded') {
        $stream->write("Usage: .plugins [loaded|config|info <name>"
            . "|load <Module> [name]|loadscript <path> [name]|unload <name>|reload <name>"
            . "|enable <name>|disable <name>|cleardata <name>]\r\n");
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


# =============================================================================
# MB678-IV-B: core operator/session commands
# =============================================================================

# .help
# ---------------------------------------------------------------------------
sub _cmd_help {
    my ($self, $stream, $id) = @_;
    $stream->write(
        "Available commands:\r\n"
      . "  .help               - this help\r\n"
      . "  .stat               - channel status (owner, chansets, nick count)\r\n"
      . "  .dccstat            - show DCC Partyline listeners and sessions\r\n"
      . "  .whom               - list users currently on the partyline\r\n"
      . "  .whois <nick>       - send WHOIS to IRC and display result\r\n"
      . "  .timers             - list all scheduled tasks\r\n"
      . "  .schedule <list|status|start|stop|restart> [name] - control scheduler tasks\r\n"
      . "  .log [n]            - show last N lines of the bot log (default 20)\r\n"
      . "  .ping               - check partyline session is alive\r\n"
      . "  .metrics            - dump Prometheus metrics\r\n"
      . "  .plugins [loaded|config|info|load|loadscript|unload|reload|enable|disable|cleardata] - plugin lifecycle (v2)\r\n"
      . "  .scriptdryrun [status|last|config|timers|canceltimers|events|clearevents|reload] - show external script bridge status and last run, pending timers, event windows\r\n"
      . "  .ai <prompt>        - ask Claude (subcommands: quota, stats, models, history, reset, forget, pin, summary [Administrator+])\r\n"
      . "  .aistats            - show Claude AI usage stats\r\n"
      . "  .top [n]            - top N speakers across all channels (default 5)\r\n"
      . "  .seen <nick>        - last activity for a nick in channel logs\r\n"
      . "  .logs <#chan> [n]   - show last N lines from CHANNEL_LOG (default 10)\r\n"
      . "  .nickinfo <nick>    - show DB info for a registered nick\r\n"
      . "  .kick <nick> <#chan> [reason] - kick a nick from channel\r\n"
      . "  .unmute <nick>               - lift a CC3/AF7 temporary nick mute\r\n"
      . "  .kv set|get|del|list [key] [val]- persistent in-memory key-value store\r\n"
      . "  .floodset <#chan> [w] [n] [s]- override AF4 params (window/max/silence)\r\n"
      . "  .cmdcooldown <#chan> <cmd> <s>- set per-cmd cooldown in seconds (CC1)\r\n"
      . "  .netsplit                    - show netsplit state and channel nicklist status\r\n"
      . "  .floodstatus                 - show live antiflood state (AF1/AF3/AF4)\r\n"
      . "  .flushcooldown [#chan]        - clear karma anti-spam cooldown\r\n"
      . "  .achievementprofile <nick> <#chan> - explain durable achievement identity (read-only)\r\n"
      . "  .dbstats            - show DB connection and query stats\r\n"
      . "  .remind <nick> <#chan> <msg> - set a reminder from Partyline\r\n"
      . "  .karmahist [nick]   - show karma history for a channel or nick\r\n"
      . "  .persona [nick]     - view/clear Claude persona (all or specific nick)\r\n"
      . "  .quota [nick]       - show Claude rate limit (all or specific nick)\r\n"
      . "  .ai quota           - show your own Claude rate limit\r\n"
      . "  .stats [#chan]      - top 3 speakers + karma for a channel\r\n"
      . "  .karma <nick> [#chan] - show karma for a nick\r\n"
      . "  .reload             - reload bot configuration (Owner)\r\n"
      . "  .seen <nick>        - last seen event for a nick\r\n"
      . "  .purgereminders     - clean up delivered reminders\r\n"
      . "  .top [#chan] [n]    - top nicks on a channel\r\n"
      . "  .remind <nick> <msg> - set IRC reminder from partyline\r\n"
      . "  .who <nick>         - find nick on joined channels\r\n"
      . "  .bcast <msg>        - broadcast to all joined channels (Master+)\r\n"
      . "  .channels           - list joined channels with stats\r\n"
      . "  .status             - show runtime session status\r\n"
      . "  .uptime             - show bot and server uptime\r\n"
      . "  .match <handle>     - show user record (wildcards * ? allowed)\r\n"
      . "  .say <#chan|nick> <msg> - send a message to channel or user\r\n"
      . "  .who #chan          - list nicks present in a channel\r\n"
      . "  .join #chan [key]   - make the bot join a channel\r\n"
      . "  .part #chan         - make the bot part a channel\r\n"
      . "  .nick <newnick>     - change the bot's nick\r\n"
      . "  .raw <IRC command>  - send a raw IRC command (Owner only)\r\n"
      . "  .lusers [refresh]   - show network stats from LUSERS (optionally request fresh ones)\r\n"
      . "  .reloadconf         - reload config file without restart\r\n"
      . "  .rehash             - reload configuration and runtime state\r\n"
      . "  .restart            - reconnect IRC without killing process (Owner)\r\n"
      . "  .die                - terminate bot process entirely (Owner only)\r\n"
      . "  .eval <perl>        - execute Perl in bot context (Owner, dangerous)\r\n"
      . "  .console [0-5|off]  - redirect bot log to this session\r\n"
      . "  .ban #chan <nick> [duration] [reason] - ban a nick via WHOIS\r\n"
      . "  .bans #chan         - list active channel bans\r\n"
      . "  .unban #chan <mask|id> - remove an active ban\r\n"
      . "  .topic #chan [text] - show or change channel topic\r\n"
      . "  .history          - show last 10 commands this session\r\n"
      . "  .boot <handle>      - kick a user off the partyline (Owner)\r\n"
      . "  .motd [text|add <line>|clear]  - show/set/append/clear MOTD (Owner)\r\n"
      . "  .quit               - close this partyline session\r\n"
      . "\r\n"
      . "Chat:\r\n"
      . "  <text>              - broadcast to all partyline users\r\n"
    );
}

# ---------------------------------------------------------------------------
# .console - display or change per-session log redirect level
# Usage : .console          → show current level
#         .console <0-5>    → set level (0=INFO … 5=DEBUG5)
#         .console off      → disable console
sub _cmd_console {
    my ($self, $stream, $id, $arg) = @_;

    my $bot    = $self->{bot};
    my $logger = $bot->{logger};

    unless ($logger && $logger->can('add_console_hook')) {
        $stream->write("Console hooks not supported by this logger.\r\n");
        return;
    }

    if (!defined $arg || $arg eq '') {
        my $cur = $self->{users}{$id}{console_level};
        if (defined $cur) {
            my $level_name = ("INFO","DEBUG1","DEBUG2","DEBUG3","DEBUG4","DEBUG5")[$cur] // "UNKNOWN";
        $stream->write("Console is ON at level $cur ($level_name).\r\n");
        } else {
            $stream->write("Console is OFF. Use .console <0-5> to enable.\r\n");
        }
        return;
    }

    if (lc($arg) eq 'off') {
        $logger->remove_console_hook($id);
        $self->{users}{$id}{console_level} = undef;
        $stream->write("Console disabled.\r\n");
        $bot->{logger}->log(2, "Partyline: " . ($self->{users}{$id}{login} // '?') . " disabled console (fd=$id)");
        return;
    }

    unless ($arg =~ /^[0-5]$/) {
        $stream->write("Usage: .console [0-5|off]  (0=INFO only, 5=all debug)\r\n");
        return;
    }

    my $level = int($arg);
    my $nick  = $self->{users}{$id}{login} // 'unknown';

    $logger->add_console_hook($id, $level, sub {
        my ($line) = @_;
        my $s = $self->{streams}{$id};
        return unless $s;

        # IO::Async::Stream ultimately uses syswrite(), which expects bytes.
        # Logger lines may contain real Perl Unicode characters coming from
        # IRC output, e.g. heatmap bars (█/░), titles, emojis, etc.
        # Encode only at the transport boundary so IRC rendering stays intact.
        my $wire = encode('UTF-8', ($line // '') . "\r\n");

        eval { $s->write($wire) };
        if ($@) {
            # Stream gone — silently remove the hook so it stops firing
            eval { $logger->remove_console_hook($id) };
            $self->{users}{$id}{console_level} = undef if $self->{users}{$id};
        }
    });

    $self->{users}{$id}{console_level} = $level;
    $stream->write("Console enabled at level $level.\r\n");
    $bot->{logger}->log(2, "Partyline: $nick set console level=$level (fd=$id)");
}

# .motd - display or set the partyline message of the day
# Usage : .motd              → display current MOTD
#         .motd <text>       → replace MOTD with a single line (Owner)
#         .motd clear        → clear MOTD (Owner)
sub _cmd_motd {
    my ($self, $stream, $id, $arg) = @_;

    my $nick = $self->{users}{$id}{login} // 'unknown';

    if (!defined $arg || $arg eq '') {
        $self->_send_motd($stream);
        return;
    }

    # Modification requires Owner level
    unless (defined($self->{users}{$id}{level}) && $self->{users}{$id}{level} == 0) {
        $stream->write("Access denied: changing MOTD requires Owner level.\r\n");
        return;
    }

    if (lc($arg) eq 'clear') {
        $self->{motd} = [];
        $stream->write("MOTD cleared.\r\n");
        $self->{bot}->{logger}->log(2, "Partyline: $nick cleared MOTD");
        return;
    }

    # .motd add <line> — append a line to a multiline MOTD
    if ($arg =~ /^add\s+(.+)$/i) {
        push @{ $self->{motd} }, $1;
        $stream->write("MOTD line added (" . scalar(@{ $self->{motd} }) . " line(s) total).\r\n");
        $self->{bot}->{logger}->log(2, "Partyline: $nick added MOTD line: $1");
        return;
    }

    # .motd <text> — replace entire MOTD with a single line
    $self->{motd} = [ $arg ];
    $stream->write("MOTD set (1 line). Use '.motd add <line>' to append more.\r\n");
    $self->{bot}->{logger}->log(2, "Partyline: $nick set MOTD to: $arg");
}

# Internal helper - send MOTD lines to a stream
sub _send_motd {
    my ($self, $stream) = @_;

    my @lines = @{ $self->{motd} || [] };

    if (!@lines) {
        $stream->write("No MOTD set.\r\n");
        return;
    }

    $stream->write("--- MOTD ---\r\n");
    for my $line (@lines) {
        $stream->write("$line\r\n");
    }
    $stream->write("--- End of MOTD ---\r\n");
}

# .whom - list all authenticated partyline sessions (Eggdrop style)
sub _cmd_whom {
    my ($self, $stream, $id) = @_;

    my @rows;
    my $count = 0;
    my $nick_width = length('Nick/Host');

    for my $fid (sort { $a <=> $b } keys %{ $self->{users} }) {
        my $u = $self->{users}{$fid};
        next unless $u && $u->{authenticated};

        # Keep full IP visible. _display_nick only truncates reverse DNS.
        my $nick       = $self->_display_nick($fid, 48);
        my $level_desc = $u->{level_desc}   // '?';
        my $con_level  = defined $u->{console_level}
            ? "console:" . $u->{console_level}
            : "console:off";
        my $is_me      = ($fid == $id) ? " *" : "";

        $nick_width = length($nick) if length($nick) > $nick_width;

        push @rows, {
            nick       => $nick,
            level_desc => $level_desc,
            fd         => $fid,
            con_level  => $con_level,
            is_me      => $is_me,
        };

        $count++;
    }

    if ($count == 0) {
        $stream->write("No users currently on the partyline.\r\n");
        return;
    }

    $nick_width = 18 if $nick_width < 18;
    $nick_width = 80 if $nick_width > 80;

    my @lines;
    for my $row (@rows) {
        push @lines, sprintf("  %-*s  %-14s  fd=%-4d  %s%s",
            $nick_width,
            $row->{nick},
            $row->{level_desc},
            $row->{fd},
            $row->{con_level},
            $row->{is_me}
        );
    }

    $stream->write(sprintf("Partyline users (%d):\r\n", $count));
    $stream->write(sprintf("  %-*s  %-14s  %-7s %s\r\n",
        $nick_width, "Nick/Host", "Level", "Socket", "Console"));
    $stream->write("  " . ("-" x ($nick_width + 2 + 14 + 2 + 7 + 1 + 14)) . "\r\n");
    $stream->write("$_\r\n") for @lines;
}

# .match <handle> - show user record from database (Eggdrop whois-style)
# Accepts exact handle or wildcard pattern (* and ?)
# .match <handle> - show user record from database (Eggdrop whois-style)
# Accepts exact handle or wildcard pattern (* and ?)
sub _cmd_match {
    my ($self, $stream, $id, $pattern) = @_;

    my $bot = $self->{bot};
    my $dbh = $bot->{dbh};

    unless (defined $pattern && $pattern ne '') {
        $stream->write("Usage: .match <handle>  (wildcards * and ? allowed)\r\n");
        return;
    }

    # Convert Eggdrop-style wildcards to SQL LIKE wildcards.
    # This command intentionally supports wildcards, so * and ? become SQL
    # wildcards. Escape SQL LIKE escape char and literal SQL wildcards first.
    my $sql_pat = $pattern;
    $sql_pat =~ s/!/!!/g;
    $sql_pat =~ s/%/!%/g;
    $sql_pat =~ s/_/!_/g;
    $sql_pat =~ s/\*/%/g;
    $sql_pat =~ s/\?/_/g;

    my $sth = $dbh->prepare(q{
        SELECT
            u.id_user,
            u.nickname,
            u.auth,
            u.info1,
            u.info2,
            ul.description  AS level_desc,
            ul.level        AS level_num
        FROM USER u
        JOIN USER_LEVEL ul ON ul.id_user_level = u.id_user_level
        WHERE u.nickname LIKE ? ESCAPE '!'
        ORDER BY u.nickname
        LIMIT 21
    }); # fetch 21 to detect truncation (display only 20)

    unless ($sth && $sth->execute($sql_pat)) {
        $bot->{logger}->log(1, "Partyline .match SQL error: $DBI::errstr");
        $stream->write("Database error.\r\n");
        $sth->finish if $sth;
        return;
    }

    my $found = 0;

    while (my $row = $sth->fetchrow_hashref) {
        $found++;
        last if $found > 20;

        my $auth  = $row->{auth} ? "logged in" : "not logged in";
        my $info1 = $row->{info1}     // "";
        my $info2 = $row->{info2}     // "";

        $stream->write("\r\n");
        $stream->write(sprintf("  Handle  : %s\r\n", $row->{nickname}));
        $stream->write(sprintf("  Level   : %s (%d)\r\n", $row->{level_desc}, $row->{level_num}));
        $stream->write(sprintf("  Status  : %s\r\n", $auth));

        my @hostmasks;
        my $hm_sth = $dbh->prepare(q{
            SELECT hostmask
            FROM USER_HOSTMASK
            WHERE id_user = ?
            ORDER BY id_user_hostmask
            LIMIT 20
        });

        if ($hm_sth && $hm_sth->execute($row->{id_user})) {
            while (my $hm = $hm_sth->fetchrow_hashref) {
                push @hostmasks, $hm->{hostmask}
                    if defined($hm->{hostmask}) && $hm->{hostmask} ne '';
            }
            $hm_sth->finish;
        }
        else {
            $bot->{logger}->log(1, "Partyline .match hostmask SQL error: $DBI::errstr")
                if $bot->{logger};
            $hm_sth->finish if $hm_sth;
        }

        if (@hostmasks) {
            my $mask_count = scalar(@hostmasks);
            $stream->write(sprintf("  Hosts   : %d shown, max 20\r\n", $mask_count));

            my $per_line = 2;
            my $page     = 1;

            while (@hostmasks) {
                my @chunk = splice(@hostmasks, 0, $per_line);
                my $line  = sprintf("  Hosts[%02d]: %s", $page, join(' | ', @chunk));

                if (length($line) > 360) {
                    $line = Mediabot::Helpers::truncate_utf8($line, 357);
                }

                $stream->write($line . "\r\n");
                $page++;
            }
        }
        else {
            $stream->write("  Hosts   : (none)\r\n");
        }

        $stream->write(sprintf("  Info1   : %s\r\n", $info1)) if $info1 ne '';
        $stream->write(sprintf("  Info2   : %s\r\n", $info2)) if $info2 ne '';
    }

    $sth->finish;

    if ($found == 0) {
        $stream->write("No match for '$pattern'.\r\n");
    }
    elsif ($found > 20) {
 $stream->write(sprintf("\r\nShowing first 20 matches for '%s' (more exist -- narrow your search).\r\n", $pattern));
    }
    elsif ($found > 1) {
        $stream->write(sprintf("\r\n%d match(es) for '%s'.\r\n", $found, $pattern));
    }
}


# .boot <handle> - kick a user off the partyline (Owner only)
sub _cmd_boot {
    my ($self, $stream, $id, $target_login) = @_;

    my $bot  = $self->{bot};
    my $nick = $self->{users}{$id}{login} // 'unknown';

    unless (defined($self->{users}{$id}{level}) && $self->{users}{$id}{level} == 0) {
        $stream->write("Access denied: .boot requires Owner level.\r\n");
        return;
    }

    unless (defined $target_login && $target_login ne '') {
        $stream->write("Usage: .boot <handle>\r\n");
        return;
    }

    # Find target session by login name
    my $target_id;
    for my $fid (keys %{ $self->{users} }) {
        next unless $self->{users}{$fid}{authenticated};
        if (lc($self->{users}{$fid}{login} // '') eq lc($target_login)) {
            $target_id = $fid;
            last;
        }
    }

    unless (defined $target_id) {
        $stream->write("No partyline session found for '$target_login'.\r\n");
        return;
    }

    if ($target_id == $id) {
        $stream->write("You cannot boot yourself. Use .quit instead.\r\n");
        return;
    }

    my $target_stream = $self->{streams}{$target_id};
    $bot->{logger}->log(2, "Partyline: $nick booted $target_login (fd=$target_id)");

    # Notify the victim
    if ($target_stream) {
        $target_stream->write("You have been booted by $nick.\r\n");
        $target_stream->close_when_empty;
    }

    # Announce to everyone else
    $self->_broadcast("*** " . $self->_display_nick($target_id) . " was booted by " . $self->_display_nick($id) . ". ***", $target_id);
    $stream->write("Booted $target_login.\r\n");

    $self->_close_session($target_id);
}



# ---------------------------------------------------------------------------
# .whois <nick>  - send WHOIS and display result in the partyline session
# Master+ only. The reply is captured via a console hook on the next
# RPL_WHOISUSER (311), RPL_WHOISCHANNELS (319), and RPL_ENDOFWHOIS (318).
# Because the WHOIS reply comes asynchronously, we store the session fd in a
# lightweight state key and let the bot's on_message_RPL_WHOISUSER handler
# write back to the stream.
# ---------------------------------------------------------------------------
sub _cmd_whois {
    my ($self, $stream, $id, $target) = @_;

    my $bot = $self->{bot};

    unless ($bot->{irc} && $bot->{irc}->is_connected) {
        $stream->write("Bot is not connected to IRC.\r\n");
        return;
    }

    unless (defined $target && $target =~ /\S/) {
        $stream->write("Usage: .whois <nick>\r\n");
        return;
    }

    # Store the session fd so the WHOIS reply callback can write back here
    $bot->{_partyline_whois_fd} = $id;
    $bot->{_partyline_whois_nick} = $target;
    $bot->{_partyline_whois_ts}   = time();

    $bot->{irc}->send_message('WHOIS', undef, $target);
    $stream->write("WHOIS sent for $target...\r\n");
    $bot->{logger}->log(3, "Partyline: $id requested WHOIS for $target");
}


# ---------------------------------------------------------------------------
# .log [n]  - show last N lines of the bot log (default: 20, max: 100)
# ---------------------------------------------------------------------------
sub _cmd_log {
    my ($self, $stream, $id, $n_arg) = @_;

    my $bot    = $self->{bot};
    my $logger = $bot->{logger};

    my $n = int($n_arg // 20);
    $n = 20  if $n < 1;
    $n = 100 if $n > 100;

    my $logfile = eval { $logger->{logfile} };
    unless ($logfile && -f $logfile) {
        $stream->write("No log file configured or file not found.\r\n");
        return;
    }

    # A6: re-check file existence just before open (may have been rotated)
    unless (-f $logfile && -r $logfile) {
        $stream->write("Log file not readable: $logfile\r\n");
        return;
    }

    open my $fh, '<:utf8', $logfile or do {  # A1: log written in UTF-8
        $stream->write("Cannot open log file: $!\r\n");
        return;
    };
    my @lines = <$fh>;
    close $fh;

    my @tail = @lines > $n ? @lines[-$n..-1] : @lines;

    $stream->write(sprintf("--- last %d line(s) of %s ---\r\n",
        scalar @tail, $logfile));
    for my $line (@tail) {
        $line =~ s/[\r\n]+$//;
        $stream->write("$line\r\n");
    }
    $stream->write("--- end ---\r\n");
}


# =============================================================================
# MB678-IV-C: scheduler / operational status commands
# =============================================================================

# ---------------------------------------------------------------------------
# .timers  - list all registered scheduler tasks (Master+)
# ---------------------------------------------------------------------------
sub _cmd_timers {
    my ($self, $stream, $id) = @_;
    # V1: delegate to _cmd_schedule list — single source of truth with next_run
    return $self->_cmd_schedule($stream, $id, 'list', undef);
}

sub _format_duration {
    my ($self, $seconds) = @_;

    $seconds = 0 unless defined $seconds && $seconds =~ /^\d+(?:\.\d+)?$/;
    $seconds = int($seconds);

    my $days = int($seconds / 86400);
    $seconds %= 86400;

    my $hours = int($seconds / 3600);
    $seconds %= 3600;

    my $minutes = int($seconds / 60);
    my $secs    = $seconds % 60;

    my @parts;
    push @parts, "${days}d" if $days;
    push @parts, "${hours}h" if $hours;
    push @parts, "${minutes}m" if $minutes;
    push @parts, "${secs}s" if $secs || !@parts;

    return join(' ', @parts);
}



# ---------------------------------------------------------------------------
# .schedule <start|stop> <name>  - control a Scheduler task at runtime
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# _seconds_to_human($secs) — format a duration as '3h 25m 12s' (SL1)
# ---------------------------------------------------------------------------
sub _seconds_to_human {
    my ($secs) = @_;
    $secs = int($secs // 0);
    return '0s' unless $secs > 0;
    my $d = int($secs / 86400); $secs %= 86400;
    my $h = int($secs / 3600);  $secs %= 3600;
    my $m = int($secs / 60);    $secs %= 60;
    my $s = $secs;
    return "${d}d ${h}h"  if $d;
    return "${h}h ${m}m"  if $h;
    return "${m}m ${s}s"  if $m;
    return "${s}s";
}

sub _cmd_schedule {
    my ($self, $stream, $id, $action, $name) = @_;
    my $bot   = $self->{bot};
    my $sched = $bot->{scheduler};

    # mb356-B2: keep the control command explicitly restricted even though the
    # current Partyline login gate already requires Master or Owner.
    my $level = $self->{users}{$id}{level};
    unless (defined($level) && $level <= 1) {
        $stream->write("Access denied: .schedule requires Master or Owner level.\r\n");
        return;
    }

    unless ($sched) {
        $stream->write("Scheduler not available.\r\n");
        return;
    }

    my $act = lc($action // 'list');

    my $find_info = sub {
        my ($wanted) = @_;
        return undef unless defined($wanted) && $wanted ne '';

        if ($sched->can('task_info')) {
            return $sched->task_info($wanted);
        }

        for my $info ($sched->all_info) {
            return $info if $info && ($info->{name} // '') eq $wanted;
        }
        return undef;
    };

    if ($act eq 'list' || !defined $action) {
        my @infos = $sched->all_info;
        unless (@infos) {
            $stream->write("No scheduled tasks.\r\n");
            return;
        }

        my $now = time();
        $stream->write(sprintf("%-28s %-9s %-8s %-6s %s\r\n",
            'Name', 'Interval', 'Status', 'Ticks', 'Next run'));
        $stream->write(("-" x 70) . "\r\n");

        for my $t (@infos) {
            my $next_str;
            if (!$t->{started}) {
                $next_str = 'stopped';
            }
            else {
                my $next = $t->{next_run} // 0;
                if ($next > 0) {
                    my $diff = $next - $now;
                    if ($diff <= 0) {
                        $next_str = 'imminent';
                    }
                    else {
                        my @nt = localtime($next);
                        $next_str = sprintf('%04d-%02d-%02d %02d:%02d:%02d (in %s)',
                            $nt[5] + 1900, $nt[4] + 1, $nt[3],
                            $nt[2], $nt[1], $nt[0], _seconds_to_human($diff));
                    }
                }
                else {
                    $next_str = 'soon';
                }
            }

            my $iv = $t->{interval} // 0;
            my $iv_str = $iv >= 3600 ? sprintf("%dh%02dm", int($iv/3600), int(($iv%3600)/60))
                       : $iv >= 60   ? sprintf("%dm%02ds", int($iv/60), $iv%60)
                       :               "${iv}s";
            $stream->write(sprintf("%-28s %-9s %-8s %-6d %s\r\n",
                $t->{name}, $iv_str,
                ($t->{started} ? 'running' : 'stopped'),
                $t->{ticks}, $next_str));
        }
        return;
    }

    if ($act eq 'status') {
        my $info = $find_info->($name);
        unless ($info) {
            $stream->write("Usage: .schedule status <task_name>\r\n");
            $stream->write("Tasks: " . join(', ', $sched->task_names) . "\r\n");
            return;
        }

        my $last;
        if ($info->{last_tick}) {
            my @lt = localtime($info->{last_tick});
            my $ago = time() - $info->{last_tick};
            $last = sprintf("%02d:%02d:%02d (%s ago)",
                $lt[2], $lt[1], $lt[0], _seconds_to_human($ago));
        }
        else {
            $last = 'never';
        }

        $stream->write("Task:     $info->{name}\r\n");
        $stream->write("Mode:     " . ($info->{mode} // 'periodic') . "\r\n");
        $stream->write("Interval: $info->{interval}s\r\n");
        $stream->write("Status:   " . ($info->{started} ? "running" : "stopped") . "\r\n");
        $stream->write("Ticks:    $info->{ticks}\r\n");
        $stream->write("Last run: $last\r\n");

        my $next_run_s;
        if (!$info->{started}) {
            $next_run_s = 'n/a (stopped)';
        }
        else {
            my $next = $info->{next_run} // 0;
            if ($next > 0) {
                my $diff = $next - time();
                if ($diff <= 0) {
                    $next_run_s = 'imminent';
                }
                else {
                    my @nt = localtime($next);
                    $next_run_s = sprintf('%04d-%02d-%02d %02d:%02d:%02d (in %s)',
                        $nt[5] + 1900, $nt[4] + 1, $nt[3],
                        $nt[2], $nt[1], $nt[0], _seconds_to_human($diff));
                }
            }
            else {
                $next_run_s = 'soon';
            }
        }
        $stream->write("Next run: $next_run_s\r\n");
        return;
    }

    unless (defined $name && $name ne '') {
        $stream->write("Usage: .schedule <list|status|start|stop|restart> [task_name]\r\n");
        return;
    }

    unless ($act eq 'start' || $act eq 'stop' || $act eq 'restart') {
        $stream->write("Unknown action '$act'. Use: list status start stop restart\r\n");
        return;
    }

    my $before = $find_info->($name);
    unless ($before) {
        $stream->write("Scheduler task '$name' not found.\r\n");
        return;
    }

    if ($act eq 'start' && $before->{started}) {
        $stream->write("Task '$name' is already running.\r\n");
        return;
    }

    if ($act eq 'stop' && !$before->{started}) {
        $stream->write("Task '$name' is already stopped.\r\n");
        return;
    }

    my $ok = eval {
        if ($act eq 'start') {
            $sched->start($name);
        }
        elsif ($act eq 'stop') {
            $sched->stop($name);
        }
        else {
            $sched->restart($name);
        }
    };

    if ($@ || !$ok) {
        my $err = $@ || 'scheduler returned failure';
        $err =~ s/\s+/ /g;
        $bot->{logger}->log(1,
            "Partyline .schedule $act $name failed: $err") if $bot->{logger};
        $stream->write("Scheduler action failed for '$name' ($act).\r\n");
        return;
    }

    my $verb = $act eq 'start' ? 'started'
             : $act eq 'stop'  ? 'stopped'
             :                   'restarted';
    $bot->{logger}->log(2,
        "Scheduler task '$name' $verb from Partyline") if $bot->{logger};
    $stream->write("Task '$name' $verb.\r\n");
    return;
}


# ---------------------------------------------------------------------------
# .status  - display the runtime status payload in the partyline session
# ---------------------------------------------------------------------------
sub _cmd_status {
    my ($self, $stream, $id) = @_;

    my $payload = eval { $self->_runtime_status_payload };
    if ($@) {
        my $err = $@;
        $self->_report_operation_error(
            $stream,
            'Partyline .status failed',
            'Status unavailable.',
            $err,
        );
        return;
    }

    my $sessions  = $payload->{sessions}  // [];
    my $bot_info  = $payload->{bot}       // {};
    my $ts        = $payload->{generated_at} // time();

    $stream->write(sprintf("--- runtime status (generated %s) ---\r\n",
        scalar localtime($ts)));
    $stream->write(sprintf("Bot:      %s  uptime: %s\r\n",
        $bot_info->{nick} // '?', $bot_info->{uptime} // '?'));
    $stream->write(sprintf("Sessions: %d active\r\n", scalar @$sessions));
    # mb552-B1 / mb553-B1: infrastructure health at a glance. Read the
    # DB handle state maintained by the canonical five-second health tick;
    # .status must never perform a synchronous ping/reconnect and become the
    # very partyline stall it is supposed to diagnose.
    {
        my $bot_h = $self->{bot};
        my $db_state = 'unknown';
        if ($bot_h && $bot_h->{db} && eval { $bot_h->{db}->can('dbh') }) {
            my $dbh = eval { $bot_h->{db}->dbh };
            $db_state = $dbh ? 'up' : 'DOWN';
        }
        $stream->write("DB:       $db_state\r\n");
        if ($bot_h && eval { $bot_h->can('last_loop_stall') }) {
            my $stall = eval { $bot_h->last_loop_stall };
            if (ref($stall) eq 'HASH' && $stall->{seconds}) {
                $stream->write(sprintf("Loop:     last stall %.2fs at %s\r\n",
                    $stall->{seconds}, scalar localtime($stall->{at} || 0)));
            }
            else {
                $stream->write("Loop:     no stall detected\r\n");
            }
        }
        # mb595-B1: jobs CommandAsync sous les yeux de l'operateur — memoire
        # seule (snapshots), contrat mb573 : .status ne lance rien, ne tue
        # rien, n'attend rien. Un job actif = un gros classement en fond ;
        # les compteurs cumulés racontent la sante depuis le demarrage.
        if ($bot_h && eval { require Mediabot::CommandAsync; 1 }) {
            my $jobs = eval { Mediabot::CommandAsync::async_jobs_snapshot($bot_h) } || [];
            my $st   = eval { Mediabot::CommandAsync::async_stats_snapshot($bot_h) } || {};
            $stream->write(sprintf(
                "Async:    %d running (since start: %d spawned, %d completed,"
                . " %d timeout(s), %d sync fallback(s), %d lock refusal(s))\r\n",
                scalar @$jobs,
                $st->{spawned} // 0, $st->{completed} // 0,
                $st->{timeouts} // 0, $st->{fallback_sync} // 0,
                $st->{lock_refused} // 0));
            for my $j (@$jobs) {
                $stream->write(sprintf("  - [%s] %s pid=%d running %ss\r\n",
                    $j->{label}, $j->{channel}, $j->{pid}, $j->{elapsed}));
            }
        }
        # mb596-B1: sante du throttle partyline (memoire seule, meme contrat).
        {
            my $rs = $self->{_rate_stats} || {};
            $stream->write(sprintf(
                "Throttle: %d rate hit(s), %d silent drop(s), %d flood boot(s)\r\n",
                $rs->{hits} // 0, $rs->{silent_drops} // 0,
                $rs->{flood_boots} // 0));
        }
    }
    # IMP24: add global AF status
    my $bot_s = $self->{bot};
    my $gaf = $bot_s->{_global_af} // {};
    if (($gaf->{silenced_until} // 0) > time()) {
        my $rem = $gaf->{silenced_until} - time();
        $stream->write("GlobalAF: SILENCED for ${rem}s\r\n");
    } else {
        my $hits = scalar @{ $gaf->{hits} // [] };
        $stream->write("GlobalAF: ok ($hits msgs in window)\r\n");
    }
    # mb573-B1: operator observability — the three queues/background jobs an
    # operator actually wonders about. Everything below reads IN-MEMORY state
    # only (same non-blocking discipline as the DB/Loop lines above: .status
    # must never query anything).
    {
        my $outq = $bot_s->{_flood_outq} // {};
        my @busy = sort grep { scalar @{ $outq->{$_}{items} // [] } } keys %$outq;
        if (@busy) {
            my $total = 0; $total += scalar @{ $outq->{$_}{items} } for @busy;
            my $detail = join(', ', map {
                sprintf('%s:%d%s', $_, scalar @{ $outq->{$_}{items} },
                    $outq->{$_}{armed} ? '' : ' UNARMED')
            } @busy);
            $stream->write("FloodQ:   $total deferred ($detail)\r\n");
        }
        else {
            $stream->write("FloodQ:   empty\r\n");
        }

        my $ach = $bot_s->{achievements};
        if ($ach && eval { $ach->can('pending_check_count') }) {
            my $pending = eval { $ach->pending_check_count } // 0;
            $stream->write($pending
                ? "AchvQ:    $pending pending check(s)\r\n"
                : "AchvQ:    empty\r\n");
            # mb612 / mb646: expose storage state through the module API.
            # DB mode is write-through; JSON fallback can still have a dirty
            # debounce window on legacy installations.
            my $stats = eval { $ach->storage_stats } || {};
            my $profiles = $stats->{profiles} // 0;
            my $counters = $stats->{counters} // 0;
            my $backend  = $stats->{backend}  // 'unknown';
            my $pending_save = $stats->{dirty} ? ' (unsaved changes)' : '';
            $stream->write(sprintf(
                "Achv:     %d profile(s), %d progress counter(s) [%s]%s\r\n",
                $profiles, $counters, $backend, $pending_save));
        }

        my $adb = eval { $bot_s->{conf}->get('mysql.CHANNEL_LOG_ARCHIVE_DBNAME') } // '';
        $adb = '' if ref $adb;
        if (!length $adb) {
            $stream->write("Archive:  disabled\r\n");
        }
        # mb573-B2: a current worker is more important than the previous result.
        # Once one run had completed, the old ordering hid every later in-flight
        # worker behind "_archive_last_run".
        elsif ($bot_s->{_channel_log_archive_pid}) {
            $stream->write(
                "Archive:  worker running (pid $bot_s->{_channel_log_archive_pid})\r\n");
        }
        elsif (my $last = $bot_s->{_archive_last_run}) {
            $stream->write(sprintf("Archive:  last run %s exit=%d in %.2fs%s\r\n",
                scalar localtime($last->{at} // 0), $last->{exit} // -1,
                $last->{elapsed} // 0,
                ($last->{signal} ? " signal=$last->{signal}" : '')));
        }
        else {
            $stream->write("Archive:  enabled, no run yet\r\n");
        }
    }

    for my $s (@$sessions) {
        my $lvl_display = $s->{level_desc} || $s->{level} // '?';
        my $con_display = defined($s->{console_level}) && $s->{console_level} ne '' && $s->{console_level} ne '0'
            ? $s->{console_level} : 'off';
        $stream->write(sprintf("  %-16s  fd=%-4s  level=%-10s  console=%s\r\n",
            $s->{login}  // '?',
            $s->{fd}     // '?',
            $lvl_display,
            $con_display));
    }
    # A5: joined channels summary
    my $bot        = $self->{bot};
    my $bot_nick_s = eval { $bot->{irc}->nick_folded } // '';
    my $chans_s    = $bot->{channels} || {};
    my @joined_s   = grep {
        my @n = eval { $bot->gethChannelsNicksOnChan($_) };
        grep { lc($_) eq lc($bot_nick_s) } @n;
    } sort keys %$chans_s;
    $stream->write(sprintf("Channels: %s\r\n",
        @joined_s ? join(", ", @joined_s) : "(none)"));
    $stream->write("--- end ---\r\n");
}


# ---------------------------------------------------------------------------
# .metrics  - dump current Prometheus metrics to the partyline session
# ---------------------------------------------------------------------------
sub _cmd_metrics {
    my ($self, $stream, $id) = @_;

    my $metrics = $self->{bot}->{metrics};
    unless ($metrics && $metrics->can('render_prometheus')) {
        $stream->write("Metrics not available.\r\n");
        return;
    }

    my $rendered = eval { $metrics->render_prometheus };
    if ($@) {
        my $err = $@;
        $self->_report_operation_error(
            $stream,
            'Partyline .metrics failed',
            'Metrics render error.',
            $err,
        );
        return;
    }

    # IMP23: show only non-zero metrics, sorted, with category grouping
    my %grouped;
    for my $line (split /\n/, $rendered) {
        next if $line =~ /^#/ || $line =~ /^\s*$/;
        if ($line =~ /^(\w+?)(?:\{[^}]*\})?\s+([\d.e+\-]+)/) {
            my ($metric, $val) = ($1, $2);
            next if $val == 0;          # IMP23: skip zeroes
            my ($cat) = $metric =~ /^([^_]+(?:_[^_]+)?)_/;
            $cat //= 'other';
            push @{ $grouped{$cat} }, $line;
        }
    }
    $stream->write("--- Prometheus metrics (non-zero) ---\r\n");
    for my $cat (sort keys %grouped) {
        $stream->write("[$cat]\r\n");
        $stream->write("  $_ \r\n") for @{ $grouped{$cat} };
    }
    $stream->write("--- end ---\r\n");
}

# =============================================================================
# MB678-IV-D: channel / network visibility commands
# =============================================================================

# ---------------------------------------------------------------------------
# .channels  - list joined channels with nick count and owner
# ---------------------------------------------------------------------------
sub _cmd_channels {
    my ($self, $stream, $id) = @_;

    my $bot      = $self->{bot};
    my $bot_nick = eval { $bot->{irc}->nick_folded } // '';
    my $chans    = $bot->{channels} || {};
    my $dbh      = eval { $bot->{db}->ensure_connected } // $bot->{dbh};

    my @names = sort keys %$chans;
    unless (@names) {
        $stream->write("No channels.\r\n");
        return;
    }

    # Batch-fetch owners (level 500) for all channels
    my %owners;
    if ($dbh) {
        my $sth_o = $dbh->prepare(
            "SELECT uc.id_channel, u.nickname FROM USER u
              JOIN USER_CHANNEL uc ON uc.id_user = u.id_user
              WHERE uc.level = 500"
        );
        if ($sth_o && $sth_o->execute()) {
            while (my $r = $sth_o->fetchrow_hashref) {
                $owners{ $r->{id_channel} } //= $r->{nickname};
            }
            $sth_o->finish;
        }
    }

    # AA3: also fetch Hailo flag and DB user count per channel
    my (%hailo_flags, %db_users);
    if ($dbh) {
        my $sth_h = $dbh->prepare(
            "SELECT c.name, cs.value FROM CHANNEL c
              JOIN CHANNEL_SET cs ON cs.id_channel = c.id_channel
              JOIN CHANSET_LIST cl ON cl.id_chanset_list = cs.id_chanset_list
              WHERE cl.name = 'Hailo'"
        );
        if ($sth_h && $sth_h->execute()) {
            while (my $r = $sth_h->fetchrow_hashref) {
                $hailo_flags{$r->{name}} = $r->{value};
            }
            $sth_h->finish;
        }
        my $sth_u = $dbh->prepare(
            "SELECT c.name, COUNT(*) AS cnt FROM USER_CHANNEL uc
              JOIN CHANNEL c ON c.id_channel = uc.id_channel
              GROUP BY uc.id_channel"
        );
        if ($sth_u && $sth_u->execute()) {
            while (my $r = $sth_u->fetchrow_hashref) {
                $db_users{$r->{name}} = $r->{cnt};
            }
            $sth_u->finish;
        }
    }

    $stream->write(sprintf("%-22s %-8s %-5s %-5s %-6s %s\r\n",
        'Channel', 'Status', 'IRC', 'DB', 'Hailo', 'Owner'));
    $stream->write("-" x 70 . "\r\n");

    for my $name (@names) {
        my $chan_obj   = $chans->{$name} or next;
        my $id_channel = eval { $chan_obj->get_id } // 0;

        my @nicks      = eval { $bot->gethChannelsNicksOnChan($name) };
        my $joined     = (grep { lc($_) eq lc($bot_nick) } @nicks) ? 'joined' : 'parted';
        my $nick_count = scalar @nicks;
        my $owner      = $owners{$id_channel} // 'none';
        my $hailo      = exists $hailo_flags{$name} ? ($hailo_flags{$name} ? 'on' : 'off') : '-';
        my $db_cnt     = $db_users{$name} // 0;

        $stream->write(sprintf("%-22s %-8s %-5d %-5d %-6s %s\r\n",
            $name, $joined, $nick_count, $db_cnt, $hailo, $owner));
    }
}


# ---------------------------------------------------------------------------
# .bcast <message>  - broadcast a message to all joined channels (Master+)
# ---------------------------------------------------------------------------
sub _cmd_bcast {
    my ($self, $stream, $id, $msg) = @_;

    my $bot      = $self->{bot};
    my $session  = $self->{users}{$id} // {};  # B1/fix: auth data in users{}, not sessions{}
    my $level    = $session->{level} // 99;

    unless (defined $level && $level <= 1) {  # Owner=0, Master=1 (inverted scale)
        $stream->write("Permission denied (Master+ required).\r\n");
        return;
    }

    unless (defined $msg && $msg =~ /\S/) {
        $stream->write("Usage: .bcast <message>\r\n");
        return;
    }

    my $bot_nick = eval { $bot->{irc}->nick_folded } // '';
    my $chans    = $bot->{channels} || {};
    my $sent     = 0;

    for my $name (sort keys %$chans) {
        my @nicks = eval { $bot->gethChannelsNicksOnChan($name) };
        next unless grep { lc($_) eq lc($bot_nick) } @nicks;
        Mediabot::Helpers::botPrivmsg($bot, $name, "[broadcast] $msg");
        $sent++;
    }

    $stream->write("Broadcast sent to $sent channel(s).\r\n");
    $bot->{logger}->log(2, "Partyline: bcast from $session->{login}: $msg");
}


# ---------------------------------------------------------------------------
# .who <nick>  - show which joined channels a nick is present on
# ---------------------------------------------------------------------------
sub _cmd_whochan {
    my ($self, $stream, $id, $target) = @_;

    my $bot      = $self->{bot};
    my $bot_nick = eval { $bot->{irc}->nick_folded } // '';

    unless (defined $target && $target =~ /\S/) {
        $stream->write("Usage: .who <nick>\r\n");
        return;
    }

    my $chans   = $bot->{channels} || {};
    my @found;

    for my $name (sort keys %$chans) {
        my @nicks = eval { $bot->gethChannelsNicksOnChan($name) };
        next unless grep { lc($_) eq lc($bot_nick) } @nicks;  # only joined
        if (grep { lc($_) eq lc($target) } @nicks) {
            push @found, $name;
        }
    }

    if (@found) {
        $stream->write("$target is on: " . join(', ', @found) . "\r\n");
    } else {
        $stream->write("$target not found on any joined channel.\r\n");
    }
}


# ---------------------------------------------------------------------------
# .top [#chan] [n]  - top n nicks on a channel (default current/first, 5)
# ---------------------------------------------------------------------------
sub _cmd_top {
    # Safe Partyline top:
    #   .top              -> usage only, no implicit full scan
    #   .top #chan [n]   -> top N on explicit channel
    #   .top all [n]     -> explicit all-channel aggregate
    my ($self, $stream, $id, $args) = @_;

    my $bot = $self->{bot};
    my $dbh = eval { $bot->{db}->ensure_connected } // $bot->{dbh};
    unless ($dbh) {
        $stream->write("DB unavailable.\r\n");
        return;
    }

    if (!defined($args) || $args !~ /\S/) {
        $stream->write("Usage: .top <#chan> [n] or .top all [n] (default n=5, max=15)\r\n");
        $stream->write("Example: .top #teuk 10\r\n");
        return;
    }

    my $all_chans = ($args =~ /\ball\b/i) ? 1 : 0;
    my ($chan) = ($args =~ /(#\S+)/i);

    # mb122-B2: avant ce fix, ($args =~ /(\d+)/) matchait le PREMIER chiffre
    # rencontre, donc `.top #chan42 10` produisait n=42 (clampe a 15).
    # On retire d'abord le nom du canal et le mot "all" pour ne considerer
    # que les arguments numeriques restants.
    my $args_for_n = $args;
    $args_for_n =~ s/#\S+//g;
    $args_for_n =~ s/\ball\b//gi;
    # mb124-B4: only accept standalone numeric tokens as n.
    # Avoid treating arbitrary words such as foo10bar as a valid limit.
    my ($n) = ($args_for_n =~ /(?:^|\s)(\d+)(?=\s|$)/);
    $n //= 5;
    $n = 5  if !$n || $n < 1;
    $n = 15 if $n > 15;

    unless ($all_chans || (defined($chan) && $chan =~ /^#/)) {
        $stream->write("Usage: .top <#chan> [n] or .top all [n] (default n=5, max=15)\r\n");
        $stream->write("Example: .top #teuk 10\r\n");
        return;
    }

    my ($sth, $label);
    if ($all_chans) {
        $sth = $dbh->prepare(
            "SELECT cl.nick, COUNT(*) AS cnt FROM CHANNEL_LOG cl"
            . " GROUP BY cl.nick ORDER BY cnt DESC LIMIT ?"
        );
        unless ($sth && $sth->execute($n)) {
            $stream->write("DB error.\r\n");
            $sth->finish if $sth;
            return;
        }
        $label = "Top $n speakers (all channels)";
    }
    else {
        $sth = $dbh->prepare(
            "SELECT cl.nick, COUNT(*) AS cnt FROM CHANNEL_LOG cl"
            . " JOIN CHANNEL c ON c.id_channel = cl.id_channel"
            . " WHERE c.name = ? GROUP BY cl.nick ORDER BY cnt DESC LIMIT ?"
        );
        unless ($sth && $sth->execute($chan, $n)) {
            $stream->write("DB error.\r\n");
            $sth->finish if $sth;
            return;
        }
        $label = "Top $n on $chan";
    }

    my $total_pl = 0;
    my $sth_t = $all_chans
        ? $dbh->prepare('SELECT COUNT(*) AS t FROM CHANNEL_LOG')
        : $dbh->prepare('SELECT COUNT(*) AS t FROM CHANNEL_LOG cl'
                      . ' JOIN CHANNEL c ON c.id_channel = cl.id_channel'
                      . ' WHERE c.name = ?');

    if ($sth_t) {
        my $ok = $all_chans ? $sth_t->execute : $sth_t->execute($chan);
        if ($ok) {
            my $r = $sth_t->fetchrow_hashref;
            $total_pl = $r->{t} // 0;
        }
        $sth_t->finish;
    }

    $stream->write("$label:\r\n");

    my $rank = 1;
    while (my $row = $sth->fetchrow_hashref) {
        my $pct = ($total_pl && $total_pl > 0)
            ? sprintf(' (%.1f%%)', 100 * $row->{cnt} / $total_pl)
            : '';

        $stream->write(sprintf("  %2d. %-20s %d msgs%s\r\n",
            $rank++, $row->{nick}, $row->{cnt}, $pct));
    }

    $sth->finish;
}

# =============================================================================
# MB678-IV-E: reminder / seen commands
# =============================================================================

# ---------------------------------------------------------------------------
# .remind <nick> <message>  - set a reminder from the Partyline
# ---------------------------------------------------------------------------
sub _cmd_remind {
    my ($self, $stream, $id, $args) = @_;

    my $bot = $self->{bot};
    my $dbh = eval { $bot->{db}->ensure_connected } // $bot->{dbh};

    my ($target, $message) = ($args =~ /^(\S+)\s+(.+)$/);
    unless ($target && $message) {
        $stream->write("Usage: .remind <nick> <message>\r\n"); return;
    }

    my $session  = $self->{users}{$id} // {};
    my $from     = $session->{login} // '?';

    # Use first joined channel
    my $bot_nick = eval { $bot->{irc}->nick_folded } // '';
    my $chans    = $bot->{channels} || {};
    my ($chan_name, $id_channel);
    for my $name (sort keys %$chans) {
        my @nicks = eval { $bot->gethChannelsNicksOnChan($name) };
        if (grep { lc($_) eq lc($bot_nick) } @nicks) {
            $chan_name = $name; last;
        }
    }
    unless ($chan_name) { $stream->write("Bot not joined on any channel.\r\n"); return; }

    unless ($dbh) { $stream->write("DB unavailable.\r\n"); return; }

    # mb93-B3: valider le nick destinataire (cohérence avec mb92-B3 dans UserCommands)
    {
        my $target_known = 0;
        # Vérifier nicklist en mémoire sur tous les canaux
        my $chans_chk = $bot->{channels} // {};
        for my $cname (keys %$chans_chk) {
            my @nicks = eval { $bot->gethChannelsNicksOnChan($cname) };
            if (grep { defined($_) && lc($_) eq lc($target) } @nicks) {
                $target_known = 1; last;
            }
        }
        unless ($target_known) {
            my $sth_seen = $dbh->prepare('SELECT 1 FROM USER_SEEN WHERE nick = ? LIMIT 1');
            if ($sth_seen && $sth_seen->execute(lc($target))) {
                $target_known = 1 if $sth_seen->fetchrow_array;
                $sth_seen->finish;
            }
        }
        unless ($target_known) {
            my $sth_user = $dbh->prepare('SELECT 1 FROM USER WHERE nickname = ? LIMIT 1');
            if ($sth_user && $sth_user->execute(lc($target))) {
                $target_known = 1 if $sth_user->fetchrow_array;
                $sth_user->finish;
            }
        }
        unless ($target_known) {
            $stream->write("Unknown nick '$target'. Remind not created.\r\n");
            return;
        }
    }

    # mb412-R1: id canal via le helper central (cache d'abord, mb411).
    $id_channel = Mediabot::Helpers::channel_id_cached($bot, $chan_name);
    unless ($id_channel) { $stream->write("Channel not found in DB.\r\n"); return; }

    my $sth = $dbh->prepare(q{
        INSERT INTO REMINDERS (id_channel, from_nick, to_nick, message) VALUES (?,?,?,?)
    });
    if ($sth && $sth->execute($id_channel, $from, lc($target), $message)) {
        $sth->finish;
        $stream->write("Reminder set for $target on $chan_name.\r\n");
    } else {
        $stream->write("DB error.\r\n");
    }
}


# ---------------------------------------------------------------------------
# .seen <nick>  - last seen event for a nick
# ---------------------------------------------------------------------------
sub _cmd_seen {
    my ($self, $stream, $id, $target) = @_;

    my $bot = $self->{bot};
    my $dbh = eval { $bot->{db}->ensure_connected } // $bot->{dbh};

    unless (defined $target && $target =~ /\S/) {
        $stream->write("Usage: .seen <nick>  (wildcard: .seen teu*)\r\n"); return;
    }

    # mb94-B1 / mb127-B3: support wildcard (* -> %, ? -> _) while escaping
    # literal SQL LIKE metacharacters from the user input.
    if ($target =~ /[*?]/) {
        my $like = '';
        for my $ch (split //, lc($target)) {
            if    ($ch eq '*') { $like .= '%';  }
            elsif ($ch eq '?') { $like .= '_';  }
            elsif ($ch eq '!') { $like .= '!!'; }
            elsif ($ch eq '%') { $like .= '!%'; }
            elsif ($ch eq '_') { $like .= '!_'; }
            else               { $like .= $ch;  }
        }
        my $sth = $dbh->prepare(q{
            SELECT nick, channel, event_type, seen_at
            FROM USER_SEEN WHERE nick LIKE ? ESCAPE '!'
            ORDER BY seen_at DESC LIMIT 5
        });
        unless ($sth && $sth->execute($like)) {
            $stream->write("DB error.\r\n"); $sth->finish if $sth; return;
        }
        my @rows;
        while (my $r = $sth->fetchrow_hashref) { push @rows, $r; }
        $sth->finish;
        unless (@rows) {
            $stream->write("No nicks matching '$target'.\r\n"); return;
        }
        for my $r (@rows) {
            $stream->write(sprintf("  %-20s  %s  on %s  (%s)\r\n",
                $r->{nick}, $r->{seen_at}, $r->{channel}, $r->{event_type}));
        }
        return;
    }

    my $sth = $dbh->prepare(q{
        SELECT nick, channel, event_type, seen_at, last_msg
        FROM USER_SEEN WHERE nick = ? ORDER BY seen_at DESC LIMIT 1
    });
    # mb100-B1: USER_SEEN stocke les nicks en lc() — normaliser $target
    unless ($sth && $sth->execute(lc($target))) {
        $stream->write("DB error.\r\n"); $sth->finish if $sth; return;
    }
    my $row = $sth->fetchrow_hashref; $sth->finish;
    unless ($row) {
        $stream->write("$target: not found in seen log.\r\n"); return;
    }
    my $msg = $row->{last_msg} ? " saying: \"$row->{last_msg}\"" : '';
    $stream->write("$target last seen $row->{seen_at} on $row->{channel}"
        . " ($row->{event_type})$msg\r\n");
}

# ---------------------------------------------------------------------------
# .purgereminders  - clean up delivered/cancelled reminders older than 7 days
# ---------------------------------------------------------------------------
sub _cmd_purgereminders {
    my ($self, $stream, $id) = @_;

    my $bot = $self->{bot};
    my $dbh = eval { $bot->{db}->ensure_connected } // $bot->{dbh};

    my $sth = $dbh->prepare(q{
        DELETE FROM REMINDERS
        WHERE delivered > 0
          AND created_at < DATE_SUB(NOW(), INTERVAL 7 DAY)
    });
    unless ($sth && $sth->execute()) {
        $stream->write("DB error.\r\n"); $sth->finish if $sth; return;
    }
    my $rows = $sth->rows; $sth->finish;
    $stream->write("Purged $rows reminder(s) older than 7 days.\r\n");
}

# =============================================================================
# MB678-IV-F: karma visibility commands
# =============================================================================

# ---------------------------------------------------------------------------
# .karma <nick> [#chan]  - show karma from partyline
# ---------------------------------------------------------------------------
sub _cmd_karma {
    my ($self, $stream, $id, $args) = @_;

    my $bot = $self->{bot};
    my $dbh = eval { $bot->{db}->ensure_connected } // $bot->{dbh};

    unless ($dbh) {
        $stream->write("DB error.\r\n");
        return;
    }

    my ($target, $chan) = split /\s+/, ($args // ''), 2;
    unless ($target) {
        $stream->write("Usage: .karma <nick> [#channel]\r\n");
        return;
    }

    my $target_lc = lc($target);

    # Explicit channel: keep old useful behavior and show zero if no row exists.
    if (defined $chan && $chan =~ /^#/) {
        my $sth_c = $dbh->prepare(
            'SELECT id_channel, name FROM CHANNEL WHERE LOWER(name) = LOWER(?)'
        );

        unless ($sth_c && $sth_c->execute($chan)) {
            $stream->write("DB error.\r\n");
            $sth_c->finish if $sth_c;
            return;
        }

        my $c = $sth_c->fetchrow_hashref;
        $sth_c->finish;

        unless ($c && $c->{id_channel}) {
            $stream->write("Channel $chan not found.\r\n");
            return;
        }

        my $sth = $dbh->prepare(
            'SELECT score FROM KARMA WHERE id_channel = ? AND nick = ?'
        );

        unless ($sth && $sth->execute($c->{id_channel}, $target_lc)) {
            $stream->write("DB error.\r\n");
            $sth->finish if $sth;
            return;
        }

        my $row = $sth->fetchrow_hashref;
        $sth->finish;

        my $score = $row ? ($row->{score} // 0) : 0;
        my $sign  = $score > 0 ? '+' : '';

        $stream->write("$target on $c->{name}: karma ${sign}${score}\r\n");
        return;
    }

    # No explicit channel: show only non-zero karma across all channels.
    # This avoids the old misleading behavior: first joined channel, often 0.
    my $sth = $dbh->prepare(q{
        SELECT c.name AS channel, k.score AS score
        FROM KARMA k
        JOIN CHANNEL c ON c.id_channel = k.id_channel
        WHERE LOWER(k.nick) = ?
          AND k.score <> 0
        ORDER BY ABS(k.score) DESC, k.score DESC, c.name ASC
    });

    unless ($sth && $sth->execute($target_lc)) {
        $stream->write("DB error.\r\n");
        $sth->finish if $sth;
        return;
    }

    my @rows;
    while (my $r = $sth->fetchrow_hashref) {
        push @rows, $r;
    }
    $sth->finish;

    unless (@rows) {
        $stream->write("$target has no karma on any channel.\r\n");
        return;
    }

    $stream->write("Karma for $target:\r\n");
    for my $r (@rows) {
        my $score = $r->{score} // 0;
        my $sign  = $score > 0 ? '+' : '';
        $stream->write(sprintf("  %-25s %s%d\r\n",
            $r->{channel} // '?', $sign, $score));
    }
}

# ---------------------------------------------------------------------------
# .karmahist [nick]  — show karma history from Partyline (K5)
# ---------------------------------------------------------------------------
sub _cmd_karmahist {
    my ($self, $stream, $id, $args) = @_;
    my $bot    = $self->{bot};
    my $filter = (defined $args && $args =~ /\S/) ? lc($args) : undef;
    $filter =~ s/^\s+|\s+$//g if $filter;

    # Resolve first active channel
    my $bot_nick = eval { $bot->{irc}->nick_folded } // '';
    my $chan;
    for my $name (sort keys %{ $bot->{channels} || {} }) {
        my @n = eval { $bot->gethChannelsNicksOnChan($name) };
        if (grep { lc($_) eq lc($bot_nick) } @n) { $chan = $name; last; }
    }
    unless ($chan) {
        $stream->write("Not on any channel.\r\n"); return;
    }

    my $klog = $bot->{_karma_log}{$chan} // [];
    unless (@$klog) {
        $stream->write("No karma history for $chan.\r\n"); return;
    }

    my @entries = reverse @$klog;
    if ($filter) {
        @entries = grep { lc($_->{nick}) eq $filter } @entries;
        unless (@entries) {
            $stream->write("No karma history for '$filter' on $chan.\r\n"); return;
        }
    }
    @entries = @entries[0..9] if @entries > 10;  # max 10 in PL

    my $label = $filter ? "Karma history for $filter" : "Recent karma changes";
    $stream->write("$label on $chan:\r\n");
    for my $e (@entries) {
        my $sign = $e->{score} > 0 ? '+' : '';
        my $ago  = Mediabot::UserCommands::_seconds_to_human(time() - $e->{ts});
        $stream->write(sprintf("  %-20s %s (now %s%d) by %-15s %s ago\r\n",
            $e->{nick}, $e->{delta}, $sign, $e->{score}, $e->{from}, $ago));
    }
}


# =============================================================================
# MB678-IV-G: configuration reload commands
# =============================================================================

# mb368-B1: one checked path for both Partyline configuration reload commands.
# Mediabot::Conf exposes reload(), not the historical/non-existent load().
sub _reload_configuration_file {
    my ($self) = @_;

    my $conf = $self->{bot}{conf};
    die "configuration object unavailable\n" unless $conf;
    die "configuration object has no reload method\n"
        unless $conf->can('reload');

    my $ok = $conf->reload();
    die "configuration reload returned failure\n" unless $ok;

    return 1;
}

# ---------------------------------------------------------------------------
# .reloadconf - reload only the configuration file in place
# ---------------------------------------------------------------------------
sub _cmd_reloadconf {
    my ($self, $stream, $id) = @_;

    my $ok = eval { $self->_reload_configuration_file() };
    if ($ok) {
        $stream->write("Configuration reloaded.\r\n");
        return 1;
    }

    my $err = $@ || 'configuration reload returned failure';
    return $self->_report_operation_error(
        $stream,
        'Partyline .reloadconf failed',
        'Configuration reload failed.',
        $err,
    );
}

# ---------------------------------------------------------------------------
# .reload  - Owner-only alias for an in-place configuration file reload
# ---------------------------------------------------------------------------
sub _cmd_reload {
    my ($self, $stream, $id) = @_;
    my $session = $self->{users}{$id} // {};
    unless (($session->{level} // 99) <= 0) {  # Owner only
        $stream->write("Permission denied (Owner required).\r\n"); return;
    }

    my $ok = eval { $self->_reload_configuration_file() };
    if ($ok) {
        my $logger = $self->{bot}{logger};
        eval {
            $logger->log(2, "Partyline: config reloaded by " . ($session->{login} // '?'))
                if $logger && $logger->can('log');
            1;
        };
        $stream->write("Configuration reloaded.\r\n");
        return 1;
    }

    my $err = $@ || 'configuration reload returned failure';
    return $self->_report_operation_error(
        $stream,
        'Partyline .reload failed',
        'Reload failed.',
        $err,
    );
}


# =============================================================================
# MB678-IV-H: network visibility and statistics commands
# =============================================================================

# ---------------------------------------------------------------------------
# .lusers [refresh] - show cached network stats from LUSERS
# ---------------------------------------------------------------------------
# mb544-B1: les details du LUSERS en partyline — lit le cache coeur (source
# independante du systeme Metrics); .lusers refresh demande une mise a jour
# immediate au serveur (les numerics repeupleront le cache en retour).
sub _cmd_lusers {
    my ($self, $stream, $id, $arg) = @_;

    my $bot = $self->{bot};
    my $stats = ($bot && eval { $bot->can('network_stats') }) ? $bot->network_stats : {};
    $stats = {} unless ref($stats) eq 'HASH';

    if (defined $arg && lc($arg) eq 'refresh') {
        my $sent = eval { $bot->can('request_lusers_now') ? $bot->request_lusers_now : 0 } || 0;
        if ($sent) {
            $stream->write("LUSERS refresh requested; values below are pre-refresh.\r\n");
        }
        else {
            $stream->write("LUSERS refresh not sent (not connected).\r\n");
        }
    }

    unless (%$stats) {
        $stream->write("Network stats: none yet (no LUSERS numerics received).\r\n");
        return;
    }

    my $line = "Network:";
    $line .= " users=" . $stats->{users} if defined $stats->{users};
    $line .= " (max " . $stats->{users_max} . ")" if defined $stats->{users_max};
    $line .= " channels=" . $stats->{channels} if defined $stats->{channels};
    $line .= " servers=" . $stats->{servers} if defined $stats->{servers};
    $line .= " operators=" . $stats->{operators} if defined $stats->{operators};
    $stream->write("$line\r\n");

    if (defined $stats->{updated_at}) {
        my $age = time() - $stats->{updated_at};
        $age = 0 if $age < 0;
        $stream->write("  updated: ${age}s ago\r\n");
    }
}

# ---------------------------------------------------------------------------
# .stats [#chan]  - top 3 msgs + karma top 3 for a channel
# ---------------------------------------------------------------------------
sub _cmd_stats {
    my ($self, $stream, $id, $args) = @_;

    my $bot = $self->{bot};
    my $dbh = eval { $bot->{db}->ensure_connected } // $bot->{dbh};
    return unless $dbh;

    # Determine channel
    my $chan;
    if (defined $args && $args =~ /^(#\S+)/) {
        $chan = $1;
    } else {
        # Default: first joined channel
        my $bot_nick = eval { $bot->{irc}->nick_folded } // '';
        for my $name (sort keys %{ $bot->{channels} || {} }) {
            my @n = eval { $bot->gethChannelsNicksOnChan($name) };
            if (grep { lc($_) eq lc($bot_nick) } @n) { $chan = $name; last; }
        }
    }
    unless ($chan) { $stream->write("No channel. Usage: .stats [#channel]\r\n"); return; }

    $stream->write("Stats for $chan:\r\n");
    $stream->write("-" x 40 . "\r\n");

    # Top 3 messages
    my $sth_top = $dbh->prepare(
        "SELECT cl.nick, COUNT(*) AS cnt FROM CHANNEL_LOG cl"
        . " JOIN CHANNEL c ON c.id_channel = cl.id_channel"
        . " WHERE c.name = ? GROUP BY cl.nick ORDER BY cnt DESC LIMIT 3"
    );
    if ($sth_top && $sth_top->execute($chan)) {
        $stream->write("  Top speakers:\r\n");
        my $rank = 1;
        while (my $r = $sth_top->fetchrow_hashref) {
            $stream->write(sprintf("    %d. %-20s %d msgs\r\n",
                $rank++, $r->{nick}, $r->{cnt}));
        }
        $sth_top->finish;
    }

    # Top 3 karma
    # mb412-R1: id canal via le helper central (cache d'abord, mb411).
    my $id_channel = Mediabot::Helpers::channel_id_cached($bot, $chan);
    if ($id_channel) {
        my $sth_k = $dbh->prepare(q{
            SELECT nick, score FROM KARMA
            WHERE id_channel = ? AND score != 0
            ORDER BY score DESC LIMIT 3
        });
        if ($sth_k && $sth_k->execute($id_channel)) {
            my @krows;
            while (my $r = $sth_k->fetchrow_hashref) { push @krows, $r; }
            $sth_k->finish;
            if (@krows) {
                $stream->write("  Top karma:\r\n");
                for my $r (@krows) {
                    my $sign = $r->{score} > 0 ? '+' : '';
                    $stream->write(sprintf("    %-20s %s%d\r\n",
                        $r->{nick}, $sign, $r->{score}));
                }
            } else {
                $stream->write("  No karma data yet.\r\n");
            }
        }
    }
    $stream->write("-" x 40 . "\r\n");
}



# =============================================================================
# MB678-IV-I: IRC control and lifecycle commands
# =============================================================================

# ---------------------------------------------------------------------------
# .join #chan [key]
# ---------------------------------------------------------------------------
sub _cmd_join {
    my ($self, $stream, $id, $chan, $key) = @_;

    my $bot  = $self->{bot};
    my $nick = $self->{users}{$id}{login};

    unless ($bot->{irc} && $bot->{irc}->is_connected) {
        $stream->write("Bot is not connected to IRC.\r\n");
        return;
    }

        $bot->joinChannel($chan, $key);

    if ($bot->can('refresh_channel_nicklist')) {
        eval { $bot->refresh_channel_nicklist($chan) };
    }

    $bot->{logger}->log(2, "Partyline: $nick requested JOIN $chan" . ($key ? " (key: [redacted])" : ""));
    $stream->write("Joining $chan" . ($key ? " with key [redacted]" : "") . "...\r\n");
}

# ---------------------------------------------------------------------------
# .part #chan
# ---------------------------------------------------------------------------
sub _cmd_part {
    my ($self, $stream, $id, $chan) = @_;

    my $bot  = $self->{bot};
    my $nick = $self->{users}{$id}{login};

    unless ($bot->{irc} && $bot->{irc}->is_connected) {
        $stream->write("Bot is not connected to IRC.\r\n");
        return;
    }

    $bot->partChannel($chan, "Partyline requested part");

    if ($bot->can('stop_channel_nicklist_timer')) {
        $bot->stop_channel_nicklist_timer($chan);
    }

    $bot->sethChannelsNicksOnChan($chan, ());
    $bot->{logger}->log(2, "Partyline: $nick requested PART $chan");
    $stream->write("Parting $chan...\r\n");
}

# ---------------------------------------------------------------------------
# .nick <newnick>  - Master level required (already enforced by login,
#                    but validated explicitly here for clarity)
# ---------------------------------------------------------------------------
sub _cmd_nick {
    my ($self, $stream, $id, $newnick) = @_;

    my $bot  = $self->{bot};
    my $nick = $self->{users}{$id}{login};

    unless ($bot->{irc} && $bot->{irc}->is_connected) {
        $stream->write("Bot is not connected to IRC.\r\n");
        return;
    }

    # Validate nick: IRC nicks must not contain spaces or control chars
    unless ($newnick =~ /^[A-Za-z\[\]\\\`_\^\{\|\}][A-Za-z0-9\[\]\\\`_\-\^\{\|\}]{0,14}$/) {
        $stream->write("Invalid nick format.\r\n");
        return;
    }

    $bot->{irc}->change_nick($newnick);
    $bot->{logger}->log(2, "Partyline: $nick changed bot nick to $newnick");
    $stream->write("Nick change requested: $newnick\r\n");
}

# ---------------------------------------------------------------------------
# .raw <IRC command>  - Owner only
# ---------------------------------------------------------------------------
sub _cmd_raw {
    my ($self, $stream, $id, $raw) = @_;

    my $bot  = $self->{bot};
    my $nick = $self->{users}{$id}{login};

    unless ($bot->{irc} && $bot->{irc}->is_connected) {
        $stream->write("Bot is not connected to IRC.\r\n");
        return;
    }

    unless (defined($self->{users}{$id}{level}) && $self->{users}{$id}{level} == 0) {
        $stream->write("Access denied: .raw requires Owner level.\r\n");
        return;
    }

    $raw =~ s/[\r\n]//g;    # strip embedded CR/LF to prevent IRC command injection
    $bot->{irc}->write($raw . "\x0d\x0a");
    $bot->{logger}->log(2, "Partyline: $nick sent RAW: $raw");
    $stream->write("RAW -> $raw\r\n");
}

# ---------------------------------------------------------------------------
# .rehash
# ---------------------------------------------------------------------------
sub _cmd_rehash {
    my ($self, $stream, $id) = @_;

    my $bot   = $self->{bot};
    my $nick  = $self->{users}{$id}{login};
    my $level = $self->{users}{$id}{level};

    unless (defined($level) && $level <= 1) {   # Owner=0, Master=1
        $stream->write("Access denied: .rehash requires Master or Owner level.\r\n");
        return;
    }

    $bot->{logger}->log(2, "Partyline: $nick requested rehash");
    $stream->write("Rehashing...\r\n");

    my $result = eval { $bot->rehash_runtime_state() };
    if (!$result) {
        my $err = $@ || 'rehash failed';
        $bot->{logger}->log(1, "Partyline rehash failed for $nick: $err");
        $stream->write("ERR rehash failed\r\n");
        return;
    }

    $stream->write("OK rehash completed\r\n");
}

# ---------------------------------------------------------------------------
# .restart
# ---------------------------------------------------------------------------
sub _cmd_restart {
    my ($self, $stream, $id, $reason) = @_;

    my $bot   = $self->{bot};
    my $nick  = $self->{users}{$id}{login};
    my $level = $self->{users}{$id}{level};

    unless (defined($level) && $level == 0) {   # Owner only
        $stream->write("Access denied: .restart requires Owner level.\r\n");
        return;
    }

    $bot->{logger}->log(2, "Partyline: $nick requested IRC restart");

    # In-process IRC restart: the Partyline stays alive.
    # restart_irc() sends QUIT best-effort, detaches the IRC object from the loop,
    # and on_timer_tick() will trigger reconnect() in the same process on the same loop.
    if ($bot->can('restart_irc')) {
        $stream->write("Restarting IRC connection (Partyline stays up)...\r\n");
        $self->_broadcast("*** IRC restarting - bot will reconnect shortly. ***");
        my $msg = (defined $reason && $reason ne '') ? $reason : "Partyline .restart by $nick";
        $bot->restart_irc(reason => $msg);
    } else {
        $stream->write("ERR: restart_irc() not available.\r\n");
    }
}


# =============================================================================
# MB678-IV-J: Claude / AI commands
# =============================================================================

# ---------------------------------------------------------------------------
# .ai <prompt>  - send a prompt to Claude from the Partyline
# ---------------------------------------------------------------------------
sub _cmd_ai {
    my ($self, $stream, $id, $prompt) = @_;

    my $bot = $self->{bot};
    unless (defined $prompt && $prompt =~ /\S/) {
        $stream->write("Usage: .ai <prompt> | .ai reset | .ai history | .ai quota | .ai stats | .ai models | .ai forget | .ai pin [clear|text] | .ai summary [n]\r\n");
        return;
    }

    $prompt =~ s/^\s+|\s+$//g;

    my $session = $self->{users}{$id} // {};
    my $pl_nick = $session->{login} // 'partyline';

    # Resolve a stable Partyline AI scope. We use the first active joined
    # channel when possible, otherwise a dedicated partyline scope.
    my $bot_nick = eval { $bot->{irc}->nick_folded } // '';
    my $chan;
    for my $name (sort keys %{ $bot->{channels} || {} }) {
        my @n = eval { $bot->gethChannelsNicksOnChan($name) };
        if (grep { lc($_) eq lc($bot_nick) } @n) {
            $chan = $name;
            last;
        }
    }
    $chan //= 'partyline';

    my ($subcmd, $rest) = split /\s+/, $prompt, 2;
    $subcmd = lc($subcmd // '');
    $rest //= '';

    # .ai reset — clear history for this Partyline AI scope.
    # DD9: .ai status — show session + char + persona counts

    if ($subcmd eq 'status') {
        my $hist    = $bot->{_claude_history} // {};
        my $pins    = $bot->{_claude_pinned}  // {};
        my $n_h     = scalar keys %$hist;
        my $n_p     = scalar keys %$pins;
        my $n_per   = scalar keys %{ $bot->{_claude_persona} // {} };
        my $chars   = 0;
        $chars += length($_->{content}//'') for map { @{ $hist->{$_} // [] } } keys %$hist;
        my $ck = $chars > 1000 ? sprintf('~%.1fk chars', $chars/1000) : "$chars chars";
        $stream->write("Claude: $n_h session(s) ($ck), $n_p pinned, $n_per persona(s).\r\n");
        return;
    }

    if ($subcmd eq 'reset') {
        my $hist_key = "$pl_nick\x00$chan";
        delete $bot->{_claude_history}{$hist_key};
        $stream->write("Conversation history cleared.\r\n");
        return;
    }

    # .ai forget — clear history, persona and pinned context for this scope.
    if ($subcmd eq 'forget') {
        my $hist_key_raw = "$pl_nick\x00$chan";
        my $hist_key_lc  = lc($pl_nick) . "\x00$chan";

        my $had = 0;
        for my $key ($hist_key_raw, $hist_key_lc) {
            $had ||= exists $bot->{_claude_history}{$key};
            $had ||= exists $bot->{_claude_persona}{$key};
            $had ||= exists $bot->{_claude_pinned}{$key};

            delete $bot->{_claude_history}{$key};
            delete $bot->{_claude_persona}{$key};
            delete $bot->{_claude_pinned}{$key};
        }

        $stream->write($had
            ? "Claude history, persona and pinned context cleared for $pl_nick on $chan.\r\n"
            : "No active Claude session found for $pl_nick on $chan.\r\n");
        return;
    }

    # .ai history — show current context.
    if ($subcmd eq 'history') {
        # AA15: 'history clear [nick]' — wipe history
        if (defined $rest && $rest =~ /^clear(?:\s+(\S+))?$/i) {
            my $tgt = defined $1 ? lc($1) : $pl_nick;
            my $cleared = 0;
            for my $k (keys %{ $bot->{_claude_history} // {} }) {
                my ($nk) = split /\x00/, $k, 2;
                if (lc($nk) eq $tgt) {
                    delete $bot->{_claude_history}{$k};
                    delete $bot->{_ai_last_active}{$k} if $bot->{_ai_last_active};
                    $cleared++;
                }
            }
            $stream->write("Cleared $cleared history session(s) for $tgt\r\n");
            return;
        }
        my $hist_key = "$pl_nick\x00$chan";
        my $history  = $bot->{_claude_history}{$hist_key} // [];

        unless (@$history) {
            $stream->write("No conversation history.\r\n");
            return;
        }

        # IMP13: also show estimated size in chars
        my $hist_chars = 0;
        $hist_chars += length($_->{content} // '') for @$history;
        my $hist_exchanges = int(scalar(@$history) / 2);
        # CC20: show exchanges + char count
        my $_cc20_chars = 0;
        $_cc20_chars += length($_->{content}//'') for @$history;
        my $_cc20_ex = int(scalar(@$history)/2);
        $stream->write(scalar(@$history)
            . " message(s) in context"
            . " ($_cc20_ex exchange(s), ~$_cc20_chars chars):\r\n");
        my @display = @$history > 6 ? @{$history}[-6..-1] : @$history;

        for my $msg (@display) {
            my $role    = $msg->{role}    // '?';
            my $content = $msg->{content} // '';
            $content = Mediabot::Helpers::truncate_utf8($content, 120);  # mb429-R1
            $stream->write("  [$role] $content\r\n");
        }
        return;
    }

    # .ai quota — show own Claude rate limit.
    if ($subcmd eq 'quota') {
        return $self->_cmd_quota($stream, $id, lc($pl_nick));
    }

    # .ai stats — same idea as .aistats, but available as a real .ai subcommand.
    if ($subcmd eq 'stats') {
        my $reqs = eval { $bot->{metrics}->get('mediabot_claude_requests_total') } // 0;
        my $errs = eval { $bot->{metrics}->get('mediabot_claude_errors_total') }   // 0;
        my $rl   = eval { $bot->{metrics}->get('mediabot_claude_ratelimit_total') } // 0;
        my $hc   = scalar keys %{ $bot->{_claude_history} // {} };
        my $pc   = scalar keys %{ $bot->{_claude_persona} // {} };
        my $pin  = scalar keys %{ $bot->{_claude_pinned}  // {} };

        $stream->write("Claude stats:\r\n");
        $stream->write("  Requests     : $reqs\r\n");
        $stream->write("  Errors       : $errs\r\n");
        $stream->write("  Rate-limited : $rl\r\n");
        $stream->write("  Histories    : $hc\r\n");
        $stream->write("  Personas     : $pc\r\n");
        $stream->write("  Pinned ctx   : $pin\r\n");
        return;
    }

    # .ai model / .ai models — show known model list and current config.
    if ($subcmd eq 'model' || $subcmd eq 'models') {
        my @known = qw(
            claude-opus-4-6
            claude-sonnet-4-6
            claude-haiku-4-5-20251001
        );

        my $current = eval { $bot->{conf}->get('anthropic.MODEL') } || 'unknown';
        my @labeled = map { $_ eq $current ? "$_ (current)" : $_ } @known;

        $stream->write("Current Claude model: $current\r\n");
        $stream->write("Known Claude models:\r\n");
        $stream->write("  $_\r\n") for @labeled;
        return;
    }

    # .ai pin            — show pinned context
    # .ai pin clear      — clear pinned context
    # .ai pin <text>     — set pinned context
    if ($subcmd eq 'pin' && (($rest // '') =~ /^list$/i || ($rest // '') eq '')) {
        # AA10: '.ai pin list' or '.ai pin' alone → list all active pins
        if (($rest // '') =~ /^list$/i || ($rest // '') eq '') {
            my $pins = $bot->{_claude_pinned} // {};
            unless (%$pins) { $stream->write("No active pins.\r\n"); }
            else {
                $stream->write("Active Claude pins:\r\n");
                for my $key (sort keys %$pins) {
                    my ($nk,$ck) = split /\x00/, $key, 2;
                    $stream->write(sprintf("  %-15s %-12s %.60s\r\n",
                        $nk, $ck, $pins->{$key}));
                }
            }
            return;
        }
    }
    if ($subcmd eq 'pin') {
        my $pin_key = lc($pl_nick) . "\x00$chan";
        my $action = $rest;
        $action =~ s/^\s+|\s+$//g;

        if ($action eq '') {
            my $current = $bot->{_claude_pinned}{$pin_key};
            $stream->write($current
                ? "Pinned context for $pl_nick on $chan: $current\r\n"
                : "No pinned context for $pl_nick on $chan.\r\n");
            return;
        }

        if (lc($action) eq 'clear') {
            delete $bot->{_claude_pinned}{$pin_key};
            $stream->write("Pinned context cleared for $pl_nick on $chan.\r\n");
            return;
        }

        # IMP9: raised to 500 chars max (was 300), warn if truncated
        my $was_long = length($action) > 500;
        my $pinned   = $was_long ? substr($action, 0, 500) : $action;
        $bot->{_claude_pinned}{$pin_key} = $pinned;
        my $notice = $was_long
            ? "Pinned context set (truncated to 500 chars): $pinned"
            : "Pinned context set: $pinned";
        $stream->write("$notice\r\n");
        return;
    }

    # .ai summary [n] — summarize recent CHANNEL_LOG messages for the resolved scope.
    if ($subcmd eq 'summary') {
        # mb631-B1: meme porte qu'en canal (Administrator+). L'echelle de la
        # partyline est INVERSEE : Owner=0, Master=1, Administrator=2, donc
        # « Administrator ou mieux » s'ecrit level <= 2.
        my $pl_level = $self->{users}{$id}{level} // 99;
        unless ($pl_level <= 2) {
            $stream->write("Permission denied (Administrator+ required).\r\n");
            return;
        }
        my $n_msgs = ($rest =~ /^\s*(\d+)/) ? int($1) : 10;
        $n_msgs = 5  if $n_msgs < 5;
        $n_msgs = 50 if $n_msgs > 50;

        if (!defined $chan || $chan eq 'partyline') {
            $stream->write("No IRC channel available for summary.\r\n");
            return;
        }

        my $dbh = eval { $bot->{db}->ensure_connected } // $bot->{dbh};
        unless ($dbh) {
            $stream->write("DB error.\r\n");
            return;
        }

        # mb348-B1: contexte IA = vraie conversation -> event_type IN ('public','action')
        # (et non publictext IS NOT NULL qui inclut join/part/kick/mode/topic).
        my $sth = $dbh->prepare(q{
            SELECT cl.nick, cl.publictext AS text
            FROM CHANNEL_LOG cl
            JOIN CHANNEL c ON c.id_channel = cl.id_channel
            WHERE c.name = ?
              AND cl.event_type IN ('public','action')
              AND cl.publictext <> ''
            ORDER BY cl.id_channel_log DESC
            LIMIT ?
        });

        unless ($sth && $sth->execute($chan, $n_msgs)) {
            $stream->write("DB error.\r\n");
            $sth->finish if $sth;
            return;
        }

        my @rows;
        while (my $r = $sth->fetchrow_hashref) {
            unshift @rows, "$r->{nick}: $r->{text}";
        }
        $sth->finish;

        unless (@rows) {
            $stream->write("No recent messages found on $chan.\r\n");
            return;
        }

        my $transcript = join("\n", @rows);
        my $summary_prompt = "Summarise this IRC conversation from $chan in 2-3 sentences:\n$transcript";

        my $output_fn = sub {
            my ($text) = @_;
            $text =~ s/[\r\n]+$//;
            $stream->write("[Claude] $text\r\n");
        };

        eval {
            Mediabot::External::claudeAI($bot, undef, $pl_nick, $chan,
                $output_fn, $summary_prompt);
        };
        if ($@) {
            my $err = $@;
            $self->_report_operation_error(
                $stream,
                'Partyline .ai summary failed',
                'AI request failed.',
                $err,
            );
        }
        return;
    }

    # Normal .ai <prompt> path.
    my $output_fn = sub {
        my ($text) = @_;
        $text =~ s/[\r\n]+$//;
        $stream->write("[Claude] $text\r\n");
    };

    eval {
        Mediabot::External::claudeAI($bot, undef, $pl_nick, $chan,
            $output_fn, split(/\s+/, $prompt));
    };
    if ($@) {
        my $err = $@;
        $self->_report_operation_error(
            $stream,
            'Partyline .ai failed',
            'AI request failed.',
            $err,
        );
    }
}

# ---------------------------------------------------------------------------
# _cmd_persona [nick [#chan]]  — view/clear persona from Partyline
# I7: operators can inspect any nick's Claude persona
# ---------------------------------------------------------------------------
sub _cmd_persona {
    my ($self, $stream, $id, $args) = @_;
    my $bot = $self->{bot};
    my $personas = $bot->{_claude_persona} // {};

    # No args — list all active personas
    unless (defined $args && $args =~ /\S/) {
        unless (%$personas) {
            $stream->write("No active personas.\r\n"); return;
        }
        $stream->write("Active Claude personas:\r\n");
        my $now_p = time();
        for my $key (sort keys %$personas) {
            my ($nick_k, $chan_k) = split /\x00/, $key, 2;
            my $text = substr($personas->{$key}, 0, 55);
            # IMP25: show time since last use from _ai_last_active
            my $last_ts = $bot->{_ai_last_active}{$key} // 0;
            my $age_str = '';
            if ($last_ts > 0) {
                my $diff = $now_p - $last_ts;
                $age_str = $diff >= 3600
                    ? sprintf(' (%dh%02dm ago)', int($diff/3600), int(($diff%3600)/60))
                    : sprintf(' (%dm ago)', int($diff/60));
            }
            $stream->write(sprintf("  %-15s %-12s %s...%s\r\n",
                $nick_k, $chan_k, $text, $age_str));
        }
        return;
    }

    # .persona <nick> [#chan] [clear]
    my @parts  = split /\s+/, $args, 3;
    my $target = lc($parts[0]);
    my $chan   = $parts[1] && $parts[1] =~ /^#/ ? $parts[1] : undef;
    my $subcmd = $chan ? ($parts[2] // '') : ($parts[1] // '');

    # Find matching keys
    my @keys = grep {
        my ($n,$c) = split /\x00/, $_, 2;
        lc($n) eq $target && (!$chan || lc($c) eq lc($chan))
    } keys %$personas;

    unless (@keys) {
        $stream->write("No persona found for '$target'" . ($chan ? " on $chan" : '') . ".\r\n");
        return;
    }

    if (lc($subcmd) eq 'clear') {
        delete $personas->{$_} for @keys;
        $stream->write("Persona cleared for $target (" . scalar(@keys) . " entr" . (@keys == 1 ? 'y' : 'ies') . ").\r\n");
    } else {
        $stream->write("Persona(s) for $target:\r\n");
        for my $key (@keys) {
            my ($n, $c) = split /\x00/, $key, 2;
            $stream->write("  [$c] $personas->{$key}\r\n");
        }
    }
}

# ---------------------------------------------------------------------------
# _cmd_quota [nick]  - show Claude rate limit status from Partyline
# ---------------------------------------------------------------------------
sub _cmd_quota {
    my ($self, $stream, $id, $args) = @_;
    my $bot = $self->{bot};
    my $now = time();

    # Keep .quota aligned with claudeAI() / !ai quota rate-limit settings.
    my $rate_max = eval { int($bot->{conf}->get('anthropic.RATE_MAX') // 5) } // 5;
    my $rate_window = eval { int($bot->{conf}->get('anthropic.RATE_WINDOW') // 60) } // 60;
    $rate_max = 1 if $rate_max < 1;
    $rate_window = 10 if $rate_window < 10;

    my $fmt_wait = sub {
        my ($wait) = @_;
        $wait = int($wait // 0);
        $wait = 0 if $wait < 0;
        return $wait >= 60
            ? sprintf('%dm %ds', int($wait/60), $wait % 60)
            : "${wait}s";
    };

    my $fmt_reset = sub {
        my ($entry) = @_;
        return '' unless $entry && defined $entry->{window};
        my $reset_at = $entry->{window} + $rate_window;
        my @rt = localtime($reset_at);
        return sprintf('resets %02d:%02d', $rt[2], $rt[1]);
    };

    if (!defined $args || $args !~ /\S/) {
        my $rl = $bot->{_claude_ratelimit} // {};
        unless (%$rl) {
            $stream->write("No active rate limit windows.\r\n");
            return;
        }

        $stream->write("Active Claude rate limit windows:\r\n");
        # A6: sort by nick then channel for readable output
        for my $key (sort {
                (split /\x00/, $a, 2)[0] cmp (split /\x00/, $b, 2)[0]
                || $a cmp $b
            } keys %$rl) {
            my $entry = $rl->{$key};
            next if ($now - ($entry->{window} // 0)) >= $rate_window;

            my ($nick_k, $chan_k) = split /\x00/, $key, 2;
            my $used = $entry->{count} // 0;
            my $remaining = $rate_max - $used;
            $remaining = 0 if $remaining < 0;

            my $wait = $rate_window - ($now - ($entry->{window} // $now));
            my $wait_h = $fmt_wait->($wait);
            my $reset_str = $fmt_reset->($entry);

            $stream->write(sprintf("  %-20s %-15s %d/%d req (%s left, %s)\r\n",
                $nick_k, $chan_k, $used, $rate_max, $wait_h, $reset_str));
        }
        return;
    }

    my $target = lc($args);
    $target =~ s/^\s+|\s+$//g;

    my $rl = $bot->{_claude_ratelimit} // {};
    my @found;

    for my $key (sort keys %$rl) {
        my ($nick_k, $chan_k) = split /\x00/, $key, 2;
        next unless lc($nick_k) eq $target;

        my $entry = $rl->{$key};
        next if ($now - ($entry->{window} // 0)) >= $rate_window;

        my $used = $entry->{count} // 0;
        my $remaining = $rate_max - $used;
        $remaining = 0 if $remaining < 0;

        my $wait = $rate_window - ($now - ($entry->{window} // $now));
        my $wait_h = $fmt_wait->($wait);
        my $reset_str = $fmt_reset->($entry);

        push @found, sprintf("  %-15s %d/%d req — %d remaining (%s left, %s)",
            $chan_k, $used, $rate_max, $remaining, $wait_h, $reset_str);
    }

    if (@found) {
        $stream->write("Claude quota for $target:\r\n");
        $stream->write("$_\r\n") for @found;
    }
    else {
        $stream->write("No active rate limit for '$target'.\r\n");
    }
}


# =============================================================================
# MB678-IV-K: runtime diagnostics and status commands
# =============================================================================

sub _cmd_ping {
    my ($self, $stream, $id) = @_;
    my ($sec, $min, $hour) = localtime(time);
    $stream->write(sprintf("PONG %02d:%02d:%02d\r\n", $hour, $min, $sec));
}

sub _cmd_uptime {
    my ($self, $stream, $id) = @_;

    my $bot = $self->{bot};
    my $now = time();

    my $bot_start = Mediabot::Helpers::getProcessStartTimestamp($bot, $now);

    my $bot_uptime = $now - $bot_start;
    $bot_uptime = 0 if $bot_uptime < 0;

    my $server_uptime = undef;
    if (open my $fh, '<', '/proc/uptime') {
        my $line = <$fh>;
        close $fh;

        if (defined $line && $line =~ /^(\d+(?:\.\d+)?)/) {
            $server_uptime = int($1);
        }
    }

    my $bot_name = eval { $bot->{conf}->get('main.MAIN_PROG_NAME') } || 'Mediabot';
    my $version  = $bot->{main_prog_version} // '';

    $stream->write("Uptime:\r\n");
    $stream->write("  Bot     : " . $self->_format_duration($bot_uptime) . "\r\n");
    $stream->write("  Process : pid $$\r\n");
    $stream->write("  Name    : $bot_name" . ($version ne '' ? " v$version" : "") . "\r\n");

    if (defined $server_uptime) {
        $stream->write("  Server  : " . $self->_format_duration($server_uptime) . "\r\n");
    }
    else {
        $stream->write("  Server  : unavailable\r\n");
    }

    # J1: Claude stats in .uptime output
    my $claude_reqs   = eval { $bot->{metrics}->get('mediabot_claude_requests_total') } // 0;
    my $claude_errs   = eval { $bot->{metrics}->get('mediabot_claude_errors_total') } // 0;
    my $claude_rl     = eval { $bot->{metrics}->get('mediabot_claude_ratelimit_total') } // 0;
    my $persona_count = scalar keys %{ $bot->{_claude_persona} // {} };
    my $hist_count    = scalar keys %{ $bot->{_claude_history}  // {} };
    $stream->write("Claude AI:\r\n");
    $stream->write("  Requests : $claude_reqs (errors: $claude_errs, ratelimited: $claude_rl)\r\n");
    $stream->write("  Personas : $persona_count active\r\n");
    $stream->write("  History  : $hist_count active session(s)\r\n");
}

sub _cmd_dccstat {
    my ($self, $stream, $id) = @_;

    my $bot = $self->{bot};

    my $public_ip = eval { $self->_resolve_dcc_public_ip($bot) } || '(not configured)';

    # Use shared helpers to avoid duplicating config key lookup logic.
    my $dcc_port  = eval { $self->_dcc_listen_port($bot) } // 0;
    my $port_mode = $dcc_port > 0
        ? "configured port $dcc_port (from DCC_PORT_MIN/MAX range)"
        : 'OS ephemeral port';

    my $offers = eval { $self->_dcc_offers_snapshot } || [];

    my @dcc_sessions;
    my @telnet_sessions;

    for my $fid (sort { $a <=> $b } keys %{ $self->{users} || {} }) {
        my $u = $self->{users}{$fid} || next;
        next unless $u->{authenticated};

        my $entry = {
            fd         => $fid,
            login      => $u->{login}      || '?',
            level_desc => $u->{level_desc} || '?',
            peer_host  => $u->{peer_host}  || 'unknown',
            peer_ip    => $u->{peer_ip}    || '',
            console    => defined $u->{console_level} ? $u->{console_level} : 'off',
        };

        if ($u->{is_dcc}) {
            push @dcc_sessions, $entry;
        }
        else {
            push @telnet_sessions, $entry;
        }
    }

    $stream->write("DCC Partyline status:\r\n");
    $stream->write("  Public IP      : $public_ip\r\n");
    $stream->write("  Port mode      : $port_mode\r\n");
    $stream->write("  Pending offers : " . scalar(@$offers) . "\r\n");
    $stream->write("  DCC sessions   : " . scalar(@dcc_sessions) . "\r\n");
    $stream->write("  Telnet sessions: " . scalar(@telnet_sessions) . "\r\n");
    $stream->write("\r\n");

    if (@$offers) {
        $stream->write("Pending DCC offers:\r\n");
        $stream->write(sprintf("  %-12s %-14s %-16s %-8s %-6s\r\n",
            "Type", "Nick", "Public IP", "Port", "Age"));
        $stream->write("  " . ("-" x 64) . "\r\n");

        my $now = time;
        for my $o (@$offers) {
            my $age = $now - ($o->{created_at} || $now);
            # Z4: human-readable age for DCC offers
            my $age_h = $age >= 60
                ? sprintf('%dm %ds', int($age/60), $age%60)
                : "${age}s";
            $stream->write(sprintf("  %-12s %-14s %-16s %-8s %s\r\n",
                $o->{type}      || '?',
                $o->{nick}      || '?',
                $o->{public_ip} || '?',
                $o->{port}      || '?',
                $age_h
            ));
        }

        $stream->write("\r\n");
    }
    else {
        $stream->write("No pending DCC offers.\r\n\r\n");
    }

    if (@dcc_sessions) {
        $stream->write("Active DCC sessions:\r\n");
        $stream->write(sprintf("  %-14s %-14s %-6s %-20s %-10s\r\n",
            "Nick", "Level", "FD", "Peer", "Console"));
        $stream->write("  " . ("-" x 76) . "\r\n");

        for my $u (@dcc_sessions) {
            $stream->write(sprintf("  %-14s %-14s fd=%-3s %-20s console:%s\r\n",
                $u->{login},
                $u->{level_desc},
                $u->{fd},
                $u->{peer_host},
                $u->{console}
            ));
        }

        $stream->write("\r\n");
    }
    else {
        $stream->write("No active DCC sessions.\r\n\r\n");
    }

    if (@telnet_sessions) {
        $stream->write("Active telnet sessions:\r\n");
        $stream->write(sprintf("  %-14s %-14s %-6s %-20s %-10s\r\n",
            "Nick", "Level", "FD", "Peer", "Console"));
        $stream->write("  " . ("-" x 76) . "\r\n");

        for my $u (@telnet_sessions) {
            $stream->write(sprintf("  %-14s %-14s fd=%-3s %-20s console:%s\r\n",
                $u->{login},
                $u->{level_desc},
                $u->{fd},
                $u->{peer_host},
                $u->{console}
            ));
        }

        $stream->write("\r\n");
    }
}

sub _cmd_stat {
    my ($self, $stream, $id) = @_;

    my $bot = $self->{bot};
    my $irc = $bot->{irc};
    my $dbh = $bot->{dbh};

    unless ($irc && $irc->is_connected) {
        $stream->write("Bot is not connected to IRC.\r\n");
        return;
    }

    my $bot_nick = $irc->nick_folded // '';

    # Header
    $stream->write(sprintf("%-30s %-12s %-5s %-20s %s\r\n",
        "Channel", "Status", "Nicks", "Owner", "Chansets"));
    $stream->write(("-" x 90) . "\r\n");

    my $channels = $bot->{channels};
    unless ($channels && ref($channels) eq 'HASH' && %$channels) {
        $stream->write("No channels known (bot not yet joined any channel).\r\n");
        return;
    }

    # Batch-fetch owners and chansets in two queries instead of N×2.
    # Results cached for 60 seconds to avoid hammering the DB on repeated .stat.
    my $stat_cache_key = '_stat_cache';
    my $stat_cache     = $self->{$stat_cache_key};
    my %owners;
    my %chansets;

    if (!$stat_cache || (time() - ($stat_cache->{at} // 0)) > 60) {
        # Owners: one query for all channels
        my $sth_o = $dbh->prepare(
            "SELECT uc.id_channel, u.nickname FROM USER u
              JOIN USER_CHANNEL uc ON uc.id_user = u.id_user
              WHERE uc.level = 500"
        );
        if ($sth_o && $sth_o->execute()) {
            while (my $r = $sth_o->fetchrow_hashref) {
                $owners{ $r->{id_channel} } //= $r->{nickname};
            }
            $sth_o->finish;
        }

        # Chansets: one query for all channels
        my $sth_c = $dbh->prepare(
            "SELECT cs.id_channel, cl.chanset FROM CHANSET_LIST cl
              JOIN CHANNEL_SET cs ON cs.id_chanset_list = cl.id_chanset_list
              ORDER BY cs.id_channel, cl.chanset"
        );
        if ($sth_c && $sth_c->execute()) {
            while (my $r = $sth_c->fetchrow_hashref) {
                $chansets{ $r->{id_channel} } //= '';
                $chansets{ $r->{id_channel} } .= '+' . $r->{chanset} . ' ';
            }
            $sth_c->finish;
        }

        $self->{$stat_cache_key} = { at => time(), owners => \%owners, chansets => \%chansets };
    } else {
        %owners   = %{ $stat_cache->{owners}   // {} };
        %chansets = %{ $stat_cache->{chansets} // {} };
    }

    foreach my $chan_name (sort keys %$channels) {
        my $chan_obj   = $bot->{channels}{lc $chan_name};
        my $id_channel = eval { $chan_obj->get_id } // 0;

        my @nicks      = $bot->gethChannelsNicksOnChan($chan_name);
        my $joined     = grep { lc($_) eq lc($bot_nick) } @nicks;
        my $nick_count = scalar @nicks;
        my $status     = $joined ? "joined" : "NOT joined";

        my $owner    = $owners{$id_channel}   // 'none';
        my $chanset_str = $chansets{$id_channel} // 'none';
        $chanset_str =~ s/\s+$//;

        $stream->write(sprintf("%-30s %-12s %-5d %-20s %s\r\n",
            $chan_name, $status, $nick_count, $owner, $chanset_str));
    }

    # EE3: bottom section — uptime, Claude sessions, memory, AF state
    $stream->write(("=" x 90) . "\r\n");
    my $started  = $bot->{metrics} ? ($bot->{metrics}{started} // time()) : time();
    my $uptime   = time() - $started;
    my $ud = int($uptime/86400); my $uh = int(($uptime%86400)/3600);
    my $um = int(($uptime%3600)/60);  my $us = $uptime%60;
    $stream->write(sprintf("Uptime: %dd %02dh%02dm%02ds\r\n", $ud,$uh,$um,$us));

    my $claude_sessions = scalar keys %{ $bot->{_claude_history} // {} };
    my $ai_cache        = scalar keys %{ $bot->{_claude_prompt_cache} // {} };
    $stream->write("Claude: $claude_sessions active session(s), $ai_cache cached prompt(s)\r\n");

    # IMP18/mb115: IRC command totals from real Prometheus counters.
    # Use public + private command counters; there is no aggregate IRC counter.
    if ($bot->{metrics}) {
        my $cmds_pub  = eval { $bot->{metrics}->get('mediabot_commands_public_total') } // 0;
        my $cmds_priv = eval { $bot->{metrics}->get('mediabot_commands_private_total') } // 0;
        my $cmds_pl   = eval { $bot->{metrics}->get('mediabot_commands_partyline_total') } // 0;
        my $msgs_out  = eval { $bot->{metrics}->get('mediabot_privmsg_out_total') } // 0;
        $stream->write("Commands: ${cmds_pub} IRC public, ${cmds_priv} IRC private, ${cmds_pl} partyline\r\n");
        $stream->write("Messages: ${msgs_out} PRIVMSG sent\r\n");
    }

    my $mutes   = scalar grep { ($bot->{_nick_mute}{$_} // 0) > time() }
                        keys %{ $bot->{_nick_mute} // {} };
    my $sil_af  = scalar grep { ($_->{silenced_until} // 0) > time() }
                        values %{ $bot->{_af} // {} };
    my $sil_cf  = scalar grep { ($_->{silenced_until} // 0) > time() }
                        values %{ $bot->{_chan_flood} // {} };
    $stream->write("Flood: $sil_af chan(s) AF-silenced, $sil_cf chan(s) CF-silenced, "
                 . "$mutes nick(s) muted\r\n");

    if (eval { require Scalar::Util::Numeric; 1 } || 1) {
        my $mem = 0;
        if (open my $fh, '<', '/proc/self/status') {
            while (<$fh>) { if (/^VmRSS:\s+(\d+)/) { $mem = int($1/1024); last; } }
            close $fh;
        }
        $stream->write("Memory: ${mem} MB RSS\r\n") if $mem;
    }
}

sub _cmd_dbstats {
    my ($self, $stream, $id) = @_;
    my $bot = $self->{bot};
    my $dbh = eval { $bot->{db}->ensure_connected } // $bot->{dbh};
    unless ($dbh) { $stream->write("DB not connected.\r\n"); return; }
    my %stats;
    for my $like ('Questions', 'Slow_queries', 'Threads_connected') {
        my $sth = eval { $dbh->prepare("SHOW STATUS LIKE '$like'") };
        if ($sth && $sth->execute()) {
            while (my $r = $sth->fetchrow_arrayref) { $stats{$r->[0]} = $r->[1]; }
            $sth->finish;
        }
    }
    my $db_name = eval { ($dbh->selectrow_array('SELECT DATABASE()'))[0] } // '?';
    $stream->write("DB stats ($db_name):\r\n");
    $stream->write(sprintf("  Threads : %s | Questions : %s | Slow : %s\r\n",
        $stats{Threads_connected}//'N/A', $stats{Questions}//'N/A', $stats{Slow_queries}//'N/A'));
    my $reqs = eval { $bot->{metrics}->get('mediabot_claude_requests_total') } // 0;
    my $yts  = eval { $bot->{metrics}->get('mediabot_ytsearch_requests_total') } // 0;
    my $kh   = eval { $bot->{metrics}->get('mediabot_karmahist_requests_total') } // 0;
    $stream->write("Bot: Claude=$reqs YTsearch=$yts KarmaHist=$kh\r\n");
}


# =============================================================================
# MB678-IV-L: channel moderation and control commands
# =============================================================================

sub _cmd_bans {
    my ($self, $stream, $id, $chan) = @_;

    my $bot = $self->{bot};

    unless ($bot->{channel_ban} && $bot->{channel_ban}->can('list_active_bans')) {
        $stream->write("ChannelBan module not available.\r\n");
        return;
    }

    unless (defined $chan && $chan =~ /^#/) {
        $stream->write("Usage: .bans #channel\r\n");
        return;
    }

    # Resolve id_channel
    my $dbh = $bot->{dbh};
    # mb412-R1: id canal via le helper central (cache d'abord, mb411).
    my $id_channel = Mediabot::Helpers::channel_id_cached($bot, $chan);
    unless ($id_channel) {
        $stream->write("Channel $chan not found in DB.\r\n");
        return;
    }
    # A2: fetch up to 11 to detect overflow without loading all bans
    my @bans = $bot->{channel_ban}->list_active_bans($id_channel, 11);

    unless (@bans) {
        $stream->write("No active bans on $chan.\r\n");
        return;
    }

    my $has_more  = scalar(@bans) > 10;
    @bans = @bans[0..9] if $has_more;  # trim to 10
    my $total_bans = scalar @bans + ($has_more ? 1 : 0);  # approximate
    my $shown_bans = scalar @bans;
    $stream->write(sprintf("%d active ban(s) on $chan (showing %d):\r\n", $total_bans, $shown_bans));
    $stream->write(sprintf("  %-4s %-30s %-8s %-16s %s\r\n",
        "#", "Mask", "Level", "By", "Expires"));
    $stream->write("  " . ("-" x 76) . "\r\n");

    my $now_sth = $dbh->prepare('SELECT TIMESTAMPDIFF(SECOND, NOW(), ?) AS secs');

    for my $ban (@bans) {
        my $expires_txt = 'permanent';
        if ($ban->{expires_at}) {
            # G1/fix: guard undef $now_sth (prepare may fail when DB is down)
            my $secs = 0;
            if ($now_sth && $now_sth->execute($ban->{expires_at})) {
                my $r = $now_sth->fetchrow_hashref;
                $now_sth->finish;
                $secs = ($r && defined $r->{secs} && $r->{secs} > 0) ? $r->{secs} : 0;
            }
            if ($secs > 0) {
                my $d = int($secs / 86400);
                my $h = int(($secs % 86400) / 3600);
                my $m = int(($secs % 3600) / 60);
                $expires_txt = '';
                $expires_txt .= "${d}d " if $d;
                $expires_txt .= "${h}h " if $h;
                $expires_txt .= "${m}m"  if $m || (!$d && !$h);
                $expires_txt =~ s/\s+$//;
            } else {
                $expires_txt = 'expiring soon';
            }
        }

        $stream->write(sprintf("  %-4s %-30s %-8s %-16s %s\r\n",
            $ban->{id_channel_ban} // '?',
            $ban->{mask}           // '?',
            $ban->{ban_level}      // '?',
            $ban->{created_by_nick} // '?',
            $expires_txt
        ));
    }
}

sub _cmd_ban {
    my ($self, $stream, $id, $chan, $nick_target, @rest) = @_;

    my $bot    = $self->{bot};
    my $actor  = $self->{users}{$id}{login} // 'unknown';

    unless ($bot->{irc} && $bot->{irc}->is_connected) {
        $stream->write("Bot is not connected to IRC.\r\n");
        return;
    }

    unless ($bot->{channel_ban}) {
        $stream->write("ChannelBan module not available.\r\n");
        return;
    }

    unless (defined $chan && $chan =~ /^#/ && defined $nick_target && $nick_target ne '') {
        $stream->write("Usage: .ban #channel <nick> [duration] [reason]\r\n");
        $stream->write("Durations: 10m 2h 3d 1w perm (default: permanent)\r\n");
        return;
    }

    # Parse optional duration (first word of @rest if it looks like a duration)
    my ($duration_secs, $dur_label, $reason);
    if (@rest && $bot->{channel_ban}->looks_like_duration($rest[0])) {
        my $dur_str = shift @rest;
        my ($secs, $label, $err) = $bot->{channel_ban}->parse_duration($dur_str);
        if ($err) {
            $stream->write("Invalid duration: $err\r\n");
            return;
        }
        ($duration_secs, $dur_label) = ($secs, $label);
    } else {
        ($duration_secs, $dur_label) = (0, 'permanent');
    }
    $reason = join(' ', @rest) // '';

    # Store context for the async WHOIS callback
    # Guard against concurrent .ban calls overwriting WHOIS_VARS.
    # Store a unique token; the callback checks it matches before proceeding.
    my $ban_token = "partylineBan:${id}:" . time() . ":" . int(rand(1_000_000));

    # Keep the expected token on the Partyline session too.
    # The async WHOIS callback must compare both sides before applying the ban.
    $self->{users}{$id}{pending_whois_token} = $ban_token;
    $self->{users}{$id}{pending_whois_sub}   = 'partylineBan';

    %{ $bot->{WHOIS_VARS} } = (
        nick      => $nick_target,
        sub       => 'partylineBan',
        token     => $ban_token,
        caller    => $id,           # fd of the Partyline session
        channel   => $chan,
        duration  => $duration_secs,
        dur_label => $dur_label,
        reason    => $reason,
        actor     => $actor,
        ts        => time,
    );

    $bot->{irc}->send_message('WHOIS', undef, $nick_target);
    $bot->{logger}->log(2, "Partyline: $actor requested ban on $nick_target in $chan");
    $stream->write("WHOIS sent for $nick_target, ban will be applied on reply...\r\n");
    delete $self->{_stat_cache};   # B5/A5: invalidate .stat cache on ban
}

sub _cmd_unban {
    my ($self, $stream, $id, $chan, $target) = @_;

    my $bot  = $self->{bot};
    my $nick = $self->{users}{$id}{login} // 'unknown';

    unless ($bot->{channel_ban} && $bot->{channel_ban}->can('mark_removed')) {
        $stream->write("ChannelBan module not available.\r\n");
        return;
    }

    unless (defined $chan && $chan =~ /^#/ && defined $target && $target ne '') {
        $stream->write("Usage: .unban #channel <mask|ban_id>\r\n");
        return;
    }

    my $dbh = $bot->{dbh};
    # mb412-R1: id canal via le helper central (cache d'abord, mb411).
    my $id_channel = Mediabot::Helpers::channel_id_cached($bot, $chan);
    unless ($id_channel) {
        $stream->write("Channel $chan not found in DB.\r\n");
        return;
    }
    my $level = $self->{users}{$id}{level};

    # Resolve ban: by numeric id or by mask
    my ($rows, $err, $mask_used);
    if ($target =~ /^\d+$/) {
        ($rows, $err) = $bot->{channel_ban}->mark_removed(
            id_channel_ban => $target,
            removed_by_nick => $nick,
        );
        $mask_used = "ban #$target";
    } else {
        ($rows, $err) = $bot->{channel_ban}->mark_removed(
            id_channel => $id_channel,
            mask       => $target,
            removed_by_nick => $nick,
        );
        $mask_used = $target;
    }

    if ($err) {
        $stream->write("Unban failed: $err\r\n");
        return;
    }

    if (!$rows) {
        $stream->write("No active ban found matching '$target' on $chan.\r\n");
        return;
    }

    # Send MODE -b to IRC
    eval {
        $bot->{irc}->send_message('MODE', undef, $chan, '-b', $target)
            if $target !~ /^\d+$/;
    };

    $bot->{logger}->log(2, "Partyline: $nick unbanned '$mask_used' on $chan");
    $stream->write("Unbanned '$mask_used' on $chan.\r\n");
    delete $self->{_stat_cache};   # invalidate .stat cache
}

sub _cmd_topic {
    my ($self, $stream, $id, $chan, $topic) = @_;

    my $bot  = $self->{bot};
    my $nick = $self->{users}{$id}{login} // 'unknown';

    unless ($bot->{irc} && $bot->{irc}->is_connected) {
        $stream->write("Bot is not connected to IRC.\r\n");
        return;
    }

    unless (defined $chan && $chan =~ /^#/) {
        $stream->write("Usage: .topic #channel [new topic]\r\n");
        return;
    }

    if (defined $topic && $topic ne '') {
        # Set new topic
        $bot->{irc}->send_message('TOPIC', undef, $chan, $topic);
        $bot->{logger}->log(2, "Partyline: $nick set topic on $chan: $topic");
        $stream->write("Topic set on $chan.\r\n");
    } else {
        # Request current topic via TOPIC (server will reply with 332)
        $bot->{irc}->send_message('TOPIC', undef, $chan);
        $stream->write("Topic request sent for $chan (check .console for server reply).\r\n");
    }
}

sub _cmd_kick {
    my ($self, $stream, $id, $args) = @_;
    unless (defined $args && $args =~ /^(\S+)\s+(#\S+)(?:\s+(.*))?$/) {
        $stream->write("Usage: .kick <nick> <#channel> [reason]\r\n"); return;
    }
    my ($target, $chan, $reason) = ($1, $2, $3 // 'Kicked by operator');
    my $bot = $self->{bot};
    eval { $bot->{irc}->send_message('KICK', undef, $chan, $target, $reason) };
    if ($@) {
        my $err = $@;
        $self->_report_operation_error(
            $stream,
            'Partyline .kick failed',
            'Kick failed.',
            $err,
        );
    }
    else {
        $stream->write("Kicked $target from $chan ($reason)\r\n");
    }
}

sub _cmd_unmute {
    # CC3: manually lift a temp mute set by AF7
    my ($self, $stream, $id, $args) = @_;
    unless (defined $args && $args =~ /^(\S+)/) {
        $stream->write("Usage: .unmute <nick>\r\n"); return;
    }
    my $target = lc($1);
    my $bot = $self->{bot};
    if (exists $bot->{_nick_mute}{$target}) {
        delete $bot->{_nick_mute}{$target};
        $stream->write("AF7 mute lifted for $target.\r\n");
    } else {
        $stream->write("$target is not muted.\r\n");
    }
}


# =============================================================================
# MB678-IV-M: anti-flood and cooldown operator commands
# =============================================================================

sub _cmd_floodset {
    my ($self, $stream, $id, $args) = @_;
    my $bot = $self->{bot};
    unless (defined $args && $args =~ /^(#\S+)(?:\s+(\d+)(?:\s+(\d+)(?:\s+(\d+))?)?)?/) {
        $stream->write("Usage: .floodset <#chan> [window] [max_cmds] [silence_secs]\r\n");
        $stream->write("  Defaults: window=10 max=8 silence=30\r\n");
        $stream->write("  Example: .floodset #quebec 10 4 60\r\n");
        return;
    }
    my ($chan, $window, $max, $silence) = ($1, $2, $3, $4);
    # Store overrides in memory — used by checkChanFlood via _chan_flood_conf
    # A-68-1: clamp override values to sane minimums (matches checkChanFlood)
    my $safe_window  = defined $window  ? (int($window)  >= 1 ? int($window)  : 1) : undef;
    my $safe_max     = defined $max     ? (int($max)     >= 1 ? int($max)     : 1) : undef;
    my $safe_silence = defined $silence ? (int($silence) >= 1 ? int($silence) : 1) : undef;
    if ((defined $window && int($window) < 1) || (defined $max && int($max) < 1)) {
        $stream->write("Warning: values below 1 clamped to 1.\r\n");
    }
    # FF6: optional warn-only mode — bot warns but does not silence
    my $warn_only = ($args && $args =~ /\bwarn.?only\b/i) ? 1 : 0;
    $bot->{_chan_flood_conf}{$chan} = {
        window    => $safe_window,
        max       => $safe_max,
        silence   => $safe_silence,
        warn_only => $warn_only,
    };
    # Also reset current flood state for this channel
    delete $bot->{_chan_flood}{$chan};
    my $conf = $bot->{_chan_flood_conf}{$chan};
    my $w = $conf->{window}  // '(default)';
    my $m = $conf->{max}     // '(default)';
    my $s = $conf->{silence} // '(default)';
    my $wo = $bot->{_chan_flood_conf}{$chan}{warn_only} ? ' warn-only' : '';
    $stream->write("CC2: floodset $chan — window=$w max=$m silence=$s${wo}\r\n");
    $stream->write("Current flood state reset.\r\n");
}

sub _cmd_cmdcooldown {
    # CC2: set per-command cooldown for a channel: .cmdcooldown #chan <cmd> <secs>
    my ($self, $stream, $id, $args) = @_;
    my $bot = $self->{bot};
    # V15: no args → list active cooldowns
    unless (defined $args && $args =~ /\S/) {
        my $conf = $bot->{_cmd_cooldown_conf} // {};
        unless (%$conf) {
            $stream->write("No cooldowns configured.\r\n"); return;
        }
        $stream->write("Active cooldowns:\r\n");
        for my $ch (sort keys %$conf) {
            for my $cmd (sort keys %{ $conf->{$ch} }) {
                my $secs = $conf->{$ch}{$cmd};
                # HH9: human-readable cooldown duration
                my $cd_str = $secs >= 60
                    ? sprintf("%dm%02ds", int($secs/60), $secs%60)
                    : "${secs}s";
                $stream->write(sprintf("  %-20s %-12s %s\r\n", $ch, "!$cmd", $cd_str));
            }
        }
        return;
    }
    unless ($args =~ /^(#\S+)\s+(\w+)\s+(\d+)$/) {
        $stream->write("Usage: .cmdcooldown <#chan> <cmd> <seconds>\r\n");
        $stream->write("  Example: .cmdcooldown #boulets ai 20\r\n");
        return;
    }
    my ($chan, $cmd, $secs) = ($1, lc($2), int($3));
    $secs = 0 if $secs < 0; $secs = 3600 if $secs > 3600;  # A-68-2: clamp range
    $bot->{_cmd_cooldown_conf}{$chan}{$cmd} = $secs;
    # Reset any active cooldown for this cmd+chan
    delete $bot->{_cmd_cooldown}{"$cmd:" . lc($chan)};
    # HH16: human-readable confirmation
    my $secs_h = $secs >= 60 ? sprintf("%dm%02ds", int($secs/60), $secs%60) : "${secs}s";
    my $action_str = $secs == 0 ? "removed" : "set to $secs_h";
    $stream->write("Cooldown for !$cmd on $chan $action_str.\r\n");
}

sub _cmd_netsplit {
    # NS: show current netsplit state
    my ($self, $stream, $id, $args) = @_;
    my $bot = $self->{bot};
    my $now = time();
    my $count = $bot->{_netsplit_quit_count} // 0;
    $stream->write("--- Netsplit state ---\r\n");
    # BB5: show time since last netsplit event if available
    my $ns_ts = $bot->{_netsplit_last_ts} // 0;
    my $ns_age_str = '';
    if ($ns_ts > 0) {
        my $ns_diff = time() - $ns_ts;
        $ns_age_str = $ns_diff >= 3600
            ? sprintf(' (last: %dh%02dm ago)', int($ns_diff/3600), int(($ns_diff%3600)/60))
            : sprintf(' (last: %dm%02ds ago)', int($ns_diff/60), $ns_diff%60);
    }
    $stream->write("  Netsplit QUITs since last reconnect: $count$ns_age_str\r\n");
    # Show antiflood state that was reset
    my $af_chans = scalar keys %{ $bot->{_af} // {} };
    my $cf_chans = scalar keys %{ $bot->{_chan_flood} // {} };
    $stream->write("  AF1 channels in state: $af_chans\r\n");
    $stream->write("  AF4 channels in state: $cf_chans\r\n");
    # Channel nicklist freshness
    $stream->write("\r\n--- Channel nicklist status ---\r\n");
    for my $chan (sort keys %{ $bot->{channels} // {} }) {
        my @nicks = eval { $bot->gethChannelsNicksOnChan($chan) };
        $stream->write(sprintf("  %-22s %d nicks\r\n", $chan, scalar @nicks));
    }
}

sub _cmd_floodstatus {
    my ($self, $stream, $id, $args) = @_;
    my $bot = $self->{bot};
    my $now = time();

    # AF1: checkAntiFlood in-memory state
    # V8: show global AF state first
    my $gaf = $bot->{_global_af} // {};
    my $gaf_hits = scalar @{ $gaf->{hits} // [] };
    my $gaf_sil  = ($gaf->{silenced_until} // 0) > time()
        ? sprintf(" SILENCED %ds", $gaf->{silenced_until} - time()) : '';
    $stream->write("--- Global AF (IMP7/IMP16) ---\r\n");
    $stream->write(sprintf("  hits in window: %d%s\r\n", $gaf_hits, $gaf_sil));
    $stream->write("--- Channel antiflood (AF1 — output guard) ---\r\n");
    my $af = $bot->{_af} // {};
    if (%$af) {
        for my $chan (sort keys %$af) {
            my $st = $af->{$chan};
            my $sil = $st->{silenced_until} // 0;
            my $status = ($sil && $now < $sil)
                ? sprintf('SILENCED (%ds remaining)', $sil - $now)
                : sprintf('%d msgs in window', $st->{nbmsg} // 0);
            $stream->write(sprintf("  %-22s %s\r\n", $chan, $status));
        }
    } else {
        $stream->write("  (no active output flood state)\r\n");
    }

    # AF4: checkChanFlood in-memory state
    $stream->write("--- Channel flood (AF4 — input guard) ---\r\n");
    my $cf = $bot->{_chan_flood} // {};
    if (%$cf) {
        for my $chan (sort keys %$cf) {
            my $st = $cf->{$chan};
            my $sil = $st->{silenced_until} // 0;
            my $cnt = scalar @{ $st->{hits} // [] };
            my $status = ($sil && $now < $sil)
                ? sprintf('SILENCED (%ds remaining)', $sil - $now)
                : sprintf('%d cmds in window', $cnt);
            $stream->write(sprintf("  %-22s %s\r\n", $chan, $status));
        }
    } else {
        $stream->write("  (no active input flood state)\r\n");
    }

    # CC3: temp-muted nicks
    $stream->write("--- Temp mutes (CC3/AF7) ---\r\n");
    my $mutes = $bot->{_nick_mute} // {};
    my @active_mutes = sort grep { ($mutes->{$_} // 0) > $now } keys %$mutes;
    if (@active_mutes) {
        for my $nick (@active_mutes) {
            $stream->write(sprintf("  %-20s muted (%ds remaining)\r\n",
                $nick, $mutes->{$nick} - $now));
        }
    } else {
        $stream->write("  (no active mutes)\r\n");
    }

    # AF3: per-nick flood state
    $stream->write("--- Per-nick flood (AF3) ---\r\n");
    my $nf = $bot->{_nick_flood} // {};
    my @throttled = sort grep {
        scalar @{ $nf->{$_}{hits} // [] } >= 3
    } keys %$nf;
    if (@throttled) {
        for my $nick (@throttled) {
            my $cnt = scalar @{ $nf->{$nick}{hits} // [] };
            $stream->write(sprintf("  %-20s %d cmds in window\r\n", $nick, $cnt));
        }
    } else {
        $stream->write("  (no active nick flood state)\r\n");
    }
}

sub _cmd_flushcooldown {
    my ($self, $stream, $id, $args) = @_;
    my $bot = $self->{bot};
    # Z6: support targeted nick+chan clear: .flushcooldown <nick> <#chan>
    if (defined $args && $args =~ /^(\S+)\s+(#\S+)$/) {
        my ($target, $chan) = (lc($1), $2);
        my $cd_key = "$target:" . lc($chan);  # matches U6 format
        if (exists $bot->{_karma_cooldown}{$chan}{$cd_key}) {
            delete $bot->{_karma_cooldown}{$chan}{$cd_key};
            $stream->write("Karma cooldown cleared for $target on $chan.\r\n");
        } else {
            $stream->write("No active cooldown for $target on $chan.\r\n");
        }
    } elsif (defined $args && $args =~ /^(#\S+)$/) {
        delete $bot->{_karma_cooldown}{$1};
        $stream->write("Karma cooldown cleared for $1.\r\n");
    } else {
        $bot->{_karma_cooldown} = {};
        $stream->write("All karma cooldowns cleared.\r\n");
    }
}


# =============================================================================
# MB678-IV-N: remaining standard/operator Partyline commands
# =============================================================================

sub _cmd_history {
    my ($self, $stream, $id) = @_;

    my $hist = $self->{users}{$id}{history} // [];
    unless (@$hist) {
        $stream->write("No command history for this session.\r\n");
        return;
    }

    $stream->write("Recent commands:\r\n");
    my $i = 1;
    for my $cmd (@$hist) {
        $stream->write(sprintf("  %2d  %s\r\n", $i++, $cmd));
    }
}

sub _cmd_say {
    my ($self, $stream, $id, $target, $msg) = @_;

    my $bot  = $self->{bot};
    my $nick = $self->{users}{$id}{login};

    unless ($bot->{irc} && $bot->{irc}->is_connected) {
        $stream->write("Bot is not connected to IRC.\r\n");
        return;
    }

    if ($target =~ /^#/) {
        # Channel message — verify bot presence (warn only, still send)
        my $target_lc = lc($target);
        unless (exists $bot->{channels}{lc $target} || exists $bot->{channels}{lc $target_lc}) {
            $stream->write("Warning: bot does not appear to be in $target (sending anyway).\r\n");
        }
    }
    # No check needed for private messages — just send

    $bot->botPrivmsg($target, $msg);
    $bot->{logger}->log(2, "Partyline: $nick sent to $target: $msg");
    $stream->write("-> $target: $msg\r\n");
}

sub _cmd_who {
    my ($self, $stream, $id, $chan) = @_;

    my $bot = $self->{bot};

    my @nicks = $bot->gethChannelsNicksOnChan($chan);
    unless (@nicks) {
        $stream->write("No nicks known for $chan (not joined or channel is empty).\r\n");
        return;
    }

    $stream->write(scalar(@nicks) . " nick(s) in $chan:\r\n");
    $stream->write(join(', ', sort @nicks) . "\r\n");
}

sub _cmd_chanlog {
    my ($self, $stream, $id, $args) = @_;
    unless (defined $args && $args =~ /^(#\S+)(?:\s+(\d+))?/) {
        $stream->write("Usage: .logs <#channel> [n]  (default n=10, max 50)\r\n"); return;
    }
    my ($chan, $n) = ($1, int($2 // 10));
    $n = 10 if $n < 1; $n = 50 if $n > 50;
    my $bot = $self->{bot};
    my $dbh = eval { $bot->{db}->ensure_connected } // $bot->{dbh};
    return unless $dbh;
    # mb349-B1: .logs affiche un log de CONVERSATION ([ts] <nick> texte), donc on
    # ne montre que les vrais messages (event_type IN ('public','action')) et plus
    # publictext IS NOT NULL, qui faisait apparaître join/part/kick/mode/topic
    # comme si le nick les avait "dits" (ex. <bob> +o alice).
    my $sth = $dbh->prepare(q{
        SELECT cl.ts, cl.nick, cl.publictext AS text FROM CHANNEL_LOG cl
        JOIN CHANNEL c ON c.id_channel = cl.id_channel
        WHERE c.name = ? AND cl.event_type IN ('public','action')
        ORDER BY cl.id_channel_log DESC LIMIT ?
    });
    unless ($sth && $sth->execute($chan, $n)) {
        $stream->write("DB error.\r\n"); $sth->finish if $sth; return;
    }
    my @rows;
    while (my $r = $sth->fetchrow_hashref) { unshift @rows, $r; }
    $sth->finish;
    unless (@rows) { $stream->write("No logs found for $chan.\r\n"); return; }
    $stream->write("Last " . scalar(@rows) . " lines on $chan:\r\n");
    for my $r (@rows) {
        # X9: show full date if entry is not from today
        my $raw_ts = $r->{ts} // '';
        my $ts;
        if ($raw_ts =~ /^(\d{4}-\d{2}-\d{2})\s+(\d{2}:\d{2})/) {
            my ($date, $hhmm) = ($1, $2);
            my $today = do { my @t=localtime(time); sprintf('%04d-%02d-%02d',$t[5]+1900,$t[4]+1,$t[3]); };
            $ts = $date eq $today ? $hhmm : "$date $hhmm";
        } else {
            $ts = substr($raw_ts, 11, 5);
        }
        $stream->write(sprintf("[%s] <%s> %s\r\n", $ts, $r->{nick}, $r->{text}));
    }
}

sub _cmd_nickinfo {
    my ($self, $stream, $id, $args) = @_;
    unless (defined $args && $args =~ /^(\S+)$/) {
        $stream->write("Usage: .nickinfo <nick>\r\n"); return;
    }
    my $target = lc($1);
    my $bot = $self->{bot};
    my $dbh = eval { $bot->{db}->ensure_connected } // $bot->{dbh};
    return unless $dbh;
    # mb109-B1: USER a 'nickname' pas 'nick', pas de email/USER_LOG/USER_HOST
    my $sth = $dbh->prepare(q{
        SELECT u.nickname, u.id_user, u.username, u.info1, u.info2,
               u.birthday, u.last_login,
               ul.description AS level
        FROM USER u
        JOIN USER_LEVEL ul ON ul.id_user_level = u.id_user_level
        WHERE LOWER(u.nickname) = ?
    });
    unless ($sth && $sth->execute($target)) {
        $stream->write("DB error.\r\n"); $sth->finish if $sth; return;
    }
    my $r = $sth->fetchrow_hashref; $sth->finish;
    unless ($r) {
        $stream->write("$target: not found in DB.\r\n"); return;
    }
    $stream->write("Nick     : $r->{nickname}\r\n");
    $stream->write("ID       : $r->{id_user}\r\n");
    $stream->write("Level    : " . ($r->{level}    // 'N/A') . "\r\n");
    $stream->write("Username : " . ($r->{username} // 'N/A') . "\r\n");
    $stream->write("Info1    : " . ($r->{info1}    // 'N/A') . "\r\n") if $r->{info1};
    $stream->write("Info2    : " . ($r->{info2}    // 'N/A') . "\r\n") if $r->{info2};
    $stream->write("Birthday : " . ($r->{birthday} // 'N/A') . "\r\n") if $r->{birthday};
    # Y1: compute age of last login
    my $ll = $r->{last_login} // '';
    if ($ll =~ /^(\d{4})-(\d{2})-(\d{2})/) {
        require Time::Local;
        my ($y,$mo,$d) = ($1,$2,$3);
        my $ep = eval { Time::Local::timelocal(0,0,12,$d,$mo-1,$y-1900) };
        if ($ep) {
            my $diff = int((time()-$ep)/86400);
            $ll .= $diff > 0 ? " (${diff}d ago)" : " (today)";
        }
    }
    $stream->write("Last login: " . ($ll || 'never') . "\r\n");
}

sub _cmd_who_chan {
    my ($self, $stream, $id, $args) = @_;
    my $bot  = $self->{bot};
    my $chan  = (defined $args && $args =~ /^(#\S+)/) ? $1 : undef;
    unless ($chan) { $stream->write("Usage: .who <#channel>\r\n"); return; }
    my @nicks = eval { $bot->gethChannelsNicksOnChan($chan) };
    unless (@nicks) {
        $stream->write("No nicks found on $chan (not joined or empty).\r\n"); return;
    }
    $stream->write(scalar(@nicks) . " nick(s) on $chan:\r\n");
    # Try to show level for each nick
    my $dbh = eval { $bot->{db}->ensure_connected } // $bot->{dbh};
    my %levels;
    if ($dbh) {
        eval {
            # mb109-B1: USER a 'nickname' pas 'nick'
            my $sth = $dbh->prepare(q{
                SELECT u.nickname, ul.description AS level FROM USER u
                JOIN USER_CHANNEL uc ON uc.id_user = u.id_user
                JOIN CHANNEL c ON c.id_channel = uc.id_channel
                JOIN USER_LEVEL ul ON ul.id_user_level = u.id_user_level
                WHERE c.name = ?
            });
            if ($sth && $sth->execute($chan)) {
                while (my $r = $sth->fetchrow_hashref) {
                    $levels{lc $r->{nickname}} = $r->{level};
                }
                $sth->finish;
            }
        };
    }
    # FF3: fetch IRC modes (op/voice) from the IRC channel object
    my %irc_flag;
    eval {
        my $irc = $bot->{irc};
        if ($irc && $irc->is_connected) {
            my $irc_chan = $irc->channel($chan);
            if ($irc_chan) {
                for my $n ($irc_chan->nicks) {
                    my $mode = $irc_chan->mode_for_nick($n) // '';
                    $irc_flag{lc($n->nick)} = $mode =~ /o/ ? '@'
                                           : $mode =~ /v/ ? '+'
                                           : '';
                }
            }
        }
    };
    my @lines;
    # Y6: sort by level desc (highest first), then alphabetically
    my @sorted_nicks = sort {
        ($levels{lc $b} // 0) <=> ($levels{lc $a} // 0)
        || lc($a) cmp lc($b)
    } @nicks;
    for my $nick (@sorted_nicks) {
        my $flag = $irc_flag{lc $nick} // '';
        my $lvl  = $levels{lc $nick}   ? " [" . $levels{lc $nick} . "]" : '';
        push @lines, "$flag$nick$lvl";
    }
    # Output in chunks of 8
    while (my @chunk = splice @lines, 0, 8) {
        $stream->write('  ' . join('  ', @chunk) . "\r\n");
    }
}

sub _cmd_kv {
    # FF8: in-memory key-value store — .kv set <key> <val>  .kv get <key>  .kv del <key>  .kv list
    my ($self, $stream, $id, $args) = @_;
    my $bot = $self->{bot};
    unless (defined $args && $args =~ /^(\w+)(?:\s+(\S+)(?:\s+(.*))?)?/) {
        $stream->write("Usage: .kv set <key> <value>  |  .kv get <key>  |  .kv del <key>  |  .kv list\r\n");
        return;
    }
    my ($op, $key, $val) = (lc($1), $2, $3);
    my $store = $bot->{_kv} //= {};
    if ($op eq 'set') {
        unless (defined $key && defined $val) {
            $stream->write("Usage: .kv set <key> <value>\r\n"); return;
        }
        $store->{$key} = $val;
        $stream->write("kv: $key = $val\r\n");
    } elsif ($op eq 'get') {
        unless (defined $key) {
            $stream->write("Usage: .kv get <key>\r\n"); return;
        }
        if (exists $store->{$key}) {
            $stream->write("kv: $key = $store->{$key}\r\n");
        } else {
            $stream->write("kv: key '$key' not found.\r\n");
        }
    } elsif ($op eq 'del') {
        unless (defined $key) {
            $stream->write("Usage: .kv del <key>\r\n"); return;
        }
        if (delete $store->{$key}) {
            $stream->write("kv: '$key' deleted.\r\n");
        } else {
            $stream->write("kv: key '$key' not found.\r\n");
        }
    } elsif ($op eq 'list') {
        unless (%$store) {
            $stream->write("kv: store is empty.\r\n"); return;
        }
        $stream->write("kv store (" . scalar(keys %$store) . " entries):\r\n");
        for my $k (sort keys %$store) {
            $stream->write("  $k = $store->{$k}\r\n");
        }
    } else {
        $stream->write("kv: unknown op '$op'. Use set/get/del/list.\r\n");
    }
}

sub _cmd_achievementprofile {
    my ($self, $stream, $id, $arg) = @_;
    $arg //= '';
    $arg =~ s/^\s+|\s+$//g;

    unless ($arg =~ /\A(\S+)\s+(#\S+)\z/) {
        $stream->write("Usage: .achievementprofile <nick> <#channel>\r\n");
        return 0;
    }
    my ($nick, $channel) = ($1, $2);

    my $ach = eval { $self->{bot}{achievements} };
    unless ($ach && eval { $ach->can('identity_profile_diagnostic') }) {
        $stream->write("Achievement diagnostics unavailable.\r\n");
        return 0;
    }

    my $diag = eval { $ach->identity_profile_diagnostic($nick, $channel) };
    if (!$diag || ref($diag) ne 'HASH') {
        $stream->write("Achievement diagnostic failed safely.\r\n");
        return 0;
    }

    my $status = $diag->{status} // 'unknown';
    my $backend = $diag->{storage_label} // $diag->{backend} // 'unknown';
    $stream->write("Achievement identity diagnostic (read-only)\r\n");
    $stream->write("  Query    : $nick on $channel\r\n");
    $stream->write("  Storage  : $backend\r\n");

    if ($status eq 'legacy_json') {
        $stream->write("  Identity : legacy nick+channel key (no durable alias graph)\r\n");
        $stream->write("  Unlocks  : " . ($diag->{unlock_count} // 0) . "\r\n");
        $stream->write("  Progress : " . ($diag->{progress_counters} // 0) . " counter(s)\r\n");
        return 1;
    }
    if ($status eq 'channel_not_found') {
        $stream->write("  Result   : channel not found in DB\r\n");
        return 1;
    }
    if ($status eq 'not_found') {
        $stream->write("  Result   : no durable achievement profile matches this nick on the channel\r\n");
        return 1;
    }
    if ($status eq 'ambiguous') {
        my $candidates = $diag->{candidates};
        $candidates = [] unless ref($candidates) eq 'ARRAY';
        $stream->write("  Result   : ambiguous nick; " . scalar(@$candidates) . " durable profiles match\r\n");
        for my $p (@$candidates) {
            next unless ref($p) eq 'HASH';
            $stream->write(sprintf(
                "    profile=%d display=%s aliases=%d unlocks=%d progress=%d\r\n",
                $p->{id_achievement_profile} // 0,
                $p->{display_nick} // '',
                $p->{alias_count} // 0,
                $p->{unlock_count} // 0,
                $p->{progress_counters} // 0,
            ));
        }
        if ($diag->{candidates_truncated}) {
            $stream->write("    ... additional candidate profiles omitted (display capped at 20)\r\n");
        }
        $stream->write("  Note     : nick-only diagnostics never choose between plausible profiles\r\n");
        return 1;
    }
    if ($status ne 'ok') {
        $stream->write("  Result   : diagnostic unavailable ($status)\r\n");
        return 0;
    }

    my $p = $diag->{profile};
    $p = {} unless ref($p) eq 'HASH';
    $stream->write("  Profile  : " . ($p->{id_achievement_profile} // '?') . "\r\n");
    $stream->write("  Display  : " . ($p->{display_nick} // '') . "\r\n");
    if (defined $p->{id_user}) {
        my $reg = defined($p->{registered_nick}) && length($p->{registered_nick})
            ? " ($p->{registered_nick})" : '';
        $stream->write("  USER     : " . $p->{id_user} . $reg
            . " [authoritative resolver anchor on this channel]\r\n");
    }
    else {
        $stream->write("  USER     : none attached\r\n");
    }
    $stream->write("  Unlocks  : " . ($p->{unlock_count} // 0) . "\r\n");
    $stream->write("  Progress : " . ($p->{progress_counters} // 0) . " counter(s)\r\n");
    $stream->write("  Aliases  : " . ($p->{alias_count} // 0) . " durable identity record(s)\r\n");

    my $aliases = $diag->{aliases};
    $aliases = [] unless ref($aliases) eq 'ARRAY';
    for my $alias (@$aliases) {
        next unless ref($alias) eq 'HASH';
        my $anick = $alias->{nick} // '';
        my $uh = $alias->{userhost} // '';
        my $identity = length($uh) ? "$anick!$uh" : "$anick [legacy alias]";
        my $last = defined($alias->{last_seen_at}) ? $alias->{last_seen_at} : '?';
        $stream->write("    $identity  last_seen=$last\r\n");
    }
    if ($diag->{aliases_truncated}) {
        $stream->write("    ... additional aliases omitted (display capped at 20)\r\n");
    }

    $stream->write("  Evidence : nick maps to one stored profile on this channel");
    $stream->write("; registered USER id is authoritative") if defined $p->{id_user};
    $stream->write("\r\n");
    $stream->write("  Note     : mb646 does not persist historical merge reasons; this shows current durable evidence only.\r\n");
    return 1;
}


1;

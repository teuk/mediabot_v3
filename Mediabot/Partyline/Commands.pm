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
use Mediabot::Helpers ();

our @EXPORT_OK = qw(
    _cmd_scriptdryrun
    _plugin_info_text
    _plugin_config_display_value
    _cmd_plugins
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

1;

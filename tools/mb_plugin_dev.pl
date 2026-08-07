#!/usr/bin/env perl
# =============================================================================
# mb_plugin_dev.pl — validate and run a plugin v2 sidecar script OFFLINE.
#
# The companion the v2 contract was missing: an author can check a sidecar
# and watch a script run WITHOUT starting the bot. Mediabot actions are
# dry-planned only: no IRC send and no plugin-data write is applied by the bot.
# IMPORTANT: `run` really executes the script process and is NOT a sandbox;
# trusted script code still has the OS permissions of the account running it.
#
#   tools/mb_plugin_dev.pl validate examples-v2/karma.py
#   tools/mb_plugin_dev.pl run examples-v2/karma.py --command karma \
#         --nick aur --channel '#quebec' --arg SlaY
#   tools/mb_plugin_dev.pl run examples-v2/daily.tcl --event plugin_cron_observed \
#         --config CHANNEL='#quebec' --config TEXT='Good morning!' \
#         --data hour=9 --data minute=0
#
# DESIGN RULE: this tool reuses the real Mediabot::PluginManager, ScriptRunner
# and ScriptActionRunner behind a minimal offline bot. Validation limits and
# refusal rules therefore come from production code. The small event-fixture
# shape map is explicit and fail-closed against PluginManager's routable-event
# allow-list so a future event cannot silently receive a guessed envelope.
#
# Mediabot actions are not applied: they are PLANNED (apply => 0), so a store
# action is reported and its document displayed, never written by Mediabot.
# The script itself is a real subprocess and may have its own side effects.
# =============================================================================

use strict;
use warnings;
no warnings 'once';  # fully-qualified contract globals are intentionally read once
use FindBin qw($Bin);
use lib "$Bin/..";
use File::Spec;
use Getopt::Long qw(GetOptionsFromArray);
use JSON::PP ();

require Mediabot::CommandRegistry;
require Mediabot::EventBus;
require Mediabot::ScriptRunner;
require Mediabot::ScriptActionRunner;
require Mediabot::PluginManager;

# --- the offline bot: just enough surface for the real modules ------------
{
    package MbDevLogger;
    sub new { bless { verbose => $_[1] ? 1 : 0 }, $_[0] }
    sub log {
        my ($self, $level, $text) = @_;
        print "  [log $level] $text\n" if $self->{verbose};
        return 1;
    }
}
{
    package MbDevConf;
    # Answers exactly like Mediabot::Conf for the keys the plugin layer
    # reads, so the real sidecar/override merge runs unchanged.
    sub new { bless { kv => $_[1] || {} }, $_[0] }
    sub get { return $_[0]{kv}{ $_[1] } }
    sub set { $_[0]{kv}{ $_[1] } = $_[2]; return 1 }
    sub get_int { my ($s,$k,%o)=@_; my $v = $s->{kv}{$k};
                  return defined $v && $v =~ /\A-?\d+\z/ ? $v : $o{default} }
}
{
    package MbDevBot;
    sub new {
        my ($class, %args) = @_;
        my $self = bless {
            registry => Mediabot::CommandRegistry->new,
            bus      => Mediabot::EventBus->new,
            conf     => MbDevConf->new($args{conf} || {}),
            logger   => MbDevLogger->new($args{verbose}),
        }, $class;
        $self->{runner} = Mediabot::ScriptRunner->new(
            bot => $self, script_dir => $args{script_dir});
        $self->{ar} = Mediabot::ScriptActionRunner->new(bot => $self);
        return $self;
    }
    sub registry             { $_[0]{registry} }
    sub events               { $_[0]{bus} }
    sub script_runner        { $_[0]{runner} }
    sub script_action_runner { $_[0]{ar} }
}

# --- helpers --------------------------------------------------------------

sub usage {
    my $code = shift // 0;
    print <<"USAGE";
Usage:
  $0 validate <script> [options]
  $0 run <script> [options]

  <script> is relative to the script directory (default: plugins/scripts).

Options:
  --script-dir DIR     where scripts live (default: plugins/scripts)
  --command NAME       run a declared command (default: the first one);
                       with --event public_command_observed, set observed command
  --event NAME         run a declared event instead of a command
  --nick NICK          caller nick (default: tester)
  --channel CHAN       channel (default: #dev)
  --arg VALUE          command argument, repeatable
  --config KEY=VALUE   operator override, repeatable (as plugins.<name>.KEY)
  --storage FILE       JSON file used as the plugin's current data.storage
  --show-envelope      print the envelope handed to the script
  --verbose            show the bot's own log lines
  --help               this text

Dry-run means Mediabot does not APPLY returned actions. `run` still executes
the script as a real, unsandboxed subprocess. Run only code you trust.

Exit code is 0 when sidecar/script/action validation passed, 1 otherwise.
USAGE
    exit $code;
}

sub fail {
    my ($msg) = @_;
    print "FAIL  $msg\n";
    exit 1;
}

sub _pretty { return JSON::PP->new->canonical->pretty->encode($_[0]) }

# --- argument parsing -----------------------------------------------------

my @argv = @ARGV;
my $action = shift @argv;
usage(0) if !defined $action || $action =~ /\A(?:-h|--help|help)\z/;
usage(1) unless $action eq 'validate' || $action eq 'run';

my $script = shift @argv;
usage(1) unless defined $script && length $script && $script !~ /\A-/;

my %opt = (nick => 'tester', channel => '#dev');
my (@args, @configs);
GetOptionsFromArray(\@argv,
    'script-dir=s'   => \$opt{script_dir},
    'command=s'      => \$opt{command},
    'event=s'        => \$opt{event},
    'nick=s'         => \$opt{nick},
    'channel=s'      => \$opt{channel},
    'arg=s'          => \@args,
    'config=s'       => \@configs,
    'data=s'         => \my @data_pairs,
    'storage=s'      => \$opt{storage},
    'show-envelope'  => \$opt{show_envelope},
    'verbose'        => \$opt{verbose},
    'help'           => sub { usage(0) },
) or usage(1);

my $script_dir = $opt{script_dir}
    || File::Spec->catdir($Bin, '..', 'plugins', 'scripts');
fail("script directory not found: $script_dir") unless -d $script_dir;

# Mount once with an empty offline conf so the REAL PluginManager performs
# path normalization, sidecar bounds/JSON validation, identity checks, command
# collisions and event allow-list checks before this tool learns anything from
# the manifest. Do not pre-open the sidecar here: that would bypass the very
# boundary this tool exists to mirror.
my $bot = MbDevBot->new(script_dir => $script_dir, conf => {},
                        verbose => $opt{verbose});
my $pm  = Mediabot::PluginManager->new(bot => $bot);

my $entry = eval { $pm->load_script_v2($script) };
if (my $err = $@) {
    $err =~ s/\s+\z//;
    $err =~ s/\APluginManager:\s*//;
    fail($err);
}

# Operator overrides are keyed by the validated registration name. Apply them
# only AFTER PluginManager has accepted the sidecar, then ask PluginManager to
# perform a real replace load so config merging follows the production path.
if (@configs) {
    my $plugin_name = $entry->{name};
    for my $pair (@configs) {
        my ($k, $v) = split /=/, $pair, 2;
        fail("--config expects KEY=VALUE, got '$pair'")
            unless defined $k && length $k && defined $v;
        $bot->{conf}->set("plugins.$plugin_name.$k", $v);
    }

    $entry = eval { $pm->load_script_v2($script, replace => 1) };
    if (my $err = $@) {
        $err =~ s/\s+\z//;
        $err =~ s/\APluginManager:\s*//;
        fail($err);
    }
}

my $manifest = $entry->{manifest} || {};
my @commands = sort keys %{ $manifest->{commands} || {} };
my @events   = @{ $manifest->{events} || [] };

print "OK    sidecar accepted: $entry->{name} v" .
      ($manifest->{version} // '?') . " (api $manifest->{api})\n";
print "      script:   $script\n";
print "      commands: " . (@commands ? join(', ', @commands) : '(none)') . "\n";
print "      events:   " . (@events ? join(', ', @events) : '(none)') . "\n";
if (ref($entry->{plugin_config}) eq 'HASH' && %{ $entry->{plugin_config} }) {
    print "      config:   $_=$entry->{plugin_config}{$_}\n"
        for sort keys %{ $entry->{plugin_config} };
}
exit 0 if $action eq 'validate';

# --- run ------------------------------------------------------------------

my $event = $opt{event};
my $command = $opt{command};
if (defined $event) {
    fail("event '$event' is not declared by this sidecar")
        unless grep { $_ eq $event } @events;
}
else {
    $command //= $commands[0];
    fail('this plugin declares no command; use --event') unless defined $command;
    fail("command '$command' is not declared by this sidecar")
        unless grep { $_ eq $command } @commands;
}

my %data = (
    channel => $opt{channel},
    target  => $opt{channel},
    nick    => $opt{nick},
);
if (defined $event) {
    # These are EVENT-FIXTURE defaults, not validation rules. Validation and
    # routability still come from PluginManager. Fail closed if its allow-list
    # ever grows without this tool learning the corresponding core event shape.
    my %event_type_for = (
        channel_join_observed  => 'join',
        channel_part_observed  => 'part',
        channel_topic_observed => 'topic',
        channel_kick_observed  => 'kick',
        channel_nick_observed  => 'nick',
        channel_quit_observed  => 'quit',
        plugin_cron_observed   => 'cron',
    );
    my %known_fixture = (%event_type_for, public_command_observed => 1);
    my @missing_fixture = grep { !$known_fixture{$_} }
        keys %Mediabot::PluginManager::ROUTABLE_SCRIPT_EVENTS;
    fail('offline event fixture mapping is stale for: '
        . join(', ', sort @missing_fixture)) if @missing_fixture;

    $data{event_type} = $event_type_for{$event}
        if exists $event_type_for{$event};

    # nick/quit/cron are network-wide in the core and therefore have no channel
    # target in the observed context.
    if ($event =~ /\A(?:plugin_cron|channel_quit|channel_nick)_observed\z/) {
        delete $data{$_} for qw(channel target);
    }

    # public_command_observed carries a Mediabot::Context in production; the
    # PluginManager bridge extracts command + args from it and no event_type.
    if ($event eq 'public_command_observed') {
        $data{command} = defined($opt{command}) ? $opt{command} : 'test';
        $data{args}    = \@args;
    }
}
else {
    $data{command} = $command;
    $data{args}    = \@args;
}
for my $pair (@data_pairs) {
    my ($k, $v) = split /=/, $pair, 2;
    fail("--data expects KEY=VALUE, got '$pair'")
        unless defined $k && length $k && defined $v;
    $data{$k} = $v;
}
if (ref($entry->{plugin_config}) eq 'HASH' && %{ $entry->{plugin_config} }) {
    $data{config} = $entry->{plugin_config};
}
if (defined $opt{storage}) {
    fail("storage fixture not found: $opt{storage}")
        unless -f $opt{storage} && !-l $opt{storage};
    my $storage_size = -s $opt{storage};
    my $storage_limit = $Mediabot::ScriptActionRunner::MAX_STORE_BYTES;
    fail("storage fixture exceeds current bot limit ($storage_limit bytes)")
        unless defined($storage_size) && $storage_size <= $storage_limit;
    my $raw = do { open my $fh, '<:raw', $opt{storage}
                       or fail("cannot read storage fixture: $!");
                   local $/; <$fh> };
    my $obj = eval { JSON::PP->new->decode($raw) };
    fail('storage fixture is not valid JSON') if $@;
    my ($storage_ok, $storage_err) =
        Mediabot::ScriptActionRunner::validate_storage_object($obj);
    fail("storage fixture rejected: $storage_err") unless $storage_ok;
    $data{storage} = $obj;
}

if (!defined($event) && ref($manifest->{commands}{$command}) eq 'HASH') {
    my $level = $manifest->{commands}{$command}{level};
    if (defined($level) && "$level" ne '0') {
        print "NOTE  command '$command' requires level $level; offline run does "
            . "not emulate USER_LEVEL authentication.\n";
    }
}

if ($opt{show_envelope}) {
    my $payload = $bot->script_runner->build_event_payload(
        (defined $event ? $event : 'public_command'), %data);
    print "\nEnvelope handed to the script:\n" . _pretty($payload);
}

my $result = eval {
    $bot->script_runner->run_script($script,
        (defined $event ? $event : 'public_command'), %data);
};
fail("the script could not be run: $@") if $@;

my $lang = $result->{lang} // '?';
my $secs = $result->{duration_s};
printf "\nRan %s (%s%s)\n", $script, $lang,
    (defined $secs ? sprintf(', %.3fs', $secs) : '');
if (defined $result->{stderr} && length $result->{stderr}) {
    my $err = $result->{stderr}; $err =~ s/\s+\z//;
    print "      stderr:  $_\n" for split /\n/, $err;
}

my $response = ref($result->{response}) eq 'HASH' ? $result->{response} : {};
unless ($result->{ok} && $response->{ok}) {
    print "FAIL  the script did not return a valid successful response\n";
    print "      error: $_\n"
        for grep { defined && !ref } @{ $response->{errors} || [] };
    print "      error: $response->{error}\n"
        if defined $response->{error} && !ref $response->{error};
    exit 1;
}

# Plan the actions WITHOUT applying them: same validator as the bot, so a
# refusal here is exactly the refusal the bot would produce.
# Same construction as the bot: the context comes from the EVENT DATA, not
# from the caller's wishes. A cron event carries no channel, so no channel
# context exists — and the mb524 scope guard correctly leaves an explicit
# target alone. Building the context from --channel would have made this
# tool refuse what the bot allows.
my $context = defined $event
    ? { event => $event, channel => $data{channel}, target => $data{target},
        nick => $data{nick} }
    : { channel => $opt{channel}, nick => $opt{nick} };
my $plan = $bot->script_action_runner->apply_actions($result, $context, apply => 0);

my @planned = @{ $plan->{planned} || [] };
my @errors  = @{ $plan->{errors}  || [] };

if (@planned) {
    print "\nActions the bot would take:\n";
    for my $a (@planned) {
        my $type = $a->{type} // '?';
        if ($type eq 'store') {
            my $json = JSON::PP->new->canonical->encode($a->{data});
            # The limit is READ from the module, never copied here: if a
            # future round changes it, this tool follows on its own.
            my $limit = $Mediabot::ScriptActionRunner::MAX_STORE_BYTES;
            printf "  store   %d bytes%s\n", length($json),
                (defined $limit ? " (limit $limit)" : '');
            print "          $json\n";
        }
        elsif ($type eq 'log') {
            printf "  log     [%s] %s\n", ($a->{level} // 3), ($a->{text} // '');
        }
        else {
            printf "  %-7s %s%s\n", $type,
                (defined $a->{target} ? "$a->{target}: " : ''),
                ($a->{text} // $a->{reason} // $a->{topic} // '');
        }
    }
}
else {
    print "\nNo actions planned (a script may legitimately stay silent).\n";
}

if (@errors) {
    print "\nRejected by the action contract:\n";
    for my $e (@errors) {
        my $text = ref($e) eq 'HASH' ? ($e->{error} // '?') : $e;
        my $idx  = ref($e) eq 'HASH' ? $e->{index} : undef;
        printf "  %s%s\n", (defined $idx ? "action[$idx] " : ''), $text;
    }
    print "\nFAIL  the bot would refuse " . scalar(@errors) . " action(s).\n";
    exit 1;
}

print "\nOK    every returned action passes the bot's action contract. "
    . "Nothing was applied by Mediabot.\n";
exit 0;

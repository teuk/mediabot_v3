# t/cases/424_mb185_partyline_scriptdryrun_routes_status.t
use strict;
use warnings;
use FindBin qw($Bin);
use File::Spec;

{
    package FakeStream;
    sub new { bless { out => '' }, shift }
    sub write { my ($self, $text) = @_; $self->{out} .= $text; return 1; }
    sub out { return $_[0]->{out}; }
}

{
    package FakePluginManager;
    sub new { my ($class, $plugin) = @_; bless { plugin => $plugin }, $class }
    sub object_for {
        my ($self, $name) = @_;
        return $self->{plugin} if $name eq 'Mediabot::Plugin::ScriptDryRun';
        return undef;
    }
}

{
    package FakeBot;
    sub new { my ($class, $pm) = @_; bless { pm => $pm }, $class }
    sub plugin_manager { return $_[0]->{pm}; }
}

{
    package FakeScriptDryRunPlugin;
    sub new { my ($class, %args) = @_; return bless \%args, $class; }
    sub script_path { return $_[0]->{script_path}; }
    sub observed_public { return $_[0]->{observed_public} || 0; }
    sub skipped_public { return $_[0]->{skipped_public} || 0; }
    sub filtered_public { return $_[0]->{filtered_public} || 0; }
    sub command_filter_enabled { return $_[0]->{filter_enabled} ? 1 : 0; }
    sub command_filter_list { return @{ $_[0]->{filter_list} || [] }; }
    sub command_routes_enabled { return $_[0]->{routes_enabled} ? 1 : 0; }
    sub command_route_list { return @{ $_[0]->{route_list} || [] }; }
    sub command_routes { return $_[0]->{route_map} || {}; }
    sub last_error { return $_[0]->{last_error}; }
    sub last_result { return $_[0]->{last_result}; }
}

my $case = sub {
    my ($assert) = @_;

    my $root = File::Spec->catdir($Bin, '..', '..');
    unshift @INC, $root;

    eval { require Mediabot::Partyline; 1 }
        or do { $assert->(0, "cannot load Mediabot::Partyline: $@"); return; };

    my $plugin = FakeScriptDryRunPlugin->new(
        script_path     => 'fallback.pl',
        observed_public => 9,
        skipped_public  => 2,
        filtered_public => 1,
        filter_enabled  => 1,
        filter_list     => [ 'hello', 'scriptdemo' ],
        routes_enabled  => 1,
        route_list      => [ 'hello', 'pyhello' ],
        route_map       => {
            hello   => 'examples/hello_perl.pl',
            pyhello => 'examples/hello_python.py',
        },
        last_result     => {
            ok      => 1,
            dry_run => 1,
            script_result => {
                ok        => 1,
                timeout   => 0,
                exit_code => 0,
            },
            action_plan => {
                ok      => 1,
                planned => [
                    { type => 'reply', target => '#teuk', text => 'hello from route dry-run' },
                ],
                errors => [],
            },
        },
    );

    my $party = bless {
        bot => FakeBot->new(FakePluginManager->new($plugin)),
    }, 'Mediabot::Partyline';

    my $status_stream = FakeStream->new;
    $party->_cmd_scriptdryrun($status_stream, 1, 'status');
    my $status = $status_stream->out;

    $assert->($status =~ /command_routes: enabled/,
        'status output reports enabled command routes');
    $assert->($status =~ /route_map: hello=examples\/hello_perl\.pl,pyhello=examples\/hello_python\.py/,
        'status output reports route map');

    my $last_stream = FakeStream->new;
    $party->_cmd_scriptdryrun($last_stream, 1, 'last');
    my $last = $last_stream->out;

    $assert->($last =~ /command_routes: enabled/,
        'last output reports enabled command routes');
    $assert->($last =~ /route_map: hello=examples\/hello_perl\.pl,pyhello=examples\/hello_python\.py/,
        'last output reports route map');

    my $config_stream = FakeStream->new;
    $party->_cmd_scriptdryrun($config_stream, 1, 'config');
    my $config = $config_stream->out;

    $assert->($config =~ /command route keys:/,
        'config output has command route section');
    $assert->($config =~ /plugins\.ScriptDryRun\.ROUTES/,
        'config output lists plugins.ScriptDryRun.ROUTES');
    $assert->($config =~ /SCRIPT_DRYRUN_ROUTES/,
        'config output lists flat SCRIPT_DRYRUN_ROUTES');
    $assert->($config =~ /route format: command=script/,
        'config output explains route format');

    my $disabled_plugin = FakeScriptDryRunPlugin->new(
        script_path     => 'fallback.pl',
        observed_public => 1,
        skipped_public  => 0,
        filtered_public => 0,
        filter_enabled  => 0,
        routes_enabled  => 0,
        route_list      => [],
        route_map       => {},
        last_result     => undef,
    );

    my $disabled_party = bless {
        bot => FakeBot->new(FakePluginManager->new($disabled_plugin)),
    }, 'Mediabot::Partyline';

    my $disabled_stream = FakeStream->new;
    $disabled_party->_cmd_scriptdryrun($disabled_stream, 1, 'status');
    my $disabled = $disabled_stream->out;

    $assert->($disabled =~ /command_routes: disabled/,
        'status output reports disabled command routes');
    $assert->($disabled !~ /route_map:/,
        'disabled command routes do not print route map');

    my $pl_file = File::Spec->catfile($root, 'Mediabot', 'Partyline.pm');
    open my $fh, '<', $pl_file
        or do { $assert->(0, "cannot open Partyline.pm: $!"); return; };
    my $src = do { local $/; <$fh> };
    close $fh;

    $assert->($src =~ /mb185-B1: include ScriptDryRun command route visibility/,
        'Partyline source contains mb185 marker');
    $assert->($src =~ /command_routes_enabled/,
        'Partyline source reads command_routes_enabled');
    $assert->($src =~ /command_route_list/,
        'Partyline source reads command_route_list');
    $assert->($src =~ /command_routes/,
        'Partyline source reads command_routes map');
    $assert->($src !~ /_cmd_scriptdryrun.*run_script_actions_dry/s,
        'Partyline ScriptDryRun routes status still does not execute script pipeline');
    $assert->($src !~ /_cmd_scriptdryrun.*send_privmsg/s,
        'Partyline ScriptDryRun routes status still does not send IRC messages');
};

if (caller) { return $case; }

my $tests = 0;
my $fail  = 0;

my $assert = sub {
    my ($ok, $name) = @_;
    $tests++;
    $name = 'unnamed assertion' unless defined $name && $name ne '';

    if ($ok) {
        print "ok $tests - $name\n";
    }
    else {
        print "not ok $tests - $name\n";
        $fail++;
    }
};

$case->($assert);
print "1..$tests\n";
exit($fail ? 1 : 0);

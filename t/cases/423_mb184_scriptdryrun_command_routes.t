# t/cases/423_mb184_scriptdryrun_command_routes.t
use strict;
use warnings;
use FindBin qw($Bin);
use File::Spec;
use File::Path qw(make_path);
use JSON::PP qw(decode_json encode_json);

{
    package RouteConf;
    sub new { my ($class, %data) = @_; return bless \%data, $class; }
    sub get { my ($self, $key) = @_; return $self->{$key}; }
}

sub write_script {
    my ($path, $label) = @_;
    open my $fh, '>', $path or die "cannot write $path: $!";
    print {$fh} <<"EOS";
use strict;
use warnings;
use JSON::PP qw(decode_json encode_json);
my \$in = do { local \$/; <STDIN> };
my \$payload = decode_json(\$in);
print encode_json({
    actions => [
        {
            type => 'reply',
            text => '$label:' . (\$payload->{data}{command} || '')
        }
    ]
});
EOS
    close $fh;
}

my $case = sub {
    my ($assert) = @_;

    my $root = File::Spec->catdir($Bin, '..', '..');
    unshift @INC, $root;

    eval { require 'Mediabot/Mediabot.pm'; 1 }
        or do { $assert->(0, "cannot load Mediabot/Mediabot.pm: $@"); return; };

    my $tmp = File::Spec->catdir($root, 't', 'tmp_mb184_scripts');
    make_path($tmp);

    write_script(File::Spec->catfile($tmp, 'perl_route.pl'),   'perl');
    write_script(File::Spec->catfile($tmp, 'python_route.pl'), 'python');
    write_script(File::Spec->catfile($tmp, 'fallback.pl'),     'fallback');

    my $bot = Mediabot->new({
        conf => RouteConf->new(
            'plugins.ScriptDryRun.SCRIPT' => 'fallback.pl',
            'plugins.ScriptDryRun.ROUTES' => 'perlcmd=perl_route.pl, pycmd=python_route.pl ; .bang=perl_route.pl',
        ),
    });

    $bot->{script_runner} = Mediabot::ScriptRunner->new(
        bot              => $bot,
        script_dir       => $tmp,
        timeout          => 3,
        max_stdout_bytes => 8192,
    );
    $bot->{script_action_runner} = Mediabot::ScriptActionRunner->new(
        bot             => $bot,
        max_text_length => 400,
    );

    $bot->plugin_manager->load_perl_module('Mediabot::Plugin::ScriptDryRun');
    my $plugin = $bot->plugin_manager->object_for('Mediabot::Plugin::ScriptDryRun');

    $assert->($plugin && $plugin->command_routes_enabled,
        'ScriptDryRun route map is enabled when ROUTES is configured');

    my @routes = $plugin->command_route_list;
    $assert->(join(',', @routes) eq 'bang,perlcmd,pycmd',
        'ScriptDryRun route map parses and normalizes route commands');

    $assert->($plugin->script_for_command('perlcmd') eq 'perl_route.pl',
        'script_for_command returns route-specific script');
    $assert->($plugin->script_for_command('.bang') eq 'perl_route.pl',
        'script_for_command strips trigger from route command');
    $assert->($plugin->script_for_command('unknown') eq 'fallback.pl',
        'script_for_command falls back to SCRIPT for unknown command');

    $assert->($plugin->command_allowed('perlcmd'),
        'command_allowed accepts routed command');
    $assert->($plugin->command_allowed('unknown'),
        'command_allowed allows fallback command when SCRIPT exists and no COMMANDS filter exists');

    my $perl_report = $bot->events->emit_report('public_command_observed', {
        channel => '#teuk',
        nick    => 'Te[u]K',
        command => 'perlcmd',
        args    => [],
    });

    my $perl_result = $plugin->last_result;
    $assert->($perl_report->{ran} == 1 && $perl_result && $perl_result->{ok},
        'routed Perl command runs dry-run pipeline');
    $assert->($perl_result->{action_plan}{planned}[0]{text} eq 'perl:perlcmd',
        'routed Perl command uses perl_route.pl');

    my $py_report = $bot->events->emit_report('public_command_observed', {
        channel => '#teuk',
        nick    => 'Te[u]K',
        command => 'pycmd',
        args    => [],
    });

    my $py_result = $plugin->last_result;
    $assert->($py_report->{ran} == 1 && $py_result && $py_result->{ok},
        'routed Python-named command runs dry-run pipeline');
    $assert->($py_result->{action_plan}{planned}[0]{text} eq 'python:pycmd',
        'routed Python-named command uses python_route.pl');

    my $fallback_report = $bot->events->emit_report('public_command_observed', {
        channel => '#teuk',
        nick    => 'Te[u]K',
        command => 'unknown',
        args    => [],
    });

    my $fallback_result = $plugin->last_result;
    $assert->($fallback_report->{ran} == 1 && $fallback_result && $fallback_result->{ok},
        'unknown command uses fallback SCRIPT when no COMMANDS filter exists');
    $assert->($fallback_result->{action_plan}{planned}[0]{text} eq 'fallback:unknown',
        'fallback command uses fallback.pl');

    my $bot_routes_only = Mediabot->new({
        conf => RouteConf->new(
            'plugins.ScriptDryRun.ROUTES' => 'only=perl_route.pl',
        ),
    });

    $bot_routes_only->{script_runner} = Mediabot::ScriptRunner->new(
        bot              => $bot_routes_only,
        script_dir       => $tmp,
        timeout          => 3,
        max_stdout_bytes => 8192,
    );
    $bot_routes_only->{script_action_runner} = Mediabot::ScriptActionRunner->new(
        bot             => $bot_routes_only,
        max_text_length => 400,
    );

    $bot_routes_only->plugin_manager->load_perl_module('Mediabot::Plugin::ScriptDryRun');
    my $routes_only = $bot_routes_only->plugin_manager->object_for('Mediabot::Plugin::ScriptDryRun');

    $assert->($routes_only->command_allowed('only'),
        'routes-only configuration allows routed command');
    $assert->(!$routes_only->command_allowed('other'),
        'routes-only configuration blocks unrouted command without fallback SCRIPT');

    $bot_routes_only->events->emit_report('public_command_observed', {
        channel => '#teuk',
        nick    => 'Te[u]K',
        command => 'only',
        args    => [],
    });

    $assert->($routes_only->last_result && $routes_only->last_result->{ok},
        'routes-only allowed command runs dry-run pipeline');

    $bot_routes_only->events->emit_report('public_command_observed', {
        channel => '#teuk',
        nick    => 'Te[u]K',
        command => 'other',
        args    => [],
    });

    $assert->($routes_only->filtered_public == 1,
        'routes-only blocked command increments filtered_public');

    my $src_file = File::Spec->catfile($root, 'Mediabot', 'Plugin', 'ScriptDryRun.pm');
    open my $sfh, '<', $src_file
        or do { $assert->(0, "cannot open ScriptDryRun.pm: $!"); return; };
    my $src = do { local $/; <$sfh> };
    close $sfh;

    $assert->(scalar($src =~ /Optional command-to-script route map/),
        'ScriptDryRun source documents command-to-script routing');
    $assert->($src =~ /plugins\.ScriptDryRun\.ROUTES/,
        'ScriptDryRun source documents ROUTES config key');
    $assert->($src =~ /script_for_command/,
        'ScriptDryRun source contains script_for_command helper');
    $assert->($src !~ /send_privmsg|send_notice|send_message|dbh->|prepare\(|INSERT|UPDATE|DELETE/,
        'ScriptDryRun routes do not send IRC messages or touch DB');
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

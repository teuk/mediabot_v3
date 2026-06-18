# t/cases/433_mb194_scriptdryrun_consumes_routed_public_commands.t
use strict;
use warnings;
use FindBin qw($Bin);
use File::Spec;
use File::Path qw(make_path);
use JSON::PP qw(decode_json encode_json);

{
    package Conf194;
    sub new { my ($class, %data) = @_; return bless \%data, $class; }
    sub get { my ($self, $key) = @_; return $self->{$key}; }
}

{
    package FakeLogger194;
    sub new { bless { lines => [] }, shift }
    sub log { my ($self, $level, $msg) = @_; push @{ $self->{lines} }, [ $level, $msg ]; return 1; }
}

sub write_script {
    my ($path) = @_;
    open my $fh, '>', $path or die "cannot write $path: $!";
    print {$fh} <<'EOS';
use strict;
use warnings;
use JSON::PP qw(decode_json encode_json);
my $in = do { local $/; <STDIN> };
my $payload = decode_json($in);
print encode_json({
    actions => [
        { type => 'reply', target => $payload->{data}{channel}, text => 'handled:' . ($payload->{data}{command} || '') }
    ]
});
EOS
    close $fh;
}

my $case = sub {
    my ($assert) = @_;

    my $root = File::Spec->catdir($Bin, '..', '..');
    unshift @INC, $root;

    eval {
        require 'Mediabot/Mediabot.pm';
        require Mediabot::Plugin::ScriptDryRun;
        1;
    } or do { $assert->(0, "cannot load required modules: $@"); return; };

    my $tmp = File::Spec->catdir($root, 't', 'tmp_mb194_scripts');
    make_path($tmp);
    write_script(File::Spec->catfile($tmp, 'pyhello.pl'));

    my $bot = Mediabot->new({
        conf => Conf194->new(
            'plugins.ScriptDryRun.ROUTES'      => 'pyhello=pyhello.pl',
            'plugins.ScriptDryRun.COMMANDS'    => 'pyhello',
            'plugins.ScriptDryRun.ACTION_MODE' => 'dry-run',
            'plugins.ScriptDryRun.ALLOW_IRC'   => 'no',
        ),
    });

    $bot->{logger} = FakeLogger194->new;
    $bot->{script_runner} = Mediabot::ScriptRunner->new(
        bot              => $bot,
        script_dir       => $tmp,
        timeout          => 3,
        max_stdout_bytes => 8192,
    );
    $bot->{script_action_runner} = Mediabot::ScriptActionRunner->new(bot => $bot);

    my $plugin = Mediabot::Plugin::ScriptDryRun->register($bot);

    my $ctx = Mediabot::Context->new(
        bot     => $bot,
        message => 'm pyhello',
        nick    => 'Te[u]K',
        channel => '#teuk',
        command => 'pyhello',
        args    => [],
    );

    my $result = $plugin->observe_public_command($ctx);

    $assert->($result && ref($result) eq 'HASH',
        'ScriptDryRun returns a result for routed pyhello command');
    $assert->($ctx->{scriptdryrun_handled},
        'ScriptDryRun marks routed command context as handled');
    $assert->($ctx->{scriptdryrun_result} && ref($ctx->{scriptdryrun_result}) eq 'HASH',
        'ScriptDryRun stores result on context marker');
    $assert->($plugin->last_result && $plugin->last_result->{script_result}{ok},
        'ScriptDryRun still records last_result for partyline');

    my $filtered_ctx = Mediabot::Context->new(
        bot     => $bot,
        message => 'm version',
        nick    => 'Te[u]K',
        channel => '#teuk',
        command => 'version',
        args    => [],
    );

    my $filtered = $plugin->observe_public_command($filtered_ctx);

    $assert->(!$filtered,
        'ScriptDryRun does not return a result for filtered command');
    $assert->(!$filtered_ctx->{scriptdryrun_handled},
        'ScriptDryRun does not mark filtered command as handled');

    my $mb_file = File::Spec->catfile($root, 'Mediabot', 'Mediabot.pm');
    open my $mfh, '<', $mb_file
        or do { $assert->(0, "cannot open Mediabot.pm: $!"); return; };
    my $mb_src = do { local $/; <$mfh> };
    close $mfh;

    my $pl_file = File::Spec->catfile($root, 'Mediabot', 'Plugin', 'ScriptDryRun.pm');
    open my $pfh, '<', $pl_file
        or do { $assert->(0, "cannot open ScriptDryRun.pm: $!"); return; };
    my $pl_src = do { local $/; <$pfh> };
    close $pfh;

    $assert->($pl_src =~ /mb194-B1\b.*ScriptDryRun runs the resolved script/,
        'ScriptDryRun source documents routed-command ownership');
    $assert->($pl_src =~ /scriptdryrun_handled/,
        'ScriptDryRun source writes scriptdryrun_handled marker');
    $assert->($mb_src =~ /PUBLIC\(scriptdryrun\)/,
        'Mediabot source logs ScriptDryRun consumed commands');
    $assert->($mb_src =~ /PUBLIC\(scriptdryrun\).*?return;/s,
        'Mediabot returns before legacy dispatch when ScriptDryRun handled command');
    $assert->($pl_src !~ /system\s*\(|qx\// && $mb_src !~ /system\s*\(|qx\//,
        'mb194 does not introduce shell execution');
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

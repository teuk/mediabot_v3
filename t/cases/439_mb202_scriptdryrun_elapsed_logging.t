# t/cases/439_mb202_scriptdryrun_elapsed_logging.t
use strict;
use warnings;
use FindBin qw($Bin);
use File::Spec;
use File::Temp qw(tempdir);
use JSON::PP qw(decode_json encode_json);

{
    package Conf202;
    sub new { my ($class, %data) = @_; return bless \%data, $class; }
    sub get { my ($self, $key) = @_; return $self->{$key}; }
}

{
    package FakeIRC202;
    sub new { bless { sent => [] }, shift }
    sub send_message {
        my ($self, @args) = @_;
        push @{ $self->{sent} }, \@args;
        return 1;
    }
    sub sent { return $_[0]->{sent}; }
}

{
    package FakeLogger202;
    sub new { bless { entries => [] }, shift }
    sub log {
        my ($self, $level, $msg) = @_;
        push @{ $self->{entries} }, [ $level, $msg ];
        return 1;
    }
    sub info {
        my ($self, $msg) = @_;
        push @{ $self->{entries} }, [ 'info', $msg ];
        return 1;
    }
    sub entries { return $_[0]->{entries}; }
}

sub write_script202 {
    my ($path) = @_;
    open my $fh, '>', $path or die "cannot write $path: $!";
    print {$fh} <<'EOS';
use strict;
use warnings;
use JSON::PP qw(decode_json encode_json);
my $in = do { local $/; <STDIN> };
my $payload = decode_json($in || '{}');
print encode_json({
    actions => [
        { type => 'reply', text => 'elapsed-ok:' . ($payload->{data}{command} || '') },
        { type => 'log', level => 'info', text => 'elapsed-log' },
    ],
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

    # mb209-B1: use a private File::Temp directory instead of a fixed
    # repository path. This avoids permission failures when earlier test runs
    # were executed as root and left t/tmp_mb202_scripts behind.
    my $tmp = tempdir('mb202_elapsed_XXXXXX', TMPDIR => 1, CLEANUP => 1);
    write_script202(File::Spec->catfile($tmp, 'elapsed.pl'));

    my $irc = FakeIRC202->new;
    my $logger = FakeLogger202->new;

    my $bot = Mediabot->new({
        conf => Conf202->new(
            'plugins.ScriptDryRun.ROUTES'              => 'elapsed=elapsed.pl',
            'plugins.ScriptDryRun.ACTION_MODE'         => 'apply',
            'plugins.ScriptDryRun.ALLOW_IRC'           => 'yes',
            'plugins.ScriptDryRun.APPLY_REQUIRE_SCOPE' => 'yes',
        ),
    });

    $bot->{irc} = $irc;
    $bot->{logger} = $logger;
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
        message => 'm elapsed',
        nick    => 'Te[u]K',
        channel => '#teuk',
        command => 'elapsed',
        args    => [],
    );

    my $result = $plugin->observe_public_command($ctx);
    $assert->($result && $result->{ok},
        'ScriptDryRun apply result remains OK with elapsed logging');
    $assert->($ctx->{scriptdryrun_handled},
        'elapsed logging does not break handled marker');
    $assert->(@{ $irc->sent } == 1,
        'elapsed logging does not break IRC application');
    $assert->($irc->sent->[0][0] eq 'PRIVMSG' && $irc->sent->[0][2] eq '#teuk',
        'elapsed logging keeps argv-style PRIVMSG payload');

    my @messages = map { $_->[1] } @{ $logger->entries };
    my ($accepted) = grep { /PUBLIC\(scriptdryrun\): accepted command=elapsed/ } @messages;
    my ($script_line) = grep { /PUBLIC\(scriptdryrun\): script_result command=elapsed/ } @messages;
    my ($plan_line) = grep { /PUBLIC\(scriptdryrun\): action_plan command=elapsed/ } @messages;

    $assert->(defined $accepted,
        'accepted route log is still emitted');
    $assert->(defined $script_line && $script_line =~ /elapsed_ms=\d+\b/,
        'script_result log includes elapsed_ms');
    $assert->(defined $script_line && $script_line =~ /ok=1 timeout=0 exit=0/,
        'script_result log still includes result summary');
    $assert->(defined $plan_line && $plan_line =~ /elapsed_ms=\d+\b/,
        'action_plan log includes elapsed_ms');
    $assert->(defined $plan_line && $plan_line =~ /ok=1 applied_ok=1 planned=2 applied=2/,
        'action_plan log still includes plan summary');

    my $pl_file = File::Spec->catfile($root, 'Mediabot', 'Plugin', 'ScriptDryRun.pm');
    open my $pfh, '<', $pl_file
        or do { $assert->(0, "cannot open ScriptDryRun.pm: $!"); return; };
    my $src = do { local $/; <$pfh> };
    close $pfh;

    $assert->($src =~ /mb202-B1: centralize runtime logging with elapsed_ms/,
        'ScriptDryRun source contains mb202 marker');
    $assert->($src =~ /use Time::HiRes qw\(time\);/,
        'ScriptDryRun imports monotonic-enough runtime clock helper');
    $assert->($src =~ /sub _elapsed_ms/,
        'ScriptDryRun defines elapsed_ms helper');
    $assert->($src =~ /script_result command=\$command elapsed_ms=/,
        'ScriptDryRun script_result log format includes elapsed_ms');
    $assert->($src =~ /action_plan command=\$command elapsed_ms=/,
        'ScriptDryRun action_plan log format includes elapsed_ms');
    $assert->($src !~ /dbh->|prepare\(|INSERT|UPDATE|DELETE|system\s*\(|qx\//,
        'mb202 logging does not introduce DB writes or shell execution');

    my $test_file = File::Spec->catfile($root, 't', 'cases', '439_mb202_scriptdryrun_elapsed_logging.t');
    open my $tfh, '<', $test_file
        or do { $assert->(0, "cannot open own test file: $!"); return; };
    my $test_src = do { local $/; <$tfh> };
    close $tfh;

    $assert->($test_src =~ /mb209-B1: use a private File::Temp directory/,
        'MB202 elapsed logging test keeps mb209 tempdir ownership marker');
    $assert->($test_src !~ /t['"\),\s]+tmp_mb202_scripts/,
        'MB202 elapsed logging test no longer writes to fixed repo tmp dir');
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

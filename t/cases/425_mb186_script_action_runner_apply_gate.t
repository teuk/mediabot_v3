# t/cases/425_mb186_script_action_runner_apply_gate.t
use strict;
use warnings;
use FindBin qw($Bin);
use File::Spec;

{
    package FakeIRC;
    sub new { bless { sent => [] }, shift }
    sub send_message {
        my ($self, @args) = @_;
        push @{ $self->{sent} }, \@args;
        return 1;
    }
    sub sent { return $_[0]->{sent}; }
}

{
    package FakeLogger;
    sub new { bless { entries => [] }, shift }
    sub log {
        my ($self, $level, $text) = @_;
        push @{ $self->{entries} }, [ $level, $text ];
        return 1;
    }
    sub info {
        my ($self, $text) = @_;
        push @{ $self->{entries} }, [ 'info', $text ];
        return 1;
    }
    sub entries { return $_[0]->{entries}; }
}

my $case = sub {
    my ($assert) = @_;

    my $root = File::Spec->catdir($Bin, '..', '..');
    unshift @INC, $root;

    eval { require Mediabot::ScriptActionRunner; 1 }
        or do { $assert->(0, "cannot load Mediabot::ScriptActionRunner: $@"); return; };

    my $irc = FakeIRC->new;
    my $logger = FakeLogger->new;
    my $bot = {
        irc    => $irc,
        logger => $logger,
    };

    my $runner = Mediabot::ScriptActionRunner->new(
        bot             => $bot,
        max_text_length => 400,
    );

    my $script_result = {
        response => {
            actions => [
                { type => 'reply',  target => '#teuk',  text => 'hello channel' },
                { type => 'notice', target => 'Te[u]K', text => 'hello notice' },
                { type => 'log',    level  => 'info',   text => 'hello log' },
            ],
        },
    };

    my $dry = $runner->apply_actions($script_result, { channel => '#teuk' });

    $assert->($dry->{dry_run},
        'apply_actions defaults to dry-run');
    $assert->($dry->{ok} && @{ $dry->{planned} } == 3,
        'default dry-run still validates planned actions');
    $assert->(!exists $dry->{applied},
        'default dry-run does not include applied actions');
    $assert->(@{ $irc->sent } == 0,
        'default dry-run sends no IRC messages');

    my $no_irc = $runner->apply_actions($script_result, { channel => '#teuk' }, apply => 1);

    $assert->(!$no_irc->{dry_run},
        'apply => 1 disables dry-run mode');
    $assert->(!$no_irc->{applied_ok},
        'apply without allow_irc is not fully applied');
    $assert->(@{ $no_irc->{applied} } == 1,
        'apply without allow_irc applies only log action');
    $assert->(@{ $no_irc->{apply_errors} } == 2,
        'apply without allow_irc records two IRC gate errors');
    $assert->(@{ $irc->sent } == 0,
        'apply without allow_irc sends no IRC messages');
    $assert->(@{ $logger->entries } == 1,
        'apply without allow_irc still applies log action');

    my $with_irc = $runner->apply_actions(
        $script_result,
        { channel => '#teuk' },
        apply     => 1,
        allow_irc => 1,
    );

    $assert->(!$with_irc->{dry_run} && $with_irc->{applied_ok},
        'apply with allow_irc applies all supported actions');
    $assert->(@{ $with_irc->{applied} } == 3,
        'apply with allow_irc reports three applied actions');
    $assert->(@{ $with_irc->{apply_errors} } == 0,
        'apply with allow_irc reports no apply errors');
    $assert->(@{ $irc->sent } == 2,
        'apply with allow_irc sends two IRC messages');

    my $first = $irc->sent->[0];
    my $second = $irc->sent->[1];

    $assert->($first->[0] eq 'PRIVMSG' && $first->[2] eq '#teuk' && $first->[3] eq 'hello channel',
        'reply action sends PRIVMSG with expected target and text');
    $assert->($second->[0] eq 'NOTICE' && $second->[2] eq 'Te[u]K' && $second->[3] eq 'hello notice',
        'notice action sends NOTICE with expected target and text');

    my $timer_result = {
        response => {
            actions => [
                { type => 'timer', name => 'demo', delay => 10 },
            ],
        },
    };

    my $timer_apply = $runner->apply_actions($timer_result, {}, apply => 1, allow_irc => 1);

    $assert->(!$timer_apply->{applied_ok},
        'timer action is not applied yet');
    $assert->($timer_apply->{apply_errors}[0]{error} =~ /not implemented/,
        'timer action returns explicit not implemented error');

    my $bad_result = {
        response => {
            actions => [
                { type => 'reply', target => '#teuk', text => ('x' x 1000) },
            ],
        },
    };

    my $bad_apply = $runner->apply_actions($bad_result, {}, apply => 1, allow_irc => 1);

    $assert->(!$bad_apply->{ok},
        'invalid action plan remains invalid under apply mode');
    $assert->(!$bad_apply->{applied_ok},
        'invalid action plan is not applied');
    $assert->($bad_apply->{apply_errors}[0]{error} =~ /action plan is invalid/,
        'invalid action plan returns explicit apply error');

    my $src_file = File::Spec->catfile($root, 'Mediabot', 'ScriptActionRunner.pm');
    open my $fh, '<', $src_file
        or do { $assert->(0, "cannot open ScriptActionRunner.pm: $!"); return; };
    my $src = do { local $/; <$fh> };
    close $fh;

    $assert->(scalar($src =~ /mb186-B1: real action application remains behind explicit gates/),
        'ScriptActionRunner source keeps the explicit apply-gate marker');
    $assert->($src =~ /allow_irc/,
        'ScriptActionRunner source uses allow_irc gate');
    # mb383: send_message now receives $wire_text, the UTF-8 encoded payload
    # that prevents a wide-character scalar from reaching syswrite(). The call
    # remains argv-style and keeps the existing apply gate unchanged.
    $assert->($src =~ /send_message\(\$command, undef, \$action->\{target\}, \$wire_text\)/,
        'ScriptActionRunner sends IRC through send_message argv-style call (wire-encoded text)');
    $assert->($src !~ /dbh->|prepare\(|INSERT|UPDATE|DELETE|system\s*\(|qx\//,
        'ScriptActionRunner apply gate does not touch DB or shell');
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

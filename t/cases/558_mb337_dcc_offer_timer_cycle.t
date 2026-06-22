use strict;
use warnings;
use FindBin qw($Bin);
use File::Spec;
use Scalar::Util qw(weaken isweak);

my $case = sub {
    my ($assert) = @_;

    my $root = File::Spec->catdir($Bin, '..', '..');
    my $partyline_file = File::Spec->catfile($root, 'Mediabot', 'Partyline.pm');

    open my $fh, '<', $partyline_file
        or do { $assert->(0, "cannot open Partyline.pm: $!"); return; };
    my $src = do { local $/; <$fh> };
    close $fh;

    my ($active) = $src =~ /sub offer_dcc_chat \{(.*?)^# ---------------------------------------------------------------------------\n# accept_dcc_chat/ms;
    my ($passive) = $src =~ /sub accept_dcc_chat_passive \{(.*?)^# ---------------------------------------------------------------------------\n# _init_dcc_session/ms;

    $assert->(defined($active) && length($active) > 0,
        'active DCC offer block extracted');
    $assert->(defined($passive) && length($passive) > 0,
        'passive DCC offer block extracted');
    $assert->($src =~ /use Scalar::Util qw\(weaken\);/,
        'Partyline imports weaken explicitly');

    $assert->($active =~ /MB337-B1/,
        'active DCC offer carries MB337 marker');
    $assert->($active =~ /\$loop->add\(\$listener\).*?\$loop->add\(\$timeout\).*?\$timeout->start;.*?weaken\(\$listener\);.*?weaken\(\$timeout\);/s,
        'active listener and timer gain strong owners before lexicals are weakened');
    $assert->($active =~ /on_expire => sub \{.*?\$loop->remove\(\$listener\).*?\$loop->remove\(\$timeout\)/s,
        'active timeout removes both listener and itself from the loop');

    $assert->($passive =~ /MB337-B1/,
        'passive DCC offer carries MB337 marker');
    $assert->($passive =~ /\$loop->add\(\$listener\).*?\$loop->add\(\$timeout\).*?\$timeout->start;.*?weaken\(\$listener\);.*?weaken\(\$timeout\);/s,
        'passive listener and timer gain strong owners before lexicals are weakened');
    $assert->($passive =~ /on_expire => sub \{.*?\$loop->remove\(\$listener\).*?\$loop->remove\(\$timeout\)/s,
        'passive timeout removes both listener and itself from the loop');

    {
        package MB337::Probe;
        sub new { bless {}, shift }
    }

    my ($leaked_listener_probe, $leaked_timeout_probe);
    {
        my ($listener, $timeout);
        $listener = MB337::Probe->new;
        $timeout  = MB337::Probe->new;

        $leaked_listener_probe = $listener;
        $leaked_timeout_probe  = $timeout;
        weaken($leaked_listener_probe);
        weaken($leaked_timeout_probe);

        $listener->{callback} = sub { return $timeout };
        $timeout->{callback}  = sub { return $listener };

        my $owners = {
            listener => $listener,
            timeout  => $timeout,
        };

        delete $owners->{listener};
        delete $owners->{timeout};
    }

    $assert->(defined($leaked_listener_probe) && defined($leaked_timeout_probe),
        'historical strong callback graph survives after external owners are removed');

    # Break the deliberately reproduced leak so the test process itself stays clean.
    delete $leaked_listener_probe->{callback} if $leaked_listener_probe;
    delete $leaked_timeout_probe->{callback}  if $leaked_timeout_probe;

    my ($fixed_listener_probe, $fixed_timeout_probe);
    my $alive_while_owned = 0;
    {
        my ($listener, $timeout);
        $listener = MB337::Probe->new;
        $timeout  = MB337::Probe->new;

        $fixed_listener_probe = $listener;
        $fixed_timeout_probe  = $timeout;
        weaken($fixed_listener_probe);
        weaken($fixed_timeout_probe);

        $listener->{callback} = sub { return $timeout };
        $timeout->{callback}  = sub { return $listener };

        my $owners = {
            listener => $listener,
            timeout  => $timeout,
        };

        weaken($listener);
        weaken($timeout);

        $alive_while_owned = defined($fixed_listener_probe)
            && defined($fixed_timeout_probe)
            && isweak($listener)
            && isweak($timeout);

        delete $owners->{listener};
        delete $owners->{timeout};
    }

    $assert->($alive_while_owned,
        'weak callback lexicals keep working while strong owners exist');
    $assert->(!defined($fixed_listener_probe) && !defined($fixed_timeout_probe),
        'weak callback graph is released when loop/registry owners disappear');
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

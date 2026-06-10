# t/cases/396_mb145_dcc_offer_timer_cleanup.t
use strict;
use warnings;
use FindBin qw($Bin);
use File::Spec;

my $case = sub {
    my ($assert) = @_;

    my $root = File::Spec->catdir($Bin, '..', '..');
    my $partyline_file = File::Spec->catfile($root, 'Mediabot', 'Partyline.pm');

    open my $fh, '<', $partyline_file
        or do { $assert->(0, "cannot open Partyline.pm: $!"); return; };
    my $src = do { local $/; <$fh> };
    close $fh;

    my ($active)  = $src =~ /sub offer_dcc_chat \{(.*?)^# ---------------------------------------------------------------------------\n# accept_dcc_chat/ms;
    my ($passive) = $src =~ /sub accept_dcc_chat_passive \{(.*?)^# ---------------------------------------------------------------------------\n# _init_dcc_session/ms;

    $assert->(defined($active) && length($active) > 0,
        'offer_dcc_chat block extracted');
    $assert->(defined($passive) && length($passive) > 0,
        'accept_dcc_chat_passive block extracted');

    $assert->($active =~ /my \$timeout;\s*# mb145-B1: stopped\/removed as soon as the DCC client connects/,
        'active offer has timeout lexical available to on_stream');
    $assert->($active =~ /if \(\$timeout\).*?\$timeout->stop if \$timeout->can\('stop'\).*?\$loop->remove\(\$timeout\)/s,
        'active offer stops and removes timeout when client connects');
    $assert->($active =~ /on_listen_error => sub.*?\$self->_dcc_offer_remove\('ctcp_chat', \$nick\).*?if \(\$timeout\).*?\$loop->remove\(\$timeout\)/s,
        'active listen error also cleans pending offer timeout');
    $assert->($active =~ /\$timeout = IO::Async::Timer::Countdown->new\(/,
        'active timeout uses existing lexical instead of shadowing it');

    $assert->($passive =~ /my \$timeout;\s*# mb145-B1: stopped\/removed as soon as the passive DCC client connects/,
        'passive offer has timeout lexical available to on_stream');
    $assert->($passive =~ /if \(\$timeout\).*?\$timeout->stop if \$timeout->can\('stop'\).*?\$loop->remove\(\$timeout\)/s,
        'passive offer stops and removes timeout when client connects');
    $assert->($passive =~ /on_listen_error => sub.*?\$self->_dcc_offer_remove\('passive_chat', \$nick\).*?if \(\$timeout\).*?\$loop->remove\(\$timeout\)/s,
        'passive listen error removes offer and cleans timeout');
    $assert->($passive =~ /\$timeout = IO::Async::Timer::Countdown->new\(/,
        'passive timeout uses existing lexical instead of shadowing it');

    $assert->($src !~ /my \$timeout = IO::Async::Timer::Countdown->new\(/,
        'no DCC offer timeout shadows the cleanup lexical');
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

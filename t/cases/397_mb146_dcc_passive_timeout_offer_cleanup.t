# t/cases/397_mb146_dcc_passive_timeout_offer_cleanup.t
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

    $assert->($active =~ /on_expire => sub \{.*?\$self->_dcc_offer_remove\('ctcp_chat', \$nick\).*?eval \{ \$loop->remove\(\$listener\) \}/s,
        'active DCC timeout removes pending offer before closing listener');

    $assert->($passive =~ /on_expire => sub \{.*?DCC CHAT passive: timeout waiting for \$nick.*?\$self->_dcc_offer_remove\('passive_chat', \$nick\).*?eval \{ \$loop->remove\(\$listener\) \}/s,
        'passive DCC timeout removes pending offer before closing listener');

    $assert->($passive =~ /mb146-B1: when a passive DCC offer times out/,
        'passive DCC timeout contains mb146-B1 marker');

    $assert->($passive =~ /on_listen_error => sub.*?\$self->_dcc_offer_remove\('passive_chat', \$nick\)/s,
        'passive DCC listen error also removes pending offer');

    $assert->($passive =~ /on_stream => sub.*?\$self->_dcc_offer_remove\('passive_chat', \$nick\).*?\$loop->remove\(\$timeout\)/s,
        'passive DCC successful connection removes offer and cancels timeout');
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

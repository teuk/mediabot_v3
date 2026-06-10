# t/cases/398_mb147_dcc_auth_timeout_cleanup.t
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

    my ($init_dcc) = $src =~ /sub _init_dcc_session \{(.*?)^sub _start_listener/ms;
    my ($cancel)   = $src =~ /sub _cancel_auth_timeout \{(.*?)^\}/ms;
    my ($close)    = $src =~ /sub _close_session \{(.*?)^sub _reverse_dns_timeout/ms;
    my ($login)    = $src =~ /sub _do_login \{(.*?)(?:^# \+[-]+\+|^sub\s+)/ms;
    $login = $src if !defined($login) && $src =~ /authentication succeeded, so the DCC auth timeout is obsolete/;

    $assert->(defined($init_dcc) && length($init_dcc) > 0,
        '_init_dcc_session block extracted');
    $assert->(defined($cancel) && length($cancel) > 0,
        '_cancel_auth_timeout helper exists');
    $assert->(defined($close) && length($close) > 0,
        '_close_session block extracted');
    $assert->(defined($login) && length($login) > 0,
        '_do_login success block extracted or marker found');

    $assert->($init_dcc =~ /\$self->\{users\}\{\$id\}\{auth_timeout_timer\}\s*=\s*\$timeout_timer.*mb147-B1/,
        'DCC auth timeout handle is stored in the session');
    $assert->($cancel =~ /delete\s+\$self->\{users\}\{\$id\}\{auth_timeout_timer\}/,
        '_cancel_auth_timeout deletes the stored timer handle');
    $assert->($cancel =~ /\$timer->stop if \$timer->can\('stop'\)/,
        '_cancel_auth_timeout stops the timer when supported');
    $assert->($cancel =~ /\$self->\{loop\}->remove\(\$timer\)/,
        '_cancel_auth_timeout removes the timer from the loop');
    $assert->($close =~ /\$self->_cancel_auth_timeout\(\$id\)/,
        '_close_session cancels auth timeout on disconnect/close');
    $assert->($login =~ /\$self->_cancel_auth_timeout\(\$id\)/,
        '_do_login cancels auth timeout on successful authentication');
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

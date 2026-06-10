# t/cases/392_mb142_dcc_token_alphanumeric.t
use strict;
use warnings;
use FindBin qw($Bin);
use File::Spec;

my $case = sub {
    my ($assert) = @_;

    my $root = File::Spec->catdir($Bin, '..', '..');
    unshift @INC, $root;

    require Mediabot::DCC;
    Mediabot::DCC->import(qw(parse_dcc_chat_payload is_dcc_passive));

    my @valid = (
        ['12345',                  'numeric old mIRC token'],
        ['1234567890abcdef',       'hex token'],
        ['f7e3a4b9-c8d2-e1f0',     'uuid-like token'],
        ['abc.def_123-XYZ',        'mixed dot underscore dash token'],
    );

    for my $case (@valid) {
        my ($token, $label) = @$case;
        my $parsed = parse_dcc_chat_payload("CHAT chat 0 0 $token");
        $assert->($parsed->{type} eq 'dcc_chat', "$label parsed as DCC CHAT");
        $assert->($parsed->{mode} eq 'passive', "$label parsed as passive");
        $assert->(($parsed->{token} // '') eq $token, "$label token preserved");
        $assert->(is_dcc_passive($parsed), "$label recognized by is_dcc_passive");
    }

    my @invalid = (
        ['tok;rm-rf', 'semicolon rejected'],
        ['tok withspace', 'space rejected'],
        ['tok|pipe', 'pipe rejected'],
        ['tok$var', 'dollar rejected'],
        ['tok<redir', 'angle rejected'],
    );

    for my $case (@invalid) {
        my ($token, $label) = @$case;
        my $parsed = parse_dcc_chat_payload("CHAT chat 0 0 $token");
        $assert->($parsed->{type} eq 'invalid', "$label");
    }

    my $active = parse_dcc_chat_payload('CHAT chat 2130706433 52001');
    $assert->($active->{type} eq 'dcc_chat', 'active DCC CHAT still parses');
    $assert->($active->{mode} eq 'active', 'active DCC CHAT mode preserved');

    my $mediabot_file = File::Spec->catfile($root, 'Mediabot', 'Mediabot.pm');
    open my $mfh, '<', $mediabot_file
        or do { $assert->(0, "cannot open Mediabot.pm: $!"); return; };
    my $src = do { local $/; <$mfh> };
    close $mfh;

    $assert->($src =~ /length\(\$token\) > 0\s+&& \$token =~ \/\^\[A-Za-z0-9\._-\]\+\$\//s,
        '_handle_dcc_chat_request accepts opaque safe passive tokens');
    $assert->($src !~ /defined \$token\s+&& \$token\s+=~ \/\^\\d\+\$\//s,
        '_handle_dcc_chat_request no longer requires numeric-only token');
    $assert->($src =~ /token=opaque-safe-id/,
        'passive DCC token comment documents opaque safe id');
};

if (caller) { return $case; }

my $tests = 0;
my $fail  = 0;
my $assert = sub {
    my ($ok, $name) = @_;
    $tests++;
    $name = 'unnamed assertion' unless defined $name && $name ne '';
    if ($ok) { print "ok $tests - $name\n"; }
    else { print "not ok $tests - $name\n"; $fail++; }
};

$case->($assert);
print "1..$tests\n";
exit($fail ? 1 : 0);

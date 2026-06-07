# t/cases/387_seen_wildcard_like_escape.t
use strict;
use warnings;
use FindBin qw($Bin);
use File::Spec;

sub _seen_glob_to_like_for_test {
    my ($input) = @_;
    my $out = '';

    for my $ch (split //, lc($input // '')) {
        if    ($ch eq '*') { $out .= '%';  }
        elsif ($ch eq '?') { $out .= '_';  }
        elsif ($ch eq '!') { $out .= '!!'; }
        elsif ($ch eq '%') { $out .= '!%'; }
        elsif ($ch eq '_') { $out .= '!_'; }
        else               { $out .= $ch;  }
    }

    return $out;
}

my $case = sub {
    my ($assert) = @_;

    my @cases = (
        ['teu*',          'teu%'],
        ['te?k',          'te_k'],
        ['bob_*',         'bob!_%'],
        ['__user__*',     '!_!_user!_!_%'],
        ['a%b*',          'a!%b%'],
        ['with!bang*',    'with!!bang%'],
        ['MIXED_Case*',   'mixed!_case%'],
        ['literal_%?*',   'literal!_!%_%'],
    );

    for my $c (@cases) {
        my ($in, $want) = @$c;
        my $got = _seen_glob_to_like_for_test($in);
        $assert->($got eq $want, "glob '$in' -> LIKE '$want'");
    }

    my $root = File::Spec->catdir($Bin, '..', '..');

    my $uc_file = File::Spec->catfile($root, 'Mediabot', 'UserCommands.pm');
    open my $ufh, '<', $uc_file
        or do { $assert->(0, "cannot open UserCommands.pm: $!"); return; };
    my $uc = do { local $/; <$ufh> };
    close $ufh;

    $assert->($uc =~ /mb127-B3: convert IRC glob/, 'mbSeen_ctx contains mb127-B3 escaping comment');
    $assert->($uc =~ /WHERE nick LIKE \? ESCAPE '!' AND channel = \?/, 'mbSeen_ctx channel wildcard query uses ESCAPE');
    $assert->($uc =~ /WHERE nick LIKE \? ESCAPE '!'\s+ORDER BY seen_at DESC LIMIT 5/s, 'mbSeen_ctx global wildcard query uses ESCAPE');

    my $pl_file = File::Spec->catfile($root, 'Mediabot', 'Partyline.pm');
    open my $pfh, '<', $pl_file
        or do { $assert->(0, "cannot open Partyline.pm: $!"); return; };
    my $pl = do { local $/; <$pfh> };
    close $pfh;

    $assert->($pl =~ /mb94-B1 \/ mb127-B3: support wildcard/, 'Partyline .seen contains mb127-B3 escaping comment');
    $assert->($pl =~ /FROM USER_SEEN WHERE nick LIKE \? ESCAPE '!'/, 'Partyline .seen wildcard query uses ESCAPE');
};

if (caller) {
    return $case;
}

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

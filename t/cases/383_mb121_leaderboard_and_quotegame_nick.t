# t/cases/383_mb121_leaderboard_and_quotegame_nick.t
# =============================================================================
# Tests des corrections mb121 :
#   - B1 : !leaderboard period clamp applique sur la valeur convertie
#          (et non sur l'input brut). 100w doit etre rejete car > 52w
#          alors qu'avant il passait car 100 <= 365.
#   - B2 : !quotegame masking et detection acceptent les nicks IRC contenant
#          des caracteres speciaux ([ ] _ \ ^ { } | -) qui ne sont pas
#          consideres comme word chars par \b en Perl.
# =============================================================================

use strict;
use warnings;

return sub {
    my ($assert) = @_;

    # -------------------------------------------------------------------------
    # B1 : period clamp logic
    # -------------------------------------------------------------------------
    my $validate = sub {
        my ($arg) = @_;
        return ('syntax', undef) unless $arg =~ /^(\d+)([hdw])$/;
        my ($n, $unit) = ($1, $2);
        return ('too small', undef) if $n < 1;
        my $max = $unit eq 'h' ? 365 * 24 : $unit eq 'd' ? 365 : 52;
        return ('too large', undef) if $n > $max;
        my ($result_n, $result_unit) = $unit eq 'w' ? ($n * 7, 'DAY')
                                      : $unit eq 'h' ? ($n, 'HOUR') : ($n, 'DAY');
        return ('OK', "$result_n $result_unit");
    };

    my @cases = (
        ['100w', 'too large'],   # bug mb120: passait avec INTERVAL 700 DAY
        ['52w',  'OK'],          # 364 days, derniere valeur legitime
        ['53w',  'too large'],
        ['365d', 'OK'],
        ['366d', 'too large'],
        ['365h', 'OK'],
        ['8761h','too large'],
        ['1h',   'OK'],
        ['0d',   'too small'],
        ['foo',  'syntax'],
    );

    for my $c (@cases) {
        my ($arg, $expect_status) = @$c;
        my ($status) = $validate->($arg);
        $assert->($status eq $expect_status,
            "leaderboard period '$arg' -> $expect_status (got $status)");
    }

    # -------------------------------------------------------------------------
    # B2 : nick masking with IRC special chars
    # -------------------------------------------------------------------------
    my $nick_char = qr/[A-Za-z0-9\[\]\\^_`{}|\-]/;

    my $mask = sub {
        my ($author, $text) = @_;
        my $masked = $text;
        $masked =~ s/(?<!$nick_char)\Q$author\E(?!$nick_char)/???/gi;
        return $masked;
    };

    my $matches = sub {
        my ($author_lc, $msg_lc) = @_;
        return $msg_lc =~ /(?<!$nick_char)\Q$author_lc\E(?!$nick_char)/ ? 1 : 0;
    };

    # Test: ces nicks doivent etre masques
    for my $case (
        ['teuk',     "teuk a dit quelque chose"],
        ['[teuk]',   "[teuk] a parle"],
        ['__user__', "__user__ raconte"],
        ['MalNick',  "voila ce que dit MalNick"],
    ) {
        my ($author, $text) = @$case;
        my $masked = $mask->($author, $text);
        $assert->($masked ne $text,
            "B2 mask: '$author' in '$text' should be masked");
    }

    # Test: ces nicks NE doivent PAS etre confondus avec substr
    for my $case (
        ['teuk',     "teukteuk a parle"],
        ['teuk',     "voici un teuk_other"],
    ) {
        my ($author, $text) = @$case;
        my $masked = $mask->($author, $text);
        $assert->($masked eq $text,
            "B2 mask: '$author' should NOT match in '$text' (substring)");
    }

    # Test: detection de reponse correcte
    for my $case (
        ['teuk',     "je crois que c est teuk",       1],
        ['[teuk]',   "pour moi c est [teuk]",         1],
        ['__user__', "c est __user__ je suis sur",    1],
        ['malnick',  "c est MalNick !",               1],  # case-insensitive
        ['teuk',     "teukteuk a parle",              0],  # substring
        ['teuk',     "voici un teuk_other",           0],  # underscore = nick char
    ) {
        my ($author, $msg, $expected) = @$case;
        my $got = $matches->(lc $author, lc $msg);
        $assert->($got == $expected,
            "B2 detect: '$author' in '$msg' -> expected=$expected got=$got");
    }
};

# t/cases/16_partyline_whois_routing.t
# =============================================================================
# Static regression checks for Partyline WHOIS routing.
#
# Protects:
#   - RPL_WHOIS lines must be scoped to the requested nick
#   - END/401 must clear pending Partyline WHOIS state
#   - ERR_NOSUCHNICK must be routed back to Partyline
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $src = _slurp(File::Spec->catfile('.', 'mediabot.pl'));

    $assert->ok(
        $src =~ /sub on_message_ERR_NOSUCHNICK;/,
        'mediabot.pl declares on_message_ERR_NOSUCHNICK'
    );

    $assert->ok(
        $src =~ /on_message_ERR_NOSUCHNICK\s*=>\s*\\&on_message_ERR_NOSUCHNICK/,
        'mediabot.pl registers ERR_NOSUCHNICK callback'
    );

    $assert->ok(
        $src =~ /sub _partyline_whois_clear/,
        'mediabot.pl has Partyline WHOIS clear helper'
    );

    $assert->ok(
        $src =~ /lc\(\$nick\) ne lc\(\$wanted\)/,
        'Partyline WHOIS helper compares reply nick with requested nick'
    );

    $assert->ok(
        $src =~ /ignoring WHOIS line for \$nick while waiting for \$wanted/,
        'Partyline WHOIS helper logs ignored unrelated WHOIS replies'
    );

    $assert->ok(
        $src =~ /_partyline_whois_write\(\$target_name,\s*"\[311\]/,
        'RPL_WHOISUSER routes through nick-scoped helper'
    );

    $assert->ok(
        $src =~ /_partyline_whois_write\(\$nick,\s*"\[319\]/,
        'RPL_WHOISCHANNELS routes through nick-scoped helper'
    );

    $assert->ok(
        $src =~ /_partyline_whois_write\(\$nick,\s*"\[312\]/,
        'RPL_WHOISSERVER routes through nick-scoped helper'
    );

    $assert->ok(
        $src =~ /_partyline_whois_write\(\$nick,\s*"\[317\]/,
        'RPL_WHOISIDLE routes through nick-scoped helper'
    );

    $assert->ok(
        $src =~ /_partyline_whois_write\(\$nick,\s*"\[318\].*clear\s*=>\s*1/s,
        'RPL_ENDOFWHOIS clears Partyline WHOIS state'
    );

    $assert->ok(
        $src =~ /sub on_message_ERR_NOSUCHNICK/,
        'mediabot.pl implements ERR_NOSUCHNICK handler'
    );

    $assert->ok(
        $src =~ /_partyline_whois_write\(\$nick,\s*"\[401\].*clear\s*=>\s*1/s,
        'ERR_NOSUCHNICK routes to Partyline and clears state'
    );
};

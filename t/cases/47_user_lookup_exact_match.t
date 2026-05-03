# t/cases/47_user_lookup_exact_match.t
# =============================================================================
# Static regression checks for exact user lookups.
#
# User nicknames/handles used as identifiers should not use SQL LIKE unless the
# command is explicitly a search command.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_user_lookup_exact {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $chan     = _slurp_user_lookup_exact(File::Spec->catfile('.', 'Mediabot', 'ChannelCommands.pm'));
    my $external = _slurp_user_lookup_exact(File::Spec->catfile('.', 'Mediabot', 'External.pm'));
    my $main     = _slurp_user_lookup_exact(File::Spec->catfile('.', 'mediabot.pl'));

    $assert->ok(
        $chan =~ /WHERE USER\.nickname = \? AND CHANNEL\.name = \?/,
        'ChannelCommands access lookup uses exact USER.nickname match'
    );

    $assert->ok(
        $chan !~ /WHERE USER\.nickname LIKE \? AND CHANNEL\.name = \?/,
        'ChannelCommands access lookup no longer uses USER.nickname LIKE'
    );

    $assert->ok(
        $main =~ /WHERE USER\.nickname = \? AND CHANNEL\.name = \?/,
        'mediabot.pl WHOIS/access lookup uses exact USER.nickname match'
    );

    $assert->ok(
        $main !~ /WHERE USER\.nickname LIKE \? AND CHANNEL\.name = \?/,
        'mediabot.pl WHOIS/access lookup no longer uses USER.nickname LIKE'
    );

    $assert->ok(
        $external =~ /SELECT fortniteid FROM USER WHERE nickname = \?/,
        'External getFortniteId uses exact nickname match'
    );

    $assert->ok(
        $external !~ /SELECT fortniteid FROM USER WHERE nickname LIKE \?/,
        'External getFortniteId no longer uses nickname LIKE'
    );
};

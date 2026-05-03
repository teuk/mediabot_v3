# t/cases/44_channel_name_exact_match.t
# =============================================================================
# Static regression checks for exact channel-name lookup.
#
# Channel names are identifiers, not SQL LIKE patterns.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_channel_name_exact_match {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $src = _slurp_channel_name_exact_match(File::Spec->catfile('.', 'Mediabot', 'ChannelCommands.pm'));

    $assert->ok(
        $src =~ /WHERE CHANNEL\.name = \?/,
        'antifloodset channel lookup uses exact channel match'
    );

    $assert->ok(
        $src =~ /SELECT tmdb_lang FROM CHANNEL WHERE name = \?/,
        'getTMDBLangChannel uses exact channel match'
    );

    $assert->ok(
        $src !~ /WHERE CHANNEL\.name LIKE \?/,
        'ChannelCommands no longer uses CHANNEL.name LIKE direct lookup'
    );

    $assert->ok(
        $src !~ /CHANNEL WHERE name LIKE \?/,
        'ChannelCommands no longer uses CHANNEL WHERE name LIKE lookup'
    );
};

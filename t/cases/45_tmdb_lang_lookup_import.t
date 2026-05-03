# t/cases/45_tmdb_lang_lookup_import.t
# =============================================================================
# Static regression checks for TMDB language lookup wiring.
#
# mbTMDBSearch_ctx lives in Mediabot::External but getTMDBLangChannel is defined
# in Mediabot::ChannelCommands. It must be imported explicitly.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_tmdb_lang_lookup {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $external = _slurp_tmdb_lang_lookup(File::Spec->catfile('.', 'Mediabot', 'External.pm'));
    my $channel  = _slurp_tmdb_lang_lookup(File::Spec->catfile('.', 'Mediabot', 'ChannelCommands.pm'));

    $assert->ok(
        $external =~ /use Mediabot::ChannelCommands qw\(getTMDBLangChannel\);/,
        'External.pm imports getTMDBLangChannel from ChannelCommands'
    );

    $assert->ok(
        $external =~ /my \$lang\s+=\s+getTMDBLangChannel\(\$self, \$channel\) \|\| 'en'/,
        'mbTMDBSearch_ctx calls getTMDBLangChannel'
    );

    $assert->ok(
        $channel =~ /sub getTMDBLangChannel/,
        'ChannelCommands defines getTMDBLangChannel'
    );

    $assert->ok(
        $channel =~ /SELECT tmdb_lang FROM CHANNEL WHERE name = \?/,
        'getTMDBLangChannel uses exact channel-name lookup'
    );

    $assert->ok(
        $channel !~ /SELECT tmdb_lang FROM CHANNEL WHERE name LIKE \?/,
        'getTMDBLangChannel no longer uses LIKE for channel name'
    );
};

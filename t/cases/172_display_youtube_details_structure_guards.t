# t/cases/172_display_youtube_details_structure_guards.t
# =============================================================================
# Regression checks for displayYoutubeDetails().
#
# YouTube API responses can be valid JSON but structurally unexpected.
# displayYoutubeDetails() must verify items is an ARRAY and nested metadata
# fields are HASH refs before dereferencing them.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_display_youtube_guards {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_body_display_youtube_guards {
    my ($src, $sub_name) = @_;

    my $start_re = qr/^sub\s+\Q$sub_name\E\s*\{/m;
    return undef unless $src =~ /$start_re/g;

    my $start = pos($src);
    my $depth = 1;
    my $pos   = $start;
    my $len   = length($src);

    while ($pos < $len) {
        my $char = substr($src, $pos, 1);

        if ($char eq '{') {
            $depth++;
        }
        elsif ($char eq '}') {
            $depth--;

            if ($depth == 0) {
                return substr($src, $start, $pos - $start);
            }
        }

        $pos++;
    }

    return undef;
}

return sub {
    my ($assert) = @_;

    my $src = _slurp_display_youtube_guards(
        File::Spec->catfile('.', 'Mediabot', 'External.pm')
    );

    my $body = _extract_sub_body_display_youtube_guards($src, 'displayYoutubeDetails');

    $assert->ok(defined $body, 'displayYoutubeDetails body found');

    $assert->like(
        $body // '',
        qr/ref\(\$sYoutubeInfo->\{items\}\) eq 'ARRAY'/,
        'displayYoutubeDetails verifies items is an ARRAY'
    );

    $assert->like(
        $body // '',
        qr/unless \(\@fTyoutubeItems && ref\(\$fTyoutubeItems\[0\]\) eq 'HASH'\)/,
        'displayYoutubeDetails verifies the first item is a HASH'
    );

    $assert->like(
        $body // '',
        qr/my \$statistics\s+= ref\(\$item->\{statistics\}\)\s+eq 'HASH' \? \$item->\{statistics\}\s+: \{\};/,
        'displayYoutubeDetails guards statistics hash'
    );

    $assert->like(
        $body // '',
        qr/my \$snippet\s+= ref\(\$item->\{snippet\}\)\s+eq 'HASH' \? \$item->\{snippet\}\s+: \{\};/,
        'displayYoutubeDetails guards snippet hash'
    );

    $assert->like(
        $body // '',
        qr/my \$localized\s+= ref\(\$snippet->\{localized\}\)\s+eq 'HASH' \? \$snippet->\{localized\}\s+: \{\};/,
        'displayYoutubeDetails guards localized hash'
    );

    $assert->like(
        $body // '',
        qr/my \$contentDetails\s+= ref\(\$item->\{contentDetails\}\) eq 'HASH' \? \$item->\{contentDetails\} : \{\};/,
        'displayYoutubeDetails guards contentDetails hash'
    );

    $assert->like(
        $body // '',
        qr/my \$sTitle\s+= \$localized->\{title\}\s+\/\/ \$snippet->\{title\} \/\/ '';/,
        'displayYoutubeDetails falls back from localized title to snippet title'
    );

    $assert->unlike(
        $body // '',
        qr/my \@fTyoutubeItems = \@\{ \$sYoutubeInfo->\{items\} \/\/ \[\] \};/,
        'displayYoutubeDetails no longer blindly dereferences items'
    );

    $assert->unlike(
        $body // '',
        qr/\$item->\{snippet\}\{localized\}\{title\}/,
        'displayYoutubeDetails no longer directly dereferences snippet.localized.title'
    );
};

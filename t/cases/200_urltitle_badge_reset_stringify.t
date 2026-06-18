# t/cases/200_urltitle_badge_reset_stringify.t
# =============================================================================
# Regression checks for UrlTitle IRC badge rendering.
#
# Badge visual style may keep a background, but displayed text after the badge
# must be preceded by a hard IRC reset. This prevents background leakage on
# clients/themes such as Empus.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_200 {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_body_200 {
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

    my $src = _slurp_200(
        File::Spec->catfile('.', 'Mediabot', 'External', 'URL.pm')
    );

    my %handlers = (
        _handle_instagram => {
            badge => q{String::IRC->new("Instagram")->white('pink')},
            reset => qr/my\s+\$msg\s*=\s*"\$badge\\x0f\s+"\s*\.\s*substr\(\$title,\s*0,\s*300\);/,
        },
        _handle_applemusic => {
            badge => q{String::IRC->new("AppleMusic")->white('grey')},
            reset => qr/my\s+\$msg\s*=\s*"\$badge\\x0f\s+\$title";/,
        },
        _handle_facebook => {
            badge => q{String::IRC->new("Facebook")->white('blue')},
            reset => qr/my\s+\$msg\s*=\s*"\$badge\\x0f\s+"\s*\.\s*substr\(\$title,\s*0,\s*300\);/,
        },
        _handle_x_twitter => {
            badge => q{String::IRC->new("X")->white('black')},
            reset => qr/my\s+\$msg\s*=\s*"\$badge\\x0f\s+"\s*\.\s*substr\(\$title,\s*0,\s*300\);/,
        },
    );

    for my $sub (sort keys %handlers) {
        my $body = _extract_sub_body_200($src, $sub);

        $assert->ok(defined $body, "$sub body found");

        $assert->like(
            $body // '',
            qr/my\s+\$badge\s*=\s*String::IRC->new\("\["\)->white\('black'\);/,
            "$sub builds a badge object first"
        );

        $assert->like(
            $body // '',
            qr/\Q$handlers{$sub}{badge}\E/,
            "$sub keeps its historical badge style"
        );

        $assert->like(
            $body // '',
            $handlers{$sub}{reset},
            "$sub stringifies badge and hard-resets before displayed text"
        );

        $assert->unlike(
            $body // '',
            qr/\$msg\s+\.=\s+String::IRC->new\("\]"\)->white\('black'\)\s*(?:\.\s*"\\x0f")?;\s*\n\s*\$msg\s+\.=/,
            "$sub no longer appends displayed text to a String::IRC msg object"
        );
    }

    my $generic = _extract_sub_body_200($src, '_handle_generic_title');

    $assert->ok(defined $generic, '_handle_generic_title body found');

    $assert->like(
        $generic // '',
        qr/my\s+\$label\s*=\s*String::IRC->new\("URL"\)->grey\('black'\);/,
        'generic URL title starts the current URL badge'
    );

    $assert->like(
        $generic // '',
        qr/\$label\s+\.=\s+String::IRC->new\(" \$domain"\)->white\('black'\) if \$domain;/,
        'generic URL title may append the current domain'
    );

    $assert->like(
        $generic // '',
        qr/\$label\s+\.=\s+String::IRC->new\(" \$nick:"\)->grey\('black'\);/,
        'generic URL title keeps the nick in the badge'
    );

    $assert->like(
        $generic // '',
        qr/botPrivmsg\(\$self,\s*\$channel,\s*"\$label\\x0f\s+\$title"\);/,
        'generic URL title hard-resets after label before displayed title'
    );

    $assert->unlike(
        $generic // '',
        qr/my\s+\$msg\s*=\s*String::IRC->new\(/,
        'generic URL title no longer sends displayed title through msg object'
    );
};

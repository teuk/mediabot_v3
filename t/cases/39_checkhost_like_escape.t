# t/cases/39_checkhost_like_escape.t
# =============================================================================
# Static regression checks for checkhost/checkhostchan SQL LIKE escaping.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_checkhost_like_escape {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_checkhost_like_escape {
    my ($src, $name) = @_;

    my $start = index($src, "sub $name");
    die "sub $name not found" if $start < 0;

    my $brace = index($src, "{", $start);
    die "opening brace for $name not found" if $brace < 0;

    my $depth      = 0;
    my $in_single  = 0;
    my $in_double  = 0;
    my $in_comment = 0;
    my $escape     = 0;

    for (my $i = $brace; $i < length($src); $i++) {
        my $c = substr($src, $i, 1);

        if ($in_comment) {
            $in_comment = 0 if $c eq "\n";
            next;
        }

        if ($in_single) {
            if ($c eq "\\" && !$escape) {
                $escape = 1;
                next;
            }
            if ($c eq "'" && !$escape) {
                $in_single = 0;
            }
            $escape = 0;
            next;
        }

        if ($in_double) {
            if ($c eq "\\" && !$escape) {
                $escape = 1;
                next;
            }
            if ($c eq '"' && !$escape) {
                $in_double = 0;
            }
            $escape = 0;
            next;
        }

        if ($c eq "#") {
            $in_comment = 1;
            next;
        }

        if ($c eq "'") {
            $in_single = 1;
            next;
        }

        if ($c eq '"') {
            $in_double = 1;
            next;
        }

        if ($c eq "{") {
            $depth++;
        }
        elsif ($c eq "}") {
            $depth--;

            if ($depth == 0) {
                return substr($src, $start, $i - $start + 1);
            }
        }
    }

    die "end of sub $name not found";
}

return sub {
    my ($assert) = @_;

    my $helpers = _slurp_checkhost_like_escape(File::Spec->catfile('.', 'Mediabot', 'Helpers.pm'));
    my $chan    = _slurp_checkhost_like_escape(File::Spec->catfile('.', 'Mediabot', 'ChannelCommands.pm'));

    my $checkhost     = _extract_sub_checkhost_like_escape($helpers, 'mbDbCheckHostnameNick_ctx');
    my $checkhostchan = _extract_sub_checkhost_like_escape($chan,    'mbDbCheckHostnameNickChan_ctx');

    $assert->ok(
        $checkhost =~ /userhost LIKE \? ESCAPE '!'/,
        q{checkhost uses MariaDB-safe ESCAPE '!'}
    );

    $assert->ok(
        $checkhost =~ /\$host_like =~ s\/!\/!!\/g/,
        'checkhost escapes LIKE escape character'
    );

    $assert->ok(
        $checkhost =~ /\$host_like =~ s\/%\/!%\/g/,
        'checkhost escapes percent wildcard literally'
    );

    $assert->ok(
        $checkhost =~ /\$host_like =~ s\/_\/!_\/g/,
        'checkhost escapes underscore wildcard literally'
    );

    $assert->ok(
        $checkhost =~ /my \$mask = '%@' \. \$host_like/,
        'checkhost uses escaped host in suffix mask'
    );

    $assert->ok(
        $checkhostchan =~ /userhost LIKE \? ESCAPE '!'/,
        q{checkhostchan uses MariaDB-safe ESCAPE '!'}
    );

    $assert->ok(
        $checkhostchan =~ /\$hostname_like =~ s\/!\/!!\/g/,
        'checkhostchan escapes LIKE escape character'
    );

    $assert->ok(
        $checkhostchan =~ /\$hostname_like =~ s\/%\/!%\/g/,
        'checkhostchan escapes percent wildcard literally'
    );

    $assert->ok(
        $checkhostchan =~ /\$hostname_like =~ s\/_\/!_\/g/,
        'checkhostchan escapes underscore wildcard literally'
    );

    $assert->ok(
        $checkhostchan =~ /my \$mask = '%@' \. \$hostname_like/,
        'checkhostchan uses escaped host in suffix mask'
    );

    $assert->ok(
        $checkhostchan =~ /Nicks for host \$hostname on \$target_chan: \$count result\(s\), showing max 10/,
        'checkhostchan summary matches SQL LIMIT 10'
    );
};

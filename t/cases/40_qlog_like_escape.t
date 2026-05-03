# t/cases/40_qlog_like_escape.t
# =============================================================================
# Static regression checks for qlog SQL LIKE escaping.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_qlog_like_escape {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_qlog_like_escape {
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

    my $src  = _slurp_qlog_like_escape(File::Spec->catfile('.', 'Mediabot', 'ChannelCommands.pm'));
    my $func = _extract_sub_qlog_like_escape($src, 'mbChannelLog_ctx');

    $assert->ok(
        $func =~ /cl\.publictext NOT LIKE \? ESCAPE '!'/,
        q{qlog exclusion uses MariaDB-safe ESCAPE '!'}
    );

    $assert->ok(
        $func =~ /cl\.nick LIKE \? ESCAPE '!'/,
        q{qlog nick filter uses MariaDB-safe ESCAPE '!'}
    );

    $assert->ok(
        $func =~ /cl\.publictext LIKE \? ESCAPE '!'/,
        q{qlog text filter uses MariaDB-safe ESCAPE '!'}
    );

    $assert->ok(
        $func =~ /\$nick_like =~ s\/!\/!!\/g/,
        'qlog nick filter escapes LIKE escape character'
    );

    $assert->ok(
        $func =~ /\$nick_like =~ s\/%\/!%\/g/,
        'qlog nick filter escapes percent wildcard literally'
    );

    $assert->ok(
        $func =~ /\$nick_like =~ s\/_\/!_\/g/,
        'qlog nick filter escapes underscore wildcard literally'
    );

    $assert->ok(
        $func =~ /\$t =~ s\/!\/!!\/g/,
        'qlog text terms escape LIKE escape character'
    );

    $assert->ok(
        $func =~ /\$t =~ s\/%\/!%\/g/,
        'qlog text terms escape percent wildcard literally'
    );

    $assert->ok(
        $func =~ /\$t =~ s\/_\/!_\/g/,
        'qlog text terms escape underscore wildcard literally'
    );

    $assert->ok(
        $func =~ /my \$pattern = '%' \. join\('%', \@safe_terms\) \. '%'/,
        'qlog keeps ordered multi-term LIKE pattern'
    );

    $assert->ok(
        $func !~ /push \@where, 'cl\.nick LIKE \?';/,
        'qlog no longer uses unescaped nick LIKE'
    );

    $assert->ok(
        $func !~ /push \@where, 'cl\.publictext LIKE \?';/,
        'qlog no longer uses unescaped publictext LIKE'
    );
};

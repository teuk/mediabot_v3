# t/cases/26_count_last_cmd_pagination.t
# =============================================================================
# Static regression checks for countcmd and lastcmd paginated output.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_count_last_cmd {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_count_last_cmd {
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

    my $src   = _slurp_count_last_cmd(File::Spec->catfile('.', 'Mediabot', 'DBCommands.pm'));
    my $count = _extract_sub_count_last_cmd($src, 'mbCountCommand_ctx');
    my $last  = _extract_sub_count_last_cmd($src, 'mbLastCommand_ctx');

    $assert->ok(
        $count =~ /countcmd\[%02d\]/,
        'countcmd detail lines are numbered'
    );

    $assert->ok(
        $count =~ /my \$per_line = 5;/,
        'countcmd paginates at 5 categories per line'
    );

    $assert->ok(
        $count =~ /details sent by notice to \$nick/,
        'countcmd avoids multi-line channel flood'
    );

    $assert->ok(
        $count =~ /botNotice\(\$self, \$nick, \$line\);/,
        'countcmd sends paginated details by notice'
    );

    $assert->ok(
        $count !~ /my \$max_len = 360/,
        'countcmd no longer uses old max_len single-line truncation'
    );

    $assert->ok(
        $count !~ /\$line = \$prefix/,
        'countcmd no longer builds one huge prefix line'
    );

    $assert->ok(
        $last =~ /LIMIT 10/,
        'lastcmd keeps SQL LIMIT 10'
    );

    $assert->ok(
        $last =~ /lastcmd\[%02d\]/,
        'lastcmd detail lines are numbered'
    );

    $assert->ok(
        $last =~ /my \$per_line = 5;/,
        'lastcmd paginates at 5 commands per line'
    );

    $assert->ok(
        $last =~ /details sent by notice to \$nick/,
        'lastcmd avoids multi-line channel flood'
    );

    $assert->ok(
        $last =~ /botNotice\(\$self, \$nick, \$line\);/,
        'lastcmd sends paginated details by notice'
    );

    $assert->ok(
        $last !~ /my \$max_len = 360/,
        'lastcmd no longer uses old max_len single-line truncation'
    );

    $assert->ok(
        $last !~ /\$line = \$prefix/,
        'lastcmd no longer builds one huge prefix line'
    );
};

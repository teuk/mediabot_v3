# t/cases/18_searchcmd_pagination.t
# =============================================================================
# Static regression checks for searchcmd paginated output and MariaDB-safe LIKE.
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

    my $src = _slurp(File::Spec->catfile('.', 'Mediabot', 'DBCommands.pm'));

    $assert->ok(
        $src =~ /sub mbDbSearchCommand_ctx/,
        'searchcmd function exists'
    );

    $assert->ok(
        $src =~ /LIMIT 50/,
        'searchcmd keeps SQL LIMIT 50'
    );

    $assert->ok(
        $src =~ /LIKE \? ESCAPE '!'/,
        q{searchcmd uses MariaDB-safe SQL LIKE ESCAPE '!'}
    );

    $assert->ok(
        $src =~ /\$like =~ s\/!\/!!\/g/,
        'searchcmd escapes the SQL LIKE escape character itself'
    );

    $assert->ok(
        $src =~ /\$like =~ s\/%\/!%\/g/,
        'searchcmd escapes percent wildcard literally'
    );

    $assert->ok(
        $src =~ /\$like =~ s\/_\/!_\/g/,
        'searchcmd escapes underscore wildcard literally'
    );

    $assert->ok(
        $src =~ /my \$per_line = 5;/,
        'searchcmd paginates at 5 commands per line'
    );

    $assert->ok(
        $src =~ /searchcmd\[%02d\]/,
        'searchcmd detail lines are numbered'
    );

    $assert->ok(
        $src =~ /details sent by notice to \$nick/,
        'searchcmd avoids multi-line channel flood'
    );

    $assert->ok(
        $src =~ /botNotice\(\$self, \$nick, \$line\);/,
        'searchcmd sends paginated details by notice'
    );

    $assert->ok(
        $src !~ /ESCAPE '\\\\'/,
        q{searchcmd no longer uses fragile ESCAPE '\'}
    );

    my ($searchcmd_func) = $src =~ /(sub mbDbSearchCommand_ctx \{.*?\n\})/s;

    $assert->ok(
        defined($searchcmd_func),
        'searchcmd function body extracted for old truncation checks'
    );

    $assert->ok(
        defined($searchcmd_func) && index($searchcmd_func, 'my $max_len = 360') < 0,
        'searchcmd no longer uses old max_len single-line truncation'
    );

    $assert->ok(
        defined($searchcmd_func) && index($searchcmd_func, '$line = $prefix') < 0,
        'searchcmd no longer builds one huge prefix line'
    );
};

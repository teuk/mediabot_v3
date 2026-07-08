# t/cases/19_help_routes_to_showcommands.t
# =============================================================================
# Static regression checks for !help behavior.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_help {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub {
    my ($src, $name) = @_;

    my $needle = "sub $name";
    my $start = index($src, $needle);
    die "sub $name not found" if $start < 0;

    my $brace = index($src, "{", $start);
    die "opening brace for $name not found" if $brace < 0;

    my $depth = 0;
    for (my $i = $brace; $i < length($src); $i++) {
        my $c = substr($src, $i, 1);
        $depth++ if $c eq "{";
        $depth-- if $c eq "}";

        if ($depth == 0) {
            return substr($src, $start, $i - $start + 1);
        }
    }

    die "end of sub $name not found";
}

return sub {
    my ($assert) = @_;

    my $src = _slurp_help(File::Spec->catfile('.', 'Mediabot', 'Mediabot.pm'));
    my $help = _extract_sub($src, 'mbHelp_ctx');

    $assert->ok(
        $help =~ /userShowcommandsChannel_ctx\(\$ctx\)/,
        '!help reuses level-filtered showcommands'
    );

    $assert->ok(
        $help =~ /wiki\|doc\|docs\|documentation/,
        '!help supports explicit wiki/doc request'
    );

    $assert->ok(
        $help =~ /Mediabot documentation:/,
        '!help wiki returns documentation link'
    );

    $assert->ok(
        $help =~ /_mbHelpSendWelcome\(\$ctx\)/,
        '!help (bare) shows the welcome/category screen (mb486)'
    );

    $assert->ok(
        $help =~ /Try: showcmd \$cmd/,
        '!help <command> points to showcmd'
    );

    $assert->ok(
        $help =~ /Try: searchcmd \$cmd/,
        '!help <command> points to searchcmd'
    );

    $assert->ok(
        $help !~ /Please visit .*full documentation on mediabot/,
        'old wiki-only help text is gone'
    );
};

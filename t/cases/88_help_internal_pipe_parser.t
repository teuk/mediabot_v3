# t/cases/88_help_internal_pipe_parser.t
# =============================================================================
# Regression checks for the internal help table parser.
#
# Some help syntaxes legitimately contain pipes:
#   <mask|nick>
#   [timezone|user]
#   [on|off]
#
# The parser must preserve those pipes in the syntax instead of shifting the
# level/description fields.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_help_pipe_parser {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_help_raw_pipe_parser {
    my ($src) = @_;

    my ($raw) = $src =~ /my\s+\$raw\s*=\s*<<'MEDIABOT_INTERNAL_HELP';\n(.*?)\nMEDIABOT_INTERNAL_HELP/s;
    return $raw;
}

sub _parse_like_runtime_pipe_parser {
    my ($raw) = @_;

    my %help;

    for my $line (split /\n/, $raw) {
        next if $line =~ /^\s*$/;

        my @fields = split /\|/, $line;
        my $cmd    = shift @fields;
        my $desc   = pop @fields;
        my $level  = pop @fields;
        my $syntax = join('|', @fields);

        next unless defined $cmd && length $cmd;

        $help{lc $cmd} = {
            syntax => defined($syntax) && length($syntax) ? $syntax : $cmd,
            level  => defined($level)  && length($level)  ? $level  : 'unknown',
            desc   => defined($desc)   && length($desc)   ? $desc   : 'No description available yet.',
        };
    }

    return %help;
}

return sub {
    my ($assert) = @_;

    my $src = _slurp_help_pipe_parser(
        File::Spec->catfile('.', 'Mediabot', 'Mediabot.pm')
    );

    $assert->ok(
        $src =~ /my\s+\@fields\s*=\s*split\s+\/\\\|\/,\s*\$line;/,
        'internal help parser splits into fields first'
    );

    $assert->ok(
        $src =~ /my\s+\$desc\s*=\s*pop\s+\@fields;/,
        'internal help parser reads description from the right'
    );

    $assert->ok(
        $src =~ /my\s+\$level\s*=\s*pop\s+\@fields;/,
        'internal help parser reads level from the right'
    );

    $assert->ok(
        $src =~ /my\s+\$syntax\s*=\s*join\('\|',\s*\@fields\);/,
        'internal help parser preserves pipes inside syntax'
    );

    my $raw = _extract_help_raw_pipe_parser($src);

    $assert->ok(
        defined $raw,
        'internal help raw table found'
    );

    my %help = _parse_like_runtime_pipe_parser($raw // '');

    $assert->is(
        $help{ban}->{syntax},
        'ban #channel <mask|nick> [duration]',
        'ban syntax preserves <mask|nick>'
    );

    $assert->is(
        $help{ban}->{level},
        'operator+',
        'ban level remains operator+'
    );

    $assert->is(
        $help{date}->{syntax},
        'date [timezone|user]',
        'date syntax preserves [timezone|user]'
    );

    $assert->is(
        $help{hailo_chatter}->{syntax},
        'hailo_chatter [on|off]',
        'hailo_chatter syntax preserves [on|off]'
    );

    $assert->is(
        $help{ignore}->{syntax},
        'ignore <nick|mask>',
        'ignore syntax preserves <nick|mask>'
    );

    $assert->is(
        $help{q}->{syntax},
        'q [nick|search]',
        'q syntax preserves [nick|search]'
    );

    $assert->is(
        $help{msg}->{syntax},
        'msg <nick|#channel> <text>',
        'msg syntax preserves <nick|#channel>'
    );
};

# t/cases/84_dispatch_dead_handlers.t
# =============================================================================
# Static regression checks for Mediabot dispatch handlers.
#
# This test guards against a common refactoring bug:
#
#   command => sub { someFunction_ctx($ctx) },
#
# where someFunction_ctx no longer exists, was renamed, moved, or forgotten.
#
# It intentionally does NOT depend on the dispatch hash variable names.
# It scans the bodies of:
#   - mbCommandPublic()
#   - mbCommandPrivate()
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Find;
use File::Spec;

sub _slurp_dispatch_dead_handlers {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _collect_project_subs_dispatch_dead_handlers {
    my %subs;

    find(
        {
            no_chdir => 1,
            wanted   => sub {
                return unless -f $File::Find::name;
                return unless $File::Find::name =~ /\.pm\z/;

                my $path = $File::Find::name;
                my $src  = _slurp_dispatch_dead_handlers($path);

                while ($src =~ /^sub\s+([A-Za-z_][A-Za-z0-9_]*)\s*\{/mg) {
                    $subs{$1}++;
                }
            },
        },
        'Mediabot'
    );

    return %subs;
}

sub _extract_sub_body_dispatch_dead_handlers {
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

sub _extract_simple_handlers_dispatch_dead_handlers {
    my ($body) = @_;

    my @handlers;

    while (
        $body =~ /^\s*
            ([A-Za-z0-9_]+)
            \s*=>\s*
            sub\s*\{\s*
            ([A-Za-z_][A-Za-z0-9_]*)
            \s*\(\s*\$ctx\s*\)
            \s*\}
            \s*,?
        /mgx
    ) {
        push @handlers, [ $1, $2 ];
    }

    return @handlers;
}

sub _find_duplicate_commands_dispatch_dead_handlers {
    my (@handlers) = @_;

    my %seen;
    my @dups;

    for my $pair (@handlers) {
        my ($cmd, undef) = @$pair;
        push @dups, $cmd if $seen{$cmd}++;
    }

    return @dups;
}

return sub {
    my ($assert) = @_;

    my $core_path = File::Spec->catfile('.', 'Mediabot', 'Mediabot.pm');
    my $core      = _slurp_dispatch_dead_handlers($core_path);

    my %subs = _collect_project_subs_dispatch_dead_handlers();

    my $public_body  = _extract_sub_body_dispatch_dead_handlers($core, 'mbCommandPublic');
    my $private_body = _extract_sub_body_dispatch_dead_handlers($core, 'mbCommandPrivate');

    $assert->ok(
        defined $public_body && length($public_body),
        'mbCommandPublic body found in Mediabot.pm'
    );

    $assert->ok(
        defined $private_body && length($private_body),
        'mbCommandPrivate body found in Mediabot.pm'
    );

    my @public_handlers = _extract_simple_handlers_dispatch_dead_handlers(
        $public_body // ''
    );

    my @private_handlers = _extract_simple_handlers_dispatch_dead_handlers(
        $private_body // ''
    );

    $assert->ok(
        scalar(@public_handlers) > 50,
        'public dispatch has many simple command handlers'
    );

    $assert->ok(
        scalar(@private_handlers) > 50,
        'private dispatch has many simple command handlers'
    );

    my @public_dups  = _find_duplicate_commands_dispatch_dead_handlers(@public_handlers);
    my @private_dups = _find_duplicate_commands_dispatch_dead_handlers(@private_handlers);

    $assert->is(
        join(', ', @public_dups),
        '',
        'public dispatch has no duplicate simple command entries'
    );

    $assert->is(
        join(', ', @private_dups),
        '',
        'private dispatch has no duplicate simple command entries'
    );

    for my $pair (@public_handlers) {
        my ($cmd, $func) = @$pair;

        $assert->ok(
            exists $subs{$func},
            "public dispatch command '$cmd' points to existing function $func"
        );
    }

    for my $pair (@private_handlers) {
        my ($cmd, $func) = @$pair;

        $assert->ok(
            exists $subs{$func},
            "private dispatch command '$cmd' points to existing function $func"
        );
    }
};

# t/cases/86_module_structure_sanity.t
# =============================================================================
# Global structural sanity checks for Mediabot modules.
#
# This test guards against:
#   - accidental joined "use" statements, e.g. use Foo;use Bar;
#   - duplicate sub definitions inside the same module
#   - duplicate symbols inside @EXPORT blocks
#   - modules missing their final true value
#
# It is intentionally static and cheap.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Find;

sub _slurp_module_structure_sanity {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _collect_pm_files_module_structure_sanity {
    my @files;

    find(
        {
            no_chdir => 1,
            wanted   => sub {
                return unless -f $File::Find::name;
                return unless $File::Find::name =~ /\.pm\z/;
                push @files, $File::Find::name;
            },
        },
        'Mediabot'
    );

    return sort @files;
}

sub _duplicates_module_structure_sanity {
    my (@items) = @_;

    my %seen;
    my @dups;

    for my $item (@items) {
        push @dups, $item if $seen{$item}++;
    }

    my %uniq;
    return grep { !$uniq{$_}++ } @dups;
}

return sub {
    my ($assert) = @_;

    my @files = _collect_pm_files_module_structure_sanity();

    $assert->ok(
        scalar(@files) >= 10,
        'found many Mediabot Perl modules'
    );

    for my $file (@files) {
        my $src = _slurp_module_structure_sanity($file);

        $assert->unlike(
            $src,
            qr/;use\s+/,
            "$file has no joined use statement"
        );

        my @subs = $src =~ /^sub\s+([A-Za-z_][A-Za-z0-9_]*)\s*\{/mg;
        my @duplicate_subs = _duplicates_module_structure_sanity(@subs);

        $assert->is(
            join(', ', @duplicate_subs),
            '',
            "$file has no duplicate sub definitions"
        );

        while ($src =~ /our\s+\@EXPORT\s*=\s*qw\(\s*(.*?)\s*\);/sg) {
            my @exports = grep { length } split /\s+/, $1;
            my @duplicate_exports = _duplicates_module_structure_sanity(@exports);

            $assert->is(
                join(', ', @duplicate_exports),
                '',
                "$file has no duplicate \@EXPORT symbols"
            );
        }

        $assert->like(
            $src,
            qr/(?:^|\n)1;\s*(?:\#.*)?(?:\n|$)/,
            "$file contains a module true value"
        );
    }
};

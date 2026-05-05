# t/cases/85_exported_symbols_resolve.t
# =============================================================================
# Static/runtime regression checks for @EXPORT wiring.
#
# This test guards against:
#   - functions listed in @EXPORT but not actually available in the package
#   - refactoring mistakes where a function was moved/renamed but export stayed
#   - broken re-export/import chains
#
# This complements:
#   - 84_dispatch_dead_handlers.t
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

sub _slurp_exported_symbols_resolve {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _module_name_from_path_exported_symbols_resolve {
    my ($path) = @_;

    $path =~ s{^\./}{};
    $path =~ s{/}{::}g;
    $path =~ s{\.pm\z}{};

    return $path;
}

sub _collect_exporting_modules_exported_symbols_resolve {
    my @modules;

    find(
        {
            no_chdir => 1,
            wanted   => sub {
                return unless -f $File::Find::name;
                return unless $File::Find::name =~ /\.pm\z/;

                my $path = $File::Find::name;
                my $src  = _slurp_exported_symbols_resolve($path);

                my ($export_block) = $src =~ /our\s+\@EXPORT\s*=\s*qw\(\s*(.*?)\s*\);/s;
                return unless defined $export_block;

                my @symbols = grep { length } split /\s+/, $export_block;

                push @modules, {
                    path    => $path,
                    package => _module_name_from_path_exported_symbols_resolve($path),
                    symbols => \@symbols,
                };
            },
        },
        'Mediabot'
    );

    return @modules;
}

return sub {
    my ($assert) = @_;

    my @modules = _collect_exporting_modules_exported_symbols_resolve();

    $assert->ok(
        scalar(@modules) >= 5,
        'found several Mediabot modules with @EXPORT blocks'
    );

    for my $module (@modules) {
        my $path    = $module->{path};
        my $package = $module->{package};

        my $required_ok = eval {
            require $path;
            1;
        };

        $assert->ok(
            $required_ok,
            "module $package loads successfully"
        );

        if (!$required_ok) {
            $assert->ok(
                0,
                "cannot verify exports for $package because require failed: $@"
            );
            next;
        }

        for my $symbol (@{ $module->{symbols} }) {
            no strict 'refs';

            $assert->ok(
                defined &{"${package}::${symbol}"},
                "$package exports resolvable symbol $symbol"
            );
        }
    }
};

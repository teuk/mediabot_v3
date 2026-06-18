# t/cases/83_admincommands_dispatch_exports.t
# =============================================================================
# Static regression checks for AdminCommands dispatch/export wiring.
#
# This test guards against:
#   - broken or joined "use" statements
#   - accidental hard dependency on Memory::Usage at compile time
#   - missing exported ctx handlers
#   - missing radio/update ctx functions
#   - dispatch entries pointing to dead functions
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_admin_dispatch_exports {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $admin = _slurp_admin_dispatch_exports(
        File::Spec->catfile('.', 'Mediabot', 'AdminCommands.pm')
    );

    my $core = _slurp_admin_dispatch_exports(
        File::Spec->catfile('.', 'Mediabot', 'Mediabot.pm')
    );

    $assert->unlike(
        $admin,
        qr/;use\s+/,
        'AdminCommands.pm does not contain joined use statements'
    );

    $assert->unlike(
        $admin,
        qr/^\s*use\s+Memory::Usage\s*;/m,
        'AdminCommands.pm does not hard-load Memory::Usage at compile time'
    );

    $assert->unlike(
        $core,
        qr/^\s*use\s+Memory::Usage\s*;/m,
        'Mediabot.pm does not hard-load unused Memory::Usage at compile time'
    );

    my ($export_block) = $admin =~ /our\s+\@EXPORT\s*=\s*qw\(\s*(.*?)\s*\);/s;

    $assert->ok(
        defined $export_block,
        'AdminCommands.pm has an @EXPORT block'
    );

    for my $symbol (
        qw(
            radioStatus_ctx
            radioMounts_ctx
            displayRadioListeners_ctx
            radioNext_ctx
            song_ctx
            update
            update_ctx
        )
    ) {
        $assert->like(
            $export_block,
            qr/(?:^|\s)\Q$symbol\E(?:\s|$)/,
            "$symbol is exported by AdminCommands.pm"
        );
    }

    for my $sub (
        qw(
            radioStatus_ctx
            radioMounts_ctx
            displayRadioListeners_ctx
            radioNext_ctx
            song_ctx
            update_ctx
        )
    ) {
        my $count = () = $admin =~ /^sub\s+\Q$sub\E\s*\{/mg;

        $assert->is(
            $count,
            1,
            "$sub is defined exactly once"
        );
    }

    my $update_count = () = $admin =~ /^sub\s+update\s*\{/mg;

    $assert->is(
        $update_count,
        1,
        'legacy update wrapper is defined exactly once'
    );

    my %public_radio_dispatch = (
        listeners => 'displayRadioListeners_ctx',
        nextsong  => 'radioNext_ctx',
        song      => 'song_ctx',
    );

    while (my ($cmd, $func) = each %public_radio_dispatch) {
        $assert->like(
            $core,
            qr/^\s*\Q$cmd\E\s*=>\s*sub\s*\{\s*_dispatch_radio\(\$ctx,\s*\$cmd\)\s*\},/m,
            "public dispatch $cmd routes through _dispatch_radio"
        );
        $assert->like(
            $core,
            qr/^\s*\Q$cmd\E\s*=>\s*\\&\Q$func\E,/m,
            "_dispatch_radio maps $cmd to $func"
        );
    }

    $assert->like(
        $core,
        qr/^\s*update\s*=>\s*sub\s*\{\s*update_ctx\(\$ctx\)\s*\},/m,
        'public dispatch update routes to update_ctx'
    );

    my %private_dispatch = (
        radiostatus => 'radioStatus_ctx',
        radiomounts => 'radioMounts_ctx',
        song        => 'song_ctx',
        update      => 'update_ctx',
    );

    while (my ($cmd, $func) = each %private_dispatch) {
        $assert->like(
            $core,
            qr/^\s*\Q$cmd\E\s*=>\s*sub\s*\{\s*\Q$func\E\(\$ctx\)\s*\},/m,
            "private dispatch $cmd routes to $func"
        );
    }
};

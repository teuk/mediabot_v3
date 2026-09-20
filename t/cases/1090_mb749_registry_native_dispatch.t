# MB749 — one registry entry owns each built-in name and executable handler.

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";
}

use Mediabot::BuiltinCommandCatalog qw(
    public_command_names
    private_command_names
    direct_public_command_names
    legacy_public_adapter_names
    legacy_private_adapter_names
    catalogue_entries
);

sub _slurp_1090 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

sub _handler_names_1090 {
    my ($source, $subname) = @_;
    my ($body) = $source =~
        /sub\s+\Q$subname\E\s*\{\s*return\s*\((.*?)\n\s*\);\s*\}/s;
    return () unless defined $body;
    return $body =~ /^\s*'?([a-z0-9_]+)'?\s*=>\s*sub\b/mg;
}

return sub {
    my ($assert) = @_;

    my $main = _slurp_1090('Mediabot/Mediabot.pm');
    my $manager = _slurp_1090('Mediabot/PluginManager.pm');
    my @public = public_command_names();
    my @private = private_command_names();
    my @legacy_public = legacy_public_adapter_names();
    my @legacy_private = legacy_private_adapter_names();
    my @public_handlers = _handler_names_1090(
        $main, '_builtin_public_command_handlers');
    my @private_handlers = _handler_names_1090(
        $main, '_builtin_private_command_handlers');
    my @entries = catalogue_entries();

    $assert->is(scalar @public_handlers, scalar @public,
        'every public built-in has one registry-native handler');
    $assert->is(scalar @private_handlers, scalar @private,
        'every private built-in has one registry-native handler');
    $assert->is(join(',', sort @public_handlers), join(',', sort @public),
        'public handler keys exactly match the public catalogue');
    $assert->is(join(',', sort @private_handlers), join(',', sort @private),
        'private handler keys exactly match the private catalogue');
    $assert->is(scalar direct_public_command_names(), 238,
        'all 238 public built-ins are direct registry handlers');
    $assert->is(scalar @legacy_public, 0,
        'public compatibility adapter list is empty');
    $assert->is(scalar @legacy_private, 0,
        'private compatibility adapter list is empty');
    $assert->is(scalar grep({ $_->{dispatch} eq 'registry' } @entries), 332,
        'all 332 catalogue entries use registry dispatch');
    $assert->is(scalar grep({ $_->{migration_fallback} } @entries), 234,
        'the previous 234 migratable public handlers keep explicit eligibility');

    $assert->unlike($main, qr/my %command_(?:map|table)\s*=/,
        'duplicate compatibility dispatch tables are absent');
    $assert->like($main, qr/my \$handler = \$entry->\{handler\};/,
        'public and private dispatch obtain handlers from registry entries');
    $assert->unlike($main, qr/\$handler->\(\$ctx,\s*sub/,
        'main dispatch no longer constructs a plugin migration fallback');

    $assert->like($manager,
        qr/\$previous->\{metadata\}\{migration_fallback\}/,
        'plugin mounting requires explicit built-in migration eligibility');
    $assert->like($manager,
        qr/my \$fallback = \$migration && \$fallback_handler\s*\?\s*sub \{ \$fallback_handler->\(\$ctx\) \}/s,
        'plugin mounting captures and calls the saved registry handler');
    $assert->unlike($manager, qr/my \(\$ctx, \$legacy_fallback\) = \@_/,
        'mounted plugin handlers use the ordinary one-context signature');
};

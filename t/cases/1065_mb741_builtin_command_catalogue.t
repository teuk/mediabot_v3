# MB741 — make CommandRegistry authoritative for the complete built-in surface.

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

sub _set_1065 {
    return { map { $_ => 1 } @_ };
}

sub _handlers_1065 {
    my ($source, $name) = @_;
    my ($body) = $source =~
        /sub\s+\Q$name\E\s*\{\s*return\s*\((.*?)\n\s*\);\s*\}/s;
    return undef unless defined $body;
    return _set_1065($body =~ /^\s*'?([a-z0-9_]+)'?\s*=>\s*sub\b/mg);
}

sub _same_keys_1065 {
    my ($left, $right) = @_;
    return join(',', sort keys %$left) eq join(',', sort keys %$right);
}

return sub {
    my ($assert) = @_;

    my @public = public_command_names();
    my @private = private_command_names();
    my @entries = catalogue_entries();
    my $public = _set_1065(@public);
    my $private = _set_1065(@private);
    my $legacy_public = _set_1065(legacy_public_adapter_names());
    my $legacy_private = _set_1065(legacy_private_adapter_names());
    my $direct_public = _set_1065(direct_public_command_names());

    $assert->is(scalar @public, 239,
        'MB789 catalogues all 239 public built-ins');
    $assert->is(scalar keys %$public, scalar @public,
        'MB741 public catalogue has no duplicate');
    $assert->is(scalar @private, 94,
        'MB741 catalogues all 94 private built-ins');
    $assert->is(scalar keys %$private, scalar @private,
        'MB741 private catalogue has no duplicate');
    $assert->is(scalar @entries, 333,
        'MB741 emits one source-scoped definition per built-in');
    $assert->is(scalar keys %$direct_public, 239,
        'MB749 makes every public built-in a direct registry handler');
    $assert->is(scalar keys %$legacy_public, 0,
        'MB749 retires the public compatibility adapter list');
    $assert->is(scalar keys %$legacy_private, 0,
        'MB749 retires the private compatibility adapter list');
    $assert->ok(!scalar(grep { $_->{dispatch} ne 'registry' } @entries),
        'every built-in catalogue entry selects registry dispatch');

    my $source = do {
        open my $fh, '<:encoding(UTF-8)', 'Mediabot/Mediabot.pm' or die $!;
        local $/;
        <$fh>;
    };
    my $public_table = _handlers_1065(
        $source, '_builtin_public_command_handlers');
    my $private_table = _handlers_1065(
        $source, '_builtin_private_command_handlers');

    $assert->ok(defined $public_table,
        'public registry handler catalogue is discoverable');
    $assert->ok(defined $private_table,
        'private registry handler catalogue is discoverable');
    $assert->ok(_same_keys_1065($public_table, $public),
        'every public built-in has exactly one registry handler');
    $assert->ok(_same_keys_1065($private_table, $private),
        'every private built-in has exactly one registry handler');

    $assert->like($source,
        qr/if \(my \$entry = \$self->commands->command_for\(\$cmd, 'public'\)\)/,
        'public dispatch starts from the authoritative catalogue');
    $assert->like($source,
        qr/if \(my \$entry = \$self->commands->command_for\(\$sCommand, 'private'\)\)/,
        'private dispatch starts from the authoritative catalogue');
    $assert->unlike($source,
        qr/my %command_(?:map|table)\s*=/,
        'compatibility dispatch tables are absent');

    require Mediabot::Mediabot;
    my $bot = Mediabot->new({});
    my $registry = $bot->commands;
    $assert->is($registry->count('public'), 239,
        'runtime registry exposes the complete public catalogue');
    $assert->is($registry->count('private'), 94,
        'runtime registry exposes the complete private catalogue');
    $assert->is($registry->command_for('version', 'public')->{metadata}{dispatch},
        'registry', 'native command has direct registry metadata');
    $assert->is($registry->command_for('karma', 'public')->{metadata}{dispatch},
        'registry', 'public built-in has native registry metadata');
    $assert->ok($registry->command_for('karma', 'public')
            ->{metadata}{migration_fallback},
        'migratable public built-in retains explicit fallback eligibility');
    $assert->ok($registry->command_for('hailo', 'public')
            && !$registry->command_for('hailo', 'public')
                ->{metadata}{migration_fallback},
        'new hailo operator command has no legacy migration fallback');
    $assert->is($registry->command_for('login', 'private')->{metadata}{dispatch},
        'registry', 'private built-in has native registry metadata');
    $assert->ok(!$registry->has_command('not_a_real_command', 'public'),
        'unknown names remain outside built-in dispatch');
};

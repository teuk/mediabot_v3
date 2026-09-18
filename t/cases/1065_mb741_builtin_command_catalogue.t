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

sub _table_1065 {
    my ($source, $name) = @_;
    my ($body) = $source =~ /my\s+%\Q$name\E\s*=\s*\((.*?)\n\s*\);/s;
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

    $assert->is(scalar @public, 238,
        'MB741 catalogues all 238 public built-ins');
    $assert->is(scalar keys %$public, scalar @public,
        'MB741 public catalogue has no duplicate');
    $assert->is(scalar @private, 94,
        'MB741 catalogues all 94 private built-ins');
    $assert->is(scalar keys %$private, scalar @private,
        'MB741 private catalogue has no duplicate');
    $assert->is(scalar @entries, 332,
        'MB741 emits one source-scoped definition per built-in');
    $assert->is(join(',', sort keys %$direct_public),
        'commands,help,uptime,version',
        'only the four already-native handlers bypass legacy adapters');

    my $source = do {
        open my $fh, '<:encoding(UTF-8)', 'Mediabot/Mediabot.pm' or die $!;
        local $/;
        <$fh>;
    };
    my $public_table = _table_1065($source, 'command_map');
    my $private_table = _table_1065($source, 'command_table');

    $assert->ok(defined $public_table,
        'public implementation adapter is discoverable');
    $assert->ok(defined $private_table,
        'private implementation adapter is discoverable');
    $assert->ok(_same_keys_1065($public_table, $legacy_public),
        'public implementation adapter exactly matches its frozen allow-list');
    $assert->ok(_same_keys_1065($private_table, $legacy_private),
        'private implementation adapter exactly matches its frozen allow-list');
    $assert->ok(_same_keys_1065($legacy_public, $public),
        'every frozen public adapter has a catalogue entry');
    $assert->ok(_same_keys_1065($legacy_private, $private),
        'every frozen private adapter has a catalogue entry');

    $assert->like($source,
        qr/if \(my \$entry = \$self->commands->command_for\(\$cmd, 'public'\)\)/,
        'public dispatch starts from the authoritative catalogue');
    $assert->like($source,
        qr/if \(my \$entry = \$self->commands->command_for\(\$sCommand, 'private'\)\)/,
        'private dispatch starts from the authoritative catalogue');
    $assert->unlike($source,
        qr/if \(my \$handler = \$command_map\{\$cmd\}\)/,
        'public dispatch has no unregistered table fallback');
    $assert->unlike($source,
        qr/if \(my \$handler = \$command_table\{/,
        'private dispatch has no unregistered table fallback');

    require Mediabot::Mediabot;
    my $bot = Mediabot->new({});
    my $registry = $bot->commands;
    $assert->is($registry->count('public'), 238,
        'runtime registry exposes the complete public catalogue');
    $assert->is($registry->count('private'), 94,
        'runtime registry exposes the complete private catalogue');
    $assert->is($registry->command_for('version', 'public')->{metadata}{dispatch},
        'registry', 'native command has direct registry metadata');
    $assert->is($registry->command_for('karma', 'public')->{metadata}{dispatch},
        'legacy-public', 'public adapter is selected by catalogue metadata');
    $assert->is($registry->command_for('login', 'private')->{metadata}{dispatch},
        'legacy-private', 'private adapter is selected by catalogue metadata');
    $assert->ok(!$registry->has_command('not_a_real_command', 'public'),
        'unknown names remain outside built-in dispatch');
};

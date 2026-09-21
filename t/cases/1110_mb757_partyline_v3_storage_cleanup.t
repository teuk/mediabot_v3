# MB757 — Partyline exposes API v3 cleanup as an explicit Owner-only action.

use strict;
use warnings;
use utf8;

sub _slurp_1110 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

{
    package PM1110;
    sub new { bless { calls => [], result => [1, 1, undef] }, $_[0] }
    sub clear_v3_plugin_data {
        my ($self, $target) = @_;
        push @{ $self->{calls} }, $target;
        return @{ $self->{result} };
    }
}
{
    package Bot1110;
    sub new { bless { pm => $_[1] }, $_[0] }
    sub plugin_manager { $_[0]{pm} }
}
{
    package Stream1110;
    sub new { bless { out => '' }, $_[0] }
    sub write { $_[0]{out} .= $_[1]; 1 }
}

return sub {
    my ($assert) = @_;
    my $source = _slurp_1110('Mediabot/Partyline/Commands.pm');
    my ($plugins) = $source =~ /(sub _cmd_plugins \{.*?)(?=^sub _cmd_help)/ms;

    $assert->like($plugins,
        qr/loadv3\|policy\|resetpolicy\|quarantine\|unquarantine\|clearv3data/,
        'clearv3data shares the explicit API v3 Owner gate');
    $assert->like($plugins, qr/if \(\$verb eq 'clearv3data'\)/,
        'API v3 cleanup has an unambiguous command branch');
    $assert->like($plugins,
        qr/clear_v3_plugin_data\(\$target\)/,
        'Partyline delegates namespace derivation to PluginManager');
    $assert->like($plugins,
        qr/Usage: \.plugins clearv3data <package>/,
        'API v3 cleanup rejects missing or extra arguments');
    $assert->like($plugins,
        qr/No stored API v3 data for package '\$target'/,
        'idempotent absence has an explicit operator result');
    $assert->like($plugins,
        qr/Stored API v3 data for package '\$target' cleared/,
        'successful cleanup has an explicit operator result');
    $assert->like($plugins,
        qr/if \(\$verb eq 'cleardata'\).*?clear_plugin_data\(\$target\)/s,
        'legacy cleardata keeps its historical namespace');
    $assert->unlike($plugins,
        qr/clearv3data.*?_v3_storage_key/s,
        'Partyline never learns or renders the private storage key');
    $assert->like($source,
        qr/\.plugins \[clearv3data\] - Owner-only API v3 repository cleanup/,
        'Partyline help separates v3 repository cleanup from v2 lifecycle');

    require Mediabot::Partyline;
    my $pm = PM1110->new;
    my $partyline = bless {
        bot => Bot1110->new($pm),
        users => {
            7 => { level => 0 },
            8 => { level => 1 },
        },
        streams => {},
    }, 'Mediabot::Partyline';

    my $stream = Stream1110->new;
    $partyline->_cmd_plugins($stream, 8,
        'clearv3data short-content-v3');
    $assert->like($stream->{out}, qr/requires Owner level/,
        'Master cannot invoke API v3 cleanup');
    $assert->is(scalar @{ $pm->{calls} }, 0,
        'denied cleanup never reaches PluginManager');

    $stream = Stream1110->new;
    $partyline->_cmd_plugins($stream, 7,
        'clearv3data short-content-v3 extra');
    $assert->like($stream->{out}, qr/^Usage: \.plugins clearv3data/m,
        'extra cleanup arguments fail closed');
    $assert->is(scalar @{ $pm->{calls} }, 0,
        'invalid arity never reaches PluginManager');

    $stream = Stream1110->new;
    $partyline->_cmd_plugins($stream, 7,
        'clearv3data short-content-v3');
    $assert->like($stream->{out}, qr/Stored API v3 data.*cleared/,
        'Owner receives an explicit successful cleanup result');
    $assert->is(join(',', @{ $pm->{calls} }), 'short-content-v3',
        'Owner request passes only the package slug to PluginManager');

    $pm->{result} = [1, 0, undef];
    $stream = Stream1110->new;
    $partyline->_cmd_plugins($stream, 7,
        'clearv3data short-content-v3');
    $assert->like($stream->{out}, qr/No stored API v3 data/,
        'already-absent state is reported without failure');
};

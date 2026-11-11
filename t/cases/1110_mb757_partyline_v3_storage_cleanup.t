# MB757 — Partyline exposes API v3 cleanup as an explicit Owner-only action.

use strict;
use warnings;
use utf8;

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
    package Stream1110;
    sub new { bless { out => '' }, $_[0] }
    sub write { $_[0]{out} .= $_[1]; 1 }
}

return sub {
    my ($assert) = @_;
    require Mediabot::Partyline::PluginAdmin;
    my $pm = PM1110->new;
    my $invoke = sub {
        my ($stream, $id, $arg) = @_;
        Mediabot::Partyline::PluginAdmin::run($stream, $arg,
            manager => $pm, level => sub { $id == 7 ? 0 : 1 });
    };

    my $stream = Stream1110->new;
    $invoke->($stream, 8,
        'clearv3data short-content-v3');
    $assert->like($stream->{out}, qr/requires Owner level/,
        'Master cannot invoke API v3 cleanup');
    $assert->is(scalar @{ $pm->{calls} }, 0,
        'denied cleanup never reaches PluginManager');

    $stream = Stream1110->new;
    $invoke->($stream, 7,
        'clearv3data short-content-v3 extra');
    $assert->like($stream->{out}, qr/^Usage: \.plugins clearv3data/m,
        'extra cleanup arguments fail closed');
    $assert->is(scalar @{ $pm->{calls} }, 0,
        'invalid arity never reaches PluginManager');

    $stream = Stream1110->new;
    $invoke->($stream, 7,
        'clearv3data short-content-v3');
    $assert->like($stream->{out}, qr/Stored API v3 data.*cleared/,
        'Owner receives an explicit successful cleanup result');
    $assert->is(join(',', @{ $pm->{calls} }), 'short-content-v3',
        'Owner request passes only the package slug to PluginManager');

    $pm->{result} = [1, 0, undef];
    $stream = Stream1110->new;
    $invoke->($stream, 7,
        'clearv3data short-content-v3');
    $assert->like($stream->{out}, qr/No stored API v3 data/,
        'already-absent state is reported without failure');

    $pm->{result} = [0, 0, "failure\r\ncontinued"];
    $stream = Stream1110->new;
    $invoke->($stream, 7, 'clearv3data short-content-v3');
    $assert->like($stream->{out}, qr/Could not clear API v3 data.*failure continued/,
        'cleanup failure remains bounded on one line');

};

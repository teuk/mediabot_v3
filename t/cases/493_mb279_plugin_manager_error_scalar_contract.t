use strict;
use warnings;
use utf8;
use Test::More;

use lib '.';
use Mediabot::PluginManager;

BEGIN {
    package MB279::BadRegisterHash;
    sub register { die { bad => 1 }; }
    $INC{'MB279/BadRegisterHash.pm'} = __FILE__;

    package MB279::BadRegisterArray;
    sub register { die [ 'bad' ]; }
    $INC{'MB279/BadRegisterArray.pm'} = __FILE__;

    package MB279::GoodPlugin;
    sub register { return bless {}, 'MB279::GoodPlugin::Object'; }
    $INC{'MB279/GoodPlugin.pm'} = __FILE__;

    package MB279::BadUnregisterHash;
    sub unregister { die { cleanup => 'bad' }; }

    package MB279::PlainObject;
}

my $pm = Mediabot::PluginManager->new();

my $ok = eval { $pm->load_perl_module('MB279::BadRegisterHash'); 1 };
ok(!$ok, 'direct load_perl_module fails when plugin register dies with HASH ref');
like($@, qr/PluginManager: failed to register MB279::BadRegisterHash: plugin register failed/, 'direct register failure gets scalar fallback');
unlike($@, qr/HASH\(/, 'direct register failure does not stringify HASH ref');

$ok = eval { $pm->load_perl_module('MB279::BadRegisterArray'); 1 };
ok(!$ok, 'direct load_perl_module fails when plugin register dies with ARRAY ref');
like($@, qr/PluginManager: failed to register MB279::BadRegisterArray: plugin register failed/, 'direct ARRAY register failure gets scalar fallback');
unlike($@, qr/ARRAY\(/, 'direct register failure does not stringify ARRAY ref');

my $loaded = $pm->load_configured_plugins({ PLUGINS => 'MB279::BadRegisterHash' });
is(scalar @{ $loaded->{loaded} || [] }, 0, 'load_configured_plugins loads no bad plugin');
is(scalar @{ $loaded->{errors} || [] }, 1, 'load_configured_plugins reports one error');
like($loaded->{errors}[0]{error}, qr/failed to register MB279::BadRegisterHash: plugin register failed/, 'configured load uses scalar diagnostic');
unlike($loaded->{errors}[0]{error}, qr/HASH\(/, 'configured load does not expose HASH ref');

my $pm2 = Mediabot::PluginManager->new();
my $old = bless {}, 'MB279::BadUnregisterHash';
my $new = bless {}, 'MB279::PlainObject';
$pm2->register_plugin(name => 'demo', object => $old);
my $entry = $pm2->register_plugin(name => 'demo', object => $new, replace => 1);
ok($entry, 'replace with cleanup failure still returns new entry');
is($entry->{metadata}{replace_cleanup_error}, 'plugin unregister failed', 'replace cleanup HASH ref error uses scalar fallback');
unlike($entry->{metadata}{replace_cleanup_error}, qr/HASH\(/, 'replace cleanup diagnostic does not stringify HASH ref');

my $pm3 = Mediabot::PluginManager->new();
my $good = eval { $pm3->load_perl_module('MB279::GoodPlugin'); };
ok($good, 'valid plugin still loads normally');
is($good->{name}, 'mb279::goodplugin', 'valid plugin canonical name preserved');

my $src = do {
    open my $fh, '<', 'Mediabot/PluginManager.pm' or die $!;
    local $/;
    <$fh>;
};
like($src, qr/mb279-B1/, 'PluginManager source contains mb279 scalar error marker');
like($src, qr/mb279-B2/, 'PluginManager source contains mb279 register boundary marker');
unlike($src, qr/\$err\s*=\s*\$@\s*\|\|\s*'unknown plugin load error';\s*\$err\s*=~\s*s/s, 'old configured-load stringification block is gone');
unlike($src, qr/failed to load \$module: \$@/, 'raw require error interpolation is gone');
unlike($src, qr/system\s*\(|exec\s*\(|`/, 'mb279 guard does not introduce shell execution');

done_testing();

#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

use lib '.';
use Mediabot::PluginManager;

my $pm = Mediabot::PluginManager->new(bot => undef);

my $err;
{
    local $@;
    eval { $pm->register_plugin(name => [ 'bad' ], module => 'MB276::Dummy'); 1 };
    $err = $@;
}
like($err, qr/plugin name must be scalar/, 'register_plugin rejects ARRAY plugin name explicitly');
unlike($err, qr/ARRAY\(0x/i, 'register_plugin ARRAY name is not stringified in diagnostic');

{
    local $@;
    eval { $pm->register_plugin(name => { bad => 1 }, module => 'MB276::Dummy'); 1 };
    $err = $@;
}
like($err, qr/plugin name must be scalar/, 'register_plugin rejects HASH plugin name explicitly');
unlike($err, qr/HASH\(0x/i, 'register_plugin HASH name is not stringified in diagnostic');

$pm->register_plugin(name => 'real_plugin', module => 'MB276::Dummy');
ok($pm->is_registered('real_plugin'), 'valid scalar plugin name still registers normally');
ok(!defined $pm->plugin([ 'real_plugin' ]), 'plugin lookup ignores ARRAY name instead of stringifying it');
is($pm->unregister_plugin({ bad => 'real_plugin' }), 0, 'unregister ignores HASH name instead of stringifying it');
ok($pm->is_registered('real_plugin'), 'invalid unregister ref did not remove valid plugin');

{
    local $@;
    eval { $pm->load_perl_module([ 'MB276::Dummy' ]); 1 };
    $err = $@;
}
like($err, qr/module name must be scalar/, 'load_perl_module rejects ARRAY module name explicitly');
unlike($err, qr/ARRAY\(0x/i, 'load_perl_module ARRAY module is not stringified in diagnostic');

{
    local $@;
    eval { $pm->load_perl_module({ bad => 'MB276::Dummy' }); 1 };
    $err = $@;
}
like($err, qr/module name must be scalar/, 'load_perl_module rejects HASH module name explicitly');
unlike($err, qr/HASH\(0x/i, 'load_perl_module HASH module is not stringified in diagnostic');

my $tmp = tempdir(CLEANUP => 1);
make_path("$tmp/MB276");
open my $fh, '>', "$tmp/MB276/LoadPlugin.pm" or die "write module: $!";
print {$fh} <<'PLUGIN';
package MB276::LoadPlugin;
use strict;
use warnings;
sub register { my ($class, $bot, %opts) = @_; return bless { name => $opts{name} }, $class; }
sub VERSION { '0.01' }
1;
PLUGIN
close $fh or die "close module: $!";

{
    local @INC = ($tmp, @INC);
    local $@;
    eval { $pm->load_perl_module('MB276::LoadPlugin', name => [ 'bad_name' ]); 1 };
    $err = $@;
}
like($err, qr/plugin name must be scalar/, 'load_perl_module rejects ARRAY explicit plugin name after scalar module validation');
unlike($err, qr/ARRAY\(0x/i, 'load_perl_module explicit ARRAY plugin name is not stringified');

{
    local @INC = ($tmp, @INC);
    my $entry = $pm->load_perl_module('MB276::LoadPlugin', name => 'load_spell');
    is($entry->{name}, 'load_spell', 'valid scalar explicit plugin name still loads normally');
    ok($pm->is_registered('load_spell'), 'valid scalar explicit plugin name is registered');
}

my $source = do {
    open my $src, '<', 'Mediabot/PluginManager.pm' or die $!;
    local $/;
    <$src>;
};
like($source, qr/mb276-B1/, 'PluginManager source contains mb276 plugin-name scalar marker');
like($source, qr/mb276-B2/, 'PluginManager source contains mb276 module-name scalar marker');
unlike($source, qr/`[^`]+`|\bqx\s*(?:\/|\(|\{)|\bsystem\s*(?:\(| )/, 'mb276 PluginManager identifier guard does not introduce shell execution');

done_testing();

#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Scalar::Util qw(refaddr);
use lib '.';

use Mediabot::PluginManager;

{
    package MB258::OverloadedDirectPlugin;
    use overload '""' => sub { 'same-visible-plugin-name' }, fallback => 1;

    sub new {
        my ($class, $label) = @_;
        return bless { label => $label, unregistered => 0 }, $class;
    }

    sub unregister {
        my ($self, %opts) = @_;
        $self->{unregistered}++;
        return 1;
    }
}

my $pm = Mediabot::PluginManager->new(bot => undef);
my $old = MB258::OverloadedDirectPlugin->new('old');
my $new = MB258::OverloadedDirectPlugin->new('new');

is("$old", "$new", 'test fixtures deliberately stringify to the same value');
isnt(refaddr($old), refaddr($new), 'test fixtures are different object references');

$pm->register_plugin(name => 'spell', object => $old);
$pm->register_plugin(name => 'spell', object => $new, replace => 1);

is($old->{unregistered}, 1, 'direct replace unregisters previous object even when stringification matches');
is($new->{unregistered}, 0, 'direct replace does not unregister replacement object');
is(refaddr($pm->object_for('spell')), refaddr($new), 'direct replace keeps replacement object registered');

$pm->register_plugin(name => 'spell', object => $new, replace => 1, metadata => { refresh => 1 });
is($new->{unregistered}, 0, 'same-object direct replace remains a metadata refresh and does not unregister current object');

my $tmp = tempdir(CLEANUP => 1);
make_path("$tmp/MB258");
open my $fh, '>', "$tmp/MB258/OverloadedLoadPlugin.pm" or die "write module: $!";
print {$fh} <<'PLUGIN';
package MB258::OverloadedLoadPlugin;
use strict;
use warnings;
use overload '""' => sub { 'same-visible-load-plugin' }, fallback => 1;

our @OBJECTS;

sub register {
    my ($class, $bot, %opts) = @_;
    my $self = bless { unregistered => 0, name => $opts{name} }, $class;
    push @OBJECTS, $self;
    return $self;
}

sub unregister {
    my ($self, %opts) = @_;
    $self->{unregistered}++;
    return 1;
}

sub VERSION { '0.01' }

1;
PLUGIN
close $fh or die "close module: $!";

local @INC = ($tmp, @INC);
my $pm2 = Mediabot::PluginManager->new(bot => undef);
$pm2->load_perl_module('MB258::OverloadedLoadPlugin', name => 'loader_spell');
my $load_old = $MB258::OverloadedLoadPlugin::OBJECTS[0];
$pm2->load_perl_module('MB258::OverloadedLoadPlugin', name => 'loader_spell', replace => 1);
my $load_new = $MB258::OverloadedLoadPlugin::OBJECTS[1];

ok($load_old && $load_new, 'load_perl_module fixtures created two plugin objects');
is("$load_old", "$load_new", 'load_perl_module fixtures also stringify to the same value');
isnt(refaddr($load_old), refaddr($load_new), 'load_perl_module fixtures are different object references');
is($load_old->{unregistered}, 1, 'load_perl_module replace unregisters previous object even when stringification matches');
is($load_new->{unregistered}, 0, 'load_perl_module replace does not unregister replacement object');
is(refaddr($pm2->object_for('loader_spell')), refaddr($load_new), 'load_perl_module replace keeps new object registered');

my $source = do {
    open my $src, '<', 'Mediabot/PluginManager.pm' or die $!;
    local $/;
    <$src>;
};

like($source, qr/mb258-B1/, 'PluginManager source contains mb258 refaddr identity marker');
like($source, qr/use\s+Scalar::Util\s+qw\(refaddr\)/, 'PluginManager imports refaddr for identity checks');
unlike($source, qr/\$previous_object"\s+eq\s+"\$replacement_object/, 'PluginManager no longer compares plugin identity by stringification');
unlike($source, qr/\b(?:system|qx)\b|`[^`]+`/, 'mb258 identity guard does not introduce shell execution');

done_testing();

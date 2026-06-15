use strict;
use warnings;
use utf8;

sub ok {
    my ($cond, $name) = @_;
    print(($cond ? 'ok' : 'not ok') . " - $name\n");
    return $cond ? 1 : 0;
}

{
    package MB282::Conf;
    sub new { my $class = shift; return bless { @_ }, $class }
    sub get { my ($self, $key) = @_; return $self->{$key}; }
}

my $failures = 0;

open my $fh, '<', 'Mediabot/Mediabot.pm' or die "cannot open Mediabot/Mediabot.pm: $!";
my $src = do { local $/; <$fh> };
close $fh;

$failures += !ok($src =~ /mb282-B1: boot-time plugin autoload config/, 'source documents MB282 autoload scalar/list contract');
$failures += !ok($src =~ /sub _flatten_local_config_values \{/, 'Mediabot.pm has local config flattening helper');
$failures += !ok($src =~ /sub _local_conf_value_has_meaningful_scalar \{/, 'Mediabot.pm has meaningful scalar fallback helper');
$failures += !ok($src !~ /return \$value if defined \$value && length "\$value";/, 'autoload fallback no longer stringifies config refs');

my ($autoload_block) = $src =~ /(\nsub _flatten_local_config_values \{.*?\n\}\n\nsub load_configured_plugins_if_enabled \{)/s;
if (!$autoload_block) {
    ($autoload_block) = $src =~ /(\nsub _conf_get_first_local \{.*?\n\}\n\nsub load_configured_plugins_if_enabled \{)/s;
}

if (!$autoload_block) {
    $failures += !ok(0, 'could not extract autoload helper block');
}
else {
    $autoload_block =~ s/\nsub load_configured_plugins_if_enabled \{\z//;
    my $code = "package MB282::UnderTest; use strict; use warnings;" . $autoload_block;
    my $loaded = eval $code;
    $failures += !ok($loaded || !$@, "autoload helper block compiles: $@");

    if ($loaded || !$@) {
        my $make_bot = sub {
            my (%conf) = @_;
            return bless { conf => MB282::Conf->new(%conf) }, 'MB282::UnderTest';
        };

        $failures += !ok($make_bot->('plugins.AUTOLOAD' => [ 'yes' ])->plugin_autoload_enabled,
            'ARRAY truthy autoload value is accepted');
        $failures += !ok($make_bot->('plugins.AUTOLOAD' => [ undef, [ '', 'enable' ] ])->plugin_autoload_enabled,
            'nested ARRAY autoload value is flattened');
        $failures += !ok($make_bot->('plugins.AUTOLOAD' => { malformed => 1 }, PLUGIN_AUTOLOAD => 'yes')->plugin_autoload_enabled,
            'HASH ref does not mask legacy scalar autoload key');
        $failures += !ok($make_bot->('plugins.AUTOLOAD' => [ undef, '', '   ' ], PLUGINS_AUTOLOAD => 'on')->plugin_autoload_enabled,
            'empty ARRAY does not mask later scalar autoload key');
        $failures += !ok(!$make_bot->('plugins.AUTOLOAD' => [ 'no' ], PLUGIN_AUTOLOAD => 'yes')->plugin_autoload_enabled,
            'explicit false ARRAY autoload keeps the gate disabled');
        $failures += !ok($make_bot->('plugins.AUTOLOAD' => bless({}, 'MB282::BogusValue'), PLUGIN_AUTOLOAD => 'true')->plugin_autoload_enabled,
            'blessed ref does not stringify or mask fallback autoload key');
    }
}

print "1..11\n";
exit($failures ? 1 : 0);

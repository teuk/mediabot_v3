# t/cases/412_mb173_partyline_plugins_status.t
use strict;
use warnings;
use FindBin qw($Bin);
use File::Spec;
use Test::More;

my $root = File::Spec->rel2abs("$Bin/../..");
my $file = File::Spec->catfile($root, 'Mediabot', 'Partyline.pm');
open my $fh, '<', $file or die "$file: $!";
local $/;
my $src = <$fh>;
close $fh;

my $commands_file = File::Spec->catfile($root, 'Mediabot', 'Partyline', 'Commands.pm');
open my $cfh, '<', $commands_file or die "$commands_file: $!";
my $commands_src = <$cfh>;
close $cfh;

my $dispatcher_file = File::Spec->catfile($root, 'Mediabot', 'Partyline', 'Dispatcher.pm');
open my $dfh, '<', $dispatcher_file or die "$dispatcher_file: $!";
my $dispatcher_src = <$dfh>;
close $dfh;

$src = $commands_src . "\n" . $src . "\n" . $dispatcher_src;

my ($dispatch) = $src =~ /(# ---- Authenticated : dispatch commands.*?Unknown command\. Type \.help)/s;
my ($help)     = $src =~ /(sub _cmd_help \{.*?^\})/ms;

ok(defined($dispatch) && length($dispatch), 'authenticated partyline dispatch block extracted');
ok(defined($help) && length($help), '_cmd_help block extracted');

like($dispatch, qr/^    elsif \(\$line =~ \/\^\\\.plugins/ms,
    '.plugins dispatch is present');
like($dispatch, qr/mediabot_commands_partyline_total.*?command => '\.plugins'/s,
    '.plugins increments partyline command metric');
like($dispatch, qr/_cmd_plugins\(\$stream, \$id, \$1\)/,
    '.plugins dispatch passes optional argument');
# mb588: la ligne historique v2 reste stable ; la v3 s'ajoute sans la casser.
like($help, qr/\.plugins \[loaded\|config\|info\|load\|loadscript\|unload\|reload\|enable\|disable\|cleardata\] - plugin lifecycle \(v2\)/,
    '.help preserves the frozen v2 plugin lifecycle line');
like($help, qr/\.plugins \[discoverv3\|loadv3\|policy\|resetpolicy\] - API v3 discovery and channel policy/,
    '.help documents v3 plugin control separately');
like($help, qr/\.plugins \[quarantine\|unquarantine\] - Owner-only API v3 resource isolation/,
    '.help documents explicit v3 resource isolation separately');
like($help, qr/\.plugins \[doctor\|failures\|quarantines\|permissions\|why\] - API v3 read-only diagnostics/,
    '.help documents v3 operator diagnostics separately');

# MB1208: load the actual isolated owner, not extracted Perl source.
use Mediabot::Partyline::PluginAdmin qw(_plugin_info_text _plugin_config_display_value);
{
    package Stream412;
    sub write { $_[0]{out} .= $_[1]; 1 }
    package Manager412;
    sub list { () }
    sub discover_v3_packages { () }
    sub is_registered { 1 }
    sub plugin { {metadata=>{api=>2}} }
    sub enable { push @{$_[0]{calls}}, ['enable',$_[1]]; 1 }
    sub disable { push @{$_[0]{calls}}, ['disable',$_[1]]; 1 }
    sub clear_v3_plugin_data { push @{$_[0]{calls}}, ['clearv3',$_[1]]; (1,1,undef) }
    sub clear_plugin_data { push @{$_[0]{calls}}, ['clear',$_[1]]; (1,1,undef) }
    sub v3_permissions_report {
        push @{$_[0]{calls}}, ['permissions',$_[1]];
        return {plugin=>$_[1],status=>'ready',requested=>['irc.reply'],
                granted=>['irc.reply'],effective=>['irc.reply'],missing=>[]};
    }
}
sub invoke_412 {
    my ($arg,$level,%extra)=@_;
    my $pm=bless {calls=>[]},'Manager412';
    my $stream=bless {out=>''},'Stream412';
    Mediabot::Partyline::PluginAdmin::run($stream,$arg,
        manager=>$pm,level=>sub {$level},autoload=>sub {0},metrics=>sub {undef},%extra);
    return ($stream->{out},$pm->{calls});
}
my ($out,$calls)=invoke_412('',undef);
is($out,"PluginManager:\r\n  autoload: disabled\r\n  registered: 0\r\n  enabled: 0\r\n  disabled: 0\r\n  plugins: none loaded\r\n",
    'summary preserves exact wire output without the bot runtime');
is_deeply($calls,[],'summary performs no mutations');
($out)=invoke_412('loaded',undef,manager=>undef);
is($out,"PluginManager: not initialized\r\n",'missing manager remains explicit');
($out)=invoke_412('discoverv3',undef);
is($out,"API v3 packages:\r\n  (none)\r\n",'empty discovery remains read-only');
($out)=invoke_412('config',undef);
like($out,qr/boot loading: skipped unless plugins.AUTOLOAD=1/,'disabled autoload is explained');
like($out,qr/plugins.ENABLED_AUTOLOAD, PLUGIN_AUTOLOAD, PLUGINS_AUTOLOAD/,'autoload aliases remain visible');
like($out,qr/PLUGINS_ENABLED, PLUGIN_ENABLED, PLUGINS/,'plugin-list aliases remain visible');
($out)=invoke_412('config',undef,autoload=>undef);
like($out,qr/boot loading: enabled by configuration gate/,'absent optional autoload method keeps historical display');
($out)=invoke_412('bogus',undef);
like($out,qr/^Usage: \.plugins \[loaded\|config/,'unknown input returns usage');
for my $verb (qw(load loadscript unload reload cleardata loadv3 policy resetpolicy quarantine unquarantine clearv3data)) {
    for my $level (undef,1,2) {
        ($out,$calls)=invoke_412("$verb example",$level);
        is($out,"Access denied: .plugins $verb requires Owner level.\r\n","$verb denies non-Owner");
        is_deeply($calls,[],"$verb denial cannot mutate manager");
    }
}
for my $verb (qw(enable disable)) {
    for my $level (undef,2) {
        ($out,$calls)=invoke_412("$verb example",$level);
        like($out,qr/requires Master or Owner level/,"$verb denies insufficient level");
        is_deeply($calls,[],"$verb denial cannot mutate manager");
    }
    for my $level (0,1) {
        ($out,$calls)=invoke_412("$verb example",$level);
        is_deeply($calls,[[$verb,'example']],"$verb permits Owner and Master once");
    }
}
for my $pair (['clearv3data','clearv3'],['cleardata','clear']) {
    ($out,$calls)=invoke_412("$pair->[0] example",0);
    is_deeply($calls,[[$pair->[1],'example']],'v2/v3 cleanup namespaces stay separate');
}
($out,$calls)=invoke_412('permissions example',undef);
is_deeply($calls,[['permissions','example']],'permissions view only requests the manager report');
like($out,qr/effective: irc.reply/,'effective permissions remain visible');
is(_plugin_config_display_value('API_KEY','secret'),'[redacted]','config secrets remain redacted');
is(_plugin_info_text("hello\r\nworld",200),'hello world','rendering stays on one line');
is(_plugin_info_text('abcdefgh',6),'abc...','rendering remains bounded');
# This case itself must stay independent of the integration dependency tree.
ok(!exists $INC{'Mediabot/Helpers.pm'} && !exists $INC{'Mediabot/Mediabot.pm'}
    && !exists $INC{'DBI.pm'} && !exists $INC{'IO/Async/Loop.pm'},
    'administration component loads without bot, DBI or async runtime');

done_testing();

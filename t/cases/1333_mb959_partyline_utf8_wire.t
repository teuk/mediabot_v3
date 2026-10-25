use strict;
use warnings;
use utf8;
use Test::More;
use Encode qw(encode find_encoding STOP_AT_PARTIAL LEAVE_SRC);
use File::Temp qw(tempdir);
use IO::Select;
use IO::Socket::INET;
use IO::Async::Loop;
use IO::Async::Stream;
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);
use Mediabot::Partyline;
use Mediabot::Partyline::WireEncoding ();
use Mediabot::PluginManager;
use Mediabot::CommandRegistry;
use Mediabot::EventBus;
use Mediabot::Scheduler;

my $codec=find_encoding('Mediabot-Partyline-Wire');
ok($codec,'the partyline codec is registered through the public Encode API');
my $text="Erreur — été 🔤\r\n";
my $bytes=encode('UTF-8',$text);
is($codec->encode($text),$bytes,'character strings become UTF-8 octets');
is($codec->encode($bytes),$bytes,'existing UTF-8 octets are not double encoded');
my $iac=pack('C*',255,251,1,255,252,1);
is($codec->encode($iac),$iac,'Telnet ECHO protocol octets remain exact');
my $raw=pack('C*',255,250,31,0,255,240,195);
my $saved=$raw;
is($codec->decode($raw,STOP_AT_PARTIAL),$saved,'input keeps raw IAC and incomplete UTF-8 bytes');
is($raw,'','codec consumes the input chunk so IO::Async does not replay it');
$raw=$saved;
$codec->decode($raw,LEAVE_SRC);
is($raw,$saved,'the Encode leave-source contract is preserved');

my $loop=IO::Async::Loop->new;
sub pair {
    socketpair(my $server,my $peer,AF_UNIX,SOCK_STREAM,PF_UNSPEC) or die $!;
    $peer->autoflush(1);
    return ($server,$peer);
}
my $read_available=sub {
    my ($peer)=@_;my $out='';my $select=IO::Select->new($peer);
    while($select->can_read(0)) {
        my $n=sysread($peer,my $chunk,65536);
        last unless defined($n) && $n;
        $out.=$chunk;
    }
    return $out;
};
my $pump=sub {my ($predicate)=@_;for(1..200){$loop->loop_once(.005);return 1 if $predicate->()}return 0};

# Real syswrite with tiny writes: the queue must account for bytes, not chars.
my ($server,$peer)=pair();my $received='';
my $stream=IO::Async::Stream->new(handle=>$server,encoding=>'Mediabot-Partyline-Wire',
    write_len=>3,write_all=>0,on_read=>sub{my ($s,$b)=@_;$received.=$$b;$$b='';0});
$loop->add($stream);
my $written=0;
my $future=$stream->write($text,on_write=>sub{$written+=$_[1]});
my $wire='';
ok($pump->(sub{$wire.=$read_available->($peer);$future->is_ready && length($wire)==length($bytes)}),'deferred partial writes finish without an exception');
is($wire,$bytes,'partial writes deliver the exact UTF-8 bytes');
is($written,length($bytes),'native write callbacks count bytes');
ok($future->is_done,'native write future completes successfully');
my @chunks=("é"," — ","🔤",undef);
$future=$stream->write(sub{shift @chunks});$wire='';my $expected=encode('UTF-8','é — 🔤');
ok($pump->(sub{$wire.=$read_available->($peer);$future->is_ready && length($wire)==length($expected)}),'deferred CODE writes use the same output boundary');
is($wire,$expected,'generated Unicode chunks are encoded once');
my $pending=$loop->new_future;$future=$stream->write($pending);$pending->done('déjà 🔤');$wire='';$expected=encode('UTF-8','déjà 🔤');
ok($pump->(sub{$wire.=$read_available->($peer);$future->is_ready && length($wire)==length($expected)}),'Future-produced text also flushes safely');
is($wire,$expected,'Future-produced UTF-8 bytes are exact');
for my $chunk (pack('C*',255,251),pack('C*',1,195),pack('C*',169,10)) {
    my $before=length($received);syswrite($peer,$chunk);
    ok($pump->(sub{length($received)>=$before+length($chunk)}),'raw fragmented input reaches the reader');
}
is($received,pack('C*',255,251,1,195,169,10),'input is neither decoded early nor duplicated across chunks');
$stream->close_now;close $peer;

{
    package MB959::WireConf;
    sub get {$_[1] eq 'plugins.DATA_DIR' ? $_[0]{dir} : undef}
    package MB959::WireLog;
    sub log {push @{$_[0]{lines}},$_[2];1}
    package MB959::WireBot;
    sub plugin_manager {$_[0]{pm}}
    sub command_registry {$_[0]{registry}}
    sub events {$_[0]{event_bus}}
    sub getLoop {$_[0]{loop}}
    sub plugin_autoload_enabled {0}
}
my $tmp=tempdir(CLEANUP=>1);
my $bot=bless {conf=>bless({dir=>$tmp},'MB959::WireConf'),
    logger=>bless({lines=>[]},'MB959::WireLog'),loop=>$loop,
    registry=>Mediabot::CommandRegistry->new,event_bus=>Mediabot::EventBus->new},'MB959::WireBot';
$bot->{scheduler}=Mediabot::Scheduler->new(loop=>$loop,logger=>$bot->{logger});
my $manager=$bot->{pm}=Mediabot::PluginManager->new(bot=>$bot,plugin_dir=>'plugins');
my $pick=IO::Socket::INET->new(LocalAddr=>'127.0.0.1',LocalPort=>0,Listen=>1) or die $!;
my $port=$pick->sockport;close $pick;
my $party=Mediabot::Partyline->new(bot=>$bot,loop=>$loop,port=>$port);
my $client=IO::Socket::INET->new(PeerAddr=>'127.0.0.1',PeerPort=>$port) or die $!;
$client->autoflush(1);
ok($pump->(sub{keys %{$party->{users}}}),'native Telnet listener accepts a real TCP session');
my ($id)=keys %{$party->{users}};
# Authentication database is outside this test; the real dispatcher receives
# the same authenticated Owner posture produced by the login handler.
@{$party->{users}{$id}}{qw(authenticated login level level_desc auth_stage)}=(1,'teuk',0,'Owner','authenticated');
my $exchange=sub {
    my ($socket,$command,$marker)=@_;
    syswrite($socket,$command."\r\n");
    my $wire='';
    ok($pump->(sub{$wire.=$read_available->($socket);index($wire,$marker)>=0}),'native command response arrives over the existing socket');
    return $wire;
};
$wire=$exchange->($client,'.plugins disable longest-word-v3',encode('UTF-8',"Unknown plugin 'longest-word-v3' — see .plugins loaded\r\n"));
like($wire,qr/\Q@{[encode('UTF-8',"Unknown plugin 'longest-word-v3' — see .plugins loaded")]}\E/,'the exact production failure now returns its complete UTF-8 response');
ok(exists($party->{users}{$id}),'unknown plugin does not close the authenticated session');
ok(!$manager->is_registered('longest-word-v3'),'unknown-plugin error never loads or enables the package');
$wire=$exchange->($client,'.plugins loaded','plugins: none loaded');
like($wire,qr/plugins: none loaded/,'the same connection can issue another command after the error');
$party->_telnet_echo_off($party->{streams}{$id});
$party->_telnet_echo_on($party->{streams}{$id});$wire='';
ok($pump->(sub{$wire.=$read_available->($client);length($wire)>=6}),'native Telnet negotiation flushes');
is($wire,$iac,'IAC WILL/WONT ECHO bytes are unchanged on the real TCP session');

my @caps=qw(data.dictionary.read events.subscribe irc.reply irc.notice irc.channel_message scheduler.jobs storage.kv);
$manager->load_package_v3_persistent('longest-word-v3',grants=>\@caps);
$manager->set_v3_channel_policy_persistent('longest-word-v3','#test',mode=>'on');
$manager->set_v3_enabled_persistent('longest-word-v3',1);
$wire=$exchange->($client,'.plugins disable longest-word-v3',"is now disabled");
ok(!$manager->is_enabled('longest-word-v3'),'loaded plugin still disables and persists through the native partyline path');
ok(exists($party->{users}{$id}),'successful disable also keeps the session');
$manager->unregister_plugin_persistent('longest-word-v3');

# DCC shares the output fix without changing its LF framing or auth timer.
my ($dcc_handle,$dcc_peer)=pair();
my $dcc=IO::Async::Stream->new(handle=>$dcc_handle);
$party->_init_dcc_session($dcc,'teuk','127.0.0.1');
my $dcc_id=fileno($dcc->read_handle);
@{$party->{users}{$dcc_id}}{qw(authenticated login level level_desc auth_stage)}=(1,'teuk',0,'Owner','authenticated');
$wire=$exchange->($dcc_peer,'.plugins disable longest-word-v3',encode('UTF-8',"Unknown plugin 'longest-word-v3' — see .plugins loaded"));
ok(exists($party->{users}{$dcc_id}),'DCC unknown-plugin reply keeps its session');
my $broadcast='Salut — été 🔤';$party->_broadcast($broadcast);
my ($tcp_wire,$dcc_wire)=('','');$expected=encode('UTF-8',$broadcast."\r\n");
ok($pump->(sub{$tcp_wire.=$read_available->($client);$dcc_wire.=$read_available->($dcc_peer);index($tcp_wire,$expected)>=0 && index($dcc_wire,$expected)>=0}),'Unicode broadcast reaches both Telnet and DCC without killing the loop');
ok(index($tcp_wire,$expected)>=0 && index($dcc_wire,$expected)>=0,'broadcast text is encoded exactly once for both transports');
$party->_cancel_auth_timeout($dcc_id);
$dcc->close_now;close $dcc_peer;
$party->{streams}{$id}->close_now;close $client;
done_testing;

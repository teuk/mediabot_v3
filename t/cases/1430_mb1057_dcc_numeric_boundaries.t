use strict;
use warnings;
use utf8;
use Test::More;
use Mediabot::DCC qw(ip_int_to_ipv4 validate_dcc_active_target parse_dcc_chat_payload parse_ctcp_payload);
use Mediabot::Mediabot;
use Mediabot::Partyline;
{
    package MB1057::Log;
    sub log {push @{$_[0]{rows}},[@_[1,2]];1}
    package MB1057::Loop;
    sub connect {my ($s,%args)=@_;push @{$s->{calls}},\%args;1}
    package MB1057::Partyline;
    our @ISA=('Mediabot::Partyline');
    sub accept_dcc_chat_passive {push @{$_[0]{passive}},[@_[1,2]];1}
    package MB1057::Bot;
    our @ISA=('Mediabot');
    sub _fetch_user_for_dcc {++$_[0]{lookups};$_[0]{row}}
    package MB1057::NoDB;
    sub prepare {die 'unexpected live database operation'}
}
my @warnings;
local $SIG{__WARN__}=sub {push @warnings,@_};
my @bad_ip=("134744072\x{663}","\x{661}34744072","134744072\n",
    "134744072\r",'134744072.0','+134744072','134744072e0',[],undef,
    '4294967296',('9'x400));
is_deeply([map {ip_int_to_ipv4($_)} @bad_ip],[(undef)x@bad_ip],
    'the native IPv4 converter rejects Unicode digits, suffixes, references and overflow before coercion');
is_deeply([map {[validate_dcc_active_target($_,5000)]} @bad_ip],
    [map {[0,undef,'invalid_ipv4_integer']} @bad_ip],
    'invalid IPv4 fields keep one explicit refusal reason and no fabricated address');
my @bad_port=("5000\x{663}","\x{665}000","5000\n","5000\r",'5000.0','+5000','5e3',[],undef,
    0,1023,65536,('9'x400));
is_deeply([map {[validate_dcc_active_target(134744072,$_)]} @bad_port],
    [map {[0,'8.8.8.8','invalid_port']} @bad_port],
    'native active-target validation requires an exact bounded ASCII decimal port');
is_deeply([map {ip_int_to_ipv4($_)} (0,'000',134744072,'000134744072',4294967295)],
    ['0.0.0.0','0.0.0.0','8.8.8.8','8.8.8.8','255.255.255.255'],
    'ASCII zero, leading zeros, ordinary and maximum IPv4 values retain their conversion');
is_deeply([map {[validate_dcc_active_target('000134744072',$_)]} (1024,65535,'0005000')],
    [[1,'8.8.8.8','ok'],[1,'8.8.8.8','ok'],[1,'8.8.8.8','ok']],
    'the inclusive active-port limits and leading-zero compatibility are preserved');
is_deeply([validate_dcc_active_target(('0'x400).'134744072',('0'x400).'5000')],
    [1,'8.8.8.8','ok'],'long leading-zero fields are handled without overflow or loss of their decimal value');
my @unicode_zero=(['٠','٠'],['0','٠'],['٠','0']);
is_deeply([map {parse_dcc_chat_payload("CHAT chat $_->[0] $_->[1] opaque")-> {mode}} @unicode_zero],
    [('active')x3],'structural DCC parsing never interprets Unicode decimal glyphs as passive zero');
is_deeply([map {my $r=parse_ctcp_payload("\x01DCC CHAT chat $_->[0] $_->[1] opaque\x01");
    [$r->{type},$r->{mode},$r->{ip_int},$r->{port}]} @unicode_zero],
    [map {['dcc_chat','active',@$_]} @unicode_zero],
    'CTCP parsing preserves raw numeric fields for active-target rejection instead of changing request type');
my $active=parse_ctcp_payload("\x01DCC CHAT chat 134744072 5000\x01");
is_deeply([@{$active}{qw(type mode ip_int port)}],['dcc_chat','active','134744072','5000'],
    'the ordinary raw CTCP active offer remains intact');
my $passive=parse_ctcp_payload("\x01DCC CHAT chat 00 000 opaque-id_7\x01");
is_deeply([@{$passive}{qw(type mode ip_int port token)}],
    ['dcc_chat','passive','00','000','opaque-id_7'],'ASCII passive offers retain leading zeros and the exact opaque token');
is(parse_ctcp_payload("\x01CHAT\x01")->{type},'ctcp_chat','the bare CTCP CHAT invitation is unchanged');
is(parse_ctcp_payload('login example example')->{type},'private_command','ordinary private command parsing is unchanged');

sub setup_1430 {
    my (%opts)=@_;
    my $logger=bless {rows=>[]},'MB1057::Log';
    my $loop=bless {calls=>[]},'MB1057::Loop';
    my $bot=bless {logger=>$logger,dbh=>bless({},'MB1057::NoDB'),lookups=>0,
        row=>{level=>exists($opts{level})?$opts{level}:0,description=>'Owner'}},'MB1057::Bot';
    my $party=bless {bot=>$bot,loop=>$loop,passive=>[]},'MB1057::Partyline';
    $bot->{partyline}=$party;
    return ($bot,$party,$loop,$logger);
}
{
    my ($bot,$party,$loop,$logger)=setup_1430();
    my @errors;
    for my $fields ((map {[$_,5000]} @bad_ip),(map {[134744072,$_]} @bad_port),@unicode_zero) {
        my $ok=eval {$bot->_handle_dcc_chat_request(undef,'Caller',@$fields,'fixture-token');1};
        push @errors,"$@" unless $ok;
    }
    is_deeply(\@errors,[],'the native request handler refuses malformed fields without throwing');
    is($bot->{lookups},0,'every malformed numeric target is refused before account lookup');
    is_deeply($loop->{calls},[],'malformed active targets cannot reach the native connection sink');
    is_deeply($party->{passive},[],'Unicode zero cannot select passive DCC even with a valid token');
    ok(!grep({$_->[1]=~/[\r\n]|ARRAY\(/ || length($_->[1])>200} @{$logger->{rows}}),
        'native refusal diagnostics remain single-line and bounded without reference or raw-port dumps');
}
{
    my ($bot,$party,$loop,$logger)=setup_1430();
    for my $fields ((map {[$_,5000]} @bad_ip),(map {[134744072,$_]} @bad_port)) {
        $party->accept_dcc_chat('Caller',@$fields);
    }
    is_deeply($loop->{calls},[],'the real partyline sink independently refuses the same malformed numeric fields');
    ok(!grep({$_->[1]=~/[\r\n]|ARRAY\(/ || length($_->[1])>200} @{$logger->{rows}}),
        'sink refusal diagnostics also avoid unbounded or multiline raw fields');
}
{
    my ($bot,$party,$loop)=setup_1430();
    $bot->_handle_dcc_chat_request(undef,'Caller','000134744072','0005000');
    is($bot->{lookups},1,'a valid active request still passes the native account gate');
    is(scalar(@{$loop->{calls}}),1,'a valid active request reaches one native connect call');
    is_deeply([@{$loop->{calls}[0]}{qw(host service socktype)}],['8.8.8.8','0005000','stream'],
        'the native sink keeps the canonical IPv4 address and existing service argument');
    is_deeply($party->{passive},[],'an ordinary active request never becomes a passive invitation');
}
{
    my ($bot,$party,$loop,$logger)=setup_1430();
    my $token='fixture-passive-id-9ab34cdef';
    $bot->_handle_dcc_chat_request(undef,'Caller','00','000',$token);
    is($bot->{lookups},1,'ASCII passive zero retains the native account gate');
    is_deeply($party->{passive},[['Caller',$token]],'passive delegation preserves the complete opaque token');
    is_deeply($loop->{calls},[],'passive initiation performs no active outbound connect');
    ok(!grep({index($_->[1],$token)>=0} @{$logger->{rows}}),'native passive logging still uses a redacted token hint');
    $bot->_handle_dcc_chat_request(undef,'Caller',0,0,'fixture token');
    is(scalar(@{$party->{passive}}),1,'the existing opaque-token alphabet still refuses embedded spaces');
}
{
    my ($bot,$party,$loop)=setup_1430(level=>2);
    $bot->_handle_dcc_chat_request(undef,'Caller',134744072,5000);
    $bot->_handle_dcc_chat_request(undef,'Caller',0,0,'opaque');
    is_deeply([$loop->{calls},$party->{passive}],[[],[]],'both modes retain the native account privilege restriction');
}
is_deeply(\@warnings,[],'numeric parsing, request admission and native connection sinks remain warning-free');
done_testing;

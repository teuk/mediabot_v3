use strict;
use warnings;
use utf8;
use Test::More;
use DBI;
use JSON::PP ();
use Encode qw(encode);
use File::Temp qw(tempfile);
use IO::Async::Loop;
use Time::HiRes ();
use Mediabot::External ();
use Mediabot::External::MixCloud ();
use Mediabot::ChannelCommands ();
use Mediabot::Context ();
use Mediabot::Channel ();
use Mediabot::Diagnostics::Channel ();
use Mediabot::IRC::TextBudget qw(_irc_wire_bytes);

binmode Test::More->builder->output, ':encoding(UTF-8)';
binmode Test::More->builder->failure_output, ':encoding(UTF-8)';
{
    package MB1020::Log; sub log {1}
    package MB1020::Bot; sub getLoop {$_[0]{loop}} sub getQuit {$_[0]{quit}//0}
    package MB1020::Loop; sub add {1} sub remove {1} sub watch_process {1}
    package MB1020::Principal; sub is_authenticated {$_[0]{auth}} sub id {1} sub has_level {$_[0]{admin}}
    package MB1020::IRC; sub is_connected {1}
    package MB1020::Runtime; sub capture_generation {$_[0]{generation}}
    package MB1020::HTTP;
    sub get {
        my ($self, $url, $options) = @_;
        push @{$self->{calls}}, [$url, $options];
        if ($self->{path}) {
            open my $fh, '>>:raw', $self->{path} or die $!;
            print {$fh} JSON::PP::encode_json({pid=>$$, url=>$url})."\n" or die $!;
            close $fh or die $!;
        }
        return $self->{response};
    }
}
my $p = 'Mediabot::External::MixCloud';
my $url = 'https://www.mixcloud.com/leekid/shut-up-and-dance/';
my $key = '/leekid/shut-up-and-dance/';
my $json = JSON::PP->new->utf8->canonical;
my $data = {key=>$key, url=>$url, name=>'Shut Up And Dance !', audio_length=>7576, user=>{name=>'Leekid'}};
my $good = {state=>'ok', title=>$data->{name}, author=>'Leekid', seconds=>7576};
sub info_1395 { return $p->can('url_info')->(@_ ? $_[0] : $url) }
sub bot_1395 {
    my $db = DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {RaiseError=>1,PrintError=>0,sqlite_unicode=>1});
    $db->do('CREATE TABLE CHANSET_LIST(id_chanset_list INTEGER PRIMARY KEY,chanset TEXT UNIQUE COLLATE NOCASE)');
    $db->do('CREATE TABLE CHANNEL(id_channel INTEGER PRIMARY KEY,name TEXT UNIQUE COLLATE NOCASE)');
    $db->do('CREATE TABLE CHANNEL_SET(id_channel_set INTEGER PRIMARY KEY,id_channel INTEGER,id_chanset_list INTEGER)');
    $db->do("INSERT INTO CHANNEL VALUES(1,'#test'),(2,'#other')");
    return bless {dbh=>$db, logger=>bless({},'MB1020::Log'), loop=>bless({},'MB1020::Loop'),
        channels=>{'#test'=>Mediabot::Channel->new({dbh=>$db,id=>1,name=>'#test'})}}, 'MB1020::Bot';
}
sub enable_1395 {
    my ($b, $channel) = @_;
    $p->can('register_chanset')->($b);
    $b->{dbh}->do('INSERT INTO CHANNEL_SET(id_channel,id_chanset_list) SELECT C.id_channel,L.id_chanset_list FROM CHANNEL C,CHANSET_LIST L WHERE C.name=? AND L.chanset=?',undef,$channel//'#test','MixCloud');
}
sub command_1395 {
    my ($b, $arg, $admin, $auth) = @_;
    my $ctx = Mediabot::Context->new(bot=>$b,nick=>'Owner',channel=>'#test',command=>'chanset',args=>[$arg]);
    $ctx->{user}=bless {admin=>$admin//1,auth=>$auth//1}, 'MB1020::Principal';
    $ctx->{_user_fetched}=1;
    no warnings qw(redefine once);
    local *Mediabot::ChannelCommands::checkUserChannelLevel = sub {0};
    local *Mediabot::ChannelCommands::logBot = sub {1};
    local *Mediabot::ChannelCommands::botNotice = sub {1};
    return Mediabot::ChannelCommands::channelSet_ctx($ctx);
}
sub handle_1395 { my ($b,$u,$ch)=@_; return $p->can('handle')->($b,undef,'Listener',$ch//'#test',$u//$url) }
sub plain_1395 { my $s=shift; $s=~s/\x03[0-9]{0,2}(?:,[0-9]{1,2})?//g; $s=~s/[\x02\x0f]//g; return $s }
sub controlled_1395 {
    my ($cb)=@_;
    my $b=bot_1395(); enable_1395($b); my (@jobs,@sent);
    no warnings qw(redefine once);
    local *Mediabot::AsyncWorker::start = sub {my ($class,%a)=@_; push @jobs,\%a; return bless {},'MB1020::Worker'};
    local *Mediabot::Helpers::botPrivmsg = sub {push @sent,[@_[1..3]];1};
    return $cb->($b,\@jobs,\@sent);
}
{
    my @urls=($url,$url.'?utm_source=clipboard&utm_term=secret#player',
        'http://mixcloud.com/leekid/shut-up-and-dance','https://m.mixcloud.com/leekid/shut-up-and-dance/');
    is_deeply([map {info_1395($_)} @urls],[(info_1395()) x @urls],
        'shared links and official host aliases use the same HTTPS show and cache identity without tracking');
}
{
    my @bad=('https://mixcloud.com.evil/leekid/show/','https://evilmixcloud.com/leekid/show/',
        'https://example.test/?u='.$url,'file://mixcloud.com/leekid/show/',
        'https://user:pass@mixcloud.com/leekid/show/','https://mixcloud.com:444/leekid/show/',
        'https://mixcloud.com:bad/leekid/show/','https://mixcloud.com/leekid/',
        'https://mixcloud.com/leekid/show/embed/','https://mixcloud.com/genres/house/',
        'https://mixcloud.com/leekid/%2f%2e%2e/','https://mixcloud.com/leekid/show%0a/',[],undef);
    is_deeply([map {defined(info_1395($_))?1:0} @bad],[(0) x @bad],
        'credentials, spoofed hosts, non-default ports, nested paths, controls and non-show pages cannot reach HTTP');
}
{
    my $b=bot_1395(); my @sql; $b->{dbh}->sqlite_trace(sub {push @sql,$_[0]});
    command_1395($b,'+MixCloud',0,1); command_1395($b,'+MixCloud',1,0);
    my $unauthorized=$b->{dbh}->selectrow_array('SELECT COUNT(*) FROM CHANSET_LIST');
    command_1395($b,'+mixcloud'); command_1395($b,'+MixCloud');
    my @on=($p->can('enabled')->($b,'#TEST'),$p->can('enabled')->($b,'#other'),$p->can('epoch')->($b,'#test'));
    command_1395($b,'-MIXCLOUD');
    is_deeply([$unauthorized,\@on,$p->can('enabled')->($b,'#test'),$p->can('epoch')->($b,'#test'),
        $b->{dbh}->selectrow_array('SELECT COUNT(*) FROM CHANSET_LIST'),scalar(grep {/\A\s*(?:CREATE|ALTER|DROP|TRUNCATE)\b/i} @sql)],
        [0,[1,0,1],0,2,1,0], 'native authorized chanset registers once, keeps channel scope and revokes without schema changes');
}
{
    my $b=bot_1395(); my @off=($p->can('enabled')->($b,'#test'),$p->can('enabled')->({},'#test'));
    enable_1395($b); $b->{dbh}->do('DROP TABLE CHANNEL_SET');
    push @off,$p->can('enabled')->($b,'#test');
    is_deeply(\@off,[0,0,0],'missing catalogue, missing database and SQL failure are off');
}
{
    my $unicode={%$data,name=>'L’été étoilé 🎶',user=>{name=>'Créateur'}};
    my $bytes=$json->encode($unicode); my $text=Encode::decode('UTF-8',$bytes);
    is_deeply([map {$p->can('parse_show')->($_,info_1395())} ($bytes,$text)],
        [({state=>'ok',title=>$unicode->{name},author=>'Créateur',seconds=>7576}) x 2],
        'API metadata decodes bytes or characters once and keeps international titles and author names');
}
{
    my @invalid=({},[],{%$data,key=>'/someone/else/'},{%$data,url=>'https://evil.test/leekid/show/'},
        {%$data,name=>[]},{%$data,error=>{message=>'private upstream error'}});
    my @results=map {$p->can('parse_show')->($json->encode($_),info_1395())} @invalid;
    push @results,$p->can('parse_show')->('{bad',info_1395()),$p->can('parse_show')->(' 'x(256*1024+1),info_1395());
    is_deeply(\@results,[(undef) x @results], 'malformed, excessive, foreign or mismatched show data cannot manufacture a title');
}
{
    my (@opts,@calls,@results);
    no warnings qw(redefine once);
    local *HTTP::Tiny::new = sub {my ($class,%o)=@_; push @opts,\%o; return bless {calls=>\@calls,response=>shift @results},'MB1020::HTTP'};
    @results=({success=>1,content=>$json->encode($data)},{success=>0,status=>302},{success=>0,status=>429});
    my @got=map {$p->can('fetch')->($url.'?utm_source=clipboard')} 1..3;
    my $safe=!grep {$_->{timeout}!=8 || $_->{max_size}!=262144 || $_->{max_redirect}!=0 || !$_->{verify_SSL}} @opts;
    is_deeply([\@got,[map {$_->[0]} @calls],$safe?1:0],
        [[$good,{state=>'unavailable'},{state=>'unavailable'}],[('https://api.mixcloud.com'.$key) x 3],1],
        'fetch uses one fixed HTTPS API request with TLS, byte/time limits and no redirects or rate-limit retries');
}
{
    my $line=$p->can('render')->('Listener',$good);
    my $long=$p->can('render')->('🎶'x80,{state=>'ok',title=>"\x01ACTION\r\n".('é🎶'x500),author=>'🎶'x80,seconds=>'NaN'});
    my $clean=plain_1395($long);
    is_deeply([plain_1395($line),_irc_wire_bytes($long)<=400?1:0,$clean=~/[\x00-\x1f\x7f]/?1:0],
        ['(Listener) [🎛️ MixCloud] Shut Up And Dance ! — Leekid · 2h06m16s',1,0],
        'deck badge, title, creator and duration fit one bounded sanitized UTF-8 IRC line');
}
{
    my $b=bot_1395(); my ($generic,$jobs)=(0,0);
    no warnings qw(redefine once);
    local *Mediabot::External::_chanset_ok = sub {1};
    local *Mediabot::External::URL::_handle_generic_title = sub {++$generic;1};
    local *Mediabot::AsyncWorker::start = sub {++$jobs;1};
    Mediabot::External::displayUrlTitle($b,undef,'Listener','#test',$url);
    enable_1395($b); command_1395($b,'-MixCloud');
    Mediabot::External::displayUrlTitle($b,undef,'Listener','#test',$url);
    Mediabot::External::displayUrlTitle($b,undef,'Listener','#test','https://example.test/public');
    is_deeply([$generic,$jobs],[1,0], 'disabled MixCloud never falls through to UrlTitle while unrelated generic URLs retain their handler');
}
{
    my ($fh,$path)=tempfile(UNLINK=>1); close $fh;
    my $b=bot_1395(); enable_1395($b); $b->{loop}=IO::Async::Loop->really_new;
    my @sent; my $parent=$$; my $http=bless {calls=>[],path=>$path,response=>{success=>1,content=>$json->encode($data)}},'MB1020::HTTP';
    no warnings qw(redefine once);
    local *HTTP::Tiny::new = sub {$http};
    local *Mediabot::External::_chanset_ok = sub {die 'MixCloud must not depend on UrlTitle'};
    local *Mediabot::Helpers::botPrivmsg = sub {push @sent,[$_[1],plain_1395($_[2])];1};
    my $handled=Mediabot::External::displayUrlTitle($b,undef,'Listener','#test',$url.'?utm_source=clipboard');
    my $before=scalar @sent;
    my $deadline=Time::HiRes::time()+8;
    $b->{loop}->loop_once(.01) while keys(%{$b->{_mixcloud_preview}{pending}}) && Time::HiRes::time()<$deadline;
    open my $read,'<:raw',$path or die $!; my @calls=map {JSON::PP::decode_json($_)} <$read>; close $read;
    is_deeply([$handled,$before,\@sent,scalar @calls,
        @calls && $calls[0]{pid}!=$parent ? 1:0,scalar keys %{$b->{_mixcloud_preview}{pending}}],
        [1,0,[['#test','(Listener) [🎛️ MixCloud] Shut Up And Dance ! — Leekid · 2h06m16s']],1,1,0],
        'native URL dispatcher and actual AsyncWorker fetch outside the IRC process and deliver exactly one public preview');
}
{
    my @counts;
    for my $case (qw(disable toggle disconnect reconnect part quit)) {
        push @counts,controlled_1395(sub {
            my ($b,$jobs,$sent)=@_;
            $b->{irc}=bless {},'MB1020::IRC';
            $b->{wit_runtime_state}=bless {generation=>1},'MB1020::Runtime';
            handle_1395($b);
            command_1395($b,'-MixCloud') if $case eq 'disable' || $case eq 'toggle';
            command_1395($b,'+MixCloud') if $case eq 'toggle';
            delete $b->{irc} if $case eq 'disconnect';
            $b->{irc}=bless {},'MB1020::IRC' if $case eq 'reconnect';
            $b->{wit_runtime_state}{generation}=2 if $case eq 'part';
            $b->{quit}=1 if $case eq 'quit';
            $jobs->[0]{on_done}->({ok=>1,value=>$good});
            return scalar @$sent;
        });
    }
    is_deeply(\@counts,[(0)x6],'pending replies are revoked after disable, off/on, transport replacement, part or shutdown');
}
{
    my $actual=controlled_1395(sub {
        my ($b,$jobs,$sent)=@_; enable_1395($b,'#other');
        handle_1395($b); handle_1395($b,$url.'?utm_source=other','#TEST'); handle_1395($b,$url,'#other');
        my $started=@$jobs;
        $jobs->[0]{on_done}->({ok=>1,value=>$good});
        $jobs->[0]{on_done}->({ok=>1,value=>$good});
        delete $b->{_mixcloud_preview}{recent}{'#other' . "\0".$key};
        handle_1395($b,$url,'#other');
        return [$started,scalar @$jobs,scalar @$sent,scalar keys %{$b->{_mixcloud_preview}{pending}}];
    });
    is_deeply($actual,[1,1,3,0],'canonical duplicates share one pending request, channels retain separate delivery and cache avoids refetch');
}
{
    my $actual=controlled_1395(sub {
        my ($b,$jobs,$sent)=@_;
        handle_1395($b,'https://mixcloud.com/u/show'.$_.'/') for 1..5;
        my $pending=keys %{$b->{_mixcloud_preview}{pending}};
        $_->{on_done}->({ok=>0,error=>'PRIVATE_FAILURE'}) for @$jobs;
        for my $i (6..14) {
            handle_1395($b,'https://mixcloud.com/u/show'.$i.'/');
            $jobs->[-1]{on_done}->({ok=>0}) if @$jobs;
        }
        return [$pending,scalar @$jobs,scalar keys %{$b->{_mixcloud_preview}{pending}},
            scalar(grep {plain_1395($_->[1]) =~ /aperçu indisponible/} @$sent),
            scalar(grep {$_->[1] =~ /PRIVATE_FAILURE/} @$sent)];
    });
    is_deeply($actual,[4,12,0,12,0],'concurrency and start rate are bounded and worker failures release ownership without exposing diagnostics');
}
{
    require MB938ChannelDiagnosticFixture;
    my ($b,$db)=MB938ChannelDiagnosticFixture::setup();
    $p->can('register_chanset')->($b);
    $db->do("INSERT INTO CHANNEL_SET(id_channel,id_chanset_list) SELECT 7,id_chanset_list FROM CHANSET_LIST WHERE chanset='MixCloud'");
    my $report=Mediabot::Diagnostics::Channel->new(bot=>$b)->collect('#test');
    my ($fh,$path)=tempfile(UNLINK=>1); binmode $fh,':raw'; print {$fh} $json->encode($report); close $fh;
    my $script=q{const fs=require('node:fs');const m=require('./contrib/mbweb/lib/channelDiagnostics');const r=JSON.parse(fs.readFileSync(process.argv[1],'utf8'));const on=m.projectReport(r,7,'#test').flags.MixCloud;delete r.flags.MixCloud;const old=m.projectReport(r,7,'#test').flags.MixCloud;process.stdout.write(JSON.stringify([on,old]));};
    open my $node,'-|','node','-e',$script,$path or die $!;
    my $out=do {local $/;<$node>}; close $node or die 'Node projection failed';
    is_deeply(JSON::PP::decode_json($out),['on','unknown'],
        'native diagnostic and web projection expose MixCloud and retain compatibility with older publications');
}
done_testing;

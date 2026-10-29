use strict;
use warnings;
use utf8;
use Test::More;
use DBI;
use JSON::PP ();
use Encode qw(encode decode);
use File::Temp qw(tempfile);
use IO::Async::Loop;
use Time::HiRes ();
use Mediabot::External ();
use Mediabot::External::MixCloud ();
use Mediabot::IRC::TextBudget qw(_irc_wire_bytes);

binmode Test::More->builder->output, ':encoding(UTF-8)';
binmode Test::More->builder->failure_output, ':encoding(UTF-8)';
{
    package MB1021::Log; sub log {1}
    package MB1021::Bot; sub getLoop {$_[0]{loop}} sub getQuit {$_[0]{quit}//0}
    package MB1021::Loop; sub add {1} sub remove {1} sub watch_process {1}
    package MB1021::IRC; sub is_connected {1}
    package MB1021::HTTP;
    sub get {
        my ($s,$url)=@_; push @{$s->{calls}},$url;
        if ($s->{path}) {
            open my $f,'>>:raw',$s->{path} or die $!;
            print {$f} JSON::PP::encode_json({url=>$url,pid=>$$})."\n" or die $!;
            close $f or die $!;
        }
        return $s->{response}->($url);
    }
}
my $pkg='Mediabot::External::MixCloud';
my $url='https://www.mixcloud.com/leekid/';
my $show=$url.'shut-up-and-dance/';
my $json=JSON::PP->new->canonical->utf8;
my $data={key=>'/leekid/',url=>$url,name=>'Leekid',username=>'leekid',city=>'Sw',country=>'France',
    follower_count=>1089,cloudcast_count=>49,biog=>'Sets vinyles &amp; archives.'};
my $good={state=>'ok',kind=>'profile',title=>'Leekid',location=>'Sw, France',followers=>1089,shows=>49,biog=>'Sets vinyles & archives.'};
my $showdata={key=>'/leekid/shut-up-and-dance/',url=>$show,name=>'Shut Up And Dance !',user=>{name=>'Leekid'},audio_length=>7576};
my $showgood={state=>'ok',title=>'Shut Up And Dance !',author=>'Leekid',seconds=>7576};
sub call_1396 {my ($name,@args)=@_;my $code=$pkg->can($name);return $code ? $code->(@args) : undef}
sub plain_1396 {my $s=shift;$s=~s/\x03[0-9]{0,2}(?:,[0-9]{1,2})?//g;$s=~s/[\x02\x0f]//g;return $s}
sub bot_1396 {
    my $db=DBI->connect('dbi:SQLite:dbname=:memory:','','',{RaiseError=>1,PrintError=>0});
    $db->do('CREATE TABLE CHANSET_LIST(id_chanset_list INTEGER PRIMARY KEY,chanset TEXT UNIQUE)');
    $db->do('CREATE TABLE CHANNEL(id_channel INTEGER PRIMARY KEY,name TEXT COLLATE NOCASE)');
    $db->do('CREATE TABLE CHANNEL_SET(id_channel_set INTEGER PRIMARY KEY,id_channel INTEGER,id_chanset_list INTEGER)');
    $db->do("INSERT INTO CHANNEL VALUES(1,'#test'),(2,'#other')");
    call_1396('register_chanset',{dbh=>$db});
    $db->do("INSERT INTO CHANNEL_SET(id_channel,id_chanset_list) SELECT 1,id_chanset_list FROM CHANSET_LIST WHERE chanset='MixCloud'");
    return bless {dbh=>$db,logger=>bless({},'MB1021::Log'),loop=>bless({},'MB1021::Loop')},'MB1021::Bot';
}
sub handle_1396 {my ($b,$u,$ch)=@_;return call_1396('handle',$b,undef,'Reader',$ch//'#test',$u//$url)}
sub controlled_1396 {
    my ($code)=@_;my $b=bot_1396();my (@jobs,@sent);
    no warnings qw(redefine once);
    local *Mediabot::AsyncWorker::start=sub {my ($class,%args)=@_;push @jobs,\%args;bless {},'MB1021::Worker'};
    local *Mediabot::Helpers::botPrivmsg=sub {push @sent,plain_1396($_[2]);1};
    return $code->($b,\@jobs,\@sent);
}
{
    my @links=($url,'http://mixcloud.com/leekid','https://m.mixcloud.com/leekid/?utm_source=share#player');
    my $expected={kind=>'profile',key=>'/leekid/',url=>$url,api=>'https://api.mixcloud.com/leekid/'};
    is_deeply([map {call_1396('link_info',$_)} @links],[($expected)x3],
        'profile links, aliases and share queries have one canonical identity distinct from mixes');
}
{
    my @bad=('https://mixcloud.com/','https://mixcloud.com/login/','https://mixcloud.com/%6cogin/',
        'https://mixcloud.com/genres/','https://mixcloud.com/leekid/playlists/favorites/',
        'https://mixcloud.com.evil/leekid/','https://example.test/?u='.$url,'file://mixcloud.com/leekid/',
        'https://user:pass@mixcloud.com/leekid/','https://mixcloud.com:444/leekid/',
        'https://mixcloud.com/%0a/','https://mixcloud.com/%2f/','https://mixcloud.com/%2e%2e/',[],undef);
    is_deeply([map {defined(call_1396('profile_info',$_))?1:0} @bad],[(0)x@bad],
        'reserved site pages, nested paths, unsafe hosts, credentials, ports and encoded controls are not profiles');
}
{
    my $info=call_1396('profile_info',$url);
    my $utf={%$data,name=>'L’été 🎶',city=>'Évry',country=>'France',follower_count=>0,cloudcast_count=>0};
    my $raw=$json->encode($utf);
    my $expected={%$good,title=>'L’été 🎶',location=>'Évry, France',followers=>0,shows=>0};
    my $minimal={key=>'/leekid/',name=>'',username=>'leekid',follower_count=>[],cloudcast_count=>'-1',biog=>[],city=>{}};
    is_deeply([call_1396('parse_profile',$json->encode($data),$info),
        call_1396('parse_profile',$raw,$info),call_1396('parse_profile',decode('UTF-8',$raw),$info),
        call_1396('parse_profile',$json->encode($minimal),$info)],
        [$good,$expected,$expected,{state=>'ok',kind=>'profile',title=>'leekid'}],
        'profile parser retains Unicode and real zero totals, falls back to username and omits unavailable optional data');
}
{
    my $info=call_1396('profile_info',$url);
    my @bad=({},[],{%$data,key=>'/other/'},{%$data,url=>$show},{%$data,url=>'https://evil.test/leekid/'},
        {%$data,name=>[],username=>[]},{%$data,error=>{message=>'private provider text'}});
    my @got=map {scalar call_1396('parse_profile',$json->encode($_),$info)} @bad;
    push @got,scalar call_1396('parse_profile','{bad',$info),scalar call_1396('parse_profile',' 'x(256*1024+1),$info);
    is_deeply(\@got,[(undef)x(@bad+2)],'only the exact requested public profile can supply bounded valid metadata');
}
{
    my (@calls,@options);
    no warnings qw(redefine once);
    my $http=bless {calls=>\@calls,response=>sub {return {success=>1,content=>$json->encode($_[0] eq 'https://api.mixcloud.com/leekid/' ? $data : $showdata)}}},'MB1021::HTTP';
    local *HTTP::Tiny::new=sub {my ($class,%args)=@_;push @options,\%args;$http};
    my @got=(call_1396('fetch',$url.'?utm_source=share'),call_1396('fetch',$show));
    my $safe=!grep {$_->{timeout}!=8 || $_->{max_size}!=262144 || $_->{max_redirect}!=0 || !$_->{verify_SSL}} @options;
    is_deeply([\@got,\@calls,$safe?1:0],[[$good,$showgood],['https://api.mixcloud.com/leekid/','https://api.mixcloud.com/leekid/shut-up-and-dance/'],1],
        'profiles and mixes each use their own single public API request with the original HTTP limits');
}
{
    my $long=call_1396('render','🎶'x80,{%$good,title=>'é🎶'x400,location=>'🎶'x100,
        biog=>"\x01ACTION\r\n".('é🎶'x500),followers=>'9999999999',shows=>'9999999999'});
    is_deeply([plain_1396(call_1396('render','Reader',$good)),_irc_wire_bytes($long)<=400?1:0,
        plain_1396($long)=~/[\x00-\x1f\x7f]/?1:0,plain_1396(call_1396('render','Reader',$showgood))],
        ['(Reader) [🎛️ MixCloud] Leekid · Profil · Sw, France · 49 mixes · 1 089 abonnés — Sets vinyles & archives.',1,0,
         '(Reader) [🎛️ MixCloud] Shut Up And Dance ! — Leekid · 2h06m16s'],
        'compact profile has biography, location and grouped counts within 400 UTF-8 bytes; mix rendering is unchanged');
}
{
    my $b=bot_1396();$b->{loop}=IO::Async::Loop->really_new;
    my ($fh,$path)=tempfile(UNLINK=>1);close $fh;my (@sent,@calls);
    my $http=bless {calls=>\@calls,path=>$path,response=>sub {return {success=>1,content=>$json->encode($_[0] eq 'https://api.mixcloud.com/leekid/' ? $data : $showdata)}}},'MB1021::HTTP';
    no warnings qw(redefine once);
    local *HTTP::Tiny::new=sub {$http};
    local *Mediabot::Helpers::botPrivmsg=sub {push @sent,[$_[1],plain_1396($_[2])];1};
    my @handled=map {Mediabot::External::displayUrlTitle($b,undef,'Reader','#test',$_)} ($url,$show);
    my $before=scalar @sent;my $deadline=Time::HiRes::time()+8;
    $b->{loop}->loop_once(.01) while keys(%{$b->{_mixcloud_preview}{pending}//{}}) && Time::HiRes::time()<$deadline;
    open my $read,'<:raw',$path or die $!;my @http=map {JSON::PP::decode_json($_)} <$read>;close $read;
    is_deeply([\@handled,$before,[sort map {$_->[1]} @sent],scalar @http,scalar(grep {$_->{pid}==$$} @http),
        scalar(grep {$_->[0] ne '#test'} @sent),scalar keys %{$b->{_mixcloud_preview}{pending}//{}}],
        [[1,1],0,[sort map {plain_1396(call_1396('render','Reader',$_))} ($good,$showgood)],2,0,0,0],
        'real dispatcher and supervised workers publish both profile and mix, with no parent HTTP or cache collision');
}
{
    my $actual=controlled_1396(sub {
        my ($b,$jobs,$sent)=@_;
        handle_1396($b,$url);handle_1396($b,$url.'?utm_source=share');handle_1396($b,$show);
        my $started=@$jobs;
        if ($started==2) {$jobs->[0]{on_done}->({ok=>1,value=>$good});$jobs->[1]{on_done}->({ok=>1,value=>$showgood})}
        my $distinct=keys %{$b->{_mixcloud_preview}{cache}//{}};
        $b->{_mixcloud_preview}{recent}={};handle_1396($b,$url);handle_1396($b,$show);
        return [$started,scalar @$jobs,scalar @$sent,$distinct];
    });
    my @revoked;
    for my $case (qw(disable toggle reconnect quit)) {
        push @revoked,controlled_1396(sub {
            my ($b,$jobs,$sent)=@_;$b->{irc}=bless {},'MB1021::IRC';handle_1396($b,$url);
            if ($case eq 'disable' || $case eq 'toggle') {
                $b->{dbh}->do('DELETE FROM CHANNEL_SET');call_1396('note_policy_change',$b,'#test');
                if ($case eq 'toggle') {
                    $b->{dbh}->do("INSERT INTO CHANNEL_SET(id_channel,id_chanset_list) SELECT 1,id_chanset_list FROM CHANSET_LIST WHERE chanset='MixCloud'");
                    call_1396('note_policy_change',$b,'#test');
                }
            }
            $b->{irc}=bless {},'MB1021::IRC' if $case eq 'reconnect';
            $b->{quit}=1 if $case eq 'quit';
            $_->{on_done}->({ok=>1,value=>$good}) for @$jobs;
            return [scalar @$jobs,scalar @$sent];
        });
    }
    is_deeply([$actual,\@revoked],[[2,2,4,2],[[1,0],[1,0],[1,0],[1,0]]],
        'shared profile queries deduplicate without hiding mixes, caches remain distinct and pending profile replies respect revocation');
}
done_testing;

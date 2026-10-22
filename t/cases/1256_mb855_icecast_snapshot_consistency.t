use strict;
use warnings;
use utf8;
use lib '.', 't/lib';
use Test::More;
use JSON::PP ();
use Mediabot::Radio::Icecast;

{
    package MB855SequenceHTTP;
    sub new { my ($class, @responses) = @_; bless {responses=>\@responses, urls=>[]}, $class }
    sub get {
        my ($self, $url) = @_;
        push @{$self->{urls}}, $url;
        return shift(@{$self->{responses}}) || {success=>0, status=>503, reason=>'unexpected extra fetch'};
    }
}
sub snapshot {
    my ($name, $first, $second, $single) = @_;
    my @mounts = (
        {listenurl=>'http://127.0.0.1:8000/radio.mp3', title=>"Björk — $name 🧭",
         listeners=>$first, bitrate=>'128.9', server_description=>"Émission $name", server_url=>'https://station.example/'},
        {listenurl=>'http://127.0.0.1:8000/aux.ogg', title=>"Archive $name", listeners=>$second, bitrate=>64},
    );
    return {success=>1, status=>200, content=>JSON::PP->new->utf8->encode({icestats=>{
        host=>"host-$name", server_id=>"server-$name", sources=>$single?1:2,
        listeners=>$first+($single?0:$second), admin=>'operator@example.test', location=>'Local',
        server_start_iso8601=>'2026-10-20T00:00:00Z', source=>$single?$mounts[0]:\@mounts,
    }})};
}
for my $method (qw(get_primary_mount_status get_summary)) {
    my $http = MB855SequenceHTTP->new(snapshot('first',12,3), snapshot('second',90,10),
        snapshot('third',200,7), snapshot('fourth',300,8));
    my $radio = Mediabot::Radio::Icecast->new(base_url=>'http://127.0.0.1:8000/', ua=>$http);
    my $result = $radio->$method(primary_mount=>'/radio.mp3', public_base=>'https://radio.example/');
    ok($result->{ok}, "$method: a valid status snapshot produces a successful aggregate");
    is($result->{host}, 'host-first', "$method: global server belongs to the first snapshot");
    is($result->{total_listeners},15,"$method: total listeners belong to that same snapshot");
    is($result->{mount_listeners},12,"$method: primary listeners belong to that same snapshot");
    is($result->{title},'Björk — first 🧭',"$method: title belongs to that same snapshot and retains Unicode");
    is($result->{description},'Émission first',"$method: selected metadata belongs to that snapshot");
    is($result->{bitrate},128,"$method: established numeric normalization remains");
    is($result->{listen_url},'https://radio.example/radio.mp3',"$method: configured public URL retains its shape");
    is_deeply($http->{urls},['http://127.0.0.1:8000/status-json.xsl'],"$method: one aggregate has one status request");
    if ($method eq 'get_summary') {
        is_deeply([map {$_->{mount}} @{$result->{mounts}||[]}],['/aux.ogg','/radio.mp3'],
            'summary: all mounts retain stable sorting');
        is_deeply([map {$_->{listeners}} @{$result->{mounts}||[]}],[3,12],
            'summary: detailed mounts agree with selected and total listeners');
    } else {
        is($result->{status_info}{raw}{host},'host-first','primary: existing raw global status remains available');
        is($result->{mount_info}{raw}{title},'Björk — first 🧭','primary: raw selected mount agrees with the aggregate');
    }
    # A new invocation must fetch again. This correction introduces no cache.
    my $fresh = $radio->$method(primary_mount=>'/radio.mp3');
    is($fresh->{host},'host-second',"$method: next call reads the next status, without a cache");
    is($fresh->{total_listeners},100,"$method: later snapshot totals replace the earlier ones");
}
for my $method (qw(get_primary_mount_status get_summary)) {
    my $http = MB855SequenceHTTP->new(snapshot('healthy',7,2),{success=>0,status=>503,reason=>'later outage'});
    my $radio = Mediabot::Radio::Icecast->new(ua=>$http);
    my $first = $radio->$method();
    ok($first->{ok},"$method: a later HTTP failure cannot discard the valid current observation");
    is(scalar @{$http->{urls}},1,"$method: current observation does not make the later failing request");
    my $later = $radio->$method();
    ok(!$later->{ok} && $later->{error}=~/503/,"$method: a subsequent real outage remains visible");
}
{
    my $http = MB855SequenceHTTP->new(snapshot('single',0,0,1));
    my $radio = Mediabot::Radio::Icecast->new(ua=>$http);
    my $result = $radio->get_summary(primary_mount=>'/missing.mp3');
    ok($result->{ok},'single HASH source remains supported');
    is($result->{primary_mount},'/radio.mp3','missing primary retains the existing first-mount fallback');
    is($result->{total_listeners},0,'explicit zero listeners remain zero');
    is(scalar @{$result->{mounts}||[]},1,'single source remains one detailed mount');
}
for my $method (qw(get_primary_mount_status get_summary)) {
    for my $case (
        ['http',{success=>0,status=>503,reason=>'temporary outage'},qr/HTTP error: 503/],
        ['empty',{success=>1,status=>200,content=>''},qr/Empty Icecast response/],
        ['json',{success=>1,status=>200,content=>'{not json'},qr/JSON decode failed/],
        ['structure',{success=>1,status=>200,content=>'[]'},qr/Invalid Icecast JSON structure/],
        ['no_mount',{success=>1,status=>200,content=>'{"icestats":{"host":"empty"}}'},qr/No Icecast mount available/],
    ) {
        my ($name,$response,$error)=@$case;
        my $http=MB855SequenceHTTP->new($response,snapshot('recovered',4,1));
        my $radio=Mediabot::Radio::Icecast->new(ua=>$http);
        my $failed=$radio->$method();
        ok(!$failed->{ok} && $failed->{error}=~$error,"$method/$name: existing failure remains explicit");
        is(scalar @{$http->{urls}},1,"$method/$name: failed observation performs no derived fetches");
        my $recovered=$radio->$method();
        ok($recovered->{ok} && $recovered->{host} eq 'host-recovered' && $recovered->{total_listeners}==5,
            "$method/$name: next valid response recovers without stale or partial state");
    }
}

# MB914: malformed optional metadata must not leak JSON references or infinities.
{
    require POSIX;
    my $number='9' x 400;
    my $finite='1'.('0' x 308);
    my $base=sub {return {host=>'station',sources=>1,source=>{
        listenurl=>'http://127.0.0.1:8000/radio.mp3',title=>'Björk 🦉',listeners=>12,bitrate=>128}}};
    my @vectors;
    {
        my $d=$base->();@$d{qw(host admin location server_id)}=({name=>'bad'},[],JSON::PP::true,{});
        $d->{server_start_iso8601}=[];$d->{server_start}='legacy date';
        push @vectors,['global_text',$d,sub {
            my ($r)=@_;my $s=$r->{get_status};
            return !grep(defined($s->{$_}),qw(host admin location server_id))
                && $s->{started} eq 'legacy date' && ref($s->{raw}{host}) eq 'HASH'
                && !defined($r->{get_summary}{host}) && !defined($r->{get_primary_mount_status}{server_id});
        }];
    }
    {
        my $d=$base->();my $s=$d->{source};
        @$s{qw(listenurl server_name title server_description server_url)}=({},'radio.mp3',[],{},[]);
        $s->{stream_start_iso8601}={};$s->{stream_start}='legacy mount date';
        push @vectors,['mount_text',$d,sub {
            my ($r)=@_;my $m=$r->{get_primary_mount_status}{mount_info};
            return $m->{mount} eq '/radio.mp3' && $m->{title} eq ''
                && !defined($m->{listenurl}) && !defined($m->{description}) && !defined($m->{server_url})
                && $m->{stream_start} eq 'legacy mount date' && ref($m->{raw}{title}) eq 'ARRAY'
                && $r->{get_now_playing}{title} eq '' && $r->{get_summary}{title} eq '';
        }];
    }
    {
        my $d=$base->();$d->{source}{listenurl}=[];$d->{source}{server_name}={name=>'bad'};
        push @vectors,['invalid_mount_identity',$d,sub {
            my ($r)=@_;my $m=$r->{get_mounts}{mounts}[0];
            return $m->{mount} eq '' && !defined($m->{server_name}) && !defined($m->{listenurl})
                && ref($m->{raw}{server_name}) eq 'HASH' && $r->{get_summary}{primary_mount} eq '';
        }];
    }
    {
        my $d=$base->();$d->{sources}=JSON::PP::true;$d->{listeners}=[];
        @{$d->{source}}{qw(bitrate samplerate channels listeners listener_peak)}=({},[],JSON::PP::true,{},[]);
        push @vectors,['numeric_references',$d,sub {
            my ($r)=@_;my $m=$r->{get_mounts}{mounts}[0];
            return $r->{get_status}{sources}==0 && $r->{get_status}{listeners}==0
                && !grep($_!=0,@$m{qw(bitrate samplerate channels listeners listener_peak)})
                && $r->{get_listeners}{total}==0 && $r->{get_summary}{total_listeners}==0;
        }];
    }
    {
        my $d=$base->();@$d{qw(sources listeners)}=($number,$number);
        @{$d->{source}}{qw(bitrate samplerate channels listeners listener_peak)}=($number) x 5;
        push @vectors,['nonfinite_conversion',$d,sub {
            my ($r)=@_;my $m=$r->{get_primary_mount_status}{mount_info};
            return $r->{get_status}{sources}==0 && $r->{get_status}{listeners}==0
                && !grep(!POSIX::isfinite($_) || $_!=0,@$m{qw(bitrate samplerate channels listeners listener_peak)})
                && $r->{get_summary}{mount_listeners}==0 && $r->{get_listeners}{total}==0;
        }];
    }
    {
        my $d=$base->();$d->{sources}=2;
        $d->{source}=[map {{listenurl=>"http://127.0.0.1:8000/$_.mp3",listeners=>$finite}} qw(one two)];
        push @vectors,['large_finite_compatibility',$d,sub {
            my ($r)=@_;
            return $r->{get_listeners}{total}==0 && $r->{get_summary}{total_listeners}==0
                && $r->{get_primary_mount_status}{total_listeners}==0
                && $r->{get_mounts}{mounts}[0]{listeners}==$finite
                && POSIX::isfinite($r->{get_primary_mount_status}{mount_listeners})
                && !grep(!POSIX::isfinite($_),values %{$r->{get_listeners}{per_mount}});
        }];
    }
    {
        my $d=$base->();$d->{sources}=2;
        $d->{source}=[$d->{source},{listenurl=>[],server_name=>{},title=>[],listeners=>$number},'invalid source'];
        push @vectors,['mixed_sources',$d,sub {
            my ($r)=@_;my $s=$r->{get_summary};
            return $s->{title} eq 'Björk 🦉' && $s->{primary_mount} eq '/radio.mp3'
                && $s->{total_listeners}==12 && @{$s->{mounts}}==2
                && !grep(ref($_->{title}) || $_->{mount}=~/HASH|ARRAY/,@{$s->{mounts}})
                && $r->{get_now_playing}{title} eq 'Björk 🦉';
        }];
    }
    {
        my $d=$base->();$d->{host}=0;$d->{source}{title}='0';$d->{source}{listeners}=0;
        push @vectors,['scalar_zero',$d,sub {
            my ($r)=@_;
            return defined($r->{get_status}{host}) && $r->{get_status}{host} eq '0'
                && $r->{get_summary}{title} eq '0' && $r->{get_listeners}{total}==0
                && $r->{get_now_playing}{title} eq '0';
        }];
    }
    my @methods=qw(get_status get_mounts get_listeners get_now_playing get_primary_mount_status get_summary);
    for my $v (@vectors) {
        my ($name,$doc,$check)=@$v;
        my $body=JSON::PP->new->utf8->encode({icestats=>$doc});
        my $http=MB855SequenceHTTP->new(map {{success=>1,status=>200,content=>$body}} @methods);
        my $radio=Mediabot::Radio::Icecast->new(ua=>$http);my (%results,@warnings,$error);
        {local $SIG{__WARN__}=sub {push @warnings,@_};
         eval {for my $method (@methods) {$results{$method}=$radio->$method()};1} or $error=$@ || 'public view failed';}
        my $same=!$error && !@warnings && @{$http->{urls}}==@methods
            && !grep(!$_ || !$_->{ok},values %results);
        $same &&= eval {$check->(\%results)};
        ok($same,"mb914: $name keeps all six public views usable from one snapshot per call")
            or diag("error=".($error//'')." warnings=".join(' ',@warnings));
    }
}
done_testing;

use strict;
use warnings;
use utf8;
use Test::More;
use File::Temp qw(tempdir);
use Fcntl qw(:DEFAULT :flock);
use POSIX ();
use Time::HiRes qw(alarm);
use JSON::PP ();
use Mediabot::URLShortener ();
use Mediabot::RSS::TinyURL ();

{
    package MB1052::HTTP;
    sub request {
        my ($self,undef,undef,$opts) = @_;
        $self->{calls}++;
        my $url = JSON::PP->new->utf8->decode($opts->{content})->{url};
        return $self->{failure} if $self->{failure};
        my $short = $self->{base}.'Abcdef23';
        my $body = $self->{legacy} ? {data=>{url=>$url,tiny_url=>$short}}
            : {protocol=>1,url=>$url,id=>'Abcdef23',short_url=>$short};
        return {success=>1,status=>201,content=>JSON::PP->new->utf8->encode($body)};
    }
}
sub bytes_1425 {
    open my $fh,'<:raw',$_[0] or die "read local state: $!";
    local $/;return <$fh>;
}
sub bounded_1425 {
    my ($code) = @_;
    local $SIG{ALRM} = sub {die "lock wait exceeded test bound\n"};
    my ($value,$ok);
    $ok = eval {alarm(1);$value=$code->();alarm(0);1};
    my $error=$@;alarm(0);
    return [$ok ? 1:0,$value,$error];
}
my @warnings;
local $SIG{__WARN__}=sub {push @warnings,@_};
for my $module ('Mediabot::URLShortener','Mediabot::RSS::TinyURL') {
    my $legacy = $module =~ /TinyURL/ ? 1:0;
    my $dir = tempdir(CLEANUP=>1);
    my $path = "$dir/state.json";
    my $base = $legacy ? 'https://tinyurl.com/' : 'https://fixture.example/shorturl/';
    my $http = bless {calls=>0,base=>$base,legacy=>$legacy},'MB1052::HTTP';
    my @events;
    my %opts = (api_key=>'a'x64,http=>$http,state_file=>$path,now=>1_800_000_000,
        on_event=>sub {push @events,$_[0]});
    @opts{qw(api_url public_base)}=($base.'api/v1/links',$base) unless $legacy;
    my $shorten=$module->can('shorten_url');
    my $original='https://article.example/first?x=1&y=%C3%A9#part';
    my $next='https://article.example/second?utm_source=fixture';
    is($shorten->($original,%opts),$base.'Abcdef23',"$module: uncontended shortening still persists a bound alias");
    my $before=bytes_1425($path);
    pipe(my $ready_r,my $ready_w) or die "ready pipe: $!";
    pipe(my $release_r,my $release_w) or die "release pipe: $!";
    my $pid=fork();die "fork: $!" unless defined $pid;
    if (!$pid) {
        close $ready_r;close $release_w;
        my $ok=eval {
            local $SIG{ALRM}=sub {die "lock holder safety timeout\n"};alarm(10);
            sysopen(my $lock,"$path.lock",O_RDWR) or die 'open lock';
            flock($lock,LOCK_EX) or die 'hold lock';
            syswrite($ready_w,'R')==1 or die 'signal ready';
            my $gate='';sysread($release_r,$gate,1)==1 or die 'wait for release';
            close $lock;alarm(0);1;
        };
        POSIX::_exit($ok?0:1);
    }
    close $ready_w;close $release_r;
    my $ready='';
    my $handshake=bounded_1425(sub {sysread($ready_r,$ready,1)});
    die 'lock holder did not become ready' unless $handshake->[0] && $ready eq 'R';
    @events=();
    my $busy=bounded_1425(sub {$shorten->($next,%opts)});
    is_deeply($busy,[1,$next,''],"$module: a held OS lock returns the exact original URL without waiting");
    is_deeply(\@events,[{kind=>'state_busy',level=>3,category=>'state_lock_busy',status=>0}],
        "$module: ordinary contention produces one bounded debug event");
    is($http->{calls},1,"$module: busy shared state never bypasses the lock with another HTTP call");
    is(bytes_1425($path),$before,"$module: another owner's cache and circuit bytes remain untouched");
    my $cached=bounded_1425(sub {$shorten->($original,%opts,on_event=>sub {die "event sink failed\n"})});
    is_deeply($cached,[1,$original,''],"$module: a busy cached URL and throwing observer remain safe fallbacks");
    is_deeply([sprintf('%04o',(stat($path))[2]&07777),sprintf('%04o',(stat("$path.lock"))[2]&07777)],
        ['0600','0600'],"$module: contention preserves private state and lock modes");
    sysopen(my $probe,"$path.lock",O_RDWR) or die 'open probe';
    ok(!flock($probe,LOCK_EX|LOCK_NB),"$module: the original process still owns its lock after fallback");
    close $probe;
    syswrite($release_w,'X');close $release_w;close $ready_r;
    waitpid($pid,0);
    is($?,0,"$module: the real lock holder exits cleanly after release");
    is_deeply(bounded_1425(sub {$shorten->($next,%opts)}),[1,$base.'Abcdef23',''],
        "$module: the next request recovers normally after the owner releases its lock");
    is($http->{calls},2,"$module: recovery performs exactly one new HTTP request");
    is($shorten->($next,%opts),$base.'Abcdef23',"$module: recovery populates the ordinary persistent cache");
    is($http->{calls},2,"$module: a recovered cache hit performs no HTTP request");
    @events=();
    $http->{failure}={success=>0,status=>503,reason=>'unavailable',headers=>{},content=>'{}'};
    my $third='https://article.example/third';
    is($shorten->($third,%opts),$third,"$module: a real provider failure still preserves the original URL");
    is_deeply([@{$events[0]}{qw(kind level category circuit_seconds)}],['failure',1,'service',600],
        "$module: actual service failures still open the existing circuit at failure severity");
    my $count=$http->{calls};
    is_deeply([$shorten->('https://article.example/fourth',%opts),$http->{calls}],
        ['https://article.example/fourth',$count],"$module: the existing circuit still suppresses HTTP retries");
    {
        my $fixture = tempdir(CLEANUP=>1);
        my $file = "$fixture/bounded.json";
        my $raw = '{"version":1,"cache":{},"circuit":{}}';
        no strict 'refs';
        local ${"${module}::MAX_STATE_BYTES"} = length($raw);
        for my $suffix ('', ' ') {
            open my $fh,'>:raw',$file or die "write fixture: $!";
            print {$fh} $raw.$suffix;close $fh;
            my ($state,$error)=$module->can('_read_state')->($file);
            is($error,length($suffix)?'state_too_large':undef,
                "$module: exact state byte limit and one-byte excess are distinguished");
            is(defined($state)?1:0,length($suffix)?0:1,
                "$module: only a size-compliant state is returned");
        }
    }
    # Real filesystem objects: the fallback must not wait, contact HTTP,
    # truncate the object, or change its permissions.
    for my $slot ('state', 'lock') {
        for my $kind ('fifo', 'directory', 'symlink') {
            my $fixture = tempdir(CLEANUP=>1);
            my $state = "$fixture/state.json";
            my $object = $slot eq 'state' ? $state : "$state.lock";
            if ($kind eq 'fifo') { POSIX::mkfifo($object,0640)==0 or die "mkfifo: $!" }
            elsif ($kind eq 'directory') { mkdir($object,0750) or die "mkdir: $!" }
            else { symlink('missing-target',$object) or die "symlink: $!" }
            my @before = lstat($object);
            my $calls = $http->{calls};
            @events=();
            is_deeply(bounded_1425(sub {$shorten->($next,%opts,state_file=>$state)}),
                [1,$next,''],"$module: $slot $kind returns original URL without waiting");
            is_deeply([$http->{calls},scalar(@events),$events[0]{kind}],
                [$calls,1,'state_error'],"$module: $slot $kind reports state failure without HTTP");
            my @after = lstat($object);
            is_deeply([@after[0,1,2]],[@before[0,1,2]],
                "$module: $slot $kind keeps its inode, type and permissions");
        }
    }
    my $formatted=$module->can('format_event')->({kind=>'state_busy',category=>'state_lock_busy',status=>0});
    like($formatted,qr/shared.*busy.*original URL/i,"$module: busy diagnostics explain the fallback without paths or credentials");
}
is_deeply(\@warnings,[],'real contention, recovery and service failure paths are warning-free');
done_testing;

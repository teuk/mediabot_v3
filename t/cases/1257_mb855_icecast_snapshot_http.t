use strict;
use warnings;
use utf8;
use lib '.', 't/lib';
use Test::More;
use File::Temp qw(tempdir);
use IO::Socket::INET;
use IO::Select;
use JSON::PP ();
use HTTP::Tiny;
use Mediabot::Radio::Icecast;

# A real loopback HTTP endpoint changes on every request. No Icecast service,
# external network, private configuration or installed stream is used.
my $dir = tempdir(CLEANUP=>1);
my $listener = IO::Socket::INET->new(LocalAddr=>'127.0.0.1', LocalPort=>0,
    Listen=>8, ReuseAddr=>1, Proto=>'tcp') or die $!;
my $port = $listener->sockport;
pipe(my $stop_read,my $stop_write) or die $!;
my $pid = fork(); die $! unless defined $pid;
if (!$pid) {
    close $stop_write;
    my $ok = eval {
        local $SIG{ALRM}=sub {die "local fixture deadline\n"}; alarm(15);
        open my $trace,'>',"$dir/requests" or die $!; $trace->autoflush(1);
        my $select=IO::Select->new($listener,$stop_read);my $sequence=0;
        LOOP: while (1) {
            for my $ready ($select->can_read(5)) {
                last LOOP if fileno($ready)==fileno($stop_read);
                my $client=$listener->accept or die $!;
                my $request=<$client> // ''; my $line;
                while (defined($line=<$client>)) {last if $line=~/^\r?\n$/}
                ++$sequence; print {$trace} "$sequence $request";
                my $payload=JSON::PP->new->utf8->encode({icestats=>{
                    host=>"snapshot-$sequence",sources=>2,source=>[
                        {listenurl=>"http://127.0.0.1:$port/radio.mp3",title=>"Émission 🧭 $sequence",listeners=>10*$sequence},
                        {listenurl=>"http://127.0.0.1:$port/aux.ogg",title=>"Other $sequence",listeners=>$sequence},
                    ]}});
                print {$client} "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ".length($payload)."\r\nConnection: close\r\n\r\n$payload" or die $!;
                close $client;
            }
        }
        alarm(0); close $trace;1;
    };
    close $listener; close $stop_read;
    require POSIX; POSIX::_exit($ok?0:1);
}
close $listener;close $stop_read;
my $reaped=0;
END {if ($pid && !$reaped) {close $stop_write if defined fileno($stop_write);waitpid($pid,0)}}
local @ENV{qw(http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy)};
local $ENV{no_proxy}='127.0.0.1'; local $ENV{NO_PROXY}='127.0.0.1';
my $ua=HTTP::Tiny->new(timeout=>2,max_size=>65536,verify_SSL=>1);
my $radio=Mediabot::Radio::Icecast->new(base_url=>"http://127.0.0.1:$port",ua=>$ua);
my $summary=$radio->get_summary(public_base=>'https://radio.example');
ok($summary->{ok},'summary succeeds over the real loopback HTTP transport');
is($summary->{host},'snapshot-1','wire summary starts with the first observation');
is($summary->{title},'Émission 🧭 1','wire title is from the same observation and decodes once');
is($summary->{total_listeners},11,'wire listener total agrees with that observation');
is_deeply([map {$_->{listeners}} @{$summary->{mounts}||[]}],[1,10],
    'wire detailed mounts agree with the summary total');
my $primary=$radio->get_primary_mount_status();
ok($primary->{ok},'a second aggregate also succeeds');
is($primary->{host},'snapshot-2','primary aggregate makes one fresh request after the summary');
is($primary->{title},'Émission 🧭 2','primary title comes from its fresh observation');
is($primary->{total_listeners},22,'primary listeners match its server and title');
is($primary->{status_info}{raw}{source}[0]{listeners},20,'raw and normalized views share the same observation');
my $mounts=$radio->get_mounts();
is($mounts->{mounts}[1]{title},'Émission 🧭 3','standalone mounts retain fresh observations');
my $listeners=$radio->get_listeners();
is_deeply($listeners->{per_mount},{'/aux.ogg'=>4,'/radio.mp3'=>40},'standalone per-mount listeners remain available');
is($listeners->{total},44,'standalone listener total retains its existing shape');
my $now_playing=$radio->get_now_playing();
is($now_playing->{per_mount}{'/radio.mp3'},'Émission 🧭 5','standalone now-playing remains fresh and preserves Unicode');
my $status=$radio->get_status();
is($status->{host},'snapshot-6','standalone status also makes one fresh request');
close $stop_write;waitpid($pid,0);$reaped=1;
is($? >> 8,0,'owned loopback HTTP server exits cleanly');
open my $trace,'<',"$dir/requests" or die $!;my @requests=<$trace>;close $trace;
is(scalar @requests,6,'six public calls issue exactly six HTTP requests');
ok(!grep(!/^\d+ GET \/status-json[.]xsl HTTP\/1[.]1\r?\n$/, @requests),
    'every observed request uses the existing Icecast status endpoint');
done_testing;

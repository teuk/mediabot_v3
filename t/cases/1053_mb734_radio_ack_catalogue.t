use strict;
use warnings;
use JSON::PP qw(decode_json);
use Mediabot::Liquidsoap;

return sub {
    my ($assert) = @_;
    for my $case (
        ["37\nEND\nBye!\nEND\n", 1, '37', 'request frame separated from quit'],
        ["0\r\nEND\r\n", 1, '0', 'CRLF and zero request id'],
        ["END\n", 1, '', 'empty queue is a complete reply'],
        ["ERROR: unknown queue\nEND\n", 0, 'ERROR: unknown queue', 'server error'],
        ["Unknown command\nEND\n", 0, 'Unknown command', 'legacy error'],
        ["No such command\nEND\n", 0, 'No such command', 'missing command'],
        ["Invalid command\nEND\n", 0, 'Invalid command', 'invalid command'],
        ["37\n", 0, 'incomplete Liquidsoap response', 'truncated acknowledgement'],
        ['', 0, 'incomplete Liquidsoap response', 'empty connection'],
        ["ENDING\n", 0, 'incomplete Liquidsoap response', 'terminator must be a line'],
        ["ERROR: failed\nEND\n37\nEND\n", 0, 'ERROR: failed', 'later success cannot mask failure'],
    ) {
        my ($ok,$body)=Mediabot::Liquidsoap::_decode_response($case->[0]);
        $assert->is($ok,$case->[1],"mb734: $case->[3] status");
        $assert->is($body,$case->[2],"mb734: $case->[3] body");
    }
    {
        no warnings 'redefine';
        my $reply;
        local *Mediabot::Liquidsoap::command = sub { (1,$reply) };
        my $liq=Mediabot::Liquidsoap->new;
        for my $case (['37',1],['0',1],['-1',0],['OK',0],['',0],['37 38',0],['37x',0]) {
            $reply=$case->[0];
            my($ok)=$liq->push('/fixture/track.mp3');
            $assert->is($ok,$case->[1],"mb734: push acknowledges only a request id ($reply)");
        }
    }
    my $probe=<<'PROBE';
BEGIN {
    $INC{'IO/Async/Timer/Countdown.pm'}=__FILE__;
    package IO::Async::Timer::Countdown; sub import {}
    $INC{'DBI.pm'}=__FILE__;
    package DBI; our $errstr=''; sub import {}
    $INC{'Mediabot/Helpers.pm'}=__FILE__;
    package Mediabot::Helpers;
    sub import {
        my ($class,@names)=@_; my $caller=caller;
        no strict 'refs';
        for my $name (@names) { *{"${caller}::$name"}=sub {}; }
    }
}
use strict; use warnings;
use File::Temp qw(tempdir);
use JSON::PP qw(encode_json);
use Mediabot::Radio::Request;
{
    package RadioFixture;
    our @ISA=('Mediabot::Radio::Request');
    sub _metadata_from_info_json { ('abcdefghijk','Artist','Track') }
    sub _logger {}
    sub _say { push @{$_[0]{messages}},$_[2]; }
    sub _insert_mp3 {
        my($s)=@_;push @{$s->{events}},'catalogue';
        die "fixture SQL failure\n" if $s->{outcome} eq 'exception';
        return $s->{outcome} eq 'failure' ? undef : 7;
    }
    sub _liquidsoap_client { my($s)=@_;push @{$s->{events}},'client';bless {parent=>$s},'QueueFixture' }
    package QueueFixture;
    sub push { my($s)=@_;push @{$s->{parent}{events}},'push';return(1,'42'); }
    package ContextFixture;
    sub bot { {} } sub nick { 'guest' } sub message { undef } sub channel { '#test' }
}
my $dir=tempdir(CLEANUP=>1);
my $mp3="$dir/track.mp3";
open my $audio,'>',$mp3 or die $!;print {$audio} 'fixture';close $audio;
my @result;
for my $outcome(qw(failure exception success)) {
    my $out="$dir/$outcome.out";my $err="$dir/$outcome.err";
    open my $fh,'>',$out or die $!;print {$fh} "$mp3\n";close $fh;
    open $fh,'>',$err or die $!;close $fh;
    my $s=bless {bot=>{},outcome=>$outcome,events=>[],messages=>[]},'RadioFixture';
    $s->_finish_download(ctx=>bless({},'ContextFixture'),query=>'fixture',id_user=>0,
                         stdout=>$out,stderr=>$err,exitcode=>0,timedout=>0);
    push @result,{events=>$s->{events},messages=>$s->{messages},file_kept=>(-f $mp3?1:0)};
}
{
    package ConfFixture;
    sub get { return $_[0]{$_[1]}; }
}
my $incoming=tempdir(CLEANUP=>1);
my $shared=bless {bot=>{conf=>bless({
    'radio.RADIO_DOWNLOAD_GROUP_READ'=>1,
    'radio.YOUTUBEDL_INCOMING'=>$incoming,
},'ConfFixture')},events=>[],messages=>[],outcome=>'success'},'RadioFixture';
my $file="$incoming/audio.mp3";
open my $f,'>',$file or die $!;print {$f} 'fixture';close $f;chmod 0600,$file;
my @permissions;
push @permissions,0+$shared->_prepare_download_permissions($file);
push @permissions,(stat($file))[2] & 0777;
my $link="$incoming/link.mp3";symlink $file,$link or die $!;
chmod 0600,$file;
push @permissions,0+$shared->_prepare_download_permissions($link);
push @permissions,(stat($file))[2] & 0777;
unlink $link;
my $hard="$incoming/hard.mp3";link $file,$hard or die $!;
push @permissions,0+$shared->_prepare_download_permissions($hard);
unlink $hard;
push @permissions,0+$shared->_prepare_download_permissions($mp3);
mkdir "$incoming/nested" or die $!;
my $nested="$incoming/nested/audio.mp3";
open $f,'>',$nested or die $!;close $f;
push @permissions,0+$shared->_prepare_download_permissions($nested);
my $off=bless {bot=>{}},'RadioFixture';
push @permissions,0+$off->_prepare_download_permissions($file);
push @permissions,(stat($file))[2] & 0777;
# A permissions refusal must stop before either the catalogue or the queue.
my $out="$dir/permissions.out";open $f,'>',$out or die $!;print {$f} "$mp3\n";close $f;
my $err="$dir/permissions.err";open $f,'>',$err or die $!;close $f;
$shared->_finish_download(ctx=>bless({},'ContextFixture'),query=>'fixture',id_user=>0,
                         stdout=>$out,stderr=>$err,exitcode=>0,timedout=>0);
print encode_json({catalogue=>\@result,permissions=>\@permissions,
    blocked_events=>$shared->{events},blocked_messages=>$shared->{messages}});
PROBE
    open my $fh,'-|',$^X,'-I.','-e',$probe or die $!;
    local $/;my $raw=<$fh>//'';close $fh;
    $assert->is($? >> 8,0,'mb734: isolated catalogue failure scenarios execute');
    my $decoded=eval { decode_json($raw) } || {};
    my $result=$decoded->{catalogue} || [];
    $assert->is(scalar(@$result),3,'mb734: failure, exception and success exercised');
    for my $i (0,1) {
        my $r=$result->[$i] || {};
        $assert->is(join(',',@{$r->{events}||[]}), 'catalogue', 'mb734: failed catalogue never contacts Liquidsoap');
        $assert->like(join(' ',@{$r->{messages}||[]}),qr/has not been queued/,'mb734: failed catalogue reported honestly');
        $assert->is($r->{file_kept},1,'mb734: downloaded file retained for recovery');
    }
    my $success=$result->[2] || {};
    $assert->is(join(',',@{$success->{events}||[]}), 'catalogue,client,push','mb734: successful catalogue precedes queue');
    $assert->like(join(' ',@{$success->{messages}||[]}),qr/downloaded, cached and queued/,'mb734: successful request remains available');
    my @expected=(1,0640,0,0600,0,0,0,1,0600);
    my @labels=('regular shared MP3 accepted','new shared MP3 is 0640',
        'symlink refused','symlink target untouched','hardlink refused',
        'outside incoming refused','nested path refused','default-off accepted',
        'default-off leaves permissions unchanged');
    for my $i (0..$#expected) {
        $assert->is(($decoded->{permissions}||[])->[$i],$expected[$i],"mb734: $labels[$i]");
    }
    $assert->is(scalar(@{$decoded->{blocked_events}||[]}),0,
        'mb734: failed sharing check contacts neither catalogue nor Liquidsoap');
    $assert->like(join(' ',@{$decoded->{blocked_messages}||[]}),qr/storage permissions.*not been queued/,
        'mb734: failed sharing check reported honestly');
};

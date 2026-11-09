use strict;
use warnings;
use File::Temp qw(tempdir);
use Fcntl qw(:flock :DEFAULT);
use Mediabot::RSS::Pacing;
use POSIX ();
use Time::HiRes qw(alarm);

return sub {
    my ($a) = @_;
    my $dir = tempdir(CLEANUP => 1);
    my $path = "$dir/state.json";
    my $now = 1000000;
    my $new = sub { Mediabot::RSS::Pacing->new(path => $path, now => sub {$now}) };
    my $p = $new->();
    $a->ok(!$p->status('#35+ans')->{active}, 'mb809: unconfigured channel retains legacy behavior');
    $a->ok(!-e $path && !-e "$path.lock", 'mb809: unconfigured status is read-only');
    $p->configure('#35+ans', gap => 180, daily => 3);
    $a->is((stat($path))[2] & 0777, 0600, 'mb809: state is private');
    $a->ok($p->reserve('#35+ans')->{allowed}, 'mb809: first fresh slot is allowed');
    $a->ok(!$new->()->reserve('#35+ANS')->{allowed}, 'mb809: restart / another feed shares the same cooldown');
    $a->is($p->status('#35+ans')->{wait}, 10800, 'mb809: channel-wide gap is three hours');
    $now += 10799;
    $a->ok(!$p->reserve('#35+ans')->{allowed}, 'mb809: slot cannot open one second early');
    $now++;
    $a->ok($p->reserve('#35+ans')->{allowed}, 'mb809: second slot opens at exact gap');
    $now += 10800;
    $a->ok($p->reserve('#35+ans')->{allowed}, 'mb809: third slot opens');
    $now += 10800;
    $a->ok(!$new->()->reserve('#35+ans')->{allowed}, 'mb809: fourth news blocked by rolling 24h quota after restart');
    $a->is($p->status('#35+ans')->{wait}, 54000, 'mb809: quota wait uses oldest of the three counted sends');
    $p->configure('#35+ans', gap => 240);
    $a->is($p->status('#35+ans')->{daily}, 3, 'mb809: partial update preserves daily cap');
    $a->is($p->status('#35+ans')->{used}, 3, 'mb809: updating limits never resets history');
    $now = 1086400;
    $a->ok($p->reserve('#35+ans')->{allowed}, 'mb809: first entry expires exactly after 24h');
    $a->is($p->status('#35+ans')->{used}, 3, 'mb809: two older slots plus new one count in rolling window');
    $p->configure('#other', gap => 60, daily => 1);
    $a->ok($p->reserve('#other')->{allowed}, 'mb809: another channel has independent quota');
    $a->ok(!$p->reserve('#35+ans')->{allowed}, 'mb809: other channel never unlocks protected channel');
    $now -= 60;
    $a->ok(!$p->reserve('#35+ans')->{allowed}, 'mb809: backwards clock cannot reset cooldown');
    my $before = do {open my $fh, '<', $path or die $!; local $/; <$fh>};
    for my $opt ({gap=>1}, {gap=>10081}, {daily=>25}, {daily=>-1}, {unknown=>3}) {
        $a->ok(!eval {$p->configure('#35+ans', %$opt); 1}, 'mb809: invalid setting rejected');
    }
    my $after = do {open my $fh, '<', $path or die $!; local $/; <$fh>};
    $a->is($after, $before, 'mb809: invalid settings leave state untouched');
    $p->configure('#35+ans', gap=>0, daily=>0);
    $a->ok(!$p->status('#35+ans')->{active}, 'mb809: both zero explicitly restore legacy mode');
    $p->configure('#35+ans', gap=>180, daily=>3);
    $a->ok(!$p->reserve('#35+ans')->{allowed}, 'mb809: off/on does not erase earlier attempts');
    sysopen(my $lock, "$path.lock", O_RDWR) or die $!;
    flock($lock, LOCK_EX) or die $!;
    $a->ok(!eval {$new->()->reserve('#35+ans'); 1}, 'mb809: simultaneous decision fails closed without blocking event loop');
    close $lock;
    open my $fh, '>', $path or die $!; print {$fh} '{broken'; close $fh;
    $a->ok(!eval {$new->()->reserve('#35+ans'); 1}, 'mb809: corrupt history cannot allow news');
    unlink $path;
    $a->ok(!eval {$new->()->status('#35+ans'); 1}, 'mb809: missing initialized state cannot disable limits');
    symlink "$dir/outside", $path or die $!;
    $a->ok(!eval {$new->()->status('#35+ans'); 1}, 'mb809: state symlink refused');
    # A broken state path must fail closed without blocking the IRC caller.
    for my $operation ('status', 'reserve', 'configure') {
        my $fixture = tempdir(CLEANUP=>1);
        my $state = "$fixture/state.json";
        POSIX::mkfifo($state,0640)==0 or die "mkfifo: $!";
        my @before=lstat($state);
        my $pacing=Mediabot::RSS::Pacing->new(path=>$state);
        my $error;
        {
            local $SIG{ALRM}=sub {die "test deadline exceeded\n"};
            eval {alarm(1);$pacing->$operation('#test');1};
            $error=$@;alarm(0);
        }
        $a->like($error,qr/RSS pacing state is not a regular file/,
            "mb1168: $operation rejects a FIFO immediately with the real state error");
        my @after=lstat($state);
        $a->is(join(':',@after[0,1,2]),join(':',@before[0,1,2]),
            "mb1168: $operation preserves the FIFO inode, type and mode");
    }
    {
        my $fixture=tempdir(CLEANUP=>1);
        my $state="$fixture/state.json";
        my $pacing=Mediabot::RSS::Pacing->new(path=>$state);
        $pacing->configure('#test',gap=>5,daily=>1);
        unlink "$state.lock" or die $!;
        POSIX::mkfifo("$state.lock",0640)==0 or die $!;
        $a->ok(!eval {$pacing->reserve('#test');1},'mb1168: FIFO lock cannot authorize a reservation');
        $a->is((lstat("$state.lock"))[2]&0777,0640,'mb1168: rejected lock permissions remain untouched');
    }
    {
        my $fixture=tempdir(CLEANUP=>1);
        my $state="$fixture/state.json";
        my $pacing=Mediabot::RSS::Pacing->new(path=>$state);
        $pacing->configure('#test',gap=>5,daily=>1);
        my $json='{"schema":1,"channels":{}}';
        for my $size (262144,262145) {
            open my $fh,'>:raw',$state or die $!;
            print {$fh} $json.(' 'x($size-length($json)));close $fh;
            my $ok=eval {$pacing->status('#test');1};
            $a->is($ok?1:0,$size==262144?1:0,'mb1168: state size boundary is enforced');
        }
    }

};

package Mediabot::NetworkStats;

use strict;
use warnings;
use Exporter 'import';
use JSON::PP ();
use File::Basename qw(dirname);
use File::Path qw(make_path);
use Fcntl qw(O_WRONLY O_CREAT O_EXCL O_NOFOLLOW);
our @EXPORT_OK = qw(parse_numeric);

# Counts only. Never persist raw IRC lines, nicknames, hosts or configuration.
sub parse_numeric {
    my ($n, $args, $text) = @_;
    $args = [] unless ref($args) eq 'ARRAY';
    $text = '' unless defined($text) && !ref($text) && length($text) <= 2048;
    my @nums = grep { defined($_) && !ref($_) && /\A[0-9]{1,9}\z/ } @$args;
    my %v;
    if ($n eq '251') {
        if ($text =~ /There are\s+([0-9]{1,9})\s+users?\s+and\s+([0-9]{1,9})\s+invisible\s+on\s+([0-9]{1,9})\s+servers?\b/i) {
            @v{qw(visible_users invisible_users servers)} = (0+$1,0+$2,0+$3);
            $v{users} = $v{visible_users} + $v{invisible_users};
        }
        # Some servers provide explicit numeric parameters instead of prose.
        elsif (@nums >= 3) {
            @v{qw(visible_users invisible_users servers)} = map { 0+$_ } @nums[0..2];
            $v{users} = $v{visible_users} + $v{invisible_users};
        }
    }
    elsif ($n eq '252' || $n eq '253' || $n eq '254') {
        $v{ {252=>'operators',253=>'unknown_connections',254=>'channels'}->{$n} } = 0+$nums[0] if @nums;
    }
    elsif ($n eq '255') {
        if ($text =~ /I have\s+([0-9]{1,9})\s+(?:clients?|users?)\s+and\s+([0-9]{1,9})\s+servers?\b/i) {
            @v{qw(local_users local_servers)} = (0+$1,0+$2);
        }
    }
    elsif ($n eq '265' || $n eq '266') {
        my $scope = $n eq '265' ? 'local' : 'global';
        my @pair;
        @pair = @nums[0,1] if @nums >= 2;
        if (!@pair && $text =~ /\Q$scope\E users[:\s]+([0-9]{1,9})[,\s]+max[:\s]+([0-9]{1,9})\b/i) { @pair=(0+$1,0+$2); }
        if (@pair) {
            my $field = $n eq '265' ? 'local_users' : 'global_users';
            $v{$field}=0+$pair[0];
            $v{$n eq '265' ? 'local_users_max' : 'users_max'}=0+$pair[1];
        }
    }
    return \%v;
}

sub new {
    my ($class,%a)=@_;
    my $get=sub { eval { $a{conf}->get($_[0]) } };
    my $on=$get->('network_stats.ENABLED');
    my $path=$get->('network_stats.OUTPUT_FILE') || 'var/network-stats.json';
    die 'Invalid network stats output path' if ref($path) || $path =~ /[\x00-\x1f]/ || length($path)>1024;
    my $network=$get->('connection.CONN_SERVER_NETWORK') || 'IRC';
    $network='IRC' if ref($network) || $network =~ /[\x00-\x1f]/ || length($network)>80;
    my $interval=$get->('main.LUSERS_REFRESH');
    $interval=300 unless defined($interval) && !ref($interval) && $interval =~ /\A[0-9]+\z/;
    $interval=300 if $interval==0;
    $interval=60 if $interval<60;
    $interval=3600 if $interval>3600;
    return bless {enabled=>defined($on) && "$on" eq '1',path=>$path,network=>$network,interval=>0+$interval,
        now=>$a{now} || sub { time() },logger=>$a{logger}},$class;
}

sub observe {
    my ($s,$n,$args,$text)=@_;
    return unless $s->{enabled};
    my $now=int($s->{now}->());
    my $v=parse_numeric($n,$args,$text);
    return unless keys %$v;
    if ($n eq '251') {
        # A new reply starts a new sample. Never reuse the previous cycle's
        # optional fields; an omitted/restricted numeric remains unknown.
        $s->{pending}={sampled_at=>$now,counts=>{},schema=>1,network=>$s->{network},interval=>$s->{interval}};
    }
    if (!$s->{pending} && ($n eq '255' || $n eq '266')) {
        $s->{pending}={sampled_at=>$now,counts=>{},schema=>1,network=>$s->{network},interval=>$s->{interval}};
    }
    my $p=$s->{pending} or return;
    if ($now-$p->{sampled_at}>20 || $now<$p->{sampled_at}) {delete $s->{pending};return;}
    @{$p->{counts}}{keys %$v}=values %$v;
    $s->{last_numeric}=$now;
    $p->{complete}=1 if $n eq '255' || $n eq '266';
    return 1;
}

sub reset { delete $_[0]->{pending}; }

sub flush {
    my ($s)=@_;
    my $p=$s->{pending} or return 0;
    my $now=int($s->{now}->());
    return 0 if $now-($s->{last_numeric}//$now)<2;
    delete $s->{pending};
    return 0 unless delete($p->{complete}) && $now >= $p->{sampled_at} && $now-$p->{sampled_at}<=25;
    # 266 supplies a total when no breakdown was available. With 251, retain
    # its sum and expose global_users separately if the server reports a gap.
    $p->{counts}{users}=$p->{counts}{global_users} unless defined $p->{counts}{users};
    return 0 unless defined $p->{counts}{users};
    my $ok=eval {
        my $dir=dirname($s->{path});
        my $cursor=$dir;
        while (1) { die 'Symbolic directory refused' if -l $cursor; my $parent=dirname($cursor);last if $parent eq $cursor; $cursor=$parent; }
        make_path($dir,{mode=>0700}) unless -d $dir;
        die 'Symbolic output refused' if -l $s->{path};
        my $tmp=$s->{path}.'.tmp.'.$$.'.'.int(rand(1000000000));
        sysopen(my $fh,$tmp,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0600) or die 'Cannot create stats snapshot';
        my $written=eval { print {$fh} JSON::PP->new->utf8->canonical->encode($p),"\n" or die 'Cannot write stats snapshot'; close($fh) or die 'Cannot close stats snapshot'; rename($tmp,$s->{path}) or die 'Cannot publish stats snapshot';1; };
        unlink($tmp) if -e $tmp;
        die 'Cannot publish stats snapshot' unless $written;
        1;
    };
    if (!$ok && $s->{logger} && (!$s->{last_error} || $now-$s->{last_error}>300)) {
        $s->{logger}->log(1,'NETWORK_STATS snapshot write failed; check output directory permissions');
        $s->{last_error}=$now;
    }
    return $ok ? 1 : 0;
}

1;

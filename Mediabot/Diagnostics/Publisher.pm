package Mediabot::Diagnostics::Publisher;
use strict;
use warnings;
use Fcntl qw(:mode);
use File::Spec;
use File::Temp qw(tempfile);
use JSON::PP;
use Scalar::Util qw(weaken);
use Mediabot::Diagnostics::Channel;

sub new {
    my ($class,%args)=@_;
    my $dir=$args{directory};my $channels=$args{channels};
    die "invalid diagnostic publication directory\n" unless defined($dir) && !ref($dir)
        && File::Spec->file_name_is_absolute($dir) && $dir !~ /[\x00-\x1f\x7f]/
        && !grep {$_ eq '..' || $_ eq '.'} File::Spec->splitdir($dir);
    die "invalid diagnostic publication channels\n" unless ref($channels) eq 'ARRAY' && @$channels && @$channels<=8;
    my %seen;my @validated;
    for my $channel (@$channels) {
        my $text=Mediabot::Diagnostics::Channel::channel_text($channel);
        die "invalid diagnostic publication channel\n" unless defined($text) && !$seen{lc $text}++;
        push @validated,$text;
    }
    die "diagnostic publication bot required\n" unless $args{bot};
    my $self=bless {bot=>$args{bot},directory=>$dir,channels=>\@validated,index=>0},$class;
    weaken($self->{bot});
    return $self;
}
sub install {
    my ($class,$bot,$scheduler)=@_;
    my $dir=eval {$bot->{conf}->get('main.CHANNEL_DIAGNOSTICS_DIR')};
    return unless defined($dir) && !ref($dir) && length($dir);
    my $publisher;my $ok=eval {
        my $channels=$bot->{conf}->get('main.CHANNEL_DIAGNOSTICS_CHANNELS');
        die "invalid publication allowlist\n" unless defined($channels) && !ref($channels);
        my @channels=grep {length} split(/[\s,]+/,$channels);
        $publisher=$class->new(bot=>$bot,directory=>$dir,channels=>\@channels);
        $scheduler->add(name=>'channel_diagnostics_publish',interval=>5,first_interval=>5,
            cb=>sub {$publisher->tick},autostart=>1);1;
    };
    eval {$bot->{logger}->log(2,'Channel diagnostic publication setup unavailable')} unless $ok;
    return $ok ? $publisher : undef;
}
sub _directory {
    my ($self)=@_;my $current=File::Spec->rootdir;
    for my $part (File::Spec->splitdir($self->{directory})) {
        next unless length $part;$current=File::Spec->catdir($current,$part);
        die "unsafe publication path\n" if -l $current;
    }
    my @s=lstat($self->{directory});
    die "publication directory unavailable\n" unless @s && S_ISDIR($s[2]) && $s[4]==$< && !($s[2]&0022);
}
sub _publish {
    my ($self,$report)=@_;$self->_directory;
    my $id=$report->{channel_id};
    die "publication requires fresh channel identity\n" unless ($report->{database}//'') eq 'fresh'
        && defined($id) && !ref($id) && "$id" =~ /\A[1-9][0-9]{0,9}\z/;
    my $path=File::Spec->catfile($self->{directory},"$id.json");
    die "unsafe publication destination\n" if -l $path || (-e $path && !-f $path);
    my $bytes=JSON::PP->new->utf8->canonical->encode($report);
    die "diagnostic publication too large\n" if length($bytes)>65536;
    my ($fh,$tmp)=tempfile('.channel-diagnostic-XXXXXX',DIR=>$self->{directory},UNLINK=>0);
    my $ok=eval {
        print {$fh} $bytes or die "publication write failed\n";
        close($fh) or die "publication close failed\n";
        chmod(0640,$tmp) or die "publication mode failed\n";
        rename($tmp,$path) or die "publication rename failed\n";1;
    };
    my $error=$@;unlink $tmp if -e $tmp;die $error unless $ok;
    return 1;
}
sub tick {
    my ($self)=@_;
    return 0 unless $self->{bot};
    my $channel=$self->{channels}[$self->{index}++ % @{$self->{channels}}];
    my $ok=eval {
        my $report=Mediabot::Diagnostics::Channel->new(bot=>$self->{bot})->collect($channel);
        $self->_publish($report);1;
    };
    if (!$ok && !$self->{failed}) {eval {$self->{bot}{logger}->log(2,'Channel diagnostic publication unavailable')}}
    $self->{failed}=$ok ? 0:1;
    return $ok ? 1:0;
}
1;

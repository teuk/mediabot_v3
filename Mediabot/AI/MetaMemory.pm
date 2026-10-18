package Mediabot::AI::MetaMemory;
use strict;
use warnings;
use Carp qw(croak);
use Fcntl qw(:DEFAULT :flock);
use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempfile);
use Digest::SHA qw(sha256_hex);
use Encode qw(encode);
use JSON::PP ();
use Mediabot::AI::MetaPolicy qw(clean fold);

sub new {
    my ($class,%args)=@_;
    croak 'memory path required' unless defined($args{path}) && !ref($args{path}) && length($args{path}) && $args{path} !~ /[\x00\r\n]/;
    return bless { path=>File::Spec->rel2abs($args{path}),
        ttl=>$args{ttl}//86400, turns=>$args{turns}//12, clock=>$args{clock}||sub {time} },$class;
}
sub actor { sha256_hex(encode('UTF-8', fold($_[1]))) }
sub _key { sha256_hex(encode('UTF-8', $_[1] // '')) }
sub _new_incarnation {
    # Epoch counters restart when an expired room is recreated. A separate
    # room incarnation prevents a late ticket from matching that new room.
    sysopen(my $fh,'/dev/urandom',O_RDONLY) or croak 'memory generation unavailable';
    my $bytes='';
    while (length($bytes)<16) {
        my $read=sysread($fh,$bytes,16-length($bytes),length($bytes));
        next if !defined($read) && $!{EINTR};
        croak 'memory generation unavailable' unless defined($read) && $read>0;
    }
    close($fh) or croak 'memory generation unavailable';
    return unpack('H*',$bytes);
}
sub _ticket_room {
    my ($state,$ticket)=@_;
    return unless ref($ticket) eq 'HASH'
        && defined($ticket->{scope}) && !ref($ticket->{scope}) && $ticket->{scope}=~/\A[a-f0-9]{64}\z/
        && defined($ticket->{epoch}) && !ref($ticket->{epoch}) && $ticket->{epoch}=~/\A\d+\z/
        && defined($ticket->{incarnation}) && !ref($ticket->{incarnation}) && $ticket->{incarnation}=~/\A[a-f0-9]{32}\z/;
    my $room=$state->{rooms}{$ticket->{scope}};
    return unless $room && defined($room->{incarnation})
        && $room->{incarnation} eq $ticket->{incarnation} && $room->{epoch}==$ticket->{epoch};
    return $room;
}
sub _locked {
    my ($self,$code)=@_;
    my $path=$self->{path}; my $dir=dirname($path);
    my $cursor=File::Spec->rootdir;
    for my $part (File::Spec->splitdir($dir)) {
        next if $part eq '';
        $cursor=File::Spec->catdir($cursor,$part);
        croak 'memory symlink refused' if -l $cursor;
    }
    croak 'memory symlink refused' if -l $path || -l "$path.lock";
    make_path($dir,{mode=>0700}) unless -d $dir;
    sysopen(my $lock,"$path.lock",O_RDWR|O_CREAT,0600) or croak 'memory lock open failed';
    chmod 0600,"$path.lock" or croak 'memory lock mode failed';
    flock($lock,LOCK_EX|LOCK_NB) or croak 'memory busy';
    my $state={version=>1,rooms=>{},usage=>{}};
    if (-e $path) {
        croak 'memory file too large' if !-f $path || -s $path > 4*1024*1024;
        open my $fh,'<:raw',$path or croak 'memory read failed';
        local $/; my $raw=<$fh>; close $fh;
        $state=eval {JSON::PP->new->utf8->decode($raw)};
        croak 'memory data invalid' if $@ || ref($state) ne 'HASH'
            || ($state->{version}//0)!=1 || ref($state->{rooms}) ne 'HASH'
            || ref($state->{usage}) ne 'HASH';
    }
    my $now=$self->{clock}->();
    for my $key (keys %{$state->{rooms}}) {
        my $room=$state->{rooms}{$key};
        croak 'memory room invalid' unless ref($room) eq 'HASH'
            && ref($room->{turns}) eq 'ARRAY' && ref($room->{actors}) eq 'HASH'
            && ($room->{epoch}//'') =~ /^\d+$/ && ($room->{next_speaker}//'') =~ /^\d+$/
            && keys(%{$room->{actors}})<=256 && @{$room->{turns}}<=24;
        croak 'memory names invalid' if exists($room->{names}) && ref($room->{names}) ne 'HASH';
        croak 'memory generation invalid' if exists($room->{incarnation})
            && (!defined($room->{incarnation}) || ref($room->{incarnation})
                || $room->{incarnation}!~/\A[a-f0-9]{32}\z/);
        for my $actor (keys %{$room->{actors}}) {
            croak 'memory actor invalid' unless $actor =~ /^[a-f0-9]{64}$/
                && ($room->{actors}{$actor}//'') =~ /^speaker\d+$/;
        }
        for my $turn (@{$room->{turns}}) {
            croak 'memory turn invalid' unless ref($turn) eq 'HASH'
                && ($turn->{actor}//'') =~ /^[a-f0-9]{64}$/
                && ($turn->{speaker}//'') =~ /^speaker\d+$/
                && length(clean($turn->{prompt},4000)) && length(clean($turn->{answer},1600));
        }
        delete $state->{rooms}{$key} if $now-($room->{at}//0)>$self->{ttl};
    }
    my ($result,$dirty)=$code->($state,$now);
    if ($dirty) {
        my $raw=JSON::PP->new->utf8->canonical->encode($state);
        croak 'memory file too large' if length($raw)>4*1024*1024;
        my ($fh,$tmp)=tempfile('.meta-memory.XXXXXX',DIR=>$dir,UNLINK=>0);
        my $ok=eval {
            chmod 0600,$tmp or die 'mode'; binmode $fh,':raw';
            print {$fh} $raw or die 'write'; close($fh) or die 'close';
            rename($tmp,$path) or die 'rename'; 1;
        };
        unlink $tmp if -e $tmp;
        croak 'memory write failed' unless $ok;
    }
    close $lock;
    return $result;
}
sub begin_turn {
    my ($self,$scope,$nick,$prompt,$daily,$display)=@_;
    my $key=$self->_key($scope); my $actor=$self->actor($nick);
    return $self->_locked(sub {
        my ($state,$now)=@_;
        my $day=int($now/86400);
        delete $state->{usage}{$_} for grep {$_ ne "$day"} keys %{$state->{usage}};
        return ({error=>'daily_limit'},0) if ($state->{usage}{$day}//0)>=$daily;
        croak 'memory room capacity' if !exists($state->{rooms}{$key}) && keys(%{$state->{rooms}})>=128;
        my $room=$state->{rooms}{$key}||={at=>$now,epoch=>1,next_speaker=>0,actors=>{},names=>{},turns=>[]};
        # Existing version-1 rooms retain their history and acquire this field
        # on their next successful begin. No reset or separate migration.
        $room->{incarnation}//=_new_incarnation();
        unless (exists $room->{actors}{$actor}) {
            croak 'memory actor capacity' if keys(%{$room->{actors}})>=256;
            $room->{actors}{$actor}='speaker'.(++$room->{next_speaker});
        }
        $room->{names}||={};
        $room->{names}{$actor}=clean($display,40) if defined($display);
        my @messages;
        for my $turn (@{$room->{turns}}) {
            croak 'memory turn invalid' unless ref($turn) eq 'HASH'
                && ($turn->{actor}//'') =~ /^[a-f0-9]{64}$/
                && ($turn->{speaker}//'') =~ /^speaker\d+$/;
            push @messages, {role=>'user',content=>$turn->{speaker}.(length($turn->{name}//'')?' ('.$turn->{name}.')':'').': '.clean($turn->{prompt},4000)},
                {role=>'assistant',content=>clean($turn->{answer},1600)};
        }
        my $speaker=$room->{actors}{$actor};
        my $name=$room->{names}{$actor}//'';
        push @messages,{role=>'user',content=>$speaker.(length($name)?" ($name)":'').': '.clean($prompt,4000)};
        $room->{at}=$now; $state->{usage}{$day}++;
        return ({messages=>\@messages,scope=>$key,epoch=>$room->{epoch},incarnation=>$room->{incarnation},actor=>$actor,
            speaker=>$speaker,name=>$name,prompt=>clean($prompt,4000)},1);
    });
}
sub commit_turn {
    my ($self,$ticket,$answer)=@_;
    return $self->_locked(sub {
        my ($state,$now)=@_; my $room=_ticket_room($state,$ticket);
        return (0,0) unless $room;
        my ($current_actor)=grep {$room->{actors}{$_} eq $ticket->{speaker}} keys %{$room->{actors}};
        push @{$room->{turns}},{actor=>$current_actor//$ticket->{actor},speaker=>$ticket->{speaker},
            name=>$ticket->{name}//'',prompt=>$ticket->{prompt},answer=>clean($answer,1600),at=>$now};
        splice @{$room->{turns}},0,@{$room->{turns}}-$self->{turns} if @{$room->{turns}}>$self->{turns};
        $room->{at}=$now;
        return (1,1);
    });
}
sub current {
    my ($self,$ticket)=@_;
    return $self->_locked(sub {
        my ($state)=@_;
        return (_ticket_room($state,$ticket) ? 1:0,0);
    });
}
sub forget_actor {
    my ($self,$scope,$nick)=@_;my $key=$self->_key($scope);my $actor=$self->actor($nick);
    return $self->_locked(sub {
        my ($state)=@_;my $room=$state->{rooms}{$key};return (0,0) unless $room;
        $room->{turns}=[grep {$_->{actor} ne $actor} @{$room->{turns}}];
        delete $room->{actors}{$actor};delete $room->{names}{$actor} if $room->{names};
        $room->{epoch}++;
        return (1,1);
    });
}
sub rename_actor {
    my ($self,$old,$new)=@_;my $from=$self->actor($old);my $to=$self->actor($new);
    return $self->_locked(sub {
        my ($state)=@_;my $changed=0;
        for my $room (values %{$state->{rooms}}) {
            next unless exists $room->{actors}{$from};
            next if exists($room->{actors}{$to}) && $room->{actors}{$to} ne $room->{actors}{$from};
            $room->{actors}{$to}=$room->{actors}{$from};
            for my $turn (@{$room->{turns}}) {$turn->{actor}=$to if $turn->{actor} eq $from}
            if ($room->{names}) {
                $room->{names}{$to}=clean((split /!/, $new,2)[0],40);
                delete $room->{names}{$from} if $from ne $to;
            }
            delete $room->{actors}{$from} if $from ne $to;
            $changed=1;
        }
        return ($changed,$changed);
    });
}
1;

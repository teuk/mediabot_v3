package Mediabot::Partyline::ShellWatch;
use strict;
use warnings;
use Scalar::Util qw(weaken refaddr);
use Time::HiRes qw(time);
use Encode ();

our $SERIAL; # Never reuse a registration name during an in-process reload.
sub _error {die bless {public=>$_[0]},__PACKAGE__.'::Usage'}

sub start {
    my ($class,$party,$id,$stream,%args)=@_;
    my $session=$party->{users}{$id};
    my $state=$session ? $session->{command_shell} : undef;
    my $scheduler=$party->{bot}{scheduler};
    _error('Watch requires an active shell and the native scheduler.')
        unless $session && $session->{authenticated} && $session->{command_mode}
            && defined($session->{level}) && !ref($session->{level}) && "$session->{level}"=~/\A[01]\z/
            && ref($state) eq 'HASH' && $scheduler && $party->{streams}{$id}
            && refaddr($party->{streams}{$id})==refaddr($stream);
    _error('Watch interval must be 5..60 seconds.')
        unless defined($args{interval}) && !ref($args{interval}) && $args{interval}=~/\A[0-9]{1,2}\z/
            && $args{interval}>=5 && $args{interval}<=60;
    _error('Watch renderer unavailable.') unless ref($args{render}) eq 'CODE';
    $class->stop($party,$id);
    my $self=bless {party=>$party,session=>$session,state=>$state,stream=>$stream,
        scheduler=>$scheduler,id=>$id,pid=>$$,name=>'partyline.shell.watch.'.++$SERIAL,
        channel=>$state->{channel}//'',channel_id=>$state->{channel_id}//'',cwd=>$state->{cwd},
        arming=>1,expires_at=>time+300,remaining=>int(300/$args{interval}),render=>$args{render}},$class;
    weaken($self->{$_}) for qw(party session state stream scheduler);
    $session->{shell_watch}=$self;
    my $weak=$self;weaken($weak);
    my $callback=sub {my $watch=$weak or return;$watch->_tick};
    my $ok=eval {
        $scheduler->add(name=>$self->{name},interval=>$args{interval},cb=>$callback);
        $self->{task_id}=$scheduler->registration_id($self->{name},$callback);
        die 'watch ownership lost' unless $self->{task_id} && !$self->{done};
        die 'watch start failed' unless $scheduler->start($self->{name});
        die 'watch caller changed' unless !$self->{done} && $party->{users}{$id}
            && refaddr($party->{users}{$id})==refaddr($session)
            && $party->{streams}{$id} && refaddr($party->{streams}{$id})==refaddr($stream)
            && $session->{shell_watch} && refaddr($session->{shell_watch})==refaddr($self)
            && $session->{command_shell} && refaddr($session->{command_shell})==refaddr($state)
            && ($state->{channel}//'') eq $self->{channel}
            && ($state->{channel_id}//'') eq $self->{channel_id} && $state->{cwd} eq $self->{cwd}
            && $session->{authenticated} && $session->{command_mode}
            && defined($session->{level}) && !ref($session->{level}) && "$session->{level}"=~/\A[01]\z/;
        1;
    };
    $self->{task_id}//=$scheduler->registration_id($self->{name},$callback);
    delete $self->{arming};
    unless ($ok) {
        my $already_done=$self->{done};
        $self->_dispose;
        $self->_remove_owned if $already_done;
        _error('Watch could not start; output revoked. Inspect ps before retrying.');
    }
    return $self;
}

sub stop {
    my ($class,$party,$id)=@_;
    my $session=$party->{users}{$id} or return 0;
    my $watch=$session->{shell_watch} or return 0;
    $watch->_dispose;
    return 1;
}

sub _dispose {
    my ($self)=@_;return if $self->{done}++;
    delete $self->{render}; # A queued callback must retain no captured query data.
    my $session=$self->{session};
    delete $session->{shell_watch} if $session && $session->{shell_watch}
        && refaddr($session->{shell_watch})==refaddr($self);
    $self->_remove_owned unless $self->{arming};
}

sub _remove_owned {
    my ($self)=@_;
    my $scheduler=$self->{scheduler} or return;
    my $task=$scheduler->task_info($self->{name});
    # Never remove a replacement registration, even with the same name.
    return unless $task && defined($self->{task_id}) && $task->{task_id}==$self->{task_id};
    my $removed=eval {$scheduler->remove($self->{name})};
    if (!$removed && $self->{party} && $self->{party}{bot}{logger}) {
        eval {$self->{party}{bot}{logger}->log(1,
            'Shell watch: output revoked; scheduler cleanup incomplete. Inspect ps.')};
    }
}

sub _tick {
    my ($self)=@_;return if $self->{done} || $$!=$self->{pid};
    my ($party,$session,$state,$stream,$scheduler)=@$self{qw(party session state stream scheduler)};
    my $current=$party ? $party->{users}{$self->{id}} : undef;
    my $owned=$current && $session && refaddr($current)==refaddr($session)
        && $current->{shell_watch} && refaddr($current->{shell_watch})==refaddr($self)
        && $party->{streams}{$self->{id}} && $stream
        && refaddr($party->{streams}{$self->{id}})==refaddr($stream);
    unless ($owned) {$self->_dispose;return}
    my $authorized=$session->{authenticated} && $session->{command_mode}
        && defined($session->{level}) && !ref($session->{level})
        && "$session->{level}"=~/\A[01]\z/;
    unless ($authorized) {$self->_dispose;return}
    my $task=$scheduler ? $scheduler->task_info($self->{name}) : undef;
    my $same=$state && $session->{command_shell}
        && refaddr($session->{command_shell})==refaddr($state)
        && ($state->{channel}//'') eq $self->{channel}
        && ($state->{channel_id}//'') eq $self->{channel_id} && $state->{cwd} eq $self->{cwd};
    unless ($same && $task && $task->{task_id}==$self->{task_id} && $task->{started}) {
        $self->_dispose;return;
    }
    if (time >= $self->{expires_at} || $self->{remaining}--<=0) {
        $self->_dispose;eval {$stream->write("\r\nWatch expired (maximum five minutes). Press Enter.\r\n")};return;
    }
    my $frame=eval {$self->{render}->($party,$state)};
    unless (defined($frame) && !ref($frame) && length(Encode::encode('UTF-8',$frame))<=16384) {
        $self->_dispose;
        eval {$stream->write("\r\nWatch stopped: observation unavailable. Run the command manually.\r\n")};return;
    }
    # Renderers can reenter shell/session code. Recheck ownership before I/O.
    return if $self->{done};
    unless ($party->{users}{$self->{id}} && refaddr($party->{users}{$self->{id}})==refaddr($session)
        && $session->{shell_watch} && refaddr($session->{shell_watch})==refaddr($self)
        && $session->{command_shell} && refaddr($session->{command_shell})==refaddr($state)
        && $party->{streams}{$self->{id}} && refaddr($party->{streams}{$self->{id}})==refaddr($stream)
        && $session->{authenticated} && $session->{command_mode}
        && defined($session->{level}) && "$session->{level}"=~/\A[01]\z/
        && ($state->{channel}//'') eq $self->{channel}
        && ($state->{channel_id}//'') eq $self->{channel_id} && $state->{cwd} eq $self->{cwd}) {$self->_dispose;return}
    my $ok=eval {$stream->write("\r\n[Watch; any input stops refresh]\r\n".$frame);1};
    $self->_dispose unless $ok;
}
1;

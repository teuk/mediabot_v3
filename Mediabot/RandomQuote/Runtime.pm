package Mediabot::RandomQuote::Runtime;
use strict;
use warnings;
use utf8;
use Encode qw(encode);
use Mediabot::AsyncWorker;
use Mediabot::Helpers ();
use Mediabot::Plugin::QuoteServiceV3;
use Mediabot::RandomQuote::State;

sub new {
    my ($class,%args)=@_;
    my $bot=$args{bot} or die 'RandomQuote bot required';
    return bless {bot=>$bot,loop=>$args{loop} || $bot->{loop},
        state=>$args{state} || Mediabot::RandomQuote::State->new(bot=>$bot),
        worker_class=>$args{worker_class} || 'Mediabot::AsyncWorker',
        inflight=>{},workers=>{}},$class;
}
sub default_interval {
    my ($self)=@_;my $value=eval {$self->{bot}{conf}->get('main.RANDOM_QUOTE')};
    return defined($value) && !ref($value) && "$value" =~ /\A[0-9]{1,6}\z/
        && $value>=900 && $value<=604800 ? 0+$value : 10800;
}
sub _log {
    my ($self,$text)=@_;$text =~ s/[\r\n\0]+/ /g;
    eval {$self->{bot}{logger}->log(1,'RandomQuote: '.substr($text,0,240))};
}
sub _dbh {
    my ($self)=@_;my $dbh=$self->{bot}{dbh} or die 'database unavailable';return $dbh;
}
sub _rows {
    my ($self,$sql,@bind)=@_;my $sth=$self->_dbh->prepare($sql) or die 'database prepare failed';
    my @rows;my $ok=eval {
        $sth->execute(@bind) or die 'database execute failed';
        while (my $row=$sth->fetchrow_hashref) {
            push @rows,{%$row};die 'channel result bound exceeded' if @rows>1000;
        }
        die 'database fetch failed' if $sth->err;
        1;
    };
    my $err=$@;eval {$sth->finish};die $err unless $ok;return \@rows;
}
sub channel_status {
    my ($self,$channel)=@_;
    Mediabot::RandomQuote::State::_channel($channel);
    my $rows=$self->_rows(q{SELECT c.name,
        CASE WHEN EXISTS (SELECT 1 FROM CHANNEL_SET cs JOIN CHANSET_LIST cl
            ON cl.id_chanset_list=cs.id_chanset_list
            WHERE cs.id_channel=c.id_channel AND cl.chanset='RandomQuote') THEN 1 ELSE 0 END AS enabled,
        (SELECT COUNT(*) FROM QUOTES q WHERE q.id_channel=c.id_channel) AS quotes
        FROM CHANNEL c WHERE c.name=?},$channel);
    return $rows->[0];
}
sub _joined {
    my ($self,$channel)=@_;my $bot=$self->{bot};
    return undef unless $bot->{_start_time} && eval {$bot->{irc}->is_connected};
    my $snapshot=eval {$bot->{wit_runtime_state}->snapshot($channel)};
    return undef unless $snapshot && $snapshot->{runtime_active}
        && $snapshot->{irc_connected} && $snapshot->{channel_joined};
    return $snapshot->{current_generation};
}
sub _enabled {
    my ($self,$channel)=@_;
    my $rows=$self->_rows(q{SELECT c.name FROM CHANNEL c
        JOIN CHANNEL_SET cs ON cs.id_channel=c.id_channel
        JOIN CHANSET_LIST cl ON cl.id_chanset_list=cs.id_chanset_list
        WHERE c.name=? AND cl.chanset='RandomQuote'},$channel);
    return @$rows ? 1 : 0;
}
sub tick {
    my ($self)=@_;my $bot=$self->{bot};
    return 0 unless $bot->{_start_time} && eval {$bot->{irc}->is_connected};
    my $rows=eval {$self->_rows(q{SELECT DISTINCT c.name FROM CHANNEL c
        JOIN CHANNEL_SET cs ON cs.id_channel=c.id_channel
        JOIN CHANSET_LIST cl ON cl.id_chanset_list=cs.id_chanset_list
        WHERE cl.chanset='RandomQuote' ORDER BY c.name})};
    unless ($rows) {$self->_log($@ || 'channel discovery failed');return 0}
    my $started=0;
    for my $row (@$rows) {
        last if keys(%{$self->{inflight}})>=2;
        my $channel=$row->{name};my $key=lc($channel // '');
        next if $self->{inflight}{$key};
        my $generation=$self->_joined($channel);next unless defined $generation;
        my $ticket=eval {$self->{state}->claim($channel,$self->default_interval)};
        if ($@) {$self->_log($@);next}
        next unless $ticket;
        $started++ if $self->_start($channel,$generation,$ticket);
    }
    return $started;
}
sub _select_quote {
    my ($self,$dbh,$channel,$ticket)=@_;
    my $service=Mediabot::Plugin::QuoteServiceV3->new(dbh=>$dbh);
    my %args=(channel=>$channel);
    $args{exclude_id}=$ticket->{last_id} if $ticket->{last_id};
    my $result=$service->random(%args);
    # A channel with only one quote may repeat it; multiple quotes avoid the
    # last successfully sent id. Deleted old ids do not bias the count.
    $result=$service->random(channel=>$channel) if !$result->{record} && $args{exclude_id};
    return {ok=>1,record=>$result->{record} ? $result->{record}->as_hash : undef};
}
sub _child {
    my ($self,$channel,$ticket)=@_;my $bot=$self->{bot};
    eval {$bot->{dbh}{InactiveDestroy}=1 if $bot->{dbh}};
    eval {$bot->{db}{dbh}{InactiveDestroy}=1 if $bot->{db} && $bot->{db}{dbh}};
    return {ok=>0,error=>'isolated database unavailable'}
        unless $bot->{db} && $bot->{db}->can('connect_isolated_handle');
    my ($dbh,$err)=$bot->{db}->connect_isolated_handle;
    return {ok=>0,error=>'isolated database unavailable'} unless $dbh;
    my $result=eval {$self->_select_quote($dbh,$channel,$ticket)};
    eval {$dbh->disconnect};
    return $result || {ok=>0,error=>'quote selection failed'};
}
sub _start {
    my ($self,$channel,$generation,$ticket)=@_;my $key=lc $channel;
    $self->{inflight}{$key}=1;
    my $worker=eval {$self->{worker_class}->start(
        loop=>$self->{loop},label=>"RandomQuote $channel",timeout=>30,max_output=>16384,
        child=>sub{$self->_child($channel,$ticket)},
        on_done=>sub {
            my ($result)=@_;delete $self->{inflight}{$key};delete $self->{workers}{$key};
            my $ok=eval {$self->_done($channel,$generation,$ticket,$result);1};
            $self->_log($@) unless $ok;
        })};
    unless ($worker) {
        delete $self->{inflight}{$key};$self->_log($@ || 'worker did not start');return 0;
    }
    $self->{workers}{$key}=$worker;return 1;
}
sub _done {
    my ($self,$channel,$generation,$ticket,$result)=@_;
    unless (ref($result) eq 'HASH' && $result->{ok}
        && ref($result->{value}) eq 'HASH' && $result->{value}{ok}) {
        $self->_log("quote worker failed on $channel");return 0;
    }
    my $record=$result->{value}{record};return 0 unless ref($record) eq 'HASH';
    my $id=$record->{id};return 0 unless defined($id) && !ref($id) && "$id" =~ /\A[1-9][0-9]{0,14}\z/;
    my $current=$self->_joined($channel);
    return 0 unless defined($current) && $current==$generation && $self->_enabled($channel);
    my $text=$record->{text};return 0 unless defined($text) && !ref($text);
    $text =~ s/[\x00-\x1f\x7f]+/ /g;
    return 0 unless $text =~ /\S/;
    my $prefix="[id: \x02$id\x02] ";
    # truncate_utf8 appends its suffix outside the requested byte budget.
    my $budget=400-length(encode('UTF-8',$prefix));
    $text=Mediabot::Helpers::truncate_utf8($text,$budget-3,'...')
        if length(encode('UTF-8',$text))>$budget;
    my $line=$prefix.$text;
    return 0 unless length(encode('UTF-8',$line))<=400;
    # Consume once before wire delivery. Config changes invalidate the ticket;
    # duplicate/late callbacks and restarts cannot produce a catch-up burst.
    return 0 unless $self->{state}->consume($channel,$ticket->{revision});
    my $sent=Mediabot::Helpers::botPrivmsg($self->{bot},$channel,$line,{no_defer=>1});
    $self->{state}->note_sent($channel,$ticket->{revision},$id) if $sent;
    return $sent ? 1 : 0;
}
1;

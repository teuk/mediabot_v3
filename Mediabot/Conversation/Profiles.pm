package Mediabot::Conversation::Profiles;
use strict;
use warnings;
use Scalar::Util qw(refaddr weaken);
use JSON::PP ();

my @FLAGS = qw(HailoChatter Spark SparkAction);
my %PRESET = (quiet => [0,0,0], balanced => [0,1,1], animated => [1,1,1]);
sub names { return [qw(quiet balanced animated)]; }
sub _id { defined($_[0]) && !ref($_[0]) && $_[0] =~ /\A[1-9][0-9]*\z/ }
sub _same { JSON::PP->new->canonical->encode($_[0]) eq JSON::PP->new->canonical->encode($_[1]) }
sub _rows {
    my ($db,$sql,@bind)=@_;
    my $st=$db->prepare($sql) or die 'database';
    my @rows;
    my $ok=eval {
        $st->execute(@bind) or die 'database';
        while(my $r=$st->fetchrow_hashref) {push @rows,{%$r};die 'database' if @rows>8}
        die 'database' if $st->err;
        1;
    };
    eval {$st->finish};die 'database' unless $ok;
    return \@rows;
}
sub _write {
    my ($db,$sql,@bind)=@_;
    my $st=$db->prepare($sql) or die 'database';
    my $ok=eval {$st->execute(@bind) or die 'database';1};
    eval {$st->finish};die 'database' unless $ok;
}
sub _read {
    my ($db,$cid,$ids)=@_;
    my %by_id=map {$ids->{$_}=>$_} @FLAGS;
    my $rows=_rows($db,'SELECT id_chanset_list FROM CHANNEL_SET WHERE id_channel=? AND id_chanset_list IN (?,?,?) FOR UPDATE',
        $cid,map {$ids->{$_}} @FLAGS);
    my %state=map {$_=>0} @FLAGS;
    for my $row (@$rows) {
        my $key=$by_id{$row->{id_chanset_list} // ''};
        die 'database' unless defined($key) && !$state{$key};
        $state{$key}=1;
    }
    my $ratios=_rows($db,'SELECT ratio FROM HAILO_CHANNEL WHERE id_channel=? FOR UPDATE',$cid);
    die 'database' if @$ratios>1;
    if (@$ratios) {
        my $r=$ratios->[0]{ratio};
        die 'database' unless defined($r) && !ref($r) && $r =~ /\A[0-9]{1,3}\z/ && $r<=100;
        $state{ratio}=0+$r;
    } else {$state{ratio}=undef}
    return \%state;
}
sub _store {
    my ($db,$cid,$ids,$from,$to)=@_;
    for my $key (@FLAGS) {
        next if $from->{$key}==$to->{$key};
        if ($to->{$key}) {
            _write($db,'INSERT INTO CHANNEL_SET (id_channel,id_chanset_list) VALUES (?,?)',$cid,$ids->{$key});
        } else {
            _write($db,'DELETE FROM CHANNEL_SET WHERE id_channel=? AND id_chanset_list=?',$cid,$ids->{$key});
        }
    }
    return if !defined($from->{ratio}) && !defined($to->{ratio});
    return if defined($from->{ratio}) && defined($to->{ratio}) && $from->{ratio}==$to->{ratio};
    if (!defined($to->{ratio})) {
        _write($db,'DELETE FROM HAILO_CHANNEL WHERE id_channel=?',$cid);
    } elsif (!defined($from->{ratio})) {
        _write($db,'INSERT INTO HAILO_CHANNEL (id_channel,ratio) VALUES (?,?)',$cid,$to->{ratio});
    } else {
        _write($db,'UPDATE HAILO_CHANNEL SET ratio=? WHERE id_channel=?',$to->{ratio},$cid);
    }
}
sub _invalidate {
    my ($bot,$channel)=@_;
    for my $key (keys %{$bot->{_chanset_cache} || {}}) {
        my ($cached)=split /\x00/,$key,2;
        delete $bot->{_chanset_cache}{$key} if lc($cached) eq lc($channel);
    }
    delete $bot->{_hailo_ratio_cache}{lc $channel};
}
sub operate {
    my ($bot,$cid,$channel,$mode)=@_;
    return {ok=>0,code=>'invalid_request'} unless _id($cid) && defined($channel) && !ref($channel)
        && $channel =~ /\A#[^\x00-\x20\x7f,:]{1,199}\z/ && defined($mode) && !ref($mode)
        && ($mode eq 'show' || $mode eq 'restore' || exists($PRESET{$mode}));
    my $db=eval {$bot->{db} ? $bot->{db}->ensure_connected : $bot->{dbh}};
    return {ok=>0,code=>'database_unavailable'} unless $db;
    my $key=lc $channel;
    my $journal=$bot->{_conversation_profile_undo} || {};
    return {ok=>0,code=>'no_previous_profile'} if $mode eq 'restore' && !exists($journal->{$key});
    return {ok=>0,code=>'connection_changed'} if $mode eq 'restore'
        && (!$journal->{$key}{connection}
            || refaddr($journal->{$key}{connection})!=refaddr($db));
    return {ok=>0,code=>'undo_capacity'} if !exists($journal->{$key}) && keys(%$journal)>=128
        && $mode ne 'show';
    my ($started,$before,$after,$changed,$ids,$code);
    my $ok=eval {
        die 'database' unless $db->{AutoCommit};
        $db->begin_work or die 'database';$started=1;
        my $channel_row=_rows($db,'SELECT id_channel FROM CHANNEL WHERE id_channel=? AND name=? FOR UPDATE',$cid,$channel);
        die 'database' unless @$channel_row==1;
        my $catalog=_rows($db,'SELECT id_chanset_list,chanset FROM CHANSET_LIST WHERE chanset IN (?,?,?) ORDER BY id_chanset_list FOR UPDATE',@FLAGS);
        $ids={};my %known=map {$_=>1} @FLAGS;
        for my $r (@$catalog) {
            die 'database' unless $known{$r->{chanset} // ''} && _id($r->{id_chanset_list}) && !exists($ids->{$r->{chanset}});
            $ids->{$r->{chanset}}=0+$r->{id_chanset_list};
        }
        die 'database' unless keys(%$ids)==3;
        $before=_read($db,$cid,$ids);$after={%$before};
        if ($mode eq 'restore') {
            unless ($journal->{$key}{cid}==$cid && _same($before,$journal->{$key}{after})
                && _same($ids,$journal->{$key}{ids})) {$code='settings_changed';die 'conflict'}
            $after={%{$journal->{$key}{before}}};
        } elsif ($mode ne 'show') {
            @{$after}{@FLAGS}=@{$PRESET{$mode}};
            $after->{ratio}=3 if $mode eq 'animated';
        }
        $changed=!_same($before,$after);
        _store($db,$cid,$ids,$before,$after) if $changed;
        die 'database' unless _same(_read($db,$cid,$ids),$after);
        $db->commit or die 'database';$started=0;1;
    };
    unless ($ok) {
        my $recovered=!$started || eval {$db->rollback or die 'rollback';1};
        return {ok=>0,code=>$recovered ? ($code || 'transaction_failed') : 'recovery_required'};
    }
    if ($changed && $mode ne 'restore') {
        $bot->{_conversation_profile_undo} ||= {};
        $bot->{_conversation_profile_undo}{$key}={cid=>0+$cid,connection=>$db,
            ids=>$ids,before=>$before,after=>$after};
        weaken($bot->{_conversation_profile_undo}{$key}{connection});
    } elsif ($mode eq 'restore') {delete $bot->{_conversation_profile_undo}{$key}}
    _invalidate($bot,$channel) if $changed;
    return {ok=>1,changed=>$changed ? 1:0,state=>$after,
        undo_available=>exists(($bot->{_conversation_profile_undo} || {})->{$key}) ? 1:0};
}
1;

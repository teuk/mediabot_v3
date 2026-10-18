package Mediabot::AI::MetaActivation;
use strict;
use warnings;
use Exporter 'import';
use Digest::SHA qw(sha256_hex);
use Mediabot::AI::MetaPolicy qw(fold);
use Mediabot::Helpers ();
our @EXPORT_OK=qw(channel_policy activation_plan initialize_chanset policy_epoch note_policy_change);

sub policy_epoch {
    my ($bot,$channel)=@_;
    return $bot->{_meta_ai_policy_epoch}{fold($channel)}//0;
}
sub note_policy_change {
    my ($bot,$channel)=@_;
    return ++$bot->{_meta_ai_policy_epoch}{fold($channel)};
}
sub _dbh {
    my ($bot)=@_;
    my $dbh=eval {$bot->{db}->ensure_connected} if $bot->{db};
    return $dbh || $bot->{dbh};
}
sub _catalogue {
    my ($dbh)=@_;
    die 'database unavailable' unless $dbh;
    my $sth=$dbh->prepare('SELECT id_chanset_list FROM CHANSET_LIST WHERE chanset=?') or die 'catalogue lookup';
    $sth->execute('MetaAI') or die 'catalogue lookup';
    my ($id)=$sth->fetchrow_array;die 'catalogue fetch' if $sth->err;$sth->finish;
    return $id;
}
sub _channel {
    my ($channel)=@_;
    return defined($channel) && !ref($channel) && $channel=~/\A#[^\s,:\x00-\x1f]{1,79}\z/;
}
sub channel_policy {
    my ($bot,$cfg,$channel)=@_;
    return {enabled=>0,mode=>'disabled'} unless _channel($channel);
    my $dbh=_dbh($bot);my $id;
    my $ok=eval {$id=_catalogue($dbh);1};
    return {enabled=>0,mode=>'unavailable'} unless $ok;
    if ($id) {
        return {enabled=>0,mode=>'chanset'} unless $cfg->{enabled};
        # Fresh reads at admission and delivery: removing +MetaAI must revoke
        # pending output without the legacy helper's two-minute chanset cache.
        my $set;
        $ok=eval {
            my $sth=$dbh->prepare(q{SELECT CS.id_channel_set FROM CHANNEL_SET CS
                JOIN CHANNEL C ON C.id_channel=CS.id_channel
                WHERE C.name=? AND CS.id_chanset_list=?}) or die 'channel lookup';
            $sth->execute($channel,$id) or die 'channel lookup';
            ($set)=$sth->fetchrow_array;die 'channel fetch' if $sth->err;$sth->finish;1;
        };
        return {enabled=>$ok && $set ? 1:0,mode=>$ok?'chanset':'unavailable'};
    }
    # Compatibility ends when this database registers MetaAI. It preserves
    # only the previous explicit enabled + listed + chatGPT route meanwhile.
    return {enabled=>0,mode=>'legacy'} unless $cfg->{legacy_enabled}
        && $cfg->{channels}{fold($channel)};
    my $legacy=eval {Mediabot::Helpers::chanset_enabled($bot,$channel,'chatGPT',default=>0)};
    return {enabled=>$legacy?1:0,mode=>'legacy'};
}
sub activation_plan {
    my ($dbh,$cfg)=@_;
    my $id=_catalogue($dbh);
    if($id){
        my $rows=$dbh->selectcol_arrayref(q{SELECT C.name FROM CHANNEL_SET CS
            JOIN CHANNEL C ON C.id_channel=CS.id_channel WHERE CS.id_chanset_list=? ORDER BY C.name},undef,$id);
        die 'channel lookup' unless ref($rows) eq 'ARRAY';
        return {registered=>1,active=>[grep {_channel($_)} @$rows],adopt=>[],omitted=>[]};
    }
    my (@adopt,@omitted);
    if($cfg->{legacy_enabled}){
        for my $channel(sort keys %{$cfg->{channels}}){
            my $rows=$dbh->selectall_arrayref(q{SELECT C.id_channel FROM CHANNEL C
                JOIN CHANNEL_SET CS ON CS.id_channel=C.id_channel
                JOIN CHANSET_LIST CL ON CL.id_chanset_list=CS.id_chanset_list
                WHERE C.name=? AND CL.chanset=?},undef,$channel,'chatGPT');
            die 'legacy channel lookup' unless ref($rows) eq 'ARRAY';
            push @{ @$rows?\@adopt:\@omitted },$channel;
        }
    }
    return {registered=>0,active=>[],adopt=>\@adopt,omitted=>\@omitted};
}
sub initialize_chanset {
    my ($dbh,$cfg,%args)=@_;
    # Only this explicit tool path writes data. Runtime admission is read-only.
    # Advisory lock is per database and serializes first registration/adoption.
    my ($database)=$dbh->selectrow_array('SELECT DATABASE()');
    die 'database unavailable' unless defined $database;
    my $lock='mb842-metaai-'.substr(sha256_hex($database),0,40);
    my ($held)=$dbh->selectrow_array('SELECT GET_LOCK(?,0)',undef,$lock);
    die 'initialization busy' unless $held;
    my ($result,$begun);
    my $ok=eval {
        die 'existing transaction' unless $dbh->{AutoCommit};
        $dbh->begin_work or die 'transaction';$begun=1;
        my $plan=activation_plan($dbh,$cfg);
        if(!$plan->{registered}){
            $dbh->do('INSERT INTO CHANSET_LIST(chanset) VALUES (?)',undef,'MetaAI') or die 'catalogue insert';
            my $id=_catalogue($dbh);die 'catalogue insert' unless $id;
            if($args{adopt_legacy}){
                for my $channel(@{$plan->{adopt}}){
                    $dbh->do(q{INSERT INTO CHANNEL_SET(id_channel,id_chanset_list)
                        SELECT C.id_channel,? FROM CHANNEL C WHERE C.name=?
                        AND NOT EXISTS(SELECT 1 FROM CHANNEL_SET CS WHERE CS.id_channel=C.id_channel AND CS.id_chanset_list=?)},
                        undef,$id,$channel,$id) or die 'channel insert';
                }
            }
        }
        $result=activation_plan($dbh,$cfg);
        $result->{created}=$plan->{registered}?0:1;
        $result->{adopted}=$args{adopt_legacy} && !$plan->{registered}?$plan->{adopt}:[];
        $dbh->commit or die 'commit';$begun=0;1;
    };
    eval {$dbh->rollback} if $begun;
    eval {$dbh->selectrow_array('SELECT RELEASE_LOCK(?)',undef,$lock)};
    die 'MetaAI initialization failed; no partial adoption committed' unless $ok;
    return $result;
}
1;

use strict;
use warnings;
use utf8;
use File::Temp qw(tempdir);
use IO::Async::Loop;
use Encode qw(encode);
use Mediabot::RSS qw(format_rss_announcement);
use Mediabot::RSS::Pacing;
use Mediabot::RSS::Poller;
use Mediabot::RSS::Runtime;
{
    package MB809::Repo;
    sub new {bless {items=>{}, seq=>0, enabled=>1, marked=>[], fail_mark=>0}, shift}
    sub insert_item {
        my ($self,$feed,$item,%opts)=@_;
        return 0 if $self->{items}{$feed}{$item->{item_key}};
        $self->{items}{$feed}{$item->{item_key}}={%$item, announced=>$opts{announced}, id_rss_item=>++$self->{seq}};
        return 1;
    }
    sub record_poll_success {1}
    sub record_not_modified {1}
    sub record_poll_error {1}
    sub pending_items {
        my ($s,$feed,$lim)=@_;
        my @items=sort {$a->{id_rss_item}<=>$b->{id_rss_item}} grep {!$_->{announced}} values %{$s->{items}{$feed}||{}};
        splice @items,$lim if @items>$lim;
        return \@items;
    }
    sub paced_pending_items {
        my ($s,$feed)=@_;
        my @items=reverse @{$s->pending_items($feed,100)};
        $_->{announced}=1 for @items[1..$#items];
        return @items ? [$items[0]] : [];
    }
    sub is_feed_enabled {$_[0]{enabled}}
    sub mark_announced {
        my ($s,$feed,$keys)=@_;
        return 0 if $s->{fail_mark};
        for my $key (@$keys) {$s->{items}{$feed}{$key}{announced}=1;push @{$s->{marked}},$key}
        return 1;
    }
}
{
    package MB809::IRC;
    sub is_connected {$_[0]{connected}}
}
sub item809 {my ($n)=@_;return {item_key=>sprintf('%064x',$n),title=>"Article $n",url=>"https://example.org/$n"}}
return sub {
    my ($a)=@_;
    my $now=1000000;
    my $dir=tempdir(CLEANUP=>1);
    my $p=Mediabot::RSS::Pacing->new(path=>"$dir/pacing.json",now=>sub{$now});
    $p->configure('#35+ans',gap=>180,daily=>3);
    my $repo=MB809::Repo->new;
    my $response={ok=>1,status=>200,feed=>{items=>[item809(1),item809(2),item809(3)]}};
    my $poller=Mediabot::RSS::Poller->new(repo=>$repo,pacing=>$p,fetcher=>sub{$response});
    my $feed={id_rss_feed=>1,channel=>'#35+ans',url=>'https://example.org/rss',announce_limit=>10};
    my $res=$poller->poll_feed($feed);
    $a->ok($res->{ok} && $res->{baseline},'mb809: paced first poll is silent baseline');
    $a->is(scalar @{$res->{pending}},0,'mb809: historical articles do not appear at activation');
    $feed->{last_success_at}='existing';
    $response={ok=>1,status=>200,feed=>{items=>[item809(4),item809(5),item809(1)]}};
    $res=$poller->poll_feed($feed);
    $a->is($res->{pending}[0]{title},'Article 4','mb809: choose newest new feed entry');
    $a->is(scalar @{$repo->pending_items(1,100)},1,'mb809: max=10 cannot create a paced backlog');
    my $bot={irc=>bless({connected=>1},'MB809::IRC')};
    my $runtime=Mediabot::RSS::Runtime->new(bot=>$bot,loop=>IO::Async::Loop->new,pacing=>$p);
    my (@sent,@options);
    no warnings 'redefine';
    local *Mediabot::RSS::Runtime::_parent_repo=sub{$repo};
    local *Mediabot::Helpers::botPrivmsg=sub{push @sent,$_[2];push @options,$_[3];return 1};
    my $enqueue=sub {
        my ($r,$id,@items)=@_;
        return $r->_enqueue_announcements(feed_id=>$id,channel=>'#35+ans',items=>[map {{item_key=>$_->{item_key},line=>format_rss_announcement(label=>'LeMonde',title=>$_->{title},url=>$_->{url},max_bytes=>400)}} @items]);
    };
    $enqueue->($runtime,1,@{$res->{pending}});
    $a->is(scalar @sent,1,'mb809: fresh candidate is sent once');
    $a->ok($options[0]{no_defer},'mb809: paced output cannot enter delayed AntiFlood queue');
    $repo->insert_item(2,item809(10),announced=>0);
    $repo->insert_item(2,item809(11),announced=>0);
    $repo->paced_pending_items(2);
    $enqueue->($runtime,2,item809(11),item809(10));
    $a->is(scalar @sent,1,'mb809: another feed cannot bypass channel cooldown');
    $a->is($runtime->queued_count,1,'mb809: only one replaceable candidate is retained per feed');
    $a->ok(!$runtime->{outq}{'#35+ans'}{timer},'mb809: no catch-up timer remains armed');
    $a->is(scalar @{$repo->pending_items(2,100)},1,'mb809: only newest candidate retained durably');
    $response={ok=>1,status=>200,feed=>{items=>[item809(6),item809(7),item809(4)]}};
    $res=$poller->poll_feed($feed);
    $a->is($res->{pending}[0]{title},'Article 6','mb809: next poll replaces old news with newest candidate');
    $response={ok=>1,not_modified=>1};
    $res=$poller->poll_feed($feed);
    $a->is(scalar @{$res->{pending}},1,'mb809: HTTP 304 retains only one candidate');
    my $restart=Mediabot::RSS::Runtime->new(bot=>$bot,loop=>IO::Async::Loop->new,pacing=>$p);
    $enqueue->($restart,1,@{$res->{pending}});
    $a->is(scalar @sent,1,'mb809: restart cannot release pending news before cooldown');
    $now+=10800;
    $enqueue->($restart,1,@{$res->{pending}});
    $a->is(scalar @sent,2,'mb809: later poll may send one fresh news at allowed time');
    $repo->insert_item(1,item809(8),announced=>0);
    $now+=10800;
    $repo->{enabled}=0;
    $enqueue->($restart,1,item809(8));
    $a->is(scalar @sent,2,'mb809: disabled feed revalidated before output');
    $a->is($p->status('#35+ans')->{used},2,'mb809: disabled feed consumes no quota');
    $repo->{enabled}=1;$bot->{irc}{connected}=0;
    $enqueue->($restart,1,item809(8));
    $a->is($p->status('#35+ans')->{used},2,'mb809: disconnected IRC consumes no slot');
    $bot->{irc}{connected}=1;
    {
        local *Mediabot::Helpers::botPrivmsg=sub{return 0};
        $enqueue->($restart,1,item809(8));
    }
    $a->is($p->status('#35+ans')->{used},3,'mb809: rejected send conservatively consumes reserved attempt');
    $enqueue->($restart,1,item809(8));
    $a->is(scalar @sent,2,'mb809: rejected attempt cannot turn into an immediate retry burst');
    $a->is(scalar @{$repo->pending_items(1,100)},1,'mb809: failed send remains a candidate');
    $now+=86400;$repo->{fail_mark}=1;
    $enqueue->($restart,1,item809(8));
    $enqueue->($runtime,1,item809(8));
    $a->is(scalar @sent,3,'mb809: acknowledgement failure cannot duplicate news inside cooldown');
    my $line=format_rss_announcement(label=>'LeMonde',title=>('Été 🦆 ' x 100),url=>'https://example.org/article',max_bytes=>400);
    $a->ok(length(encode('UTF-8',$line))<=400,'mb809: accented and emoji title stays inside one IRC line');
    $a->like($line,qr/https:\/\/example.org\/article\001\z/,'mb809: bounded line preserves URL and closing CTCP');
    $a->ok(!defined format_rss_announcement(label=>'LeMonde',title=>'Title',url=>'https://example.org/'.('a'x450),max_bytes=>400),'mb809: oversized unshortened URL is skipped instead of flooding');
    open my $fh,'>',$p->{path} or die $!;print {$fh} 'broken';close $fh;
    $enqueue->($runtime,1,item809(8));
    $a->is(scalar @sent,3,'mb809: corrupted pacing state blocks actual IRC output');
};

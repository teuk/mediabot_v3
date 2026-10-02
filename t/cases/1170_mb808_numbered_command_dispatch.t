use strict;
use warnings;
use utf8;
use Mediabot::Mediabot;
use Mediabot::Context;
use Mediabot::VDM::Runtime;
use MockBot;
{
    package MB808::ManualFetcher;
    sub new {bless {calls=>[]},shift}
    sub fetch {my ($self,%args)=@_;push @{$self->{calls}},\%args;1}
    sub complete {$_[0]{calls}[-1]{on_done}->($_[1])}
}
return sub {
    my ($a)=@_;
    my (@sent,@notices);
    my $bot=MockBot->new;
    $bot->{enabled}=1;
    my $fetch=MB808::ManualFetcher->new;
    $bot->{_vdm_runtime}=Mediabot::VDM::Runtime->new(bot=>$bot,fetcher=>$fetch,
        chanset_cb=>sub{$_[0]{enabled}},connected_cb=>sub{1},joined_cb=>sub{1},now_cb=>sub{1000},
        send_cb=>sub{push @sent,$_[2];1},notice_cb=>sub{push @notices,$_[2];1});
    my %handlers=Mediabot::_builtin_public_command_handlers();
    my $ctx=Mediabot::Context->new(bot=>$bot,channel=>'#test',nick=>'Pablo',command=>'vdm',args=>[304759]);
    $a->ok($handlers{vdm}->($ctx),'mb808: real registry handles numbered VDM');
    $a->is($fetch->{calls}[-1]{id},304759,'mb808: context ID crosses runtime into worker request');
    $fetch->complete({ok=>1,items=>[{id=>517747,story=>"Aujourd'hui, une autre histoire. VDM"},{id=>304759,story=>"Aujourd'hui, mon billet porte le bon numéro. VDM"}]});
    $a->like($sent[-1],qr/\[304759\]/,'mb808: actual numbered registry path emits requested ID');
    $a->is(scalar @sent,1,'mb808: requested VDM emits exactly one public line');
    $handlers{vdm}->($ctx);
    $fetch->complete({ok=>1,items=>[{id=>304759,story=>"Aujourd'hui, mon billet porte le bon numéro. VDM"}]});
    $a->is(scalar @sent,2,'mb808: explicit ID can be requested again within random repeat window');
    $handlers{vdm}->($ctx);
    $fetch->complete({ok=>1,items=>[{id=>517747,story=>"Aujourd'hui, une autre histoire. VDM"}]});
    $a->is(scalar @sent,2,'mb808: wrong-ID worker result never substitutes a random story');
    $a->like($notices[-1],qr/#304759.*introuvable/,'mb808: wrong or absent requested VDM is explicit');
    my $before=@{$fetch->{calls}};
    for my $args (['x'],[304759,'extra'],[{}]){
        $ctx->{args}=$args;$handlers{vdm}->($ctx);
    }
    $a->is(scalar @{$fetch->{calls}},$before,'mb808: malformed VDM arguments cannot trigger feed retrieval');
    $ctx->{args}=[304759];$bot->{enabled}=0;$handlers{vdm}->($ctx);
    $a->is(scalar @{$fetch->{calls}},$before,'mb808: numbered VDM respects -VDM');
    $bot->{enabled}=1;$handlers{vdm}->($ctx);$bot->{enabled}=0;
    $fetch->complete({ok=>1,items=>[{id=>304759,story=>"Aujourd'hui, mon billet porte le bon numéro. VDM"}]});
    $a->is(scalar @sent,2,'mb808: numbered VDM revalidates authorization before delivery');

    my @ids;
    my ($random,$search,$enabled,$returned_id)=(0,0,1,77);
    # Keep the actual registry + context + dispatcher, replace only IO boundaries.
    no warnings 'redefine';
    local *Mediabot::Helpers::chanset_enabled=sub{$enabled};
    local *Mediabot::Helpers::botPrivmsg=sub{push @sent,$_[2];1};
    local *Mediabot::Helpers::botNotice=sub{push @notices,$_[2];1};
    local *Mediabot::CommandAsync::run_ctx_async=sub{$_[3]->()};
    local *Mediabot::DTC::Commands::fetch_by_id=sub{push @ids,$_[0];return {ok=>1,id=>$returned_id,text=>'<Pablo> numbered quote'}};
    local *Mediabot::DTC::Commands::fetch_random=sub{$random++;return {ok=>1,id=>99,text=>'random quote'}};
    local *Mediabot::DTC::Commands::search_ids=sub{$search++;return {ok=>1,ids=>[77]}};
    for my $name (qw(dtc bashfr)){
        @sent=();$ctx->{command}=$name;$ctx->{args}=[77];
        $a->ok($handlers{$name}->($ctx),"mb808: real $name alias handles numeric ID");
        $a->is($ids[-1],77,"mb808: $name passes ID to direct source lookup");
        $a->like($sent[0],qr/\[77\]/,"mb808: $name displays requested ID");
    }
    $a->is($random,0,'mb808: numbered DTC aliases never call random source');
    $a->is($search,0,'mb808: numbered DTC aliases never become text search');
    @sent=();$returned_id=88;$handlers{dtc}->($ctx);
    $a->like($sent[0],qr/quote #77/,'mb808: wrong DTC ID returns not-found message');
    $a->unlike($sent[0],qr/\[88\]/,'mb808: wrong DTC result is not labelled as requested quote');
    $enabled=0;$before=@ids;$handlers{bashfr}->($ctx);
    $a->is(scalar @ids,$before,'mb808: numbered alias respects -DansTonChat before IO');
    $enabled=1;$returned_id=77;$ctx->{args}=[];$handlers{dtc}->($ctx);
    $a->is($random,1,'mb808: unnumbered DTC still uses random source');
    $ctx->{args}=['linux'];$handlers{bashfr}->($ctx);
    $a->is($search,1,'mb808: alias text search stays supported');
};

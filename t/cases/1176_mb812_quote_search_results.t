use strict;
use warnings;
use utf8;
use DBI;
use Mediabot::Mediabot;
use Mediabot::Context;
use Mediabot::Quotes;
use Mediabot::PluginContext;
use Mediabot::Plugin::QuoteServiceV3;
use Mediabot::Plugin::InvocationV3;
use Mediabot::Plugin::PrincipalV3;
use MockBot;
use MockUser;
use MockMessage;
BEGIN {unshift @INC, './plugins/quotes-v3/lib'}
use Quotes;
return sub {
    my ($a)=@_;
    my $dbh=DBI->connect('dbi:SQLite:dbname=:memory:','','',{
        RaiseError=>1,PrintError=>0,sqlite_unicode=>1});
    $dbh->do('CREATE TABLE CHANNEL (id_channel INTEGER PRIMARY KEY, name TEXT)');
    $dbh->do('CREATE TABLE USER (id_user INTEGER PRIMARY KEY, nickname TEXT)');
    $dbh->do('CREATE TABLE QUOTES (id_quotes INTEGER PRIMARY KEY, id_channel INTEGER, id_user INTEGER, quotetext TEXT, ts TEXT, hits INTEGER DEFAULT 0)');
    $dbh->do(q{INSERT INTO CHANNEL VALUES (1,'#test'),(2,'#other')});
    $dbh->do(q{INSERT INTO USER VALUES (1,'Pablo')});
    my $add=sub{$dbh->do('INSERT INTO QUOTES (id_quotes,id_channel,id_user,quotetext,ts) VALUES (?,?,?,?,?)',undef,@_,'2026-10-02 21:06:00')};
    $add->(1,1,1,'normal normal');
    $add->(2,1,1,'normal normal normal');
    $add->(3,1,1,'normal');
    $add->(4,1,undef,'thirsan normal');
    $add->(5,2,1,'normal normal normal normal thirsan');
    $add->(6,1,1,'literal 100% a_b wow! .*[ café');
    $add->(7,1,1,'normal normal normal');
    $add->($_,1,1,'crowded') for 100..150;
    $add->($_,1,1,'many') for 200..210;
    my $bot=MockBot->new(dbh=>$dbh,mock_user=>MockUser->new(auth=>1,level=>'User'));
    my $ctx=Mediabot::Context->new(bot=>$bot,nick=>'Teuk',channel=>'#test',command=>'q',args=>[],message=>MockMessage->new);
    my %handlers=Mediabot::_builtin_public_command_handlers();
    no warnings 'redefine';
    local *Mediabot::Quotes::botPrivmsg=sub{$_[0]->botPrivmsg($_[1],$_[2])};
    local *Mediabot::Quotes::botNotice=sub{$_[0]->botNotice($_[1],$_[2])};
    local *Mediabot::Quotes::logBot=sub{1};
    my (@output,@warnings);
    my $service=Mediabot::Plugin::QuoteServiceV3->new(dbh=>$dbh);
    my $authority=Mediabot::PluginContext->new(
        plugin=>'quotes-v3',requested=>[qw(data.quotes.read irc.reply irc.notice)],
        granted=>[qw(data.quotes.read irc.reply irc.notice)],
        quotes_read_sink=>sub{
            my ($inv,$operation,$args)=@_;
            die 'Unexpected operation' unless $operation eq 'search';
            return $service->search(%$args,channel=>$inv->channel);
        });
    my $principal=Mediabot::Plugin::PrincipalV3->new(authenticated=>0,global_level=>'user');
    my $plugin=Mediabot::Plugin::Quotes->new(context=>$authority);
    my $run=sub {
        my ($path,@args)=@_;@output=();@warnings=();$bot->reset_replies;
        local $SIG{__WARN__}=sub{push @warnings,$_[0]};
        my $ok=eval {
            if ($path eq 'legacy') {$ctx->{args}=\@args;$handlers{q}->($ctx)}
            else {
                my $inv=Mediabot::Plugin::InvocationV3->new(
                    nick=>'Teuk',channel=>'#test',command=>'q',args=>\@args,
                    source=>'public',is_private=>0,authority=>$authority,
                    activation=>'on',config=>{},principal=>$principal,
                    reply_sink=>sub{push @output,{type=>'privmsg',to=>'#test',text=>$_[0]};1},
                    notice_sink=>sub{push @output,{type=>'notice',to=>'Teuk',text=>$_[0]};1});
                $plugin->command_q($authority,$inv);
            }
            1;
        };
        my $err=$@;
        @output=@{$bot->{replies}} if $path eq 'legacy';
        $a->ok($ok,"mb812: $path q @args completes without exception ($err)");
        $a->is(scalar @warnings,0,"mb812: $path search produces no ranking warnings");
        return join("\n",map{$_->{text}}@output);
    };
    for my $path ('legacy','v3') {
        for my $alias ('s','search') {
            my $text=$run->($path,$alias,'normal');
            $a->like($text,qr/5 quote\(s\).*7\|2\|1\|4\|3/,
                "mb812: $path/$alias ranks frequency then newest id");
            $a->like($text,qr/Best match.*by Pablo.*\x027[\x02\x0f].*normal normal normal/,
                "mb812: $path/$alias displays the best quote with attribution");
            $a->is(scalar @output,2,"mb812: $path/$alias sends summary and best match");
            $a->ok(!(grep {$_->{to} ne '#test'} @output),"mb812: $path/$alias stays in issuing channel");
        }
        my $text=$run->($path,'s','thirsan');
        $a->like($text,qr/1 quote\(s\).* : 4\nBest match.*by Unknown/,
            "mb812: $path single anonymous quote works and excludes other channel");
        $text=$run->($path,'s','thirsan','normal');
        $a->like($text,qr/1 quote\(s\).*thirsan normal/,
            "mb812: $path multiword search retains AND matching");
        for my $literal ('100%','a_b','wow!','.*[','café') {
            $text=$run->($path,'s',$literal);
            $a->like($text,qr/1 quote\(s\).* : 6\n/,
                "mb812: $path treats $literal as literal search data");
        }
        $text=$run->($path,'s','machin');
        $a->like($text,qr/No quote found matching "machin" on #test/,
            "mb812: $path explicitly answers an empty search");
        $a->is(scalar @output,1,"mb812: $path empty result emits one reply");
        $text=$run->($path,'s');
        $a->like($text,qr/q \[search or s\] <text>/,"mb812: $path missing text returns syntax");
        $a->is($output[0]{type},'notice',"mb812: $path syntax stays private");
        $text=$run->($path,'s','crowded');
        $a->like($text,qr/More than 50 quotes/,"mb812: $path oversized result asks for refinement");
        $a->is(scalar @output,1,"mb812: $path oversized result never floods quotes");
        $text=$run->($path,'s','many');
        $a->like($text,qr/11 quote\(s\).*210\|209\|208\|207\|206\|205\|204\|203\|202\|201 \.\.\./,
            "mb812: $path result summary remains capped at ten ids");
        $a->like($text,qr/Best match.*\x02210[\x02\x0f]/,
            "mb812: $path equal scores select newest id");
    }
    $a->is($dbh->selectrow_array('SELECT SUM(hits) FROM QUOTES'),0,'mb812: searches do not mutate recall counters');
    $a->is($dbh->selectrow_array('SELECT COUNT(*) FROM QUOTES'),69,'mb812: searches preserve all quote rows');
    $dbh->disconnect;
};

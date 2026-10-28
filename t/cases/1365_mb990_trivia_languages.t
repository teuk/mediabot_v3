use strict;
use warnings;
use utf8;
use Test::More;
binmode Test::More->builder->output, ':encoding(UTF-8)';
binmode Test::More->builder->failure_output, ':encoding(UTF-8)';
use JSON::PP;
use Storable qw(dclone);
use DBI;
use IO::Async::Loop;
use Time::HiRes qw(time);
use Mediabot::Mediabot;
use Mediabot::External::TriviaFR;
use MockUser;

my $json = JSON::PP->new->utf8;
my $raw = do {open my $fh,'<:raw','Mediabot/Games/data/trivia-fr.json' or die $!;local $/;<$fh>};
my $doc = Mediabot::External::TriviaFR::parse_catalog($raw);
is(scalar @{$doc->{questions}},6044,'entire French corpus validates, including every answer and IRC budget');
is(scalar @{$doc->{sources}},206,'all original quiz attributions retained');
is($doc->{source_revision},'a16819964d171e40e6652368fc562f3bd27d0c5b','archival corpus has an exact reproducible source revision');
is($doc->{source_snapshot_date},'2022-02-12','catalog age is explicit rather than presented as a live service');
is($doc->{license},'CC-BY-SA-4.0','French data retains its original license');
my $cats = Mediabot::External::TriviaFR::categories();
is(scalar keys %$cats,14,'fourteen French categories');

{
    package MB990::HTTP;
    sub get {
        push @{$_[0]{urls}},$_[1];
        return {success=>1,status=>200,content=>$_[0]{content},headers=>{'content-type'=>'application/json'}};
    }
    package MB990::DBI; our @ISA=('DBI');
    package MB990::DBI::db; our @ISA=('DBI::db');
    sub prepare {
        my ($db,$sql,@rest)=@_;
        $sql =~ s/ON DUPLICATE KEY UPDATE/ON CONFLICT(id_channel,nick) DO UPDATE SET/;
        $sql =~ s/NOW\(\)/CURRENT_TIMESTAMP/g;
        return $db->SUPER::prepare($sql,@rest);
    }
    package MB990::DBI::st; our @ISA=('DBI::st');
    package MB990::Conf; sub get {$_[0]{$_[1]}}
    package MB990::Log; sub log {1}
    package MB990::Channel; sub get_id {$_[0]{id}}
    package MB990::Bot; our @ISA=('Mediabot');
    sub botNotice {push @{$_[0]{wire}},['notice',$_[1],$_[2]];1}
}
$INC{'MB990/DBI.pm'}=__FILE__;
my $english = {question=>'Capital of France?',correct_answer=>'Paris',incorrect_answers=>['Rome','Berlin','Madrid'],
    category=>'Geography',difficulty=>'easy'};
my $http = bless {urls=>[],content=>$json->encode({response_code=>0,results=>[$english]})},'MB990::HTTP';

# Every existing remote category/difficulty still uses the exact Open Trivia DB URL.
for my $case ([9,'easy'],[32,'hard']) {
    my ($id,$level)=@$case;
    my $r=Mediabot::External::OpenTriviaDB::_trivia_fetch_sync($id,$level,http=>$http,max_attempts=>1,language=>'en');
    is_deeply([$r->{ok},$r->{question},$http->{urls}[-1]],
        [1,$english,"https://opentdb.com/api.php?amount=1&type=multiple&category=$id&difficulty=$level"],
        'English provider preserves the original question, category and difficulty');
}
my $calls=@{$http->{urls}};
for my $case ([18,'easy'],[23,'medium'],[11,'hard']) {
    my ($id,$level)=@$case;
    my $r=Mediabot::External::OpenTriviaDB::_trivia_fetch_sync($id,$level,http=>$http,language=>'fr');
    is_deeply([$r->{ok},$r->{question}{category_id},$r->{question}{difficulty}],
        [1,$id,$level],'French source respects both filters');
}
is(scalar @{$http->{urls}},$calls,'French selection never calls the English HTTP source');
my @ids;
for (1..2) {
    my $r=Mediabot::External::TriviaFR::fetch(18,'easy',exclude_ids=>\@ids);
    ok(!grep($_ eq $r->{question}{id},@ids),'recent French question is excluded while fresh choices remain');
    push @ids,$r->{question}{id};
}
is(Mediabot::External::TriviaFR::fetch(19,undef)->{error},'fr_category','unsupported French category is explicit, without English fallback');

my $one={%$doc,questions=>[dclone($doc->{questions}[0])]};
for my $mutation (
    sub {$_[0]{language}='en'}, sub {$_[0]{questions}[0]{correct_answer}=undef},
    sub {$_[0]{questions}[0]{question}="bad\rline"}, sub {$_[0]{questions}[0]{question}='X'x301},
    sub {$_[0]{questions}[0]{category_id}=99}, sub {$_[0]{questions}[0]{difficulty}='impossible'},
    sub {$_[0]{questions}[0]{incorrect_answers}[0]=$_[0]{questions}[0]{correct_answer}},
    sub {push @{$_[0]{questions}},dclone($_[0]{questions}[0])},
) {
    my $bad=dclone($one);$mutation->($bad);
    ok(!eval {Mediabot::External::TriviaFR::parse_catalog($json->encode($bad));1},'malformed or ambiguous French data is refused');
}
is(Mediabot::External::TriviaFR::answer_key('  ÉMILE   ZOLA '),'emile zola','French case, accents and whitespace normalize');
is(Mediabot::External::TriviaFR::answer_key('L’ŒUVRE'),"l'oeuvre",'French apostrophe and ligature normalize');

no warnings qw(redefine once);
my %flags;
local *Mediabot::Helpers::chanset_enabled=sub {my($b,$ch,$name)=@_;return $flags{"$ch/$name"}//0};
local *Mediabot::Helpers::botPrivmsg=sub {push @{$_[0]{wire}},['public',$_[1],$_[2]];1};
local *Mediabot::UserCommands::botPrivmsg=sub {goto &Mediabot::Helpers::botPrivmsg};
local *Mediabot::UserCommands::botNotice=sub {push @{$_[0]{wire}},['notice',$_[1],$_[2]];1};
local *Mediabot::UserCommands::logBot=sub {1};
my $master=MockUser->new(level=>'Master',auth=>1);
sub bot_1365 {
    my ($language)=@_;
    my $db=DBI->connect('dbi:SQLite:dbname=:memory:','','',{
        RootClass=>'MB990::DBI',RaiseError=>1,PrintError=>0,sqlite_unicode=>1});
    $db->do('CREATE TABLE CHANNEL(id_channel INTEGER PRIMARY KEY,name TEXT)');
    $db->do("INSERT INTO CHANNEL VALUES(1,'#test'),(2,'#other')");
    $db->do('CREATE TABLE TRIVIA_SCORES(id_channel INTEGER,nick TEXT,score INTEGER,last_correct TEXT,PRIMARY KEY(id_channel,nick))');
    $db->do("INSERT INTO TRIVIA_SCORES VALUES(1,'alice',40,'2026-10-27'),(2,'alice',90,'2026-10-27')");
    my $bot=Mediabot->new({dbh=>$db});bless $bot,'MB990::Bot';
    $bot->{conf}=bless {'main.LANG'=>$language,'main.TRIVIA_TIMEOUT'=>30},'MB990::Conf';
    $bot->{logger}=bless {},'MB990::Log';$bot->{wire}=[];$bot->{pending}=[];
    $bot->{channels}={map {$_->[0]=>bless({id=>$_->[1]},'MB990::Channel')} ['#test',1],['#other',2]};
    return $bot;
}
sub command_1365 {
    my ($bot,$command,@args)=@_;
    my $ctx=Mediabot::Context->new(bot=>$bot,nick=>'Alice',channel=>'#test',command=>$command,args=>\@args);
    $ctx->{_user_fetched}=1;$ctx->{user}=$master;
    return $bot->command_registry->handler_for($command,'public')->($ctx);
}
sub text_1365 {join(' ',map {$_->[2]} @{$_[0]{wire}})}
sub score_1365 {$_[0]{dbh}->selectrow_array("SELECT score FROM TRIVIA_SCORES WHERE id_channel=1 AND nick='alice'")}

{
    local *Mediabot::UserCommands::_trivia_fetch_async=sub {
        my($bot,$cat,$diff,$cb,%opts)=@_;
        push @{$bot->{pending}},{category=>$cat,difficulty=>$diff,callback=>$cb,%opts};return 1;
    };
    for my $case (
        ['en',[],{},'en'], ['fr',[],{},'en'], ['en',[],{'#test/LangFR'=>1},'en'],
        ['en',['fr'],{},'fr'],
        ['en',['fr','histoire','difficile'],{},'fr'],
    ) {
        my ($default,$args,$channels,$expected)=@$case;%flags=%$channels;
        my $bot=bot_1365($default);command_1365($bot,'trivia',@$args);
        my $p=$bot->{pending}[-1];
        is($p->{language},$expected,'explicit language selects the source; existing defaults stay English');
        my $r=$expected eq 'fr' ? Mediabot::External::TriviaFR::fetch($p->{category},$p->{difficulty}) : {ok=>1,question=>dclone($english)};
        $p->{callback}->($r);
        is($bot->{_trivia}{'#test'}{language},$expected,'selected language reaches the live question');
        like(text_1365($bot),$expected eq 'fr'?qr/Choix :.*dans le salon/s:qr/Choices:.*just say it/s,'choices and answer instructions use selected language');
        my $answer=$bot->{_trivia}{'#test'}{answer_display};
        Mediabot::UserCommands::checkTriviaAnswer($bot,'Alice','#test',
            $expected eq 'fr'?Mediabot::External::TriviaFR::answer_key($answer):$answer);
        is(score_1365($bot),41,'both languages add to existing persistent score rather than resetting it');
        is($bot->{dbh}->selectrow_array("SELECT score FROM TRIVIA_SCORES WHERE id_channel=2 AND nick='alice'"),90,'other channel score is preserved');
        like(text_1365($bot),$expected eq 'fr'?qr/Bonne réponse, Alice/:qr/Correct, Alice/,'answer feedback is localized');
    }
    %flags=();
    {
        my $bot=bot_1365('en');command_1365($bot,'trivia','fr','start',2);
        my $first=$bot->{pending}[-1];
        $first->{callback}->({ok=>1,question=>{question=>'Quel auteur ?',correct_answer=>'Émile Zola',
            incorrect_answers=>['Victor Hugo','Albert Camus','Jules Verne'],category=>'Littérature',difficulty=>'easy',id=>'oqdb-140-1'}});
        like(text_1365($bot),qr/Manche 1\/2/,'French multi-round opening is localized');
        my $active=dclone($bot->{_trivia}{'#test'});
        command_1365($bot,'trivia','en');
        is_deeply($bot->{_trivia}{'#test'},$active,'English request cannot overwrite an active French question');
        Mediabot::UserCommands::checkTriviaAnswer($bot,'Alice','#test','emile zolas');
        ok($bot->{_trivia}{'#test'}{active},'accent-insensitive matching still rejects an embedded longer answer');
        Mediabot::UserCommands::checkTriviaAnswer($bot,'Alice','#test','EMILE ZOLA');
        like(text_1365($bot),qr/Scores après la manche 1\/2/,'French round scores are localized');
        command_1365($bot,'trivia');
        my $next=$bot->{pending}[-1];
        is($next->{language},'fr','unfinished French series keeps its language despite English channel default');
        is_deeply($next->{exclude_ids},['oqdb-140-1'],'recent question ids reach subsequent requests');
        command_1365($bot,'triviastop');
        like(text_1365($bot),qr/Chargement.*annulé/,'pending French stop is localized and retains MB983 cleanup');
        ok(!$bot->{_trivia}{'#test'}{multi_total},'French stop removes the abandoned series');
        $next->{callback}->({ok=>1,question=>dclone($english)});
        ok(!$bot->{_trivia}{'#test'}{active},'late response cannot revive cancelled French game');
        command_1365($bot,'trivia','en');
        is($bot->{pending}[-1]{language},'en','English remains selectable after a French series');
        is(score_1365($bot),41,'language switching and stop retain all already-earned SQL points');
    }
    {
        my $bot=bot_1365('en');command_1365($bot,'trivia','fr','maths');
        is(scalar @{$bot->{pending}},0,'unavailable French category cannot silently fetch English');
        like(text_1365($bot),qr/Catégorie non disponible/,'unavailable French filters have clear guidance');
        command_1365($bot,'trivia','en','maths');
        is($bot->{pending}[-1]{category},19,'same category remains available through Open Trivia DB');
    }
    {
        my $bot=bot_1365('fr');command_1365($bot,'trivia','fr','categories');
        like(text_1365($bot),qr/littérature.*informatique.*géographie/,'French category list and accents are readable');
        command_1365($bot,'trivia','en','categories');
        like(text_1365($bot),qr/Trivia categories:.*maths.*politics/,'full original English category list remains available');
        command_1365($bot,'trivia','fr','myscore');
        like(text_1365($bot),qr/Score Trivia de alice.*40 bonne/,'French personal score reads existing SQL score');
        command_1365($bot,'trivia','fr','leaderboard');
        like(text_1365($bot),qr/Classement Trivia/,'French persistent leaderboard is localized');
        command_1365($bot,'trivia','fr');$bot->{pending}[-1]{callback}->({ok=>0,error=>'fr_catalog'});
        like(text_1365($bot),qr/catalogue français est indisponible/,'French source failure is explicit');
        ok(!$bot->{_trivia}{'#test'}{active},'French source failure creates no English question');
    }
    {
        my $bot=bot_1365('fr');command_1365($bot,'trivia','fr');
        $bot->{pending}[-1]{callback}->({ok=>1,question=>{question=>'Quel auteur ?',correct_answer=>'Émile Zola',
            incorrect_answers=>['Victor Hugo','Albert Camus','Jules Verne'],category=>'Littérature',difficulty=>'hard'}});
        $bot->{_trivia}{'#test'}{deadline}=CORE::time()+5;
        Mediabot::UserCommands::checkTriviaAnswer($bot,'Alice','#test','aucune idée');
        like(text_1365($bot),qr/Indice : é____ ____/,'French hint keeps accented spelling and word layout');
        $bot->{_trivia}{'#test'}{deadline}=CORE::time()-1;
        Mediabot::UserCommands::checkTriviaAnswer($bot,'Alice','#test','emile zola');
        like(text_1365($bot),qr/Temps écoulé.*DIFFICILE.*réponse était : Émile Zola/,'French timeout and difficulty retain the original accented answer');
        is(score_1365($bot),40,'late French answer cannot add a point');
        command_1365($bot,'triviascore');
        like(text_1365($bot),qr/Aucun score Trivia pour le moment/,'French session scoreboard is localized');
    }
}

# One real fork/JSON/IO::Async round trip proves that French text and source
# selection survive the existing runtime worker, without any HTTP or SQL call.
{
    my $bot=bot_1365('en');$bot->{loop}=IO::Async::Loop->new;
    my @done;
    Mediabot::Games::Trivia::_trivia_fetch_async($bot,18,'easy',sub {push @done,$_[0]},language=>'fr');
    my $end=time()+10;
    while (!@done && time()<$end) {$bot->{loop}->loop_once(0.05)}
    is(scalar @done,1,'real French worker completes exactly once');
    ok($done[0]{ok},'real French worker succeeds');
    is($done[0]{language},'fr','language survives worker JSON transport');
    like($done[0]{question}{id}//'',qr/^oqdb-/,'worker uses the real French catalog');
    is($done[0]{question}{category_id},18,'worker retains the selected French category');
}
done_testing;

# t/cases/658_mb443_trivia_answer_accent_boundary.t
# =============================================================================
# mb443 — Les frontières de mot du matching de réponse trivia sont byte-safe.
#
# Historical byte-input contract; public IRC now also supplies decoded text.
# Les frontières ASCII seules
# [A-Za-z0-9] traitaient un octet d'accent (>= 0x80) comme un séparateur : une
# réponse courte comme "on" était validée à tort par "garçon" (l'octet 0xA7 de
# ç avant "on" passait pour une frontière). mb443 inclut \x80-\xFF dans les
# classes de frontière : "garçon" ne valide plus "on", mais "... is on" / "on!"
# restent valides.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_658 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

return sub {
    my ($assert) = @_;

    my $matched = sub {
        my ($text, $answer) = @_;
        $answer = lc $answer;
        return ( lc($text) eq $answer
            || lc($text) =~ /(?<![A-Za-z0-9\x80-\xFF])\Q$answer\E(?![A-Za-z0-9\x80-\xFF])/ ) ? 1 : 0;
    };

    # ç = C3 A7, é = C3 A9 (octets UTF-8 explicites)
    my $garcon = "gar" . chr(0xC3) . chr(0xA7) . "on";
    my $beton  = "b" . chr(0xC3) . chr(0xA9) . "ton";   # béton

    $assert->is($matched->($garcon, 'on'),          0, 'garçon ne valide plus "on" (faux positif corrigé)');
    $assert->is($matched->('the answer is on', 'on'),1, '"on" délimité par espaces -> valide');
    $assert->is($matched->('on!', 'on'),             1, '"on!" -> valide');
    $assert->is($matched->('onze', 'on'),            0, '"onze" -> rejet (in-word)');
    $assert->is($matched->($beton, 'ton'),           0, 'béton ne valide pas "ton" (t alnum avant)');

    # Réponse accentuée exacte / bornée
    my $cafe = "caf" . chr(0xC3) . chr(0xA9);
    $assert->is($matched->("un $cafe.", $cafe),      1, '"café" délimité -> valide');
    $assert->is($matched->("${cafe}s", $cafe),       0, '"cafés" -> rejet (s après)');

    # --- Câblage réel ------------------------------------------------------
    my $src = _slurp_658(File::Spec->catfile('.', 'Mediabot', 'UserCommands.pm'));
    $assert->like($src,
        qr/\(\?<!\[A-Za-z0-9\\x80-\\xFF(?:\\p\{[LNM]\})*\]\)\\Q\$answer\\E\(\?!\[A-Za-z0-9\\x80-\\xFF(?:\\p\{[LNM]\})*\]\)/,
        'checkTrivia utilise des frontières byte-safe');
    $assert->like($src, qr/mb443-B1/, 'tag mb443-B1');

    # MB920: real game entry points, incoming decoder, DBI/SQLite and timers.
    # The private SQL bridge supplies RAND and translates only the trivia upsert.
    require JSON::PP;
    my $probe = <<'MB920_NATIVE';
use strict;
use warnings;
use utf8;
BEGIN { *CORE::GLOBAL::time = sub {1792740000} }
use DBI;
use Encode qw(encode);
use IO::Async::Loop;
use JSON::PP;
use Mediabot::UserCommands;
{
 package MB920::DBI; our @ISA=('DBI');
 package MB920::DBI::db; our @ISA=('DBI::db');
 sub prepare {
  my($s,$sql,@rest)=@_;my$st=$s->{private_mb920};
  push @{$st->{sql}},$sql if$st;
  $sql =~ s/ON DUPLICATE KEY UPDATE score = score \+ 1, last_correct = NOW\(\)/ON CONFLICT(id_channel,nick) DO UPDATE SET score = score + 1, last_correct = CURRENT_TIMESTAMP/;
  $sql =~ s/NOW\(\)/CURRENT_TIMESTAMP/g;
  my$sth=$s->SUPER::prepare($sql,@rest);$sth->{private_mb920}=$st if$sth&&$st;return$sth;
 }
 package MB920::DBI::st; our @ISA=('DBI::st');
 sub execute {my($s,@bind)=@_;my$st=$s->{private_mb920};push @{$st->{binds}},\@bind if$st;return$s->SUPER::execute(@bind)}
 package MB920::Bot; sub getLoop {$_[0]{loop}}
 package MB920::Channel; sub get_id {1}
 package MB920::Metrics; sub inc {$_[0]{counts}{$_[1]}++}
 package MB920::Log; sub log {push @{$_[0]{events}},[$_[1],$_[2]];1}
 package MB920::Ctx;
 sub bot {$_[0]{bot}} sub channel {'#test'} sub nick {'Player'} sub args {[]} sub message {undef}
}
$INC{'MB920/DBI.pm'}=__FILE__;
sub fixture {
 my($mode)=@_;my$h=DBI->connect('dbi:SQLite:dbname=:memory:','','',{
  RootClass=>'MB920::DBI',RaiseError=>1,PrintError=>0,AutoCommit=>1,sqlite_unicode=>($mode eq 'bytes'?0:1)});
 $h->sqlite_create_function('RAND',0,sub{0.5});
 $h->do('CREATE TABLE TRIVIA_SCORES(id_channel INTEGER,nick TEXT,score INTEGER,last_correct TEXT,UNIQUE(id_channel,nick))');
 $h->do('CREATE TABLE CHANNEL(id_channel INTEGER,name TEXT)');
 $h->do('CREATE TABLE USER(id_user INTEGER,nickname TEXT)');
 $h->do('CREATE TABLE QUOTES(id_quotes INTEGER,id_channel INTEGER,id_user INTEGER,quotetext TEXT)');
 $h->do(q{INSERT INTO CHANNEL VALUES(1,'#test')});
 my$state={out=>[],sql=>[],binds=>[]};$h->{private_mb920}=$state;
 my$b=bless {dbh=>$h,loop=>IO::Async::Loop->new,probe=>$state,
  channels=>{'#test'=>bless({},'MB920::Channel')},logger=>bless({events=>[]},'MB920::Log'),
  metrics=>bless({counts=>{}},'MB920::Metrics')},'MB920::Bot';return($b,$state);
}
no warnings qw(redefine once);
local *Mediabot::Helpers::botPrivmsg=sub {my($b,$to,$text)=@_;push @{$b->{probe}{out}},[$to,$text,utf8::is_utf8($text)?1:0,unpack('H*',utf8::is_utf8($text)?encode('UTF-8',$text):$text)];1};
local *Mediabot::UserCommands::botPrivmsg=sub {goto &Mediabot::Helpers::botPrivmsg};
local *Mediabot::UserCommands::botNotice=sub {goto &Mediabot::Helpers::botPrivmsg};
local *Mediabot::Helpers::chanset_enabled=sub {1};
sub representation {
 my($s,$mode)=@_;return encode('UTF-8',$s) if$mode eq 'bytes';
 return Mediabot::Helpers::decode_irc_text(encode('UTF-8',$s)) if$mode eq 'wire';return$s;
}
sub run_answer {
 my($game,$text,$answer,$mode)=@_;my($b,$s)=fixture($mode);
 $text=representation($text,$mode);$answer=representation(lc($answer),$mode);
 my$kind=$game eq 'trivia'?'_trivia':'_quotegame';
 $b->{$kind}{'#test'}={active=>1,deadline=>time()+600,started=>time(),answer=>$answer,
  answer_display=>$answer,author=>$answer,author_lc=>$answer,scores=>{},timeout=>30,token=>'test'};
 Mediabot::UserCommands::_quotegame_start_timer($b,'#test','test',60) if$game eq 'quote';
 my$method=$game eq 'trivia'?\&Mediabot::UserCommands::checkTriviaAnswer:\&Mediabot::UserCommands::checkQuotegameAnswer;
 $method->($b,'Player','#test',$text);
 my$g=$b->{$kind}{'#test'};
 my$r={active=>$g->{active},score=>$g->{scores}{Player}//0,metrics=>$b->{metrics}{counts},out=>$s->{out},
  stored=>scalar($b->{dbh}->selectrow_array('SELECT COALESCE(SUM(score),0) FROM TRIVIA_SCORES')),
  timer=>$g->{timer}?1:0,sql=>$s->{sql},binds=>$s->{binds}};
 Mediabot::UserCommands::_quotegame_cancel_timer($b,'#test') if$game eq 'quote';
 $b->{dbh}->disconnect;return$r;
}
sub run_mask {
 my($text,$answer,$mode)=@_;my($b,$s)=fixture($mode);
 $text=representation($text,$mode);$answer=representation($answer,$mode);
 $b->{dbh}->do('INSERT INTO USER VALUES(1,?)',undef,$answer);
 $b->{dbh}->do('INSERT INTO QUOTES VALUES(1,1,1,?)',undef,$text);
 Mediabot::UserCommands::mbQuotegame_ctx(bless({bot=>$b},'MB920::Ctx'));
 my$r={out=>$s->{out},active=>$b->{_quotegame}{'#test'}{active},timer=>$b->{_quotegame}{'#test'}{timer}?1:0};
 Mediabot::UserCommands::_quotegame_cancel_timer($b,'#test');$b->{dbh}->disconnect;return$r;
}
my@blocked=(
 ['latin_prefix',"\x{100}on",'on'],['latin_suffix',"on\x{153}",'on'],
 ['cyrillic',"\x{43f}\x{43e}\x{434}\x{430}\x{440}\x{43e}\x{43a}","\x{434}\x{430}"],
 ['cjk_prefix',"\x{5b57}on",'on'],['cjk_suffix',"on\x{5b57}",'on'],
 ['digit_prefix',"\x{660}on",'on'],['digit_suffix',"on\x{660}",'on'],
 ['number_prefix',"\x{2167}on",'on'],['number_suffix',"on\x{2167}",'on'],
 ['mark_prefix',"\x{301}on",'on'],['mark_suffix',"on\x{301}",'on'],
 ['nonbmp_letter',"on\x{10400}",'on']);
my@valid=(['word','on','on'],['sentence','the answer is on!','on'],
 ['unicode_punctuation',"\x{2014}on\x{2014}",'on'],['emoji',"\x{1f31f}on\x{1f31f}",'on'],
 ['cyrillic_word',"\x{434}\x{430}","\x{434}\x{430}"],['marks_in_answer',"o\x{301}n","o\x{301}n"]);
my%out;
for my$mode(qw(characters wire bytes)){
 for my$group(['blocked',\@blocked],['valid',\@valid]){
  for my$v(@{$group->[1]}){my($label,$text,$answer)=@$v;
   for my$game(qw(trivia quote)){$out{$group->[0]}{$mode}{$game}{$label}=run_answer($game,$text,$answer,$mode)}
   $out{masks}{$group->[0]}{$mode}{$label}=run_mask("Longue citation: $text ; $answer.",$answer,$mode);
  }
 }
}
print JSON::PP->new->canonical->utf8->encode(\%out);
MB920_NATIVE
    open my $native, '-|', $^X, '-I.', '-It/lib', '-e', $probe
        or die "start native Unicode game probe: $!";
    my $output = do { local $/; <$native> };
    close $native;
    $assert->is($? >> 8, 0, 'native Unicode game probe completes');
    my $r = JSON::PP::decode_json($output);
    my $json = JSON::PP->new->canonical;
    for my $game (qw(trivia quote)) {
        my (@actual, @expected);
        for my $mode (qw(characters wire bytes)) {
            for my $label (sort keys %{$r->{blocked}{$mode}{$game}}) {
                my $s = $r->{blocked}{$mode}{$game}{$label};
                push @actual, [@$s{qw(active score stored metrics out timer)}];
                push @expected, [1, 0, 0, {}, [], $game eq 'quote' ? 1 : 0];
            }
        }
        $assert->is($json->encode(\@actual), $json->encode(\@expected),
            "$game: embedded Unicode/legacy answers leave the round, score, SQL, metrics and timer untouched");
    }
    my %texts = (
        latin_prefix => "\x{100}on", latin_suffix => "on\x{153}",
        cyrillic => "\x{43f}\x{43e}\x{434}\x{430}\x{440}\x{43e}\x{43a}",
        cjk_prefix => "\x{5b57}on", cjk_suffix => "on\x{5b57}",
        digit_prefix => "\x{660}on", digit_suffix => "on\x{660}",
        number_prefix => "\x{2167}on", number_suffix => "on\x{2167}",
        mark_prefix => "\x{301}on", mark_suffix => "on\x{301}",
        nonbmp_letter => "on\x{10400}",
    );
    my (@masked, @expected_masked);
    for my $mode (qw(characters wire)) {
        for my $label (sort keys %texts) {
            my $s = $r->{masks}{blocked}{$mode}{$label};
            my ($shown) = $s->{out}[0][1] =~ /Who said: "\x02(.*?)\x02"/s;
            push @masked, [$shown, $s->{active}, $s->{timer}];
            push @expected_masked, ["Longue citation: $texts{$label} ; ???.", 1, 1];
        }
    }
    $assert->is($json->encode(\@masked), $json->encode(\@expected_masked),
        'quotegame masks the separate author without damaging the surrounding Unicode word');
    my (@accepted, @expected_accepted);
    for my $mode (qw(characters wire bytes)) {
        for my $game (qw(trivia quote)) {
            for my $label (sort keys %{$r->{valid}{$mode}{$game}}) {
                my $s = $r->{valid}{$mode}{$game}{$label};
                my $win = $mode eq 'bytes' && $label =~ /^(?:emoji|unicode_punctuation)$/ ? 0 : 1;
                my $metric = $game eq 'trivia' ? 'mediabot_trivia_correct_total' : 'mediabot_quotegame_correct_total';
                push @accepted, [@$s{qw(active score stored timer)}, $s->{metrics}{$metric} // 0, scalar @{$s->{out}}];
                push @expected_accepted, [!$win ? 1 : 0, $win, $game eq 'trivia' ? $win : 0,
                    $game eq 'quote' && !$win ? 1 : 0, $win, $win];
            }
        }
    }
    $assert->is($json->encode(\@accepted), $json->encode(\@expected_accepted),
        'standalone answers, Unicode punctuation and emoji work; legacy high-byte boundary behavior remains');
};

# t/cases/670_mb457_karmawatch_list_recent_score.t
# =============================================================================
# mb457 — !karmawatch list : score "courant" déterministe.
#
# Le mode `list` affiche, pour chaque nick surveillé, son score karma "courant"
# (commentaire IMP19). L'ancien code parcourait `keys %_karma_log` (ordre de
# hash NON déterministe) et s'arrêtait (`last`) au premier canal contenant une
# entrée -> pour un nick actif sur plusieurs canaux, le score affiché était
# arbitraire, et potentiellement périmé.
#
# mb457-B1 sélectionne l'entrée la PLUS RÉCENTE (max `ts`) toutes canaux
# confondus. On valide (a) la sémantique de sélection sur une fixture
# multi-canal, et (b) la présence du comparateur ts dans le source.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_670 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

# Réplique de la sélection mb457-B1 : entrée de score la plus récente pour $wt,
# tous canaux confondus.
sub _current_score {
    my ($karma_log, $wt) = @_;
    my $best;
    for my $ch (keys %$karma_log) {
        for my $e (@{ $karma_log->{$ch} // [] }) {
            next unless defined $e->{nick}
                     && lc($e->{nick}) eq lc($wt)
                     && defined $e->{score};
            $best = $e if !defined $best || ($e->{ts} // 0) > ($best->{ts} // 0);
        }
    }
    return '' unless defined $best;   # sentinelle '' comme le vrai code
    my $sc = $best->{score};
    return $sc >= 0 ? "+$sc" : "$sc";
}

return sub {
    my ($assert) = @_;

    # Fixture : 'bob' a du karma sur 2 canaux ; l'entrée la plus récente est
    # sur #b (ts=200, score=7). Une entrée plus ancienne sur #a (ts=100,
    # score=3) NE doit PAS l'emporter, quel que soit l'ordre de hash.
    my $klog = {
        '#a' => [
            { ts => 50,  nick => 'bob',   score => 1, delta => '+1', from => 'x' },
            { ts => 100, nick => 'bob',   score => 3, delta => '+1', from => 'y' },
            { ts => 90,  nick => 'alice', score => 9, delta => '+1', from => 'z' },
        ],
        '#b' => [
            { ts => 200, nick => 'Bob',   score => 7, delta => '+1', from => 'w' },  # casse ≠, plus récent
            { ts => 150, nick => 'bob',   score => 5, delta => '-1', from => 'v' },
        ],
    };

    $assert->is(_current_score($klog, 'bob'), '+7',
        'karmawatch list : score le plus récent (max ts) toutes canaux confondus, insensible à la casse');

    # Nick sans entrée -> pas de score.
    $assert->is(_current_score($klog, 'nobody'), '',
        'nick sans entrée karma : aucun score (sentinelle vide)');

    # Score négatif -> signe conservé.
    my $klog_neg = { '#c' => [ { ts => 10, nick => 'zoe', score => -4 } ] };
    $assert->is(_current_score($klog_neg, 'zoe'), '-4',
        'score négatif : signe conservé');

    # Déterminisme : deux entrées, la plus récente gagne indépendamment de
    # l'ordre d'insertion.
    my $klog_ord = {
        '#x' => [ { ts => 300, nick => 'kai', score => 12 } ],
        '#y' => [ { ts => 250, nick => 'kai', score => 8  } ],
    };
    $assert->is(_current_score($klog_ord, 'kai'), '+12',
        'la plus récente gagne (ts 300 > 250), indépendamment du canal');

    # --- Scan source ---------------------------------------------------------
    my $src = _slurp_670(File::Spec->catfile('.', 'Mediabot', 'Karma.pm'));
    my ($blk) = $src =~ /(# IMP19: show current karma score.*?You are watching:)/s;
    $blk //= '';
    $assert->ok($blk ne '', 'bloc karmawatch list extrait');
    # mb459: la sélection est déléguée au helper partagé _karma_current_score.
    $assert->like($blk, qr/_karma_current_score\(\$self, \$wt\)/,
        'karmawatch list délègue à _karma_current_score (mb459)');
    $assert->unlike($blk, qr/reverse \@\$klog/,
        'ancien pattern non déterministe (reverse+last) supprimé');

    # MB919: execute the real vote handlers against a private SQLite database.
    # The bridge translates only MariaDB syntax; failures come from native
    # missing-table preparation and a rejecting SQLite trigger. No live service.
    require JSON::PP;
    my $probe = <<'MB919_NATIVE';
use strict;
use warnings;
use utf8;
use DBI;
use JSON::PP;
use Mediabot::Karma;
{
 package MB919::DBI;
 our @ISA = ('DBI');
 package MB919::DBI::db;
 our @ISA = ('DBI::db');
 sub prepare {
  my ($s,$sql,@rest)=@_;
  my $state=$s->{private_mb919};
  my $kind=$sql =~ /INSERT INTO KARMA\b/ ? 'vote'
   : $sql =~ /INSERT IGNORE INTO KARMA_LOG/ ? 'history'
   : $sql =~ /SELECT score/ ? 'score' : 'rank';
  push @{$state->{sql}},$sql if $state;
  # Only the SQLite test bridge changes dialect, never the runtime query.
  $sql =~ s/ON DUPLICATE KEY UPDATE score = score \+ \?/ON CONFLICT(id_channel,nick) DO UPDATE SET score = score + ?/;
  $sql =~ s/INSERT IGNORE INTO KARMA_LOG/INSERT OR IGNORE INTO KARMA_LOG/;
  $sql =~ s/NOW\(\)/CURRENT_TIMESTAMP/g;
  $sql =~ s/\bKARMA\b/absent_karma/g
   if $state && (($state->{fail}//'') eq 'prepare' && $kind eq 'vote'
    || ($state->{fail}//'') eq 'read' && $kind eq 'score');
  my $sth=$s->SUPER::prepare($sql,@rest);
  if($sth && $state){$sth->{private_mb919}={state=>$state,kind=>$kind}}
  return $sth;
 }
 package MB919::DBI::st;
 our @ISA = ('DBI::st');
 sub execute {
  my($s,@bind)=@_;my$p=$s->{private_mb919};
  push @{$p->{state}{binds}},[$p->{kind},@bind] if$p;
  return $s->SUPER::execute(@bind);
 }
 sub finish {
  my($s)=@_;my$p=$s->{private_mb919};
  $p->{state}{vote_finishes}++ if$p && $p->{kind} eq 'vote';
  return $s->SUPER::finish;
 }
 package MB919::Bot;
 sub gethChannelsNicksOnChan {qw(Alice Bob Carol Dave Erin)}
 package MB919::Channel;
 sub get_id {1}
 package MB919::Metrics;
 sub inc {$_[0]{counts}{$_[1]}++}
 package MB919::Log;
 sub log {push @{$_[0]{events}},[$_[1],$_[2]];1}
 package MB919::Ctx;
 sub bot {$_[0]{bot}} sub nick {$_[0]{nick}//'Alice'}
 sub channel {'#test'} sub args {$_[0]{args}} sub message {undef}
}
$INC{'MB919/DBI.pm'}=__FILE__;
sub fixture {
 my($fail)=@_;
 my$dbh=DBI->connect('dbi:SQLite:dbname=:memory:','','',{
  RootClass=>'MB919::DBI',RaiseError=>0,PrintError=>0,AutoCommit=>1});
 die 'SQLite unavailable' unless$dbh;
 $dbh->do('CREATE TABLE KARMA(id_channel INTEGER,nick TEXT,score INTEGER,UNIQUE(id_channel,nick))') or die$dbh->errstr;
 $dbh->do('CREATE TABLE KARMA_LOG(id_channel INTEGER,nick TEXT,delta INTEGER,from_nick TEXT,score INTEGER,ts TEXT)') or die$dbh->errstr;
 if(($fail//'') eq 'execute'){
  $dbh->do(q{CREATE TRIGGER reject_vote BEFORE INSERT ON KARMA BEGIN SELECT RAISE(FAIL,'fixture rejects vote'); END}) or die$dbh->errstr;
 }
 my$state={fail=>$fail//'',notices=>[],messages=>[],at_notice=>[],sql=>[],binds=>[],vote_finishes=>0};
 $dbh->{private_mb919}=$state;
 my$b=bless {dbh=>$dbh,channels=>{'#test'=>bless({},'MB919::Channel')},
  _karma_watch=>{Watcher=>['bob']},metrics=>bless({counts=>{}},'MB919::Metrics'),
  logger=>bless({events=>[]},'MB919::Log'),probe=>$state},'MB919::Bot';
 return($b,$state);
}
no warnings qw(redefine once);
local *Mediabot::Helpers::botNotice=sub {
 my($b,$nick,$text)=@_;my$s=$b->{probe};
 push @{$s->{notices}},[$nick,$text];
 push @{$s->{at_notice}},{score=>scalar($b->{dbh}->selectrow_array(q{SELECT (score) FROM KARMA WHERE id_channel=1 AND nick='bob'})),finishes=>$s->{vote_finishes}};
 return 1;
};
local *Mediabot::Helpers::botPrivmsg=sub {push @{$_[0]{probe}{messages}},[$_[1],$_[2]];1};
local *Mediabot::UserCommands::botNotice=sub {goto &Mediabot::Helpers::botNotice};
local *Mediabot::UserCommands::botPrivmsg=sub {goto &Mediabot::Helpers::botPrivmsg};
sub summary {
 my($b,$s)=@_;
 $s->{stored_score}=$b->{dbh}->selectrow_array(q{SELECT (score) FROM KARMA WHERE id_channel=1 AND nick='bob'});
 $s->{history_rows}=$b->{dbh}->selectrow_array('SELECT COUNT(*) FROM KARMA_LOG');
 $s->{memory_history}=$b->{_karma_log}{'#test'}//[];
 $s->{cooldown_reserved}=exists($b->{_karma_cooldown}{'#test'}{'alice:bob'})?1:0;
 $s->{metrics}=$b->{metrics}{counts};
 return$s;
}
my%out;
for my$style(qw(automatic explicit)){
 for my$op(qw(++ --)){
  for my$fail(qw(none prepare execute read)){
   my($b,$s)=fixture($fail eq 'none'?'':$fail);
   if($style eq 'automatic'){Mediabot::Karma::processKarma($b,'Alice','#test',"bob$op")}
   else{Mediabot::Karma::mbKarma_ctx(bless({bot=>$b,args=>[$op,'bob']},'MB919::Ctx'))}
   $out{$style}{$op}{$fail}=summary($b,$s);
   $b->{dbh}->disconnect;
  }
 }
}
# A failed attempt still consumes the historical anti-spam reservation.
# Once the normal 30-second window has expired, a later vote can succeed.
{
 my($b,$s)=fixture('execute');
 Mediabot::Karma::processKarma($b,'Alice','#test','bob++');
 $b->{dbh}->do('DROP TRIGGER reject_vote');
 Mediabot::Karma::processKarma($b,'Alice','#test','bob++');
 $out{cooldown}={notices=>[@{$s->{notices}}],messages=>[@{$s->{messages}}],score=>scalar($b->{dbh}->selectrow_array('SELECT (score) FROM KARMA')),attempts=>$b->{metrics}{counts}{mediabot_karma_votes_total}};
 $b->{_karma_cooldown}{'#test'}{'alice:bob'}=time()-31;
 Mediabot::Karma::processKarma($b,'Alice','#test','bob++');
 $out{recovery}=summary($b,$s);
 $b->{dbh}->disconnect;
}
# A refused target must not suppress a subsequent valid target in the message.
{
 my($b,$s)=fixture('');
 $b->{_karma_watch}{Watcher}=['bob','carol'];
 $b->{dbh}->do(q{CREATE TRIGGER reject_bob BEFORE INSERT ON KARMA WHEN NEW.nick='bob' BEGIN SELECT RAISE(FAIL,'fixture rejects bob'); END});
 Mediabot::Karma::processKarma($b,'Alice','#test','bob++ carol--');
 $out{mixed}=summary($b,$s);
 $out{mixed}{scores}=$b->{dbh}->selectall_arrayref('SELECT nick,score FROM KARMA ORDER BY nick');
 $b->{dbh}->disconnect;
}
# The sixth distinct voter must be blocked, without skipping the next target.
{
 my($b,$s)=fixture('');$b->{_karma_watch}{Watcher}=['bob','carol'];
 Mediabot::Karma::processKarma($b,"Voter$_",'#test','bob++') for 1..5;
 Mediabot::Karma::processKarma($b,'Voter6','#test','bob++ carol--');
 Mediabot::Karma::processKarma($b,'Voter7','#test','bob++');
 my$warns=grep {$_->[1]=~/Karma brigade detected/}@{$s->{messages}};
 $out{brigade}={scores=>$b->{dbh}->selectall_arrayref('SELECT nick,score FROM KARMA ORDER BY nick'),
  watcher_count=>scalar@{$s->{notices}},warnings=>$warns,attempts=>$b->{metrics}{counts}{mediabot_karma_votes_total},
  blocked=>$b->{metrics}{counts}{mediabot_karma_brigade_blocks},
  history_rows=>scalar($b->{dbh}->selectrow_array('SELECT COUNT(*) FROM KARMA_LOG'))};
 $_=time()-31 for values%{$b->{_karma_brigade}{'brigade:bob:#test'}{nicks}};
 Mediabot::Karma::processKarma($b,'Voter8','#test','bob--');
 $out{brigade_recovery}={score=>scalar($b->{dbh}->selectrow_array(q{SELECT (score) FROM KARMA WHERE nick='bob'})),
  notices=>scalar@{$s->{notices}},warned=>$b->{_karma_brigade}{'brigade:bob:#test'}{warned},
  history_rows=>scalar($b->{dbh}->selectrow_array('SELECT COUNT(*) FROM KARMA_LOG'))};
 $b->{dbh}->disconnect;
}
print JSON::PP->new->canonical->utf8->encode(\%out);
MB919_NATIVE
    open my $native, '-|', $^X, '-I.', '-It/lib', '-e', $probe
        or die "start karma write-boundary probe: $!";
    my $output = do { local $/; <$native> };
    close $native;
    $assert->is($? >> 8, 0, 'native karma write-boundary probe completes');
    my $r = JSON::PP::decode_json($output);
    my $json = JSON::PP->new->canonical;
    my (@nominal, @expected_nominal, @failed, @expected_failed,
        @cleanup, @expected_cleanup, @read, @expected_read);
    for my $style (qw(automatic explicit)) {
        for my $op (qw(++ --)) {
            my $delta = $op eq '++' ? 1 : -1;
            my $score_text = $delta > 0 ? '+1' : '-1';
            my $notice = [['Watcher', "[karmawatch] bob received $op karma from Alice on #test"]];
            my $s = $r->{$style}{$op}{none};
            push @nominal, [@$s{qw(stored_score at_notice notices messages history_rows cooldown_reserved metrics)}];
            push @expected_nominal, [$delta, [{score => $delta, finishes => 1}], $notice,
                [['#test', "bob's karma: $score_text (rank #1)"]], 1, 1,
                {mediabot_karma_votes_total => 1}];
            for my $failure (qw(prepare execute)) {
                $s = $r->{$style}{$op}{$failure};
                push @failed, [@$s{qw(stored_score notices messages history_rows memory_history cooldown_reserved metrics)}];
                push @expected_failed, [undef, [], [], 0, [], 1,
                    {mediabot_karma_votes_total => 1}];
                push @cleanup, $s->{vote_finishes};
                push @expected_cleanup, $failure eq 'execute' ? 1 : 0;
            }
            $s = $r->{$style}{$op}{read};
            push @read, [@$s{qw(stored_score at_notice notices messages history_rows)}];
            push @expected_read, [$delta, [{score => $delta, finishes => 1}], $notice, [], 0];
        }
    }
    $assert->is($json->encode(\@nominal), $json->encode(\@expected_nominal),
        'both vote entry points announce signed votes after SQL storage and statement release');
    $assert->is($json->encode(\@failed), $json->encode(\@expected_failed),
        'prepare/execute failures create no watcher, channel or history claim; attempt guards remain');
    $assert->is($json->encode(\@cleanup), $json->encode(\@expected_cleanup),
        'failed native executions release their statement and never finish a missing statement');
    $assert->is($json->encode(\@read), $json->encode(\@expected_read),
        'a stored vote remains announced if the subsequent score read fails');
    $assert->ok(!@{$r->{cooldown}{notices}} && !defined($r->{cooldown}{score})
        && $r->{cooldown}{attempts} == 1 && @{$r->{cooldown}{messages}} == 1
        && $r->{cooldown}{messages}[0][1] =~ /wait [0-9]+s before voting/,
        'SQL failure still reserves the normal cooldown and prevents an immediate retry');
    $assert->is($json->encode([@{$r->{recovery}}{qw(stored_score notices history_rows vote_finishes metrics)}]),
        $json->encode([1, [['Watcher', '[karmawatch] bob received ++ karma from Alice on #test']],
            1, 2, {mediabot_karma_votes_total => 2}]),
        'after the existing cooldown expires a later vote succeeds and is announced once');
    $assert->is($json->encode([@{$r->{mixed}}{qw(scores notices messages history_rows vote_finishes)}]),
        $json->encode([[['carol', -1]], [['Watcher', '[karmawatch] carol received -- karma from Alice on #test']],
            [['#test', "carol's karma: -1 (rank #1)"]], 1, 2]),
        'a failed first target does not announce a ghost vote or suppress the next valid target');

    $assert->is($json->encode([$r->{brigade}, $r->{brigade_recovery}]),
        $json->encode([{scores => [['bob', 5], ['carol', -1]], watcher_count => 6,
            warnings => 1, attempts => 6, blocked => 2, history_rows => 6},
            {score => 4, notices => 7, warned => 0, history_rows => 7}]),
        'the sixth distinct voter is blocked; another target and an expired window remain usable');
};

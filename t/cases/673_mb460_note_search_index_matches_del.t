# t/cases/673_mb460_note_search_index_matches_del.t
# =============================================================================
# mb460 — !note search : index affiché = index de suppression.
#
# `!note search <mot>` affichait les résultats numérotés 1..N selon leur position
# DANS LA LISTE DES HITS. Or `!notes del <index>` supprime selon la position dans
# la liste COMPLÈTE des notes. Quand les correspondances ne sont pas les
# premières notes, l'index affiché ne correspondait pas à l'index de suppression
# -> l'utilisateur supprimait la mauvaise note.
#
# mb460-B1 affiche l'index réel (position dans la liste complète) = celui
# qu'attend `!notes del`. On valide la sémantique (réplique) + le câblage source.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_673 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

# Réplique de la sélection corrigée : renvoie la liste [index_complet_1based, texte].
sub _search_hits {
    my ($notes, $query) = @_;
    my @hits;
    for my $idx (0 .. $#$notes) {
        my $n   = $notes->[$idx];
        my $txt = ref($n) eq 'HASH' ? ($n->{text} // '') : ($n // '');
        push @hits, [ $idx + 1, $txt ] if lc($txt) =~ /\Q\L$query\E/;
    }
    return @hits;
}

return sub {
    my ($assert) = @_;

    # 5 notes ; 'pizza' matche les notes en positions 2 et 4 (1-based).
    my $notes = [
        { id => 10, text => 'buy milk' },
        { id => 11, text => 'order PIZZA tonight' },
        { id => 12, text => 'call mom' },
        { id => 13, text => 'pizza dough recipe' },
        { id => 14, text => 'gym at 6' },
    ];

    my @hits = _search_hits($notes, 'pizza');
    $assert->is(scalar(@hits), 2, 'deux correspondances pour "pizza"');

    # Les index affichés doivent être 2 et 4 (positions dans la liste complète),
    # PAS 1 et 2 (positions dans les hits).
    $assert->is($hits[0][0], 2, 'premier hit affiché à l\'index 2 (et non 1)');
    $assert->is($hits[1][0], 4, 'second hit affiché à l\'index 4 (et non 2)');

    # Un !notes del sur l'index affiché supprime bien la note recherchée :
    # del 4 -> notes->[3] = 'pizza dough recipe'.
    my $del_index_shown = $hits[1][0];          # 4
    my $target_note = $notes->[$del_index_shown - 1];
    $assert->like($target_note->{text}, qr/pizza dough/,
        'l\'index affiché pointe bien la note recherchée pour !notes del');

    # Recherche insensible à la casse (PIZZA / pizza).
    $assert->like($hits[0][1], qr/PIZZA/, 'match insensible à la casse');

    # --- Câblage source ------------------------------------------------------
    my $src = _slurp_673(File::Spec->catfile('.', 'Mediabot', 'CommunityState.pm'));
    my ($blk) = $src =~ /(# W7: !note search.*?return 1;\n    \}\n    unless \(\$text ne '')/s;
    $blk //= '';
    $assert->ok($blk ne '', 'bloc !note search extrait');
    $assert->like($blk, qr/push \@hits, \[ \$idx, \$n \]/,
        'search conserve l\'index complet de chaque hit');
    $assert->like($blk, qr/\[" \. \(\$idx \+ 1\) \. "\]/,
        'search affiche [idx+1] = index de la liste complète (mb460)');
    $assert->like($blk, qr/mb460-B1/, 'tag mb460-B1 présent');
    $assert->unlike($blk, qr/for my \$i \(0\.\.\$#hits\)/,
        'ancien indexage positionnel sur les hits supprimé');

    # MB921: exercise both real entry points with cold/warm caches and native
    # SQLite data. Distinct list ordinals and persistent ids detect wrong deletes.
    require JSON::PP;
    my $probe = <<'MB921_NATIVE';
use strict;
use warnings;
use utf8;
use DBI;
use JSON::PP;
use Mediabot::CommunityState;
use Mediabot::UserCommands;
{
 package MB921::DBI;our @ISA=('DBI');
 package MB921::DBI::db;our @ISA=('DBI::db');
 sub prepare {
  my($s,$sql,@rest)=@_;my$state=$s->{private_mb921};
  push @{$state->{sql}},$sql if$state;
  my$sth=$s->SUPER::prepare($sql,@rest);$sth->{private_mb921}={state=>$state,sql=>$sql} if$sth&&$state;return$sth;
 }
 package MB921::DBI::st;our @ISA=('DBI::st');
 sub execute {my($s,@bind)=@_;my$p=$s->{private_mb921};push @{$p->{state}{binds}},[$p->{sql},@bind] if$p;return$s->SUPER::execute(@bind)}
 package MB921::Ordinal;use overload '""'=>sub{'2'},'0+'=>sub{2},fallback=>1;
 package MB921::Log;sub log {push @{$_[0]{events}},[$_[1],$_[2]];1}
 package MB921::Ctx;
 sub bot {$_[0]{bot}} sub nick {$_[0]{nick}//'Alice'} sub args {$_[0]{args}} sub channel {'#test'} sub message {undef}
}
$INC{'MB921/DBI.pm'}=__FILE__;
my@base=([10,'first'],[21,'deuxième'],[35,'third'],[77,'pizza recipe'],[99,'last']);
sub fixture {
 my($warm)=@_;my$h=DBI->connect('dbi:SQLite:dbname=:memory:','','',{
  RootClass=>'MB921::DBI',RaiseError=>1,PrintError=>0,AutoCommit=>1,sqlite_unicode=>1});
 $h->do('CREATE TABLE NOTE(id_note INTEGER PRIMARY KEY,nick TEXT,text TEXT)');
 $h->do('INSERT INTO NOTE VALUES(?,?,?)',undef,$_->[0],'alice',$_->[1]) for@base;
 $h->do(q{INSERT INTO NOTE VALUES(200,'bob','other user')});
 my$s={notices=>[],sql=>[],binds=>[],warnings=>[]};$h->{private_mb921}=$s;
 my$b={dbh=>$h,probe=>$s,logger=>bless({events=>[]},'MB921::Log')};
 $b->{_notes}{alice}=[map{{id=>$_->[0],text=>$_->[1]}}@base] if$warm;
 return($b,$s);
}
no warnings qw(redefine once);
local *Mediabot::UserCommands::botNotice=sub{push @{$_[0]{probe}{notices}},[$_[1],$_[2]];1};
local *Mediabot::UserCommands::botPrivmsg=sub{push @{$_[0]{probe}{notices}},[$_[1],$_[2]];1};
sub run {
 my($style,$warm,$args)=@_;my($b,$s)=fixture($warm);
 my$c=bless {bot=>$b,args=>$args},'MB921::Ctx';
 my$method=$style eq 'module'?\&Mediabot::CommunityState::mbNotes_ctx:\&Mediabot::UserCommands::mbNotes_ctx;
 local$SIG{__WARN__}=sub{push @{$s->{warnings}},@_};
 my$ret=$method->($c);
 $s->{return}=$ret;$s->{cache}=$b->{_notes}{alice}//[];
 $s->{rows}=$b->{dbh}->selectall_arrayref('SELECT id_note,nick,text FROM NOTE ORDER BY id_note');
 $s->{deletes}=scalar grep{/^DELETE FROM NOTE/}@{$s->{sql}};
 $b->{dbh}->disconnect;return$s;
}
my@bad=(['suffix','2oops'],['fraction','2.5'],['scientific','2e0'],['unicode_suffix',"2\x{661}"],
 ['unicode_digit',"\x{662}"],['negative','-2'],['empty',''],['internal_space','2 3'],
 ['newline',"2\n"],['hash',{}],['array',[]],['object',bless({},'MB921::Ordinal')],['huge','9'x1024],['zero','0'],['outside','6']);
my@good=(['first',['del','1']],['second',['del','2']],['last',['del','5']],
 ['leading_zeros',['del','0002']],['plus',['del','+2']],['plus_zeros',['del','+0002']],
 ['spaces',['del'," \t2\t "]],['default',['del']],['undefined',['del',undef]],
 ['many_zeros',['del',('0'x1024).'2']],['list',[]]);
my%out;
for my$style(qw(module facade)){
 for my$warm(0,1){
  for my$v(@bad){$out{bad}{$style}{$warm}{$v->[0]}=run($style,$warm,['del',$v->[1]])}
  for my$v(@good){$out{good}{$style}{$warm}{$v->[0]}=run($style,$warm,$v->[1])}
 }
}
# Search's displayed list ordinal must keep selecting the same persisted id.
{
 my($b,$s)=fixture(0);my$c=bless{bot=>$b,args=>['search','pizza']},'MB921::Ctx';
 Mediabot::CommunityState::mbNote_ctx($c);
 $s->{search_notices}=[@{$s->{notices}}];$s->{notices}=[];
 $c->{args}=['del','4'];Mediabot::CommunityState::mbNotes_ctx($c);
 $s->{rows}=$b->{dbh}->selectall_arrayref('SELECT id_note,nick,text FROM NOTE ORDER BY id_note');
 $s->{cache}=$b->{_notes}{alice};$out{search_delete}=$s;$b->{dbh}->disconnect;
}
print JSON::PP->new->canonical->utf8->encode(\%out);
MB921_NATIVE
    open my $native, '-|', $^X, '-I.', '-It/lib', '-e', $probe
        or die "start native note-index probe: $!";
    my $output = do { local $/; <$native> };
    close $native;
    $assert->is($? >> 8, 0, 'native note-index probe completes');
    my $r = JSON::PP::decode_json($output);
    my $json = JSON::PP->new->canonical;
    my @base = ([10, 'first'], [21, "deuxi\x{e8}me"], [35, 'third'],
        [77, 'pizza recipe'], [99, 'last']);
    my @all_rows = ((map { [$_->[0], 'alice', $_->[1]] } @base), [200, 'bob', 'other user']);
    my @all_cache = map { {id => $_->[0], text => $_->[1]} } @base;
    my (@bad, @expected_bad, @good, @expected_good);
    for my $style (qw(module facade)) {
        for my $warm (0, 1) {
            for my $label (sort keys %{$r->{bad}{$style}{$warm}}) {
                my $s = $r->{bad}{$style}{$warm}{$label};
                push @bad, [@$s{qw(return cache rows notices warnings deletes)}];
                push @expected_bad, [1, \@all_cache, \@all_rows,
                    [['Alice', 'Note not found.']], [], 0];
            }
            for my $label (sort keys %{$r->{good}{$style}{$warm}}) {
                my $s = $r->{good}{$style}{$warm}{$label};
                my $id = $label =~ /^(?:first|default|undefined)$/ ? 10
                    : $label eq 'last' ? 99 : $label eq 'list' ? undef : 21;
                my @cache = grep { !defined($id) || $_->{id} != $id } @all_cache;
                my @rows = grep { !defined($id) || $_->[0] != $id } @all_rows;
                my @notices = defined($id) ? (['Alice', 'Note deleted.'])
                    : (['Alice', '5 note(s):'], map { ['Alice', sprintf('  [%d] %s', $_+1, $base[$_][1])] } 0..$#base);
                my @deletes = grep { $_->[0] =~ /^DELETE FROM NOTE/ } @{$s->{binds}};
                push @good, [@$s{qw(return cache rows notices warnings deletes)}, \@deletes];
                push @expected_good, [1, \@cache, \@rows, \@notices, [], defined($id) ? 1 : 0,
                    defined($id) ? [['DELETE FROM NOTE WHERE nick = ? AND id_note = ?', 'alice', $id]] : []];
            }
        }
    }
    $assert->is($json->encode(\@bad), $json->encode(\@expected_bad),
        'malformed/ref/out-of-range indexes preserve every note and execute no DELETE or warning');
    $assert->is($json->encode(\@good), $json->encode(\@expected_good),
        'integer/default/plus/zero/space forms preserve the actual saved id, owner and displayed ordinal');
    $assert->is($json->encode([@{$r->{search_delete}}{qw(search_notices notices cache rows)}]),
        $json->encode([[['Alice', "1/5 note(s) matching 'pizza':"], ['Alice', '  [4] pizza recipe']],
            [['Alice', 'Note deleted.']], [grep {$_->{id} != 77} @all_cache],
            [grep {$_->[0] != 77} @all_rows]]),
        'a native search result at ordinal four still deletes persisted id 77 and preserves other users');
};

# t/cases/689_mb478_factoid_details.t
# =============================================================================
# mb478 — Valorisation des métadonnées factoid :
#   !factoids top       -> classement par nombre de consultations (hits)
#   !factoid <keyword>  -> détail (auteur, dates, nombre de rappels)
#
# On teste les deux réellement via MockBot + un faux DBH émulant FACTOID avec
# ses métadonnées (hits, created_by_nick, dates).
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

use MockBot;
use Mediabot::Context;
use Mediabot::UserCommands;

sub _slurp_689 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

{
    package FakeChan689; sub new { bless { id => $_[1] }, $_[0] } sub get_id { $_[0]->{id} }
    package FakeSTH689;
    sub new { my ($c,%a)=@_; bless { %a, i=>0 }, $c }
    sub execute {
        my ($s,@b)=@_; my $store=$s->{store}; $s->{rows}=[]; $s->{i}=0;
        my $sql=$s->{sql};
        if ($sql =~ /SELECT keyword, hits FROM FACTOID/i) {           # factoids top
            my $idc=$b[0];
            my @r;
            for my $k (keys %$store) {
                my ($ci,$kw)=split /\0/,$k; next unless $ci==$idc;
                next unless $store->{$k}{hits} > 0;
                push @r, { keyword=>$kw, hits=>$store->{$k}{hits} };
            }
            @r = sort { $b->{hits} <=> $a->{hits} || $a->{keyword} cmp $b->{keyword} } @r;
            $s->{rows}=[ @r[0..($#r>9?9:$#r)] ] if @r;
        }
        elsif ($sql =~ /SELECT value, created_by_nick,/i) {           # factoid <kw> details
            my ($idc,$kw)=@b; my $k="$idc\0$kw";
            if (exists $store->{$k}) {
                my $f=$store->{$k};
                $s->{rows}=[ { value=>$f->{value}, created_by_nick=>$f->{nick},
                               created_d=>$f->{created}, updated_d=>$f->{updated}, hits=>$f->{hits} } ];
            }
        }
        return 1;
    }
    sub fetchrow_hashref { my $s=shift; return undef if $s->{i}>=@{$s->{rows}}; return $s->{rows}[$s->{i}++]; }
    sub fetchrow_array   { my $s=shift; return () if $s->{i}>=@{$s->{rows}}; my $r=$s->{rows}[$s->{i}++]; return ($r->{keyword},$r->{hits}); }
    sub finish { 1 }
    package FakeDBH689;
    sub new { bless { store=>($_[1]//{}) }, $_[0] }
    sub prepare { my ($self,$sql)=@_; FakeSTH689->new(sql=>$sql, store=>$self->{store}) }
    sub ping { 1 }
}

my @sent;
return sub {
    my ($assert) = @_;

    no warnings 'redefine';
    local *Mediabot::UserCommands::botNotice  = sub { push @sent, { to=>$_[1], text=>$_[2] } };
    local *Mediabot::UserCommands::botPrivmsg = sub { push @sent, { to=>$_[1], text=>$_[2] } };
    use warnings 'redefine';

    my %store = (
        "42\0coffee" => { value=>'black gold', nick=>'alice', created=>'2026-07-01', updated=>'2026-07-01', hits=>7 },
        "42\0perl"   => { value=>'a language', nick=>'bob',   created=>'2026-07-02', updated=>'2026-07-05', hits=>3 },
        "42\0tea"    => { value=>'a drink',    nick=>'carol', created=>'2026-07-03', updated=>'2026-07-03', hits=>0 },
    );
    my $mkbot = sub {
        MockBot->new(dbh=>FakeDBH689->new(\%store), channels=>{'#test'=>FakeChan689->new(42)});
    };

    # -------------------------------------------------------------------------
    # 1. factoids top : classe par hits desc, exclut hits=0.
    # -------------------------------------------------------------------------
    {
        @sent=();
        my $bot=$mkbot->();
        my $ctx=Mediabot::Context->new(bot=>$bot, nick=>'alice', channel=>'#test', args=>['top']);
        Mediabot::UserCommands::mbFactoids_ctx($ctx);
        my $j=join("\n", map { $_->{text} } @sent);
        $assert->like($j, qr/Top factoids on #test:/, 'factoids top -> en-tête');
        $assert->like($j, qr/coffee \(7\).*perl \(3\)/, 'ordre par hits desc (coffee avant perl)');
        $assert->unlike($j, qr/\btea\b/, 'exclut les factoids jamais consultés (hits=0)');
    }

    # -------------------------------------------------------------------------
    # 2. factoid <keyword> : détail (auteur, dates, rappels).
    # -------------------------------------------------------------------------
    {
        @sent=();
        my $bot=$mkbot->();
        my $ctx=Mediabot::Context->new(bot=>$bot, nick=>'bob', channel=>'#test', args=>['perl']);
        Mediabot::UserCommands::mbFactoid_ctx($ctx);
        my $j=join("\n", map { $_->{text} } @sent);
        $assert->like($j, qr/factoid 'perl':/, 'en-tête factoid');
        $assert->like($j, qr/created 2026-07-02 by bob/, 'auteur + date de création');
        $assert->like($j, qr/updated 2026-07-05/, 'date de mise à jour (différente)');
        $assert->like($j, qr/3 recall\(s\)/, 'nombre de rappels');
        $assert->like($j, qr/value: a language/, 'valeur affichée');
    }

    # -------------------------------------------------------------------------
    # 3. factoid <keyword> non modifié : pas de "updated" redondant.
    # -------------------------------------------------------------------------
    {
        @sent=();
        my $bot=$mkbot->();
        my $ctx=Mediabot::Context->new(bot=>$bot, nick=>'alice', channel=>'#test', args=>['coffee']);
        Mediabot::UserCommands::mbFactoid_ctx($ctx);
        my $j=join("\n", map { $_->{text} } @sent);
        $assert->like($j, qr/created 2026-07-01 by alice/, 'création affichée');
        $assert->unlike($j, qr/updated/, 'pas de "updated" si identique à created');
    }

    # -------------------------------------------------------------------------
    # 4. factoid inconnu.
    # -------------------------------------------------------------------------
    {
        @sent=();
        my $bot=$mkbot->();
        my $ctx=Mediabot::Context->new(bot=>$bot, nick=>'bob', channel=>'#test', args=>['nope']);
        Mediabot::UserCommands::mbFactoid_ctx($ctx);
        my $j=join("\n", map { $_->{text} } @sent);
        $assert->like($j, qr/don't know 'nope'/, 'factoid inconnu signalé');
    }

    # -------------------------------------------------------------------------
    # 5. Intégration : export, dispatch, help.
    # -------------------------------------------------------------------------
    {
        my $uc=_slurp_689(File::Spec->catfile('.', 'Mediabot', 'UserCommands.pm'));
        $assert->like($uc, qr/^\s*mbFactoid_ctx\s*$/m, 'mbFactoid_ctx exporté');
        my $med=_slurp_689(File::Spec->catfile('.', 'Mediabot', 'Mediabot.pm'));
        $assert->like($med, qr/factoid\s*=>\s*sub\s*\{\s*mbFactoid_ctx/, 'factoid dans le dispatch');
        $assert->like($med, qr/^factoid\|factoid <keyword>/m, 'factoid documenté');
        $assert->like($med, qr/factoids \[pattern\\?\|top\]/, 'factoids top documenté');
    }
};

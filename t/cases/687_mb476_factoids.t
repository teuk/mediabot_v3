# t/cases/687_mb476_factoids.t
# =============================================================================
# mb476 — Factoids : faits partagés par canal (!learn / !whatis / !forget /
#         !factoids), stockés dans la table FACTOID.
#
# On teste réellement les 4 handlers via MockBot + un faux DBH stateful qui
# émule FACTOID (UPSERT sur (id_channel,keyword), SELECT, DELETE, LIKE). Les
# sorties passent par botNotice/botPrivmsg -> capturées via override local.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

use MockBot;
use Mediabot::Context;
use Mediabot::UserCommands;

sub _slurp_687 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

# --- faux channel + user ---
{
    package FakeChan687; sub new { bless { id => $_[1] }, $_[0] } sub get_id { $_[0]->{id} }
    package FakeUser687; sub new { bless { id => $_[1], nick => $_[2] }, $_[0] }
      sub id { $_[0]->{id} } sub nickname { $_[0]->{nick} }
}

# --- faux DBH stateful émulant FACTOID ---
# Store partagé : { "$id_channel\0$keyword" => { value, created_by_nick, hits } }
{
    package FakeSTH687;
    sub new { my ($c,%a)=@_; bless { %a, i=>0 }, $c }
    sub _assign_id {
        my ($store,$row)=@_;
        return $row->{id_factoid} if defined $row->{id_factoid};
        my $max=0;
        for my $item (values %$store) {
            $max=$item->{id_factoid} if ($item->{id_factoid}//0)>$max;
        }
        return $row->{id_factoid}=$max+1;
    }
    sub execute {
        my ($s, @bind) = @_;
        my $store = $s->{store};
        my $sql   = $s->{sql};
        $s->{rows} = [];
        $s->{i} = 0;
        $s->{affected} = 0;
        if ($sql =~ /INSERT INTO FACTOID/i) {
            my ($idc,$kw,$val,$uid,$nick) = @bind;
            my $k = "$idc\0$kw";
            if (exists $store->{$k}) { $store->{$k}{value} = $val; }   # ON DUP UPDATE
            else { $store->{$k} = { value=>$val, created_by=>$uid, created_by_nick=>$nick, hits=>0 }; }
            _assign_id($store,$store->{$k});
            return 1;
        }
        if ($sql =~ /SELECT id_factoid, value, created_by_nick FROM FACTOID/i) {
            my ($idc,$kw) = @bind; my $k="$idc\0$kw";
            $s->{rows} = exists $store->{$k}
              ? [ { id_factoid=>_assign_id($store,$store->{$k}),
                    value=>$store->{$k}{value}, created_by_nick=>$store->{$k}{created_by_nick} } ] : [];
            return 1;
        }
        if ($sql =~ /SELECT id_factoid, created_by, created_by_nick FROM FACTOID/i) {
            my ($idc,$kw) = @bind; my $k="$idc\0$kw";
            $s->{rows} = exists $store->{$k}
              ? [ { id_factoid=>_assign_id($store,$store->{$k}),
                    created_by=>$store->{$k}{created_by}, created_by_nick=>$store->{$k}{created_by_nick} } ] : [];
            return 1;
        }
        if ($sql =~ /UPDATE FACTOID SET hits/i) {
            my ($id,$idc)=@bind;
            for my $key (keys %$store) {
                my ($channel)=split /\0/,$key;
                $store->{$key}{hits}++
                    if $channel==$idc && ($store->{$key}{id_factoid}//0)==$id;
            }
            return 1;
        }
        if ($sql =~ /DELETE FROM FACTOID/i) {
            my ($id,$idc)=@bind;
            for my $key (keys %$store) {
                my ($channel)=split /\0/,$key;
                next unless $channel==$idc && ($store->{$key}{id_factoid}//0)==$id;
                delete $store->{$key}; $s->{affected}++;
            }
            return 1;
        }
        if ($sql =~ /SELECT keyword FROM FACTOID/i) {
            my $idc = $bind[0];
            my @keys;
            for my $k (sort keys %$store) {
                my ($ci,$kw) = split /\0/, $k;
                next unless $ci == $idc;
                if (@bind > 1) {   # LIKE pattern
                    my $like = $bind[1];
                    (my $re = $like) =~ s/([.^$@%*+?()\[\]{}|\\])/\\$1/g;
                    $re =~ s/\\%/.*/g; $re =~ s/\\_/./g;
                    next unless $kw =~ /^$re$/;
                }
                push @keys, $kw;
            }
            $s->{rows} = [ map { { keyword => $_ } } @keys ];
            return 1;
        }
        return 1;
    }
    sub fetchrow_hashref { my $s=shift; return undef if $s->{i} >= @{$s->{rows}}; return $s->{rows}[$s->{i}++]; }
    sub fetchrow_array   { my $s=shift; return () if $s->{i} >= @{$s->{rows}}; my $r=$s->{rows}[$s->{i}++]; return ($r->{keyword}); }
    sub err { undef }
    sub rows { $_[0]{affected} }
    sub finish { 1 }

    package FakeDBH687;
    sub new { bless { store => ($_[1] // {}) }, $_[0] }
    sub prepare { my ($self,$sql)=@_; return FakeSTH687->new(sql=>$sql, store=>$self->{store}); }
    sub ping { 1 }
}

my @sent;   # capture botNotice + botPrivmsg
sub _reset_687 { @sent = () }

sub mkctx_687 {
    my (%o) = @_;
    my $store = $o{store} // {};
    my $bot = MockBot->new(
        dbh => FakeDBH687->new($store),
        channels => { lc($o{channel} // '#test') => FakeChan687->new(42) },
    );
    my $ctx = Mediabot::Context->new(
        bot => $bot, nick => $o{nick} // 'alice',
        channel => $o{channel}, message => $o{message} // '',
        args => $o{args} // [],
    );
    # user identifié optionnel
    if ($o{user}) { $bot->{_forced_user} = $o{user}; }
    return ($bot, $ctx, $store);
}

return sub {
    my ($assert) = @_;

    # capture déterministe de botNotice + botPrivmsg (package Mediabot::UserCommands)
    no warnings 'redefine';
    local *Mediabot::UserCommands::botNotice  = sub { push @sent, { to=>$_[1], text=>$_[2] } };
    local *Mediabot::UserCommands::botPrivmsg = sub { push @sent, { to=>$_[1], text=>$_[2] } };
    use warnings 'redefine';

    my %store;   # store partagé entre les sous-cas (persistance simulée)

    # -------------------------------------------------------------------------
    # 1. learn : enregistre un factoid.
    # -------------------------------------------------------------------------
    {
        _reset_687();
        my ($bot,$ctx) = mkctx_687(store=>\%store, nick=>'alice', channel=>'#test',
            args=>['coffee','=','black','gold','of','the','morning']);
        Mediabot::UserCommands::mbLearn_ctx($ctx);
        my $j = join("\n", map { $_->{text} } @sent);
        $assert->like($j, qr/Learned 'coffee'/, 'learn confirme l\'enregistrement');
        $assert->ok(exists $store{"42\0coffee"}, 'factoid stocké dans (channel,keyword)');
        $assert->like($store{"42\0coffee"}{value}, qr/black gold/, 'valeur stockée');
    }

    # -------------------------------------------------------------------------
    # 2. whatis : rappelle le factoid sur le canal + incrémente hits.
    # -------------------------------------------------------------------------
    {
        _reset_687();
        my ($bot,$ctx) = mkctx_687(store=>\%store, nick=>'bob', channel=>'#test',
            args=>['coffee']);
        Mediabot::UserCommands::mbWhatis_ctx($ctx);
        my @pm = grep { $_->{to} eq '#test' } @sent;
        my $j = join("\n", map { $_->{text} } @pm);
        $assert->like($j, qr/coffee: black gold/, 'whatis renvoie la valeur sur le canal');
        $assert->is($store{"42\0coffee"}{hits}, 1, 'hits incrémenté');
    }

    # -------------------------------------------------------------------------
    # 3. whatis inconnu -> invite à apprendre.
    # -------------------------------------------------------------------------
    {
        _reset_687();
        my ($bot,$ctx) = mkctx_687(store=>\%store, nick=>'bob', channel=>'#test',
            args=>['tea']);
        Mediabot::UserCommands::mbWhatis_ctx($ctx);
        my $j = join("\n", map { $_->{text} } @sent);
        $assert->like($j, qr/don't know 'tea'/, 'whatis inconnu -> invite à learn');
    }

    # -------------------------------------------------------------------------
    # 4. learn met à jour (UPSERT) sans changer l'auteur.
    # -------------------------------------------------------------------------
    {
        _reset_687();
        my ($bot,$ctx) = mkctx_687(store=>\%store, nick=>'carol', channel=>'#test',
            args=>['coffee','=','fuel']);
        Mediabot::UserCommands::mbLearn_ctx($ctx);
        $assert->is($store{"42\0coffee"}{value}, 'fuel', 'valeur mise à jour');
        $assert->is($store{"42\0coffee"}{created_by_nick}, 'alice', 'auteur original conservé');
    }

    # -------------------------------------------------------------------------
    # 5. factoids : liste les clés du canal.
    # -------------------------------------------------------------------------
    {
        _reset_687();
        $store{"42\0perl"} = { value=>'a language', created_by_nick=>'alice', hits=>0 };
        my ($bot,$ctx) = mkctx_687(store=>\%store, nick=>'alice', channel=>'#test', args=>[]);
        Mediabot::UserCommands::mbFactoids_ctx($ctx);
        my $j = join("\n", map { $_->{text} } @sent);
        $assert->like($j, qr/coffee/, 'liste contient coffee');
        $assert->like($j, qr/perl/,   'liste contient perl');
    }

    # -------------------------------------------------------------------------
    # 6. forget par l'auteur : autorisé.
    # -------------------------------------------------------------------------
    {
        _reset_687();
        my ($bot,$ctx) = mkctx_687(store=>\%store, nick=>'alice', channel=>'#test',
            args=>['coffee']);
        Mediabot::UserCommands::mbForget_ctx($ctx);
        my $j = join("\n", map { $_->{text} } @sent);
        $assert->like($j, qr/Forgot 'coffee'/, 'auteur peut forget');
        $assert->ok(!exists $store{"42\0coffee"}, 'factoid supprimé');
    }

    # -------------------------------------------------------------------------
    # 7. forget par un non-auteur non-op : refusé.
    # -------------------------------------------------------------------------
    {
        _reset_687();
        $store{"42\0rules"} = { value=>'be nice', created_by_nick=>'alice', hits=>0 };
        my ($bot,$ctx) = mkctx_687(store=>\%store, nick=>'mallory', channel=>'#test',
            args=>['rules']);
        Mediabot::UserCommands::mbForget_ctx($ctx);
        my $j = join("\n", map { $_->{text} } @sent);
        $assert->like($j, qr/only the author or a channel op/, 'non-auteur refusé');
        $assert->ok(exists $store{"42\0rules"}, 'factoid conservé après refus');
    }

    # -------------------------------------------------------------------------
    # 8. Refus en privé (pas de canal).
    # -------------------------------------------------------------------------
    {
        _reset_687();
        my ($bot,$ctx) = mkctx_687(store=>\%store, nick=>'alice', channel=>undef,
            args=>['x','=','y']);
        Mediabot::UserCommands::mbLearn_ctx($ctx);
        my $j = join("\n", map { $_->{text} } @sent);
        $assert->like($j, qr/use it in a channel/, 'learn refusé en privé');
    }

    # -------------------------------------------------------------------------
    # 9. Intégration : export, dispatch, help, schéma, migrations, chanset.
    # -------------------------------------------------------------------------
    {
        my $uc = _slurp_687(File::Spec->catfile('.', 'Mediabot', 'UserCommands.pm'));
        $assert->like($uc, qr/^\s*mbLearn_ctx\s*$/m, 'mbLearn_ctx exporté');
        $assert->like($uc, qr/^\s*mbWhatis_ctx\s*$/m, 'mbWhatis_ctx exporté');

        my $med = _slurp_687(File::Spec->catfile('.', 'Mediabot', 'Mediabot.pm'));
        $assert->like($med,
            qr/learn\s*=>\s*sub\s*\{\s*my \(\$ctx\) = \@_;\s*mbLearn_ctx/,
            'learn dans le registre');
        $assert->like($med,
            qr/whatis\s*=>\s*sub\s*\{\s*my \(\$ctx\) = \@_;\s*mbWhatis_ctx/,
            'whatis dans le registre');
        $assert->like($med, qr/^learn\|learn <keyword>/m, 'learn documenté');
        $assert->like($med, qr/\+Factoids\b/, 'chanset Factoids documenté');

        my $sql = _slurp_687(File::Spec->catfile('.', 'install', 'mediabot.sql'));
        $assert->like($sql, qr/CREATE TABLE `FACTOID`/, 'table FACTOID dans le schéma');
        $assert->like($sql, qr/UNIQUE KEY `uniq_factoid_channel_keyword`/, 'unicité (channel,keyword)');
        $assert->like($sql, qr/\(19,\s*'Factoids'\)/, 'chanset Factoids (id 19)');
        $assert->like($sql, qr/fk_factoid_channel/, 'FK vers CHANNEL');

        for my $m ('20260707_factoid.sql','20260707_factoids_chanset.sql') {
            $assert->ok(-f File::Spec->catfile('.','install','migrations',$m), "migration $m présente");
        }
        my $db = _slurp_687(File::Spec->catfile('.', 'docs', 'DB_MIGRATIONS.md'));
        $assert->like($db, qr/20260707_factoid\.sql/, 'table migration déclarée');
        $assert->like($db, qr/20260707_factoids_chanset\.sql/, 'chanset migration déclarée');
    }
};

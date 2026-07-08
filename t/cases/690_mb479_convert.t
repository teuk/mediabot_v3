# t/cases/690_mb479_convert.t
# =============================================================================
# mb479 — Conversion d'unités hors-ligne (!convert).
#
# Teste Mediabot::Convert (logique pure) et le câblage handler/dispatch/help.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;
use Mediabot::Convert;

sub _slurp_690 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

# tolérance flottante : on vérifie la valeur numérique extraite du résultat
sub _num_of {
    my ($str) = @_;
    return undef unless defined $str && $str =~ /=\s*([-+]?\d*\.?\d+(?:[eE][-+]?\d+)?)/;
    return $1 + 0;
}
sub _approx {
    my ($assert, $got, $exp, $tol, $label) = @_;
    $tol //= 0.01;
    my $ok = (defined $got && abs($got - $exp) <= $tol) ? 1 : 0;
    $assert->ok($ok, "$label (got=" . (defined $got ? $got : 'undef') . " exp~$exp)");
}

return sub {
    my ($assert) = @_;

    # -------------------------------------------------------------------------
    # 1. Conversions correctes (familles variées).
    # -------------------------------------------------------------------------
    {
        my ($ok,$r) = Mediabot::Convert::convert(100,'km','mi');
        $assert->is($ok, 1, '100 km->mi ok');
        _approx($assert, _num_of($r), 62.1371, 0.01, '100 km = ~62.14 mi');
    }
    {
        my ($ok,$r) = Mediabot::Convert::convert(100,'c','f');
        _approx($assert, _num_of($r), 212, 0.001, '100 C = 212 F');
    }
    {
        my ($ok,$r) = Mediabot::Convert::convert(32,'f','c');
        _approx($assert, _num_of($r), 0, 0.001, '32 F = 0 C');
    }
    {
        my ($ok,$r) = Mediabot::Convert::convert(0,'c','k');
        _approx($assert, _num_of($r), 273.15, 0.001, '0 C = 273.15 K');
    }
    {
        my ($ok,$r) = Mediabot::Convert::convert(1,'kg','lb');
        _approx($assert, _num_of($r), 2.20462, 0.001, '1 kg = ~2.205 lb');
    }
    {
        my ($ok,$r) = Mediabot::Convert::convert(1,'gb','mib');
        _approx($assert, _num_of($r), 953.674, 0.01, '1 GB = ~953.67 MiB');
    }
    {
        my ($ok,$r) = Mediabot::Convert::convert(1,'l','ml');
        _approx($assert, _num_of($r), 1000, 0.001, '1 L = 1000 ml');
    }

    # aliases / casse / symboles
    {
        my ($ok,$r) = Mediabot::Convert::convert(1,'Mile','Kilometers');
        $assert->is($ok, 1, 'alias longs + casse acceptés');
        _approx($assert, _num_of($r), 1.60934, 0.001, '1 mile = ~1.609 km');
    }

    # -------------------------------------------------------------------------
    # 2. Erreurs propres.
    # -------------------------------------------------------------------------
    {
        my ($ok,$r) = Mediabot::Convert::convert(5,'km','kg');
        $assert->is($ok, 0, 'familles différentes -> erreur');
        $assert->like($r, qr/different families/, 'message familles');
    }
    {
        my ($ok,$r) = Mediabot::Convert::convert(1,'foo','m');
        $assert->is($ok, 0, 'unité inconnue -> erreur');
        $assert->like($r, qr/unknown unit/, 'message unité inconnue');
    }
    {
        my ($ok,$r) = Mediabot::Convert::convert('abc','km','mi');
        $assert->is($ok, 0, 'valeur non numérique -> erreur');
    }
    {
        my ($ok,$r) = Mediabot::Convert::convert(20,'c','m');
        $assert->is($ok, 0, 'temp vers non-temp -> erreur');
    }

    # valeur négative et décimale
    {
        my ($ok,$r) = Mediabot::Convert::convert(-40,'c','f');
        _approx($assert, _num_of($r), -40, 0.001, '-40 C = -40 F');
    }

    # -------------------------------------------------------------------------
    # 3. Handler mbConvert_ctx via MockBot (capture via Context->reply).
    # -------------------------------------------------------------------------
    {
        require MockBot;
        require Mediabot::Context;
        require Mediabot::DBCommands;

        my @replies;
        no warnings 'redefine';
        local *Mediabot::Context::reply         = sub { push @replies, { pub=>1, text=>$_[1] } };
        local *Mediabot::Context::reply_private = sub { push @replies, { pub=>0, text=>$_[1] } };
        use warnings 'redefine';

        my $bot = MockBot->new;
        # cas OK : "100 km to mi" (séparateur 'to' toléré)
        my $ctx = Mediabot::Context->new(bot=>$bot, nick=>'alice', channel=>'#test',
            message=>'convert 100 km to mi', args=>['100','km','to','mi']);
        Mediabot::DBCommands::mbConvert_ctx($ctx);
        my ($pub) = grep { $_->{pub} } @replies;
        $assert->ok($pub && $pub->{text} =~ /100 km = 62/, 'handler: 100 km to mi -> réponse publique');

        # cas syntaxe insuffisante -> privé
        @replies = ();
        my $ctx2 = Mediabot::Context->new(bot=>$bot, nick=>'alice', channel=>'#test',
            message=>'convert 100', args=>['100']);
        Mediabot::DBCommands::mbConvert_ctx($ctx2);
        my ($priv) = grep { !$_->{pub} } @replies;
        $assert->ok($priv && $priv->{text} =~ /Syntax: convert/, 'handler: args manquants -> syntaxe en privé');

        # cas erreur (familles) -> privé
        @replies = ();
        my $ctx3 = Mediabot::Context->new(bot=>$bot, nick=>'alice', channel=>'#test',
            message=>'convert 5 km kg', args=>['5','km','kg']);
        Mediabot::DBCommands::mbConvert_ctx($ctx3);
        my ($e) = grep { !$_->{pub} } @replies;
        $assert->ok($e && $e->{text} =~ /different families/, 'handler: erreur -> privé');
    }

    # -------------------------------------------------------------------------
    # 4. Intégration : export, dispatch, help.
    # -------------------------------------------------------------------------
    {
        my $db = _slurp_690(File::Spec->catfile('.', 'Mediabot', 'DBCommands.pm'));
        $assert->like($db, qr/^\s*mbConvert_ctx\s*$/m, 'mbConvert_ctx exporté');
        my $med = _slurp_690(File::Spec->catfile('.', 'Mediabot', 'Mediabot.pm'));
        $assert->like($med, qr/convert\s*=>\s*sub\s*\{\s*mbConvert_ctx/, 'convert dans le dispatch');
        $assert->like($med, qr/^convert\|convert <value> <from> <to>/m, 'convert documenté');
        $assert->ok(-f File::Spec->catfile('.', 'Mediabot', 'Convert.pm'), 'module Convert.pm présent');
    }
};

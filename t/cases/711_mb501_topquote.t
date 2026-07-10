# t/cases/711_mb501_topquote.t
# =============================================================================
# mb501 — !topquote / !halloffame : le hall of fame des quotes les plus
# rappelées du canal, classées par un compteur `hits` incrémenté à chaque
# affichage d'une quote (par id via !quote view, ou aléatoire via !quote rand).
#
#   [1] mbTopQuote_ctx : classement par hits, rendu, limite, cas vide, garde ;
#   [2] _quote_bump_hits : incrément best-effort (tolérant si colonne absente) ;
#   [3] incréments câblés dans mbQuoteView + mbQuoteRand ;
#   [4] intégration : dispatch (topquote+halloffame), help, catégorie, colonne
#       schéma, migration déclarée.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

use Mediabot::Quotes;

sub _slurp_711 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }
sub _strip { my ($s)=@_; $s =~ s/\x03\d{0,2}(?:,\d{1,2})?|\x0f|\x02//g; return $s; }

{
    package STHok711;   # schéma avec hits
    sub new { my ($c,%a)=@_; bless { %a, bumped=>$a{bumped} }, $c }
    sub execute { my ($s,@b)=@_; push @{$s->{cap}}, [@b] if $s->{cap}; 1 }
    sub fetchall_arrayref {
        return [
            { id=>7, txt=>'la meilleure blague', hits=>42, author=>'alice' },
            { id=>3, txt=>'un classique',        hits=>17, author=>'bob'   },
            { id=>1, txt=>'le premier',          hits=>1,  author=>'carol' },
        ];
    }
    sub finish { 1 }
    package DBHok711;
    sub new { bless { cap=>$_[1] }, $_[0] }
    sub prepare { STHok711->new(sql=>$_[1], cap=>$_[0]->{cap}) }

    package STHbump711;  # capture l'UPDATE hits
    sub new { my ($c,%a)=@_; bless { %a }, $c }
    sub execute { my ($s,@b)=@_; push @{$s->{cap}}, { sql=>$s->{sql}, bind=>[@b] }; 1 }
    sub finish { 1 }
    package DBHbump711;
    sub new { bless { cap=>$_[1] }, $_[0] }
    sub prepare { STHbump711->new(sql=>$_[1], cap=>$_[0]->{cap}) }
}

my @SENT;

return sub {
    my ($assert) = @_;

    no warnings 'redefine';
    no warnings 'once';
    local *Mediabot::Quotes::botPrivmsg = sub { push @SENT, $_[2]; 1 };
    local *Mediabot::Quotes::botNotice  = sub { push @SENT, "NOTICE: $_[2]"; 1 };

    # --- [1] classement + rendu --------------------------------------------
    {
        @SENT = ();
        my $self = { dbh => DBHok711->new([]) };
        Mediabot::Quotes::mbTopQuote_ctx($self, 'tester', '#teuk', undef);
        my $all = join("\n", map { _strip($_) } @SENT);
        $assert->like($all, qr/Hall of fame #teuk/, '[1] titre hall of fame');
        $assert->like($all, qr/1\. \[id:7\] <alice> la meilleure blague \(42 recalls\)/, '[1] #1 avec hits');
        $assert->like($all, qr/3\. \[id:1\] <carol> le premier \(1 recall\)/, '[1] singulier "1 recall"');
    }

    # --- [1b] limite bornée + garde canal ----------------------------------
    {
        @SENT = ();
        my @cap;
        my $self = { dbh => DBHok711->new(\@cap) };
        Mediabot::Quotes::mbTopQuote_ctx($self, 'tester', '#teuk', '99');   # >10 -> 10
        my ($bind) = grep { @$_ == 2 } @cap;   # (channel, limit)
        $assert->is($bind->[1], 10, '[1b] limite plafonnée à 10');

        @SENT = ();
        Mediabot::Quotes::mbTopQuote_ctx($self, 'tester', undef, undef);   # hors canal
        $assert->like(join("\n",@SENT), qr/NOTICE:.*use it in a channel/, '[1b] refus hors canal');
    }

    # --- [1c] cas vide ------------------------------------------------------
    {
        @SENT = ();
        my $empty = { dbh => bless({}, 'EmptyDBH711') };
        {
            no strict 'refs';
            *EmptyDBH711::prepare = sub { bless {}, 'EmptySTH711' };
            *EmptySTH711::execute = sub { 1 };
            *EmptySTH711::fetchall_arrayref = sub { [] };
            *EmptySTH711::finish = sub { 1 };
        }
        Mediabot::Quotes::mbTopQuote_ctx($empty, 'tester', '#teuk', undef);
        $assert->like(join("\n",@SENT), qr/No quotes yet/, '[1c] message si aucune quote');
    }

    # --- [2] _quote_bump_hits best-effort ----------------------------------
    {
        my @cap;
        my $self = { dbh => DBHbump711->new(\@cap) };
        Mediabot::Quotes::_quote_bump_hits($self, 7);
        $assert->ok(@cap == 1, '[2] un UPDATE émis');
        $assert->like($cap[0]{sql}, qr/UPDATE QUOTES SET hits = hits \+ 1 WHERE id_quotes = \?/,
            '[2] incrément SQL correct');
        $assert->is($cap[0]{bind}[0], 7, '[2] bind id_quotes');

        # entrées invalides : pas d'UPDATE
        @cap = ();
        Mediabot::Quotes::_quote_bump_hits($self, undef);
        Mediabot::Quotes::_quote_bump_hits($self, 'abc');
        $assert->is(scalar(@cap), 0, '[2] pas d\'UPDATE pour id invalide');

        # tolérant : un dbh qui explose ne fait pas planter (eval interne)
        my $boom = { dbh => bless({}, 'BoomDBH711') };
        { no strict 'refs'; *BoomDBH711::prepare = sub { die "no such column: hits" }; }
        my $ok = eval { Mediabot::Quotes::_quote_bump_hits($boom, 5); 1 };
        $assert->ok($ok, '[2] tolérant si la colonne hits manque (pré-migration)');
    }

    # --- [3][4] câblage + intégration --------------------------------------
    {
        my $q = _slurp_711(File::Spec->catfile('.', 'Mediabot', 'Quotes.pm'));
        $assert->like($q, qr/_quote_bump_hits\(\$self, \$id_quotes\)/, '[3] bump dans mbQuoteView');
        $assert->like($q, qr/_quote_bump_hits\(\$self, \$ref->\{id_quotes\}\)/, '[3] bump dans mbQuoteRand');
        $assert->like($q, qr/^\s*mbTopQuote_ctx\s*$/m, '[4] mbTopQuote_ctx exporté');

        my $med = _slurp_711(File::Spec->catfile('.', 'Mediabot', 'Mediabot.pm'));
        $assert->like($med, qr/topquote\s*=>\s*sub/, '[4] topquote au dispatch');
        $assert->like($med, qr/halloffame\s*=>\s*sub/, '[4] alias halloffame au dispatch');
        $assert->like($med, qr/^topquote\|topquote \[n\]\|public/m, '[4] topquote documenté');
        $assert->like($med, qr/topquote\s*=>\s*'ai_fun'/, '[4] topquote catégorisé');

        my $sql = _slurp_711(File::Spec->catfile('.', 'install', 'mediabot.sql'));
        $assert->like($sql, qr/`hits`\s+BIGINT UNSIGNED NOT NULL DEFAULT 0/, '[4] colonne hits au schéma QUOTES');

        $assert->ok(-f File::Spec->catfile('.','install','migrations','20260710_quotes_hits.sql'),
            '[4] migration présente');
        my $db = _slurp_711(File::Spec->catfile('.', 'docs', 'DB_MIGRATIONS.md'));
        $assert->like($db, qr/20260710_quotes_hits\.sql/, '[4] migration déclarée');
    }
};

#!/usr/bin/perl
# =============================================================================
#  Mediabot v3 - Framework de test des commandes IRC
#  Usage : perl t/test_commands.pl [--verbose] [--filter <pattern>]
#           [--nick <nick>] [--host <host>] [--channel <chan>]
#           [--botnick <botnick>] [--cmdchar <char>]
# =============================================================================

BEGIN {
    require FindBin;
    unshift @INC, "$FindBin::Bin/lib";  # t/lib/
    unshift @INC, "$FindBin::Bin/..";   # racine projet
}

use strict;
use warnings;
use MockBot;
use MockIRC;
use MockMessage;
use MockUser;
use Getopt::Long;
use File::Basename;
use POSIX qw(strftime);

binmode(STDOUT, ':encoding(UTF-8)');

# Mediabot.pm charge "use diagnostics" qui formate les warnings longuement.
# On le desactive juste avant chaque execution de closure (apres chargement).


# ---- Options CLI ------------------------------------------------------------
my $opt_verbose = 0;
my $opt_filter  = '';
my $opt_nick    = 'testuser';
my $opt_host    = 'test.host';
my $opt_channel = '#test';
my $opt_botnick = 'mediabot';
my $opt_cmdchar = '!';
GetOptions(
    'verbose|v'   => \$opt_verbose,
    'filter|f=s'  => \$opt_filter,
    'nick|n=s'    => \$opt_nick,
    'host=s'      => \$opt_host,
    'channel|c=s' => \$opt_channel,
    'botnick|b=s' => \$opt_botnick,
    'cmdchar=s'   => \$opt_cmdchar,
) or die <<USAGE;
Usage: $0 [options]
  --verbose, -v          Afficher chaque test [OK]/[FAIL]
  --filter,  -f <pat>    Lancer uniquement les fichiers matching <pat>
  --nick,    -n <nick>   Pseudo par defaut (defaut: testuser)
  --host        <host>   Hostname par defaut (defaut: test.host)
  --channel, -c <chan>   Canal par defaut   (defaut: #test)
  --botnick, -b <name>   Pseudo du bot      (defaut: mediabot)
  --cmdchar     <char>   Caractere de commande (defaut: !)
USAGE

# ---- Classe d'assertion -----------------------------------------------------
package Assert;

sub new {
    my ($class, %args) = @_;
    return bless { verbose => $args{verbose} // 0, pass => 0, fail => 0 }, $class;
}

sub _result {
    my ($self, $ok, $desc, $extra) = @_;
    if ($ok) {
        $self->{pass}++;
        print "  [OK] $desc\n" if $self->{verbose};
    } else {
        $self->{fail}++;
        my $info = $extra ? " ($extra)" : '';
        print "  [FAIL] $desc$info\n";
    }
}

sub ok {
    my ($self, $val, $desc) = @_;
    $self->_result($val ? 1 : 0, $desc // '(unnamed)',
        $val ? '' : 'got: ' . (defined $val ? "'$val'" : 'undef'));
}

sub is {
    my ($self, $got, $expected, $desc) = @_;
    my $ok = defined $got && defined $expected && $got eq $expected;
    $self->_result($ok, $desc // '(unnamed)',
        $ok ? '' : 'got: ' . (defined $got ? "'$got'" : 'undef') . " expected: '$expected'");
}

sub isnt {
    my ($self, $got, $unexpected, $desc) = @_;
    my $ok = !defined $got || $got ne $unexpected;
    $self->_result($ok, $desc // '(unnamed)',
        $ok ? '' : "got unexpected: '$got'");
}

sub like {
    my ($self, $got, $pattern, $desc) = @_;
    my $ok = defined $got && $got =~ /$pattern/;
    $self->_result($ok, $desc // '(unnamed)',
        $ok ? '' : 'got: ' . (defined $got ? "'$got'" : 'undef') . " pattern: $pattern");
}

sub unlike {
    my ($self, $got, $pattern, $desc) = @_;
    my $ok = !defined $got || $got !~ /$pattern/;
    $self->_result($ok, $desc // '(unnamed)',
        $ok ? '' : "unexpectedly matched '$pattern'");
}

sub pass { $_[0]->_result(1, $_[1] // '(pass)') }
sub fail { $_[0]->_result(0, $_[1] // '(fail)') }

sub total  { $_[0]->{pass} + $_[0]->{fail} }
sub passed { $_[0]->{pass} }
sub failed { $_[0]->{fail} }

# ---- Runner -----------------------------------------------------------------
package main;

sub make_bot {
    my (%args) = @_;
    my $default_nick = $opt_nick;
    my $user = $args{user} // MockUser->new(nick => $default_nick, level => 'Owner', auth => 1);
    return MockBot->new(
        mock_user   => $user,
        debug_level => $args{debug_level} // -1,
        botnick     => $args{botnick}     // $opt_botnick,
        cmd_char    => $args{cmd_char}    // $opt_cmdchar,
    );
}

sub make_msg_chan {
    my (%args) = @_;
    return MockMessage->from_channel(
        prefix  => $args{prefix}  // "$opt_nick!$opt_nick\@$opt_host",
        channel => $args{channel} // $opt_channel,
        text    => $args{text}    // '',
    );
}

sub make_msg_priv {
    my (%args) = @_;
    return MockMessage->from_private(
        prefix => $args{prefix} // "$opt_nick!$opt_nick\@$opt_host",
        text   => $args{text}   // '',
    );
}

# ---- Chargement des cas de test ---------------------------------------------

my $assert   = Assert->new(verbose => $opt_verbose);
my $ts_start = time();

# Chemin absolu vers t/cases/ — indépendant du CWD
my $cases_dir  = "$FindBin::Bin/cases";
my @test_files = sort glob("$cases_dir/*.t");

if ($opt_filter) {
    @test_files = grep { basename($_) =~ /$opt_filter/i } @test_files;
}

if (!@test_files) {
    print "Aucun fichier de test trouve dans $cases_dir\n";
    exit 1;
}

for my $file (@test_files) {
    my $name = basename($file);
    print "\n[ $name ]\n";

    my $code = do $file;
    if ($@) {
        print "  ERREUR de chargement : $@\n";
        $assert->fail("$name: chargement");
        next;
    }
    if (ref $code eq 'CODE') {
        disable diagnostics if $diagnostics::VERSION;
        local $SIG{__WARN__} = sub {
            my $w = shift;
            return if $w =~ /uninitialized|redefine|prototype|only once/i;
            warn $w;
        };
        $code->($assert, \&make_bot, \&make_msg_chan, \&make_msg_priv);
    } else {
        print "  (pas de sous-routine retournee, skip)\n";
    }
}

# ---- Resume -----------------------------------------------------------------

my $elapsed = time() - $ts_start;
my $total   = $assert->total;
my $passed  = $assert->passed;
my $failed  = $assert->failed;

print "\n" . "=" x 60 . "\n";
if ($failed == 0) {
    printf "PASSED : %d/%d  (%ds)\n", $passed, $total, $elapsed;
} else {
    printf "FAILED : %d/%d  (%d passed)  (%ds)\n", $failed, $total, $passed, $elapsed;
}
print "=" x 60 . "\n";

exit($failed > 0 ? 1 : 0);